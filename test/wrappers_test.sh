#!/usr/bin/env bash
# Runs ./tf, ./k and ./h in a scratch git repository, against stand-ins for terraform, gcloud, kubectl
# and helm that only write down how they were called. Checks the environment word, the profile and
# kubeconfig each environment gets, and ./tf's guard on commands that change an environment.
# Part of ./check; touches no cluster, no cloud and no real repository.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failed=0
expect() { # expect "<what>" <command...>: prints ok or FAIL
  local what="$1"
  shift
  if "$@"; then printf 'ok    %s\n' "$what"; else printf 'FAIL  %s\n' "$what"; failed=1; fi
}

# Stand-ins: one line per call in $LOG, with the profile and kubeconfig they saw.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/stand-in" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0") $* | profile=${CLOUDSDK_ACTIVE_CONFIG_NAME:-} kubeconfig=${KUBECONFIG:-}" \
  "admin=${TF_VAR_admin_cidr:-} allowed=${TF_VAR_allowed_cidrs:-}" >> "$LOG"
case "$(basename "$0") $*" in
  "gcloud config config-helper"*) echo "not-a-real-token" ;;
  "gcloud container clusters get-credentials"*) echo "fake" > "$KUBECONFIG" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/stand-in"
for tool in terraform gcloud kubectl helm; do ln -s "$tmp/bin/stand-in" "$tmp/bin/$tool"; done

# A scratch repository with the wrappers and a bare "GitHub" to fetch from.
work="$tmp/work"
mkdir -p "$work/lib" "$work/envs/main/cluster" "$work/envs/main/edge" "$work/envs/production/cluster" "$work/envs/production/edge"
cp "$here/tf" "$here/k" "$here/h" "$work/"
cp "$here/lib/env.sh" "$work/lib/"
printf 'tfplan*\n.kube/\naccess.tfvars\n' > "$work/.gitignore"
# Who may connect, kept off GitHub: ignored by git, so it never makes the checkout look changed.
printf 'admin_cidr    = "198.51.100.9/32"\nallowed_cidrs = ["198.51.100.9/32"]\n' > "$work/access.tfvars"
g() { git -C "$work" -c user.name=test -c user.email=test@example.invalid "$@"; }
git init -q --bare "$tmp/origin.git"
g init -q -b main
g add -A
g commit -q -m start
g remote add origin "$tmp/origin.git"
g push -q origin main main:production
g switch -q -c feature

# run <name> <command...>: runs in the scratch repository with the stand-ins first on the PATH.
run() {
  local name="$1"
  shift
  : > "$tmp/$name.log"
  (cd "$work" && env PATH="$tmp/bin:$PATH" LOG="$tmp/$name.log" "$@") > "$tmp/$name.out" 2>&1
  echo $? > "$tmp/$name.status"
}
status_is() { [ "$(cat "$tmp/$1.status")" = "$2" ]; }
called() { grep -qF -- "$2" "$tmp/$1.log"; }                  # called <run> <text in the call log>
nothing_called() { [ ! -s "$tmp/$1.log" ]; }
said() { grep -qF -- "$2" "$tmp/$1.out"; }                    # said <run> <text in the output>
refused() { status_is "$1" 3 && ! called "$1" "terraform " && said "$1" "$2"; }

# The environment and layer words.
run noargs ./tf
run badenv ./tf prod cluster plan
run badlayer ./tf main network plan
expect "tf with no words: usage, nothing run" bash -c "[ \"\$(cat '$tmp/noargs.status')\" = 2 ] && [ ! -s '$tmp/noargs.log' ]"
expect "tf with no words: says main or production" said noargs "main or production"
expect "tf prod: refused, nothing run" bash -c "[ \"\$(cat '$tmp/badenv.status')\" = 2 ] && [ ! -s '$tmp/badenv.log' ]"
expect "tf main network: says cluster or edge, nothing run" bash -c "[ \"\$(cat '$tmp/badlayer.status')\" = 2 ] && [ ! -s '$tmp/badlayer.log' ] && grep -qF 'cluster or edge' '$tmp/badlayer.out'"

run bare ./tf main cluster
expect "tf main cluster with no terraform words: runs terraform (its help)" \
  called bare "terraform -chdir=$work/envs/main/cluster | profile=gke-lab-main"

# Read-only commands run on any branch (here: feature), each with its own profile and folder.
run planmain ./tf main cluster plan
run planprod ./tf production edge plan
run statelist ./tf main cluster state list
expect "plan main cluster from a short-lived branch: runs in envs/main/cluster as gke-lab-main" \
  called planmain "terraform -chdir=$work/envs/main/cluster plan | profile=gke-lab-main"
expect "plan production edge from a short-lived branch: runs in envs/production/edge as gke-lab" \
  called planprod "terraform -chdir=$work/envs/production/edge plan | profile=gke-lab"
expect "state list from a short-lived branch: runs" called statelist "terraform -chdir=$work/envs/main/cluster state list"

# Who may connect comes from access.tfvars, which git ignores, as TF_VAR_ variables.
expect "plan: access.tfvars reaches terraform as TF_VAR_admin_cidr and TF_VAR_allowed_cidrs" \
  called planmain 'admin=198.51.100.9/32 allowed=["198.51.100.9/32"]'
