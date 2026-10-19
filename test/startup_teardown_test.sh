#!/usr/bin/env bash
# Runs ./startup and ./teardown in a scratch git repository, against stand-ins for terraform, gcloud,
# kubectl, helm, curl and sleep that only write down how they were called (sleep returns at once, so
# every wait runs to its end in a moment). Checks the order of the steps, the fresh copy of GitHub's
# branch they work from, where each one stops, and the side-by-side run of both environments.
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

# The stand-ins. Each call is one line in $LOG: the tool, its arguments, the gcloud profile, the
# kubeconfig and, for terraform, the commit of the folder it ran in. FAIL_ON fails any call whose line
# contains it. Counters (in $STATE, one per profile) let an answer change after a number of calls.
mkdir -p "$tmp/bin" "$tmp/state"
cat > "$tmp/bin/stand-in" <<'EOF'
#!/usr/bin/env bash
tool="$(basename "$0")"
profile="${CLOUDSDK_ACTIVE_CONFIG_NAME:-}"
commit=""
if [ "$tool" = terraform ]; then commit=" admin=${TF_VAR_admin_cidr:-} commit=$(git -C "${1#-chdir=}" rev-parse HEAD 2> /dev/null)"; fi
line="$tool $* | profile=$profile kubeconfig=${KUBECONFIG:-}$commit${CLOUDSDK_CORE_DISABLE_PROMPTS:+ prompts=off}"
echo "$line" >> "$LOG"
if [ -n "${FAIL_ON:-}" ] && [[ "$line" == *"$FAIL_ON"* ]]; then exit 1; fi
# HANG_ON: that call takes HANG_SECONDS (37 unless set), or, stopped by Ctrl-C, one more second to
# finish, as Terraform does. Either way it notes whether its folder was still there when it ended.
if [ -n "${HANG_ON:-}" ] && [[ "$line" == *"$HANG_ON"* ]]; then
  dir="${1#-chdir=}"
  ended() {
    if [ -d "$dir" ]; then echo "hang $1: its folder was still there" >> "$LOG"; else echo "hang $1: its folder was GONE" >> "$LOG"; fi
  }
  trap '/bin/sleep 1; ended stopped; kill "$s" 2> /dev/null; exit 1' INT
  /bin/sleep "${HANG_SECONDS:-37}" &
  s=$!
  wait "$s"
  ended done
  exit 0
fi
# count <name>: how many times this has been asked before, for this profile.
count() {
  local f="$STATE/$1-$profile" n
  n="$(cat "$f" 2> /dev/null || echo 0)"
  echo $((n + 1)) > "$f"
  echo "$n"
}
case "$tool $*" in
  # Before anything changes (lib/preflight.sh): the profile's account and project, a fresh token, this
  # Mac's address and GitHub's answer to the deploy key. NO_PROFILE, PROFILE_ACCOUNT, PROFILE_PROJECT,
  # REAUTH, MY_IP and KEY_ACCEPTED play what can be missing.
  "gcloud config configurations describe"*)
    [ -z "${NO_PROFILE:-}" ] || { echo "ERROR: (gcloud.config.configurations.describe) The configuration [$4] does not exist." >&2; exit 1; }
    case "$*" in
      *core.account*) echo "${PROFILE_ACCOUNT-lab@example.invalid}" ;;
      *) if [ -n "${PROFILE_PROJECT:-}" ]; then echo "$PROFILE_PROJECT"; elif [ "$4" = gke-lab ]; then echo samwen-gke-lab; else echo samwen-gke-lab-main; fi ;;
    esac
    ;;
  "gcloud config config-helper"*)
    if [ -n "${REAUTH:-}" ]; then
      printf 'ERROR: (gcloud.config.config-helper) There was a problem refreshing your current auth tokens: Reauthentication failed. cannot prompt during non-interactive execution.\nPlease run:\n\n  $ gcloud auth login\n' >&2
      exit 1
    fi
    echo "not-a-real-token"
    ;;
  "curl"*"checkip.amazonaws.com"*) echo "${MY_IP-198.51.100.9}" ;;
  "ssh"*)
    if [ "${KEY_ACCEPTED-yes}" = yes ]; then
      echo "Hi xinferai/gke-genai-serving! You've successfully authenticated, but GitHub does not provide shell access." >&2
      exit 1
    fi
    echo "git@github.com: Permission denied (publickey)." >&2
    exit 255
    ;;
  "gcloud container clusters get-credentials"*) echo "fake" > "$KUBECONFIG" ;;
  "gcloud container clusters list"*) printf '%s' "${CLUSTERS-lab}" ;;
  "gcloud certificate-manager certificates describe"*) echo "${CERT_STATE-ACTIVE}" ;;
  "gcloud compute forwarding-rules list"*) [ "$(count rules)" -ge "${RULES_FOR:-0}" ] || echo "chat-lab-rule" ;;
  # The chat data disk is there unless DATA_DISK says otherwise; the disk list holds only it unless DISKS is set.
  "gcloud compute disks describe"*) [ "${DATA_DISK-there}" = there ] || exit 1; echo chat-data ;;
  "gcloud compute disks list"*) if [ -n "${DISKS+set}" ]; then printf '%s' "$DISKS"; else printf 'chat-data\tus-central1-a\n'; fi ;;
  terraform*" plan "*) for a in "$@"; do case "$a" in -out=*) touch "${1#-chdir=}/${a#-out=}" ;; esac; done ;;
  terraform*" show -json "*) cat "$PLAN_JSON" ;;
  "kubectl get crd"*) [ "${ARGOCD-installed}" = installed ] && echo "customresourcedefinition/applications.argoproj.io" ;;
  "kubectl -n argocd get applications -o json"*)
    if [ "$(count apps)" -ge "${APPS_READY_AFTER:-0}" ]; then cat "$tmp_apps/ready.json"; else cat "$tmp_apps/waiting.json"; fi ;;
  # Pods and events, for what the app wait says it is waiting on: none unless PODS_JSON / EVENTS_JSON name a file.
  "kubectl get pods -A -o json"*) [ -z "${PODS_JSON:-}" ] || cat "$PODS_JSON" ;;
  "kubectl get events -A -o json"*) [ -z "${EVENTS_JSON:-}" ] || cat "$EVENTS_JSON" ;;
  "kubectl"*"--dry-run=client"*) echo "kind: Secret" ;;
  "kubectl"*"--local"*) cat ;;
  "kubectl"*"apply -f -"*) cat > /dev/null ;;
  "curl"*) [ "$(count curl)" -ge "${HTTP_AFTER:-0}" ] && printf 200 || printf 000 ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/stand-in"
