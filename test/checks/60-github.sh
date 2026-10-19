# shellcheck shell=bash
# Sourced by ./check, which defines check(), strict(), here, tmp, repo, schemas, envs and other().

# --- GitHub: what may be merged into production ----------------------------------------------------
wf=.github/workflows/into-production.yml
# run_script <job>: the job's own script, as written in the workflow.
run_script() { yq e ".jobs[\"$1\"].steps[] | select(has(\"run\")) | .run" "$wf"; }
from_branch() { # from_branch <head branch> [head repository]: runs source-allowed's script the way GitHub would
  local script
  script="$(run_script source-allowed)" && [ -n "$script" ] || return 1
  HEAD_REF="$1" HEAD_REPO="${2-xinferai/gke-genai-serving}" BASE_REPO=xinferai/gke-genai-serving \
    bash -e -o pipefail -c "$script"
}
# rejects_forks: a branch named main from any other repository, or from a deleted fork (no name), fails.
rejects_forks() {
  local r
  for r in someone/gke-genai-serving xinferai/other ''; do
    ! from_branch main "$r" > /dev/null || { echo "accepted main from: '$r'"; return 1; }
  done
}
# rejects <branch>...: the script exists, and fails for every branch named.
rejects() {
  local b
  [ -n "$(run_script source-allowed 2> /dev/null)" ] || { echo "no source-allowed script"; return 1; }
  for b in "$@"; do
    ! from_branch "$b" > /dev/null || { echo "accepted: $b"; return 1; }
  done
}
# Branch names and commit ids reach the scripts through environment variables, never pasted into
# them: a branch named like a shell command must not run.
injection_safe() {
  yq e -e '.jobs["source-allowed"].steps[0].env.HEAD_REF == "${{ github.head_ref }}"' "$wf" > /dev/null &&
    yq e -e '.jobs["source-allowed"].steps[0].env.HEAD_REPO == "${{ github.event.pull_request.head.repo.full_name }}"' "$wf" > /dev/null &&
    yq e -e '.jobs["source-allowed"].steps[0].env.BASE_REPO == "${{ github.repository }}"' "$wf" > /dev/null &&
    yq e -e '.jobs["source-has-production"].steps[1].env.HEAD_SHA == "${{ github.event.pull_request.head.sha }}"' "$wf" > /dev/null &&
    ! yq e '.jobs[].steps[] | select(has("run")) | .run' "$wf" | grep -qF '${{'
}
scripts_pass_shellcheck() {
  local job
  for job in source-allowed source-has-production; do
    run_script "$job" > "$tmp/$job.sh" && [ -s "$tmp/$job.sh" ] || { echo "no script in $job"; return 1; }
    shellcheck -s bash "$tmp/$job.sh" || return 1
  done
}

# pull_request_target runs the default branch's copy of this file (main's), so a pull request cannot
# rewrite the checks that judge it (on pull_request, GitHub would run the copy in the pull request's
# merge result). It is safe here only because no code from the pull request runs: the checkout keeps
# main's code, and the history check only reads the pull request's commits with git log.
check "production workflow: runs main's copy (pull_request_target), on pull requests into production" \
  yq e -e '(.on | has("pull_request") | not) and (.on.pull_request_target.branches | length) == 1 and .on.pull_request_target.branches[0] == "production"' "$wf"
check "production workflow: the checkout keeps main's code, never the pull request's" \
  yq e -e '.jobs["source-has-production"].steps[0].with | has("ref") | not' "$wf"
check "production workflow: its two checks are source-allowed and source-has-production" \
  yq e -e '(.jobs | length) == 2 and (.jobs | has("source-allowed")) and (.jobs | has("source-has-production"))' "$wf"
check "production workflow: no permissions, except reading the code for the history check" \
  yq e -e '(.permissions | tag) == "!!map" and (.permissions | length) == 0 and (.jobs["source-allowed"] | has("permissions") | not) and (.jobs["source-has-production"].permissions | length) == 1 and .jobs["source-has-production"].permissions.contents == "read"' "$wf"
check "production workflow: checkout pinned to a full commit id" \
  yq e -e '.jobs["source-has-production"].steps[0].uses | test("^actions/checkout@[0-9a-f]{40}$")' "$wf"
check "production workflow: checkout fetches every branch's history and leaves no token behind" \
  yq e -e '.jobs["source-has-production"].steps[0].with["fetch-depth"] == 0 and .jobs["source-has-production"].steps[0].with["persist-credentials"] == false' "$wf"
check "production workflow: names and commit ids arrive as environment variables, never pasted into a script" injection_safe
check "production workflow: its scripts pass shellcheck" scripts_pass_shellcheck
check "production workflow: source-allowed passes a pull request from main" from_branch main
check "production workflow: source-allowed fails main from a fork (public repository)" rejects_forks
check "production workflow: source-allowed fails any other branch, hotfix/ included" \
  rejects feature hotfix/ingress-timeout hotfix/ hotfixes/x main-old Main my/main 'main; true' ''
# The hotfix lane was replaced by setting main aside (docs/release-process.md): no message may still point to it.
no_hotfix_words() { ! grep -n -i hotfix "$wf"; }
check "production workflow: no word of the hotfix lane it replaced" no_hotfix_words
check "production workflow: source-has-production, run on scratch branch histories" test/workflow_test.sh