mv "$work/access.tfvars" "$tmp/access.tfvars"
run planno ./tf main cluster plan
run initno ./tf main cluster init
expect "plan without access.tfvars: refused, names access.tfvars.example" refused planno "access.tfvars.example"
expect "init without access.tfvars: runs (it needs no values)" called initno "terraform -chdir=$work/envs/main/cluster init"
printf 'admin_cidr = "198.51.100.9/32"\n' > "$work/access.tfvars"
run planhalf ./tf main cluster plan
expect "access.tfvars without allowed_cidrs: refused" refused planhalf "allowed_cidrs"
printf 'admin_cidr = "198.51.100.9/32"\nadmin_cidr = "198.51.100.10/32"\nallowed_cidrs = ["198.51.100.9/32"]\n' > "$work/access.tfvars"
run plantwice ./tf main cluster plan
expect "access.tfvars with admin_cidr twice: refused" refused plantwice "one line each"
mv "$tmp/access.tfvars" "$work/access.tfvars"

# Changing commands: only from the environment's branch, clean, identical to GitHub's copy.
run applyfeature ./tf main cluster apply
run statemv ./tf main cluster state mv a b
expect "apply from a short-lived branch: refused, names the branch" refused applyfeature "main branch"
expect "state mv from a short-lived branch: refused" refused statemv "main branch"
g switch -q main
echo scratch > "$work/scratch.txt"
run applydirty ./tf main cluster apply
rm "$work/scratch.txt"
expect "apply with an uncommitted file: refused" refused applydirty "uncommitted"
echo change > "$work/change.txt"
g add change.txt
g commit -q -m "not pushed"
run applyahead ./tf main cluster apply
expect "apply with a commit GitHub does not have: refused" refused applyahead "GitHub"
g push -q origin main
run applyok ./tf main cluster apply
expect "apply on main, clean, identical to GitHub: runs in envs/main/cluster as gke-lab-main" \
  called applyok "terraform -chdir=$work/envs/main/cluster apply | profile=gke-lab-main"
expect "apply on main with access.tfvars in place (ignored by git): gets who may connect" called applyok "admin=198.51.100.9/32"
mv "$work/access.tfvars" "$tmp/access.tfvars"
run destroyno ./tf main cluster destroy
mv "$tmp/access.tfvars" "$work/access.tfvars"
expect "destroy on main without access.tfvars: refused, names access.tfvars.example" refused destroyno "access.tfvars.example"
run applyprod ./tf production cluster apply
expect "apply production from main: refused, names the production branch" refused applyprod "production branch"

# A saved plan holds the configuration it was made from, not what is on disk when it is applied:
# it may be applied only on the commit it was made from, with nothing uncommitted at the time.
g switch -q feature
run planfeature ./tf main cluster plan -out=tfplan-feature
touch "$work/envs/main/cluster/tfplan-feature"           # the stand-in terraform writes no plan file
g switch -q main
run applyfeatureplan ./tf main cluster apply tfplan-feature
expect "a plan saved on a short-lived branch: refused on main" refused applyfeatureplan "saved plan"
run planmain2 ./tf main cluster plan -out=tfplan-main
touch "$work/envs/main/cluster/tfplan-main"
run applymainplan ./tf main cluster apply tfplan-main
expect "a plan saved on main, applied on main: runs" \
  called applymainplan "terraform -chdir=$work/envs/main/cluster apply tfplan-main | profile=gke-lab-main"
echo scratch > "$work/scratch.txt"
run plandirty ./tf main cluster plan -out=tfplan-dirty
rm "$work/scratch.txt"
touch "$work/envs/main/cluster/tfplan-dirty"
run applydirtyplan ./tf main cluster apply tfplan-dirty
expect "a plan saved with uncommitted changes: refused" refused applydirtyplan "saved plan"
# Values from outside the branch.
run applyvar ./tf main cluster apply -var=admin_cidr=0.0.0.0/0
run applyvarfile ./tf main cluster apply -var-file=/tmp/other.tfvars
expect "apply with -var: refused" refused applyvar "-var"
expect "apply with -var-file: refused" refused applyvarfile "-var"

# kubectl and Helm.
run knoenv ./k get pods
run kmain ./k main get pods
run hprod ./h production list
expect "k without an environment: usage, nothing run" bash -c "[ \"\$(cat '$tmp/knoenv.status')\" = 2 ] && [ ! -s '$tmp/knoenv.log' ]"
expect "k main: fetches main's credentials as gke-lab-main into .kube/main/config" \
  called kmain "gcloud container clusters get-credentials lab --zone us-central1-a | profile=gke-lab-main kubeconfig=$work/.kube/main/config"
expect "k main: runs kubectl with .kube/main/config" called kmain "kubectl get pods | profile=gke-lab-main kubeconfig=$work/.kube/main/config"
expect "h production: runs helm with .kube/production/config as gke-lab" \
  called hprod "helm list | profile=gke-lab kubeconfig=$work/.kube/production/config"
exit "$failed"