for tool in terraform gcloud kubectl helm curl sleep ssh gke-gcloud-auth-plugin; do ln -s "$tmp/bin/stand-in" "$tmp/bin/$tool"; done

# Plans and app lists the stand-ins hand back.
mkdir -p "$tmp/apps"
cat > "$tmp/apps/ready.json" <<'EOF'
{"items": [
  {"metadata": {"name": "root"}, "status": {"sync": {"status": "Synced"}, "health": {"status": "Healthy"}}},
  {"metadata": {"name": "chat"}, "status": {"sync": {"status": "Synced"}, "health": {"status": "Healthy"}}},
  {"metadata": {"name": "chat-edge"}, "status": {"sync": {"status": "Synced"}, "health": {"status": "Healthy"}}}]}
EOF
cat > "$tmp/apps/waiting.json" <<'EOF'
{"items": [
  {"metadata": {"name": "root"}, "status": {"sync": {"status": "Synced"}, "health": {"status": "Healthy"}}},
  {"metadata": {"name": "chat"}, "status": {"sync": {"status": "Synced"}, "health": {"status": "Progressing"}}},
  {"metadata": {"name": "chat-edge"}, "status": {"sync": {"status": "OutOfSync"}, "health": {"status": "Missing"}}}]}
EOF
# A model server that cannot start for want of a Spot GPU, as on 2026-10-16: one pod Pending, one running.
cat > "$tmp/pods.json" <<'EOF'
{"items": [
  {"metadata": {"namespace": "chat", "name": "chat-ollama-x"}, "status": {"phase": "Pending"}},
  {"metadata": {"namespace": "chat", "name": "chat-open-webui-0"}, "status": {"phase": "Running",
    "containerStatuses": [{"name": "open-webui", "state": {"running": {}}}]}}]}
EOF
cat > "$tmp/events.json" <<'EOF'
{"items": [
  {"type": "Warning", "reason": "FailedScheduling", "lastTimestamp": "2026-10-16T19:01:00Z",
   "involvedObject": {"kind": "Pod", "namespace": "chat", "name": "chat-ollama-x"},
   "message": "0/3 nodes are available: 1 Insufficient nvidia.com/gpu."},
  {"type": "Warning", "reason": "FailedScaleUp", "lastTimestamp": "2026-10-16T19:16:00Z",
   "involvedObject": {"kind": "Pod", "namespace": "chat", "name": "chat-ollama-x"},
   "message": "Node scale up in zones us-central1-a associated with this pod failed: GCE out of resources. Pod is at risk of not being scheduled."},
  {"type": "Warning", "reason": "FailedScheduling", "lastTimestamp": "2026-10-16T19:19:00Z",
   "involvedObject": {"kind": "Pod", "namespace": "chat", "name": "chat-ollama-x"},
   "message": "0/2 nodes are available: 1 node(s) didn't match Pod's node affinity/selector."},
  {"type": "Normal", "reason": "TriggeredScaleUp", "lastTimestamp": "2026-10-16T19:00:30Z",
   "involvedObject": {"kind": "Pod", "namespace": "chat", "name": "chat-ollama-x"},
   "message": "pod triggered scale-up"},
  {"type": "Warning", "reason": "Unhealthy", "lastTimestamp": "2026-10-16T19:02:00Z",
   "involvedObject": {"kind": "Pod", "namespace": "chat", "name": "chat-open-webui-0"},
   "message": "Readiness probe failed: not about this pod"}]}
EOF
plan() { # plan <file> <actions>...: a saved plan's JSON, one resource per action (create, update, ...)
  local f="$1" a i=0 items=""
  shift
  for a in "$@"; do
    items="$items${items:+,}{\"address\": \"thing.n$i\", \"change\": {\"actions\": [\"${a//+/\",\"}\"]}}"
    i=$((i + 1))
  done
  echo "{\"resource_changes\": [$items]}" > "$f"
}
plan "$tmp/adds.json" create create read create
plan "$tmp/updates.json" create update
plan "$tmp/replaces.json" create delete+create
plan "$tmp/nothing.json" no-op no-op read

# A scratch repository with the commands, a bare "GitHub", and a checkout on a short-lived branch with
# an uncommitted change: the commands must work from their own copy of GitHub's branch, not this one.
work="$tmp/work"
mkdir -p "$work/lib" "$work/argocd" "$work/envs/main/edge" "$work/envs/production/edge" \
  "$work/envs/main/cluster" "$work/envs/production/cluster"
