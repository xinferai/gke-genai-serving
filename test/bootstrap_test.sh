#!/usr/bin/env bash
# Runs ./bootstrap against stand-ins for ./k and ./h that only write down what they were asked to do,
# so its order, its environment handling and its handling of the deploy key are checked without a
# cluster. Part of ./check.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failed=0

# expect "<what>" <command...>: prints ok or FAIL.
expect() {
  local what="$1"
  shift
  if "$@"; then printf 'ok    %s\n' "$what"; else printf 'FAIL  %s\n' "$what"; failed=1; fi
}

# The stand-in: writes one line per call to $LOG; fails on purpose when its arguments contain
# $FAIL_ON; plays its part in the secret pipeline (create --dry-run | label --local | apply -f -).
cat > "$tmp/stand-in" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$LOG"
if [ -n "${FAIL_ON:-}" ] && [[ "$*" == *"$FAIL_ON"* ]]; then exit 1; fi
case "$*" in
  *--dry-run=client*) echo "kind: Secret" ;;
  *--local*) cat ;;
  *"apply -f -"*) cat > /dev/null ;;
esac
exit 0
EOF
chmod +x "$tmp/stand-in"
ln -s "$tmp/stand-in" "$tmp/k"
ln -s "$tmp/stand-in" "$tmp/h"
echo "MARKER-not-a-real-key" > "$tmp/key"
mkdir -p "$tmp/home"

# run <name> <env, or - for none> [VAR=value ...]: runs bootstrap with the stand-ins. Calls go to
# $tmp/<name>.log, output to $tmp/<name>.out, the exit status to $tmp/<name>.status.
run() {
  local name="$1" env="$2"
  shift 2
  local args=()
  [ "$env" = "-" ] || args=("$env")
  : > "$tmp/$name.log"
  env LOG="$tmp/$name.log" K="$tmp/k" H="$tmp/h" ARGOCD_DEPLOY_KEY="$tmp/key" "$@" \
    "$here/bootstrap" "${args[@]}" > "$tmp/$name.out" 2>&1
  echo $? > "$tmp/$name.status"
}
succeeded() { grep -qx 0 "$tmp/$1.status"; }

installs_argocd_first() {
  local first
  first="$(head -1 "$tmp/good.log")"
  [[ "$first" == "h main upgrade --install argocd argo-cd "* && "$first" == *" --version 10.10.5 "* &&
    "$first" == *" -f $here/argocd/values.yaml "* && "$first" == *" --wait"* ]]
}
secret_made_and_applied() {
  grep -qxF -- "k main -n argocd create secret generic repo-gke-genai-serving --from-literal=type=git --from-literal=url=git@github.com:xinferai/gke-genai-serving.git --from-file=sshPrivateKey=$tmp/key --dry-run=client -o yaml" "$tmp/good.log" &&
    grep -qxF -- "k main label --local -f - argocd.argoproj.io/secret-type=repository -o yaml" "$tmp/good.log" &&
    grep -qxF -- "k main apply -f -" "$tmp/good.log"
}
# The safety checks below first make sure the run got as far as the step they are about, so they
# cannot pass just because bootstrap stopped early or does not exist. Each picks its lines into a
# file first: grep -q in a pipe can end the pipe early, and with pipefail that can turn a real
# match into a pass.
no_plain_create() {
  succeeded good || return 1
  grep -E '^k main( .*)? create( |$)' "$tmp/good.log" > "$tmp/creates" || return 1
  ! grep -vqF -- '--dry-run=client' "$tmp/creates"
}
root_applied_last() { [ "$(tail -1 "$tmp/good.log")" = "k main apply -k $here/argocd/main" ]; }
only_its_environment() { ! grep -v '^[kh] main ' "$tmp/good.log" | grep -q .; }
key_kept_from_helm() {
  grep '^h ' "$tmp/good.log" > "$tmp/helm-calls" || return 1
  ! grep -qF -e "$tmp/key" -e MARKER "$tmp/helm-calls"
}
key_not_shown() { succeeded good && ! grep -q MARKER "$tmp/good.out"; }
stops_without_key() { ! succeeded nokey && grep -q 'No deploy key' "$tmp/nokey.out" && [ ! -s "$tmp/nokey.log" ]; }
says_how_to_make_key() { grep -q 'ssh-keygen' "$tmp/nokey.out" && grep -q 'gh repo deploy-key add' "$tmp/nokey.out"; }
default_key_is_per_environment() {
  ! succeeded defaultkey && grep -qF "$tmp/home/.ssh/gke-genai-serving-argocd-production" "$tmp/defaultkey.out" &&
    [ ! -s "$tmp/defaultkey.log" ]
}
stops_without_environment() { ! succeeded noenv && grep -qF 'main or production' "$tmp/noenv.out" && [ ! -s "$tmp/noenv.log" ]; }
# stops_before_root <run> <the call that failed>: that call was made, and the root app was not applied.
stops_before_root() { ! succeeded "$1" && grep -qF -- "$2" "$tmp/$1.log" && ! grep -q 'apply -k' "$tmp/$1.log"; }

run good main
run nokey main ARGOCD_DEPLOY_KEY="$tmp/no-such-key"
run defaultkey production ARGOCD_DEPLOY_KEY= HOME="$tmp/home"
run noenv -
run badenv prod
run helmfails main FAIL_ON="upgrade --install"
run secretfails main FAIL_ON="apply -f -"

expect "a normal run succeeds" succeeded good
expect "step 1 installs Argo CD: pinned to 10.10.5, our settings, waits until ready" installs_argocd_first
expect "the repository secret is made from the key file and applied" secret_made_and_applied
expect "nothing uses a plain create, which would fail on a second run" no_plain_create
expect "the environment's root app (argocd/main) is applied last" root_applied_last
expect "every call goes to the named environment" only_its_environment
expect "the key never goes to Helm" key_kept_from_helm
expect "the key's contents never appear in the output" key_not_shown
expect "no key file: stops before touching the cluster" stops_without_key
expect "no key file: says how to make and register one" says_how_to_make_key
expect "the default key is the environment's own (gke-genai-serving-argocd-production)" default_key_is_per_environment
expect "no environment: stops before touching anything" stops_without_environment
expect "an unknown environment: stops before touching anything" bash -c "! grep -qx 0 '$tmp/badenv.status' && [ ! -s '$tmp/badenv.log' ]"
expect "Helm fails (say, an expired gcloud login): stops before the root app" \
  stops_before_root helmfails "h main upgrade --install"
expect "the secret step fails: stops before the root app" stops_before_root secretfails "k main apply -f -"
exit "$failed"
