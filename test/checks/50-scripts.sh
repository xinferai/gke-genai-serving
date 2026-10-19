# shellcheck shell=bash
# Sourced by ./check, which defines check(), strict(), here, tmp, repo, schemas, envs and other().

# --- the scripts -------------------------------------------------------------------------------
# Everything except SC2329 ("this function is never called"): the functions above are called through
# check(), which shellcheck cannot see. Its other notes stay on, the unquoted-variable one above all.
# lib/env.sh and test/checks/*.sh are checked through the scripts that source them (-x), where
# the variables they use are defined.
check "scripts pass shellcheck" shellcheck -x -e SC2329 check tf k h bootstrap startup teardown hotfix \
  test/bootstrap_test.sh test/wrappers_test.sh test/workflow_test.sh test/startup_teardown_test.sh test/hotfix_test.sh
check "tf, k and h, run against stand-ins in a scratch repository" test/wrappers_test.sh
check "bootstrap, run against stand-ins for ./k and ./h" test/bootstrap_test.sh
check "startup and teardown, run against stand-ins in a scratch repository" test/startup_teardown_test.sh
check "hotfix, run against a stand-in GitHub in scratch repositories" test/hotfix_test.sh
# ./k and ./h keep each cluster's kubeconfig in .kube/<env>/ inside this folder; git must never pick
# one up (it holds the cluster's address and certificate, and the auth plugin caches tokens beside it).
kube_ignored() {
  local f
  for f in .kube/main/config .kube/production/config .kube/main/gke_gcloud_auth_plugin_cache; do
    git check-ignore -q "$f" || { echo "not ignored: $f"; return 1; }
  done
}
check "kubeconfigs under .kube/ are never committed" kube_ignored