cp "$here/tf" "$here/k" "$here/h" "$here/bootstrap" "$here/startup" "$here/teardown" "$work/" 2> /dev/null
cp "$here"/lib/*.sh "$work/lib/"
cp -R "$here/argocd/." "$work/argocd/"
cp "$here/envs/main/edge/terraform.tfvars" "$work/envs/main/edge/"
cp "$here/envs/production/edge/terraform.tfvars" "$work/envs/production/edge/"
touch "$work/envs/main/cluster/main.tf" "$work/envs/production/cluster/main.tf"
cp "$here/envs/main/cluster/terraform.tfvars" "$work/envs/main/cluster/"
cp "$here/envs/production/cluster/terraform.tfvars" "$work/envs/production/cluster/"
cp "$here/.gitignore" "$work/"
g() { git -C "$work" -c user.name=test -c user.email=test@example.invalid "$@"; }
git init -q --bare "$tmp/origin.git"
g init -q -b main
g add -A
g commit -q -m start
g remote add origin "$tmp/origin.git"
g push -q origin main
g switch -q -c production
echo production > "$work/production-only.txt"
g add production-only.txt
g commit -q -m "a production commit"
g push -q origin production
g switch -q -c feature main
echo scratch > "$work/unsaved.txt"
main_sha="$(g rev-parse origin/main)"
prod_sha="$(g rev-parse origin/production)"
echo "MARKER-not-a-real-key" > "$tmp/key"
# Who may connect: in this checkout only, ignored by git (the .gitignore above says so), never on "GitHub".
printf 'admin_cidr    = "198.51.100.9/32"\nallowed_cidrs = ["198.51.100.9/32"]\n' > "$work/access.tfvars"

# run <name> <stdin text> <command...>: runs in the checkout, with the stand-ins first on the PATH. Calls
# go to $tmp/<name>.log, output to $tmp/<name>.out, the exit status to $tmp/<name>.status. Variables
# for the stand-ins (PLAN_JSON, CERT_STATE, ...) come from the environment; plans default to adds.json.
run() {
  local name="$1" input="$2"
  shift 2
  : > "$tmp/$name.log"
  rm -rf "$tmp/state" "$tmp/copies" && mkdir -p "$tmp/state" "$tmp/copies"
  mkdir -p "$work/.kube/main" "$work/.kube/production"
  echo old > "$work/.kube/main/config"
  echo old > "$work/.kube/production/config"
  (cd "$work" && printf '%s' "$input" | env PATH="$tmp/bin:$PATH" LOG="$tmp/$name.log" STATE="$tmp/state" \
    tmp_apps="$tmp/apps" TMPDIR="$tmp/copies" ARGOCD_DEPLOY_KEY="${ARGOCD_DEPLOY_KEY:-$tmp/key}" PLAN_JSON="${PLAN_JSON:-$tmp/adds.json}" \
    "$@") > "$tmp/$name.out" 2>&1
  echo $? > "$tmp/$name.status"
}
status_is() { [ "$(cat "$tmp/$1.status")" = "$2" ]; }
succeeded() { status_is "$1" 0; }
called() { grep -qF -- "$2" "$tmp/$1.log"; }        # called <run> <text in the call log>
not_called() { ! called "$@"; }
nothing_called() { [ ! -s "$tmp/$1.log" ]; }
said() { grep -qF -- "$2" "$tmp/$1.out"; }          # said <run> <text in the output>
said_all() { # said_all <run> <text>...: every text is in the output
  local name="$1" t
  shift
  for t in "$@"; do said "$name" "$t" || { echo "not said: $t"; return 1; }; done
}
calls() { grep -cF -- "$2" "$tmp/$1.log"; }        # calls <run> <text>: how many calls had it
# in_order <run> <text>...: the first call with each text comes after the first call with the one before.
in_order() {
  local name="$1" at=0 n
  shift
  for t in "$@"; do
    n="$(grep -nF -- "$t" "$tmp/$name.log" | head -1 | cut -d: -f1)"
    [ -n "$n" ] && [ "$n" -gt "$at" ] || { echo "out of order or missing: $t"; return 1; }
    at="$n"
  done
}
# terraform_in_copy <run> <sha>: every terraform call ran in a fresh copy (under TMPDIR), at <sha>.
terraform_in_copy() {
  grep '^terraform ' "$tmp/$1.log" > "$tmp/$1.tf" || return 1
  ! grep -vF -- "-chdir=$tmp/copies/" "$tmp/$1.tf" | grep -q . && ! grep -v "commit=$2\$" "$tmp/$1.tf" | grep -q .
}
# copies_removed <run>: the run did work in a fresh copy, and no copy is left.
copies_removed() {
  grep -qF -- "-chdir=$tmp/copies/" "$tmp/$1.log" && [ "$(g worktree list | wc -l)" -eq 1 ] && [ -z "$(ls -A "$tmp/copies")" ]
}
# The checks that something did not happen first make sure the run got as far as the step before it,
# so they cannot pass just because a command stopped early or does not exist.
checkout_untouched() { [ "$(g branch --show-current)" = feature ] && [ -f "$work/unsaved.txt" ]; }
succeeded_untouched() { succeeded "$1" && checkout_untouched; }
kube_removed() { [ ! -e "$work/.kube/$1" ]; }

# --- ./startup ------------------------------------------------------------------------------------
run s_none "" ./startup
run s_bad "" ./startup prod
expect "startup with no word: usage, nothing run" bash -c "[ \"\$(cat '$tmp/s_none.status')\" = 2 ] && [ ! -s '$tmp/s_none.log' ]"
expect "startup with no word: says main, production or both" said s_none "main, production or both"
expect "startup prod: refused, nothing run" bash -c "[ \"\$(cat '$tmp/s_bad.status')\" = 2 ] && [ ! -s '$tmp/s_bad.log' ]"

run s_prod "" ./startup production
expect "startup production: succeeds" succeeded s_prod
expect "... checks the certificate and the data disk, then init, plan, apply, bootstrap, apps, HTTPS, in that order" \
  in_order s_prod "gcloud certificate-manager certificates describe chat-lab --location=global" \
  "gcloud compute disks describe chat-data --zone=us-central1-a" "cluster init" "cluster plan" "cluster show -json tfplan-startup" "cluster apply -input=false tfplan-startup" \
  "helm upgrade --install argocd" "kubectl apply -k" "kubectl -n argocd get applications -o json" \
  "curl -s -o /dev/null"
expect "... every terraform call runs in a fresh copy of GitHub's production" terraform_in_copy s_prod "$prod_sha"
expect "... everything as the production profile" bash -c "grep -q '^terraform ' '$tmp/s_prod.log' && ! grep -E '^(gcloud|terraform|kubectl|helm) ' '$tmp/s_prod.log' | grep -v 'profile=gke-lab ' | grep -q ."
expect "... asks production's address over HTTPS" called s_prod "https://chat-lab.liveinference.com/"
expect "... the cluster's credentials are fetched fresh" called s_prod "gcloud container clusters get-credentials lab"
expect "... and this checkout's old ones (.kube/production) are removed" kube_removed production
expect "... main's are left alone" bash -c "grep -qx 0 '$tmp/s_prod.status' && [ -f '$work/.kube/main/config' ]"
expect "... the fresh copy is removed afterwards" copies_removed s_prod
expect "... this checkout is untouched (branch and uncommitted file)" succeeded_untouched s_prod
expect "... prints each step's time and the total" bash -c "grep -qF 'startup production: done in' '$tmp/s_prod.out' && [ \"\$(grep -c '^ *[0-9]*m [0-9][0-9]s  ' '$tmp/s_prod.out')\" -ge 7 ]"
expect "... says which commit it brought up" said s_prod "${prod_sha:0:7}"
expect "... terraform in the fresh copy gets this checkout's access.tfvars (who may connect)" \
  bash -c "grep -F 'cluster plan -input=false -out=tfplan-startup' '$tmp/s_prod.log' | grep -qF 'admin=198.51.100.9/32'"
mv "$work/access.tfvars" "$tmp/access.tfvars"
run s_noaccess "" ./startup production
mv "$tmp/access.tfvars" "$work/access.tfvars"
expect "startup without access.tfvars: stops before cloning, no terraform" bash -c "! grep -qx 0 '$tmp/s_noaccess.status' && ! grep -q '^terraform ' '$tmp/s_noaccess.log' && [ -z \"\$(ls -A '$tmp/copies')\" ]"
expect "... and says to copy access.tfvars.example" said s_noaccess "access.tfvars.example"

run s_main "" ./startup main
expect "startup main: works from GitHub's main, as gke-lab-main" \
  bash -c "grep -q '^terraform .*profile=gke-lab-main .*commit=$main_sha\$' '$tmp/s_main.log'"
expect "... asks main's address" called s_main "https://chat-lab-main.liveinference.com/"

# --- Before anything changes: sign-ins, the GKE plugin, this Mac's address, the deploy keys ---------
# held_back <run>: stopped before cloning or changing anything, and said so.
held_back() {
  ! succeeded "$1" && said "$1" "Not ready, and nothing was changed" && [ -z "$(ls -A "$tmp/copies")" ] &&
    ! grep -qE '^(terraform|kubectl|helm) |certificates describe|forwarding-rules' "$tmp/$1.log"
}
expect "startup main checks first: the profile, a fresh token, this Mac's address, the deploy key" \
  in_order s_main "gcloud config configurations describe gke-lab-main --format=value(properties.core.account)" \
  "gcloud config config-helper --force-auth-refresh" "curl -s --max-time 10 https://checkip.amazonaws.com" \
  "ssh -i $tmp/key" "gcloud certificate-manager certificates describe"
expect "... asks gcloud for the token with prompts off, so it cannot stop for a password" \
  bash -c "grep 'config-helper --force-auth-refresh' '$tmp/s_main.log' | head -1 | grep -q 'prompts=off'"
expect "... and says each is ok" said_all s_main "  ok  gcloud profile gke-lab-main: lab@example.invalid, signed in" \
  "  ok  kubectl's GKE sign-in plugin" "  ok  your public address, 198.51.100.9, is in access.tfvars" \
  "  ok  Argo CD's deploy key for main: GitHub accepts it for xinferai/gke-genai-serving"

REAUTH=1 run p_reauth "" ./startup main
expect "signed out of Google Cloud: stops before cloning or changing anything" held_back p_reauth
expect "... says why, in gcloud's words, and the command to sign in, then to run it again" said_all p_reauth \
  "  NO  gcloud profile gke-lab-main: lab@example.invalid must sign in again (gcloud: There was a problem refreshing" \
  "  gcloud auth login lab@example.invalid --no-activate" "then ./startup main again"
PROFILE_ACCOUNT=someone@example.invalid REAUTH=1 run p_account "" ./startup main
expect "the account is the profile's, whichever it is: the one checked and the one to sign in" said_all p_account \
  "  NO  gcloud profile gke-lab-main: someone@example.invalid must sign in again" \
  "  gcloud auth login someone@example.invalid --no-activate"
PROFILE_ACCOUNT="" run p_noaccount "" ./startup main
expect "a profile naming no account: stops, says to set one" held_back p_noaccount
expect "... with the commands, the account left for you to fill in" said_all p_noaccount \
  "  NO  gcloud profile gke-lab-main names no account" "  # Put your Google account in place of ACCOUNT:" \
  "  gcloud config set account ACCOUNT --configuration=gke-lab-main" "  gcloud auth login ACCOUNT --no-activate"
PROFILE_PROJECT=another-project run p_project "" ./startup main
expect "a profile pointing at another project: stops, says to set the environment's project" \
  bash -c "! grep -qx 0 '$tmp/p_project.status' && grep -qF 'gcloud config set project samwen-gke-lab-main --configuration=gke-lab-main' '$tmp/p_project.out'"
NO_PROFILE=1 run p_noprofile "" ./startup main
expect "no gcloud profile at all: stops, lists the commands that make it" held_back p_noprofile
expect "... create, account, project, sign in" said_all p_noprofile \
  "  gcloud config configurations create gke-lab-main --no-activate" \
  "  gcloud config set account ACCOUNT --configuration=gke-lab-main" \
  "  gcloud config set project samwen-gke-lab-main --configuration=gke-lab-main" \
  "  gcloud auth login ACCOUNT --no-activate"
GKE_AUTH_PLUGIN=no-such-plugin run p_plugin "" ./startup main
expect "no GKE sign-in plugin for kubectl: stops, says how to install it" held_back p_plugin
expect "... with the command" said p_plugin "  gcloud components install gke-gcloud-auth-plugin"

MY_IP=203.0.113.50 run p_ip "" ./startup main
expect "this Mac's address not in access.tfvars: stops" held_back p_ip
expect "... startup: the file, then the entrance's Cloud Armor, from the environment's branch" said_all p_ip \
  "  NO  your public address, 203.0.113.50, is not in access.tfvars" \
  "admin_cidr = \"203.0.113.50/32\", and \"203.0.113.50/32\" in allowed_cidrs" \
  "  git switch main && git pull --ff-only" "  ./tf main edge plan -out=tfplan-access" "  ./tf main edge apply tfplan-access"
MY_IP=203.0.113.50 run p_ipdown "main"$'\n' ./teardown main
expect "... teardown: stops too, and the fix is the cluster's control plane" \
  bash -c "! grep -qx 0 '$tmp/p_ipdown.status' && ! grep -qE '^(terraform|kubectl) ' '$tmp/p_ipdown.log' && grep -qF './tf main cluster plan -out=tfplan-access' '$tmp/p_ipdown.out'"
MY_IP="" run p_noip "" ./startup main
expect "this Mac's address unknown (no answer): stops, says so" \
  bash -c "! grep -qx 0 '$tmp/p_noip.status' && grep -qF 'checkip.amazonaws.com did not answer' '$tmp/p_noip.out'"
cp "$work/access.tfvars" "$tmp/access.keep"
printf 'admin_cidr    = "198.51.100.0/24"\nallowed_cidrs = ["203.0.113.7/32", "198.51.100.0/24"]\n' > "$work/access.tfvars"
MY_IP=198.51.100.77 run p_range "" ./startup main
MY_IP=198.51.101.77 run p_outside "" ./startup main
cp "$tmp/access.keep" "$work/access.tfvars"
expect "an address inside access.tfvars' ranges (a /24, second in the list): goes on" \
  bash -c "grep -qx 0 '$tmp/p_range.status' && grep -qF '  ok  your public address, 198.51.100.77, is in access.tfvars' '$tmp/p_range.out'"
expect "... one just outside them: stops" held_back p_outside

ARGOCD_DEPLOY_KEY="$tmp/no-key" run p_nokey "" ./startup main
expect "no deploy key on this Mac: startup stops before the 12-minute build, not at bootstrap" held_back p_nokey
expect "... with the commands that make it and add it to GitHub" said_all p_nokey \
  "  ssh-keygen -t ed25519 -N '' -C 'argocd-lab-main read-only deploy key' -f $tmp/no-key" \
  "  gh repo deploy-key add $tmp/no-key.pub --repo xinferai/gke-genai-serving --title \"argocd-lab-main (read-only)\""
KEY_ACCEPTED=no run p_keyrefused "" ./startup main
expect "a deploy key GitHub does not accept: stops, says what ssh said, and how to add it" said_all p_keyrefused \
  "  NO  GitHub does not accept Argo CD's deploy key for main for xinferai/gke-genai-serving (ssh: git@github.com: Permission denied (publickey).)" \
  "  gh repo deploy-key add $tmp/key.pub --repo xinferai/gke-genai-serving"
expect "... before anything changes" held_back p_keyrefused

REAUTH=1 MY_IP=203.0.113.50 KEY_ACCEPTED=no run p_many "" ./startup both
expect "several things missing, both environments: all listed at once, nothing changed" held_back p_many
expect "... both profiles checked, the address once, both keys" said_all p_many \
  "  NO  gcloud profile gke-lab-main:" "  NO  gcloud profile gke-lab:" "  NO  your public address, 203.0.113.50" \
  "deploy key for main" "deploy key for production" "./tf production edge apply tfplan-access" "then ./startup both again"
expect "... one sign-in covers both profiles: listed once" \
  bash -c "[ \"\$(grep -c '^  gcloud auth login lab@example.invalid --no-activate\$' '$tmp/p_many.out')\" = 1 ]"

CERT_STATE=PROVISIONING run s_cert "" ./startup main
CERT_STATE="" run s_nocert "" ./startup main
expect "certificate not ACTIVE: stops before terraform" bash -c "grep -q 'certificates describe' '$tmp/s_cert.log' && ! grep -qx 0 '$tmp/s_cert.status' && ! grep -q '^terraform ' '$tmp/s_cert.log'"
expect "... says what it found and that the entrance comes first" bash -c "grep -qF PROVISIONING '$tmp/s_cert.out' && grep -qF 'edge' '$tmp/s_cert.out'"
expect "no certificate at all: stops before terraform" bash -c "grep -q 'certificates describe' '$tmp/s_nocert.log' && ! grep -qx 0 '$tmp/s_nocert.status' && ! grep -q '^terraform ' '$tmp/s_nocert.log'"

DATA_DISK=missing run s_nodisk "" ./startup main
expect "no chat data disk: stops before terraform" bash -c "grep -q 'disks describe chat-data' '$tmp/s_nodisk.log' && ! grep -qx 0 '$tmp/s_nodisk.status' && ! grep -q '^terraform ' '$tmp/s_nodisk.log'"
expect "... says the disk comes with the entrance (./tf main edge)" bash -c "grep -qF chat-data '$tmp/s_nodisk.out' && grep -qF './tf main edge' '$tmp/s_nodisk.out'"

PLAN_JSON="$tmp/updates.json" run s_update "" ./startup main
PLAN_JSON="$tmp/replaces.json" run s_replace "" ./startup main
expect "a plan that changes something: stops before apply" bash -c "grep -q 'show -json' '$tmp/s_update.log' && ! grep -qx 0 '$tmp/s_update.status' && ! grep -q 'cluster apply' '$tmp/s_update.log'"
expect "... and names it" said s_update "update thing.n1"
expect "a plan that replaces something: stops before apply" bash -c "grep -q 'show -json' '$tmp/s_replace.log' && ! grep -qx 0 '$tmp/s_replace.status' && ! grep -q 'cluster apply' '$tmp/s_replace.log'"
expect "... the fresh copy is removed even so" copies_removed s_replace

PLAN_JSON="$tmp/nothing.json" run s_upalready "" ./startup main
expect "nothing to add (the cluster is up): no apply, goes on to bootstrap and succeeds" \
  bash -c "grep -qx 0 '$tmp/s_upalready.status' && ! grep -q 'cluster apply' '$tmp/s_upalready.log' && grep -q '^helm upgrade' '$tmp/s_upalready.log'"
expect "... and says so" said s_upalready "already up"

FAIL_ON="cluster apply" run s_applyfails "" ./startup main
expect "apply fails: stops before bootstrap" bash -c "grep -q 'cluster apply' '$tmp/s_applyfails.log' && ! grep -qx 0 '$tmp/s_applyfails.status' && ! grep -q '^helm ' '$tmp/s_applyfails.log'"
expect "... and names the failed step" said s_applyfails "FAILED: "

FAIL_ON="upgrade --install" run s_bootfails "" ./startup main
expect "bootstrap fails: stops before waiting for the apps" \
  bash -c "grep -q '^helm upgrade' '$tmp/s_bootfails.log' && ! grep -qx 0 '$tmp/s_bootfails.status' && ! grep -q 'get applications' '$tmp/s_bootfails.log'"

APPS_READY_AFTER=3 run s_appslate "" ./startup main
expect "apps healthy on the fourth look: succeeds, after three waits" \
  bash -c "grep -qx 0 '$tmp/s_appslate.status' && [ \"\$(grep -c 'get applications' '$tmp/s_appslate.log')\" = 4 ]"
expect "... shows what it is waiting for" said s_appslate "chat Synced/Progressing"
APPS_READY_AFTER=100000 run s_appsnever "" ./startup main
expect "apps never healthy: gives up, never asks HTTPS" \
  bash -c "grep -q 'get applications' '$tmp/s_appsnever.log' && ! grep -qx 0 '$tmp/s_appsnever.status' && ! grep -q '^curl -s -o /dev/null' '$tmp/s_appsnever.log'"
expect "... after 25 minutes of 15-second waits" bash -c "[ \"\$(grep -c '^sleep 15' '$tmp/s_appsnever.log')\" = 100 ]"
expect "... and points to the Spot GPU note" said s_appsnever "Spot"
expect "... says it is still waiting every 5 minutes, though nothing changes" \
  bash -c "[ \"\$(grep -c 'still waiting' '$tmp/s_appsnever.out')\" = 5 ]"
expect "apps healthy on the fourth look: never says still waiting" \
  bash -c "grep -qx 0 '$tmp/s_appslate.status' && ! grep -q 'still waiting' '$tmp/s_appslate.out'"

PODS_JSON="$tmp/pods.json" EVENTS_JSON="$tmp/events.json" APPS_READY_AFTER=100000 run s_stall "" ./startup main
expect "a pod that cannot start: the app wait names it and its state" said s_stall "chat/chat-ollama-x Pending"
expect "... with its latest warning of each kind" bash -c "grep -qF 'FailedScaleUp: Node scale up in zones us-central1-a associated with this pod failed: GCE out of resources' '$tmp/s_stall.out' && grep -qF 'FailedScheduling: 0/2 nodes are available' '$tmp/s_stall.out'"
expect "... but not an older one of the same kind" bash -c "grep -qF 'FailedScheduling: 0/2' '$tmp/s_stall.out' && ! grep -qF '0/3 nodes' '$tmp/s_stall.out'"
expect "... says in plain words what out of resources means" said s_stall "no free machines"
expect "... leaves out running pods and their warnings" bash -c "grep -qF 'chat-ollama-x' '$tmp/s_stall.out' && ! grep -qF 'chat-open-webui-0' '$tmp/s_stall.out' && ! grep -qF 'not about this pod' '$tmp/s_stall.out'"
expect "... says it once while it stays the same, and again with each still waiting" \
  bash -c "[ \"\$(grep -c 'chat/chat-ollama-x Pending' '$tmp/s_stall.out')\" = 6 ]"
expect "... and nothing like it when every pod runs" bash -c "grep -q 'get applications' '$tmp/s_appsnever.log' && ! grep -q ' chat/' '$tmp/s_appsnever.out'"

HTTP_AFTER=2 run s_httplate "" ./startup main
expect "HTTPS 200 on the third try: succeeds" bash -c "grep -qx 0 '$tmp/s_httplate.status' && [ \"\$(grep -c '^curl -s -o /dev/null' '$tmp/s_httplate.log')\" = 3 ]"
HTTP_AFTER=100000 run s_httpnever "" ./startup main
expect "HTTPS never 200: gives up after 15 minutes of 15-second waits" \
  bash -c "! grep -qx 0 '$tmp/s_httpnever.status' && [ \"\$(grep -c '^sleep 15' '$tmp/s_httpnever.log')\" = 60 ]"

run s_both "" ./startup both
expect "startup both: succeeds" succeeded s_both
expect "... brings up each from its own branch" \
  bash -c "grep -q 'cluster apply .*profile=gke-lab-main .*commit=$main_sha\$' '$tmp/s_both.log' && grep -q 'cluster apply .*profile=gke-lab .*commit=$prod_sha\$' '$tmp/s_both.log'"
expect "... each with its own log in .logs/" \
  bash -c "ls '$work'/.logs/startup-main-*.log > /dev/null && ls '$work'/.logs/startup-production-*.log > /dev/null"
expect "... the logs hold each one's steps" \
  bash -c "grep -qF 'startup main: done in' '$work'/.logs/startup-main-*.log && grep -qF 'startup production: done in' '$work'/.logs/startup-production-*.log"
expect "... reports both done" bash -c "grep -q '^main: done' '$tmp/s_both.out' && grep -q '^production: done' '$tmp/s_both.out'"
expect "... the terminal shows each run's steps as they happen, after its name" \
  bash -c "grep -qE '^main +\[0m 00s\] the entrance' '$tmp/s_both.out' && grep -qE '^production +  ok, ' '$tmp/s_both.out' && grep -qE '^production +\[[0-9]+m [0-9]+s\] https://chat-lab.liveinference.com/ answers 200' '$tmp/s_both.out'"
expect "... and how each run ended, after its name" \
  bash -c "grep -qE '^main +startup main: done in' '$tmp/s_both.out' && grep -qE '^production +startup production: done in' '$tmp/s_both.out'"
expect "... both copies removed" copies_removed s_both
expect ".logs/ is never committed" bash -c "cd '$work' && git check-ignore -q .logs/startup-main-x.log"
rm -rf "$work/.logs"

# The run that ends first is reported first: here main's apply takes 3 seconds longer.
HANG_ON="cluster apply -input=false tfplan-startup | profile=gke-lab-main" HANG_SECONDS=3 run s_bothorder "" ./startup both
expect "startup both, production done first: reported first" \
  bash -c "grep -qx 0 '$tmp/s_bothorder.status' && p=\$(grep -n '^production: done' '$tmp/s_bothorder.out' | cut -d: -f1) && m=\$(grep -n '^main: done' '$tmp/s_bothorder.out' | cut -d: -f1) && [ \"\$p\" -lt \"\$m\" ]"
rm -rf "$work/.logs"

# Production's run fails (its calls, made with production's kubeconfig; the checks before it pass).
FAIL_ON="profile=gke-lab kubeconfig=$work/.kube/production" run s_bothfail "" ./startup both
expect "startup both, production failing: the run fails" \
  bash -c "grep -q 'certificates describe.*profile=gke-lab ' '$tmp/s_bothfail.log' && ! grep -qx 0 '$tmp/s_bothfail.status'"
expect "... main still comes up" called s_bothfail "cluster apply -input=false tfplan-startup | profile=gke-lab-main"
expect "... the report names production and its failed step, and main as done" \
  bash -c "grep -q '^production: FAILED at ' '$tmp/s_bothfail.out' && grep -q '^main: done' '$tmp/s_bothfail.out'"
rm -rf "$work/.logs"

# A signal in a side-by-side run. Ctrl-C reaches only ./startup (each run has its own process group),
# and so does a closed terminal (HUP): it passes Ctrl-C on to everything in both runs, waits for them to
# stop, and only then removes the copies. Started the way a terminal starts a command, with Ctrl-C not
# ignored (a script's background commands ignore it).
# start_bg <name> <VAR=value...> -- <command...>: starts a run in the background; sets bg_pid.
start_bg() {
  local name="$1"
  shift
  local vars=()
  while [ "$1" != -- ]; do vars+=("$1"); shift; done
  shift
  : > "$tmp/$name.log"
  rm -rf "$tmp/state" "$tmp/copies" && mkdir -p "$tmp/state" "$tmp/copies"
  # shellcheck disable=SC2016  # the single quotes hold Perl, not shell
  (cd "$work" && exec env PATH="$tmp/bin:$PATH" LOG="$tmp/$name.log" STATE="$tmp/state" tmp_apps="$tmp/apps" \
    TMPDIR="$tmp/copies" ARGOCD_DEPLOY_KEY="$tmp/key" PLAN_JSON="$tmp/adds.json" "${vars[@]}" \
    perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' "$@") > "$tmp/$name.out" 2>&1 < /dev/null &
  bg_pid=$!
}
# hung <name> <count>: waits (up to 10 seconds) until <count> calls hang.
hung() { for _ in $(seq 100); do [ "$(grep -c 'cluster apply' "$tmp/$1.log")" -ge "$2" ] && return; /bin/sleep 0.1; done; }
signal_both() { # signal_both <name> <signal>
  local at
  start_bg "$1" HANG_ON="cluster apply" -- ./startup both
  hung "$1" 2
  at=$SECONDS
  kill "-$2" "$bg_pid"
  wait "$bg_pid"
  echo $? > "$tmp/$1.status"
  echo $((SECONDS - at)) > "$tmp/$1.took"
}
for sig in INT HUP; do
  signal_both "s_$sig" "$sig"
  expect "$sig during startup both: both runs were applying when it came" \
    bash -c "[ \"\$(grep -c 'cluster apply' '$tmp/s_$sig.log')\" = 2 ]"
  expect "... the run ends within seconds, not when the hung calls would" test "$(cat "$tmp/s_$sig.took")" -lt 10
  expect "... both runs stopped while their copies were still there" \
    bash -c "[ \"\$(grep -c 'hang stopped: its folder was still there' '$tmp/s_$sig.log')\" = 2 ] && ! grep -q GONE '$tmp/s_$sig.log'"
  expect "... reports both as failed" bash -c "grep -q '^main: FAILED' '$tmp/s_$sig.out' && grep -q '^production: FAILED' '$tmp/s_$sig.out' && ! grep -qx 0 '$tmp/s_$sig.status'"
  expect "... nothing is left running" bash -c "! pgrep -f 'sleep 37' > /dev/null"
  expect "... both copies removed" copies_removed "s_$sig"
  rm -rf "$work/.logs"
done

# TERM to ./startup alone, in a single run: the run goes on to its end, and only then does the copy go.
start_bg s_term HANG_ON="cluster apply" HANG_SECONDS=2 -- ./startup main
hung s_term 1
kill -TERM "$bg_pid"
wait "$bg_pid"
echo $? > "$tmp/s_term.status"
expect "TERM to startup main alone: the apply ends in its copy, still there" called s_term "hang done: its folder was still there"
expect "... the run fails, since it was told to stop" bash -c "! grep -qx 0 '$tmp/s_term.status'"
expect "... and its copy is removed afterwards" copies_removed s_term

# --- ./teardown -----------------------------------------------------------------------------------
run t_none "" ./teardown
expect "teardown with no word: usage, nothing run" bash -c "[ \"\$(cat '$tmp/t_none.status')\" = 2 ] && [ ! -s '$tmp/t_none.log' ]"
run t_wrong "yes"$'\n' ./teardown main
run t_empty "" ./teardown main
run t_other "production"$'\n' ./teardown main
expect "teardown main, answered 'yes': nothing run" bash -c "grep -q 'Type main' '$tmp/t_wrong.out' && ! grep -qx 0 '$tmp/t_wrong.status' && [ ! -s '$tmp/t_wrong.log' ]"
expect "... says it did nothing" said t_wrong "Not torn down"
expect "... and asked for the environment's name" said t_wrong "Type main"
expect "... having said the chat data disk stays" said t_wrong "the chat data disk chat-data (accounts, passwords, chats)"
expect "teardown main, no answer: nothing run" bash -c "grep -q 'Type main' '$tmp/t_empty.out' && ! grep -qx 0 '$tmp/t_empty.status' && [ ! -s '$tmp/t_empty.log' ]"
expect "teardown main, answered 'production': nothing run" bash -c "grep -q 'Type main' '$tmp/t_other.out' && ! grep -qx 0 '$tmp/t_other.status' && [ ! -s '$tmp/t_other.log' ]"
expect "... and its credentials are kept" bash -c "grep -q 'Type main' '$tmp/t_other.out' && [ -f '$work/.kube/main/config' ]"

RULES_FOR=3 run t_main "main"$'\n' ./teardown main
expect "teardown main: succeeds" succeeded t_main
expect "... deletes the root app, waits for no forwarding rules, destroys, checks disks, in that order" \
  in_order t_main "kubectl -n argocd delete application root" "gcloud compute forwarding-rules list" \
  "cluster init" "cluster destroy -auto-approve" "gcloud compute disks list"
expect "... the root app's deletion waits, up to 15 minutes" called t_main "delete application root --ignore-not-found --timeout=15m"
expect "... looks again until the rules are gone (4 looks)" bash -c "[ \"\$(grep -c 'forwarding-rules list' '$tmp/t_main.log')\" = 4 ]"
expect "... every terraform call runs in a fresh copy of GitHub's main" terraform_in_copy t_main "$main_sha"
expect "... everything as the main profile" bash -c "grep -q '^terraform ' '$tmp/t_main.log' && ! grep -E '^(gcloud|terraform|kubectl) ' '$tmp/t_main.log' | grep -v 'profile=gke-lab-main ' | grep -q ."
expect "... this checkout's credentials (.kube/main) are removed" kube_removed main
expect "... production's are left alone" bash -c "grep -qx 0 '$tmp/t_main.status' && [ -f '$work/.kube/production/config' ]"
expect "... the fresh copy is removed" copies_removed t_main
expect "... the destroy gets access.tfvars too" bash -c "grep -F 'cluster destroy -auto-approve' '$tmp/t_main.log' | grep -qF 'admin=198.51.100.9/32'"
mv "$work/access.tfvars" "$tmp/access.tfvars"
run t_noaccess "main"$'\n' ./teardown main
mv "$tmp/access.tfvars" "$work/access.tfvars"
expect "teardown without access.tfvars: no terraform, says to copy access.tfvars.example" bash -c "! grep -qx 0 '$tmp/t_noaccess.status' && ! grep -q '^terraform ' '$tmp/t_noaccess.log' && grep -qF access.tfvars.example '$tmp/t_noaccess.out'"
expect "... this checkout is untouched" succeeded_untouched t_main
expect "... prints each step's time and the total" said t_main "teardown main: done in"
expect "... checks the profile and this Mac's address first, but not the deploy key (only startup uses it)" \
  bash -c "grep -qF '  ok  gcloud profile gke-lab-main' '$tmp/t_main.out' && grep -qF '  ok  your public address' '$tmp/t_main.out' && ! grep -q '^ssh ' '$tmp/t_main.log'"
expect "... the chat data disk is not a disk left behind: it stays, and teardown says so" \
  bash -c "grep -qx 0 '$tmp/t_main.status' && grep -qF 'The chat data disk chat-data stays' '$tmp/t_main.out' && ! grep -qF 'left behind, still billing' '$tmp/t_main.out'"

RULES_FOR=100000 run t_rules "main"$'\n' ./teardown main
expect "the load balancer never goes: gives up without destroying" \
  bash -c "grep -q 'forwarding-rules list' '$tmp/t_rules.log' && ! grep -qx 0 '$tmp/t_rules.status' && ! grep -q 'destroy' '$tmp/t_rules.log'"
expect "... after 15 minutes of 15-second waits" bash -c "[ \"\$(grep -c '^sleep 15' '$tmp/t_rules.log')\" = 60 ]"
expect "... names what is left" said t_rules "chat-lab-rule"
expect "... keeps the credentials, for a look" bash -c "grep -q 'forwarding-rules list' '$tmp/t_rules.log' && [ -f '$work/.kube/main/config' ]"

FAIL_ON="forwarding-rules list" run t_rulesfail "main"$'\n' ./teardown main
expect "gcloud cannot list the rules (say, an expired login): stops without destroying" \
  bash -c "grep -q 'forwarding-rules list' '$tmp/t_rulesfail.log' && ! grep -qx 0 '$tmp/t_rulesfail.status' && ! grep -q 'destroy' '$tmp/t_rulesfail.log'"
expect "... at once, without waiting" bash -c "grep -q 'forwarding-rules list' '$tmp/t_rulesfail.log' && ! grep -q '^sleep' '$tmp/t_rulesfail.log'"
expect "... and says to sign in again" said t_rulesfail "auth login"

FAIL_ON="delete application root" run t_rootfails "main"$'\n' ./teardown main
expect "the root app's deletion fails: stops without destroying" \
  bash -c "grep -q 'delete application root' '$tmp/t_rootfails.log' && ! grep -qx 0 '$tmp/t_rootfails.status' && ! grep -q 'destroy' '$tmp/t_rootfails.log'"

FAIL_ON="container clusters list" run t_listfails "main"$'\n' ./teardown main
expect "gcloud cannot list clusters: stops without destroying" \
  bash -c "grep -q 'container clusters list' '$tmp/t_listfails.log' && ! grep -qx 0 '$tmp/t_listfails.status' && ! grep -q 'destroy' '$tmp/t_listfails.log'"

CLUSTERS="" run t_nocluster "main"$'\n' ./teardown main
expect "no cluster: nothing to delete in it, still destroys what Terraform holds, succeeds" \
  bash -c "grep -qx 0 '$tmp/t_nocluster.status' && ! grep -q '^kubectl ' '$tmp/t_nocluster.log' && grep -q 'cluster destroy' '$tmp/t_nocluster.log'"

ARGOCD=absent run t_noargo "main"$'\n' ./teardown main
expect "Argo CD not installed: no root app to delete, still destroys" \
  bash -c "grep -qx 0 '$tmp/t_noargo.status' && ! grep -q 'delete application' '$tmp/t_noargo.log' && grep -q 'cluster destroy' '$tmp/t_noargo.log'"

DISKS="pvc-1234" run t_disks "main"$'\n' ./teardown main
expect "a disk left behind: the run fails after the destroy" \
  bash -c "! grep -qx 0 '$tmp/t_disks.status' && grep -q 'cluster destroy' '$tmp/t_disks.log'"
expect "... and names it" said t_disks "pvc-1234"
expect "... and says the chat data disk is not there" said t_disks "chat-data is not there"
DISKS=$'chat-data\tus-central1-a\npvc-1234\tus-central1-a\n' run t_disks2 "main"$'\n' ./teardown main
expect "the data disk and another one: the run fails, naming the other" bash -c "! grep -qx 0 '$tmp/t_disks2.status' && grep -q '^  pvc-1234' '$tmp/t_disks2.out'"
expect "... but not the data disk, among those to delete" bash -c "grep -q '^  pvc-1234' '$tmp/t_disks2.out' && ! grep -q '^  chat-data' '$tmp/t_disks2.out'"
DISKS="" run t_nodata "main"$'\n' ./teardown main
expect "no disks at all: succeeds (nothing left behind)" succeeded t_nodata
expect "... and says the chat data disk is not there, so the next startup stops" \
  bash -c "grep -qF 'chat-data is not there' '$tmp/t_nodata.out' && grep -qF './startup main stops' '$tmp/t_nodata.out'"

run t_bothmain "main"$'\n' ./teardown both
expect "teardown both, answered 'main': nothing run" bash -c "grep -q 'Type both' '$tmp/t_bothmain.out' && ! grep -qx 0 '$tmp/t_bothmain.status' && [ ! -s '$tmp/t_bothmain.log' ]"
run t_both "both"$'\n' ./teardown both
expect "teardown both, answered 'both': succeeds" succeeded t_both
expect "... asks once" bash -c "[ \"\$(grep -o 'Type both' '$tmp/t_both.out' | wc -l)\" -eq 1 ]"
expect "... destroys each from its own branch" \
  bash -c "grep -q 'cluster destroy .*profile=gke-lab-main .*commit=$main_sha\$' '$tmp/t_both.log' && grep -q 'cluster destroy .*profile=gke-lab .*commit=$prod_sha\$' '$tmp/t_both.log'"
expect "... both credentials removed" bash -c "[ ! -e '$work/.kube/main' ] && [ ! -e '$work/.kube/production' ]"
expect "... reports both done" bash -c "grep -q '^main: done' '$tmp/t_both.out' && grep -q '^production: done' '$tmp/t_both.out'"
expect "... both copies removed" copies_removed t_both

# --- GitHub's production from before the chat data disk (no zone in its entrance settings) ---------
# Last, since it changes GitHub's production.
g switch -q production
grep -v '^zone ' "$work/envs/production/edge/terraform.tfvars" > "$tmp/tfvars" && cp "$tmp/tfvars" "$work/envs/production/edge/terraform.tfvars"
g commit -q -am "production from before the chat data disk"
g push -q origin production
g switch -q feature
run s_old "" ./startup production
expect "GitHub's production from before the data disk: startup stops before terraform" \
  bash -c "! grep -qx 0 '$tmp/s_old.status' && ! grep -q '^terraform ' '$tmp/s_old.log'"
expect "... and says the branch is from before the disk, so promote main first" \
  bash -c "grep -qF 'from before the chat data disk' '$tmp/s_old.out' && grep -qF 'promote main' '$tmp/s_old.out'"
exit "$failed"
