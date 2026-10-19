#!/usr/bin/env bash
# Runs ./hotfix in scratch git repositories, each with a bare "GitHub", and stand-ins: gh (which opens
# pull requests and merges them in that bare repository, squash or merge commit, as GitHub does, under
# the account's primary email unless given --author-email),
# terraform, gcloud and ./check, which write down how they were called. Walks an urgent fix both ways:
# straight through main when main has nothing production lacks, and with main set aside when it has.
# Part of ./check; touches no cluster, no cloud and no real repository.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
# KEEP_TMP=1 keeps the scratch folder, to read a run's output and calls after it.
# shellcheck disable=SC2064  # $tmp is fixed now; KEEP_TMP is read once
trap "${KEEP_TMP:+:} rm -rf \"$tmp\"" EXIT
failed=0
expect() { # expect "<what>" <command...>: prints ok or FAIL
  local what="$1"
  shift
  if "$@"; then printf 'ok    %s\n' "$what"; else printf 'FAIL  %s\n' "$what"; failed=1; fi
}

# Git as a test user, with no settings from this Mac (signing, hooks, aliases).
: > "$tmp/gitconfig"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

mkdir -p "$tmp/bin"
# gh: each call is a line in $LOG. Pull requests live in $GH_STATE, one file each: base, head, title, state.
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$LOG"
mkdir -p "$GH_STATE"
arg() { # arg <flag> <args...>: the value after the flag
  local f="$1"
  shift
  while [ $# -gt 0 ]; do [ "$1" = "$f" ] && { echo "$2"; return; }; shift; done
}
case "$1 $2" in
  "pr create")
    n=$(($(cat "$GH_STATE/next" 2> /dev/null || echo 0) + 1))
    echo "$n" > "$GH_STATE/next"
    printf '%s\n%s\n%s\nopen\n' "$(arg --base "$@")" "$(arg --head "$@")" "$(arg --title "$@")" > "$GH_STATE/pr-$n"
    echo "https://github.com/xinferai/gke-genai-serving/pull/$n"
    ;;
  "pr list")
    base="$(arg --base "$@")" head="$(arg --head "$@")"
    for f in "$GH_STATE"/pr-*; do
      [ -f "$f" ] || continue
      { read -r b; read -r h; read -r _; read -r s; } < "$f"
      [ "$b" = "$base" ] && [ "$h" = "$head" ] && [ "$s" = open ] && echo "${f##*pr-}"
    done | head -1
    ;;
  "pr checks")
    case " $* " in *" --json "*) echo 2 ;; *) exit "${CHECKS_EXIT:-0}" ;; esac
    ;;
  "pr merge")
    n="$3"
    { read -r base; read -r head; read -r title; read -r state; } < "$GH_STATE/pr-$n"
    [ "$state" = open ] || { echo "pull request #$n is $state" >&2; exit 1; }
    c="$(mktemp -d)"
    git clone -q "$ORIGIN" "$c/r" && cd "$c/r" && git checkout -q "$base" || exit 1
    # Without --author-email, GitHub uses the account's primary email.
    email="$(arg --author-email "$@")"
    export GIT_AUTHOR_EMAIL="${email:-primary@example.invalid}"
    if [ "$4" = --squash ]; then
      # As this repository's setting does (squash_merge_commit_message COMMIT_MESSAGES): the commits'
      # bodies become the squash commit's body.
      body="$(git log --format=%b "origin/$base..origin/$head")"
      git merge -q --squash "origin/$head" > /dev/null && git commit -q -m "$title (#$n)" -m "$body" || exit 1
    else
      git merge -q --no-ff "origin/$head" -m "Merge pull request #$n from xinferai/$head" || exit 1
    fi
    git push -q origin "$base" || exit 1
    printf '%s\n%s\n%s\nmerged\n' "$base" "$head" "$title" > "$GH_STATE/pr-$n"
    rm -rf "$c"
    ;;
esac
exit 0
EOF
# terraform: a plan says "there are changes" (exit 2, as -detailed-exitcode does) unless PLAN_EXIT says otherwise.
cat > "$tmp/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform $* | commit=$(git -C "${1#-chdir=}" rev-parse HEAD)" >> "$LOG"
case " $* " in
  *" plan "*)
    for a in "$@"; do case "$a" in -out=*) touch "${1#-chdir=}/${a#-out=}" ;; esac; done
    exit "${PLAN_EXIT:-2}"
    ;;
esac
exit 0
EOF
# gcloud: main's cluster is up unless CLUSTERS is set empty.
cat > "$tmp/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud $* | profile=${CLOUDSDK_ACTIVE_CONFIG_NAME:-}" >> "$LOG"
case "$*" in
  "config config-helper"*) echo "not-a-real-token" ;;
  "container clusters list"*) printf '%s' "${CLUSTERS-lab}" ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/terraform" "$tmp/bin/gcloud"

# setup <name>: a scratch "GitHub" ($tmp/<name>/origin.git) with main and production on the same first
# commit, and a checkout of it ($tmp/<name>/work) on main, holding ./hotfix, ./tf and lib/ from here and
# a ./check that only writes down that it ran (and fails when CHECK_EXIT says so).
setup() {
  local d="$tmp/$1"
  work="$d/work"
  origin="$d/origin.git"
  mkdir -p "$work/lib" "$work/apps" "$work/modules/edge" "$work/modules/platform" \
    "$work/envs/main/edge" "$work/envs/main/cluster" "$work/envs/production/edge" "$work/envs/production/cluster"
  cp "$here/hotfix" "$here/tf" "$work/"
  cp "$here"/lib/*.sh "$work/lib/"
  cp "$here/.gitignore" "$work/"
  # Who may connect, which ./tf needs for plan and apply: ignored by git, so it never reaches "GitHub".
  printf 'admin_cidr    = "198.51.100.9/32"\nallowed_cidrs = ["198.51.100.9/32"]\n' > "$work/access.tfvars"
  # shellcheck disable=SC2016  # the stand-in expands these when it runs
  printf '#!/usr/bin/env bash\necho "check" >> "$LOG"\nexit "${CHECK_EXIT:-0}"\n' > "$work/check"
  chmod +x "$work/check"
  echo "v1" > "$work/apps/app.txt"
  echo "# edge" > "$work/modules/edge/main.tf"
  echo "# platform" > "$work/modules/platform/main.tf"
  for f in envs/main/edge envs/main/cluster envs/production/edge envs/production/cluster; do echo "# $f" > "$work/$f/main.tf"; done
  git init -q --bare -b main "$origin"
  git -C "$work" init -q -b main
  git -C "$work" add -A
  git -C "$work" commit -q -m start
  git -C "$work" remote add origin "$origin"
  git -C "$work" push -q origin main main:production
  git -C "$work" fetch -q origin
  rm -rf "$d/gh"
}
# on_github <message> <file> <text>: a commit straight onto GitHub's main, as if merged there by someone.
on_github() {
  local c="$tmp/side"
  rm -rf "$c"
  git clone -q "$origin" "$c" && echo "$3" > "$c/$2" && git -C "$c" add -A && git -C "$c" commit -q -m "$1" &&
    git -C "$c" push -q origin main && git -C "$work" fetch -q origin
}
# run <name> <answers> [VAR=value...]: ./hotfix in the checkout, with the answers on its input. Calls go to
# $tmp/<name>.log, output to $tmp/<name>.out, the exit status to $tmp/<name>.status.
run() {
  local name="$1" input="$2"
  shift 2
  : > "$tmp/$name.log"
  (cd "$work" && printf '%b' "$input" | env PATH="$tmp/bin:$PATH" LOG="$tmp/$name.log" GH_STATE="$(dirname "$work")/gh" \
    ORIGIN="$origin" "$@" ./hotfix) > "$tmp/$name.out" 2>&1
  echo $? > "$tmp/$name.status"
}
succeeded() { [ "$(cat "$tmp/$1.status")" = 0 ]; }
stopped() { [ "$(cat "$tmp/$1.status")" != 0 ] && grep -qF "Stopped" "$tmp/$1.out"; }
said() { grep -qF -- "$2" "$tmp/$1.out"; }
called() { grep -qF -- "$2" "$tmp/$1.log"; }
no_gh() { ! grep -q '^gh ' "$tmp/$1.log"; }
gh_calls() { grep -c "^gh $2" "$tmp/$1.log"; }
on_branch() { [ "$(git -C "$work" branch --show-current)" = "$1" ]; }
remote_has() { git -C "$work" fetch -q --prune origin && git -C "$work" rev-parse -q --verify "refs/remotes/origin/$1" > /dev/null; }
subject() { git -C "$work" log -1 --format=%s "$1"; }
file_at() { git -C "$work" show "$1:$2" 2> /dev/null; }
# printed <run>: every pull request created or merged was printed in full ("+ ...") before it ran (the
# shell's quoting, ' and \, left out of the comparison).
printed() {
  local line
  grep -qE '^gh pr (create|merge)' "$tmp/$1.log" || { echo "no pull request was made or merged"; return 1; }
  while IFS= read -r line; do
    tr -d "'\\\\" < "$tmp/$1.out" | grep -qF -- "+ $(tr -d "'\\\\" <<< "$line")" || { echo "not printed: $line"; return 1; }
  done < <(grep -E '^gh pr (create|merge)' "$tmp/$1.log")
}
# asked_first <run>: every push, pull request, merge, apply and deletion in the output came after a question
# for it ("Type yes ...", or "Type promote ..."); a push and its pull request share one question.
asked_first() {
  grep -qE '^\+ (git push|gh pr (create|merge))' "$tmp/$1.out" || { echo "nothing pushed, opened or merged"; return 1; }
  awk '
    /Type (yes|promote)/ { asked = 1 }
    /^\+ (git push|gh pr (create|merge)|\.\/tf main [a-z]+ apply)/ {
      if (/^\+ gh pr create/ && pushed) { pushed = 0; next }
      if (!asked) { print "not asked first: " $0; bad = 1 }
      asked = 0
      pushed = /^\+ git push -u / ? 1 : 0
    }
    END { exit bad }' "$tmp/$1.out"
}
in_order() { # in_order <run> <text>...: the first call with each text comes after the one before
  local name="$1" at=0 n t
  shift
  for t in "$@"; do
    n="$(grep -nF -- "$t" "$tmp/$name.log" | head -1 | cut -d: -f1)"
    [ -n "$n" ] && [ "$n" -gt "$at" ] || { echo "out of order or missing: $t"; return 1; }
    at="$n"
  done
}

# --- A checkout with uncommitted changes -----------------------------------------------------------
setup dirty
echo "v9" > "$work/apps/app.txt"
run x1 ""
expect "uncommitted changes: stops before anything else" bash -c "grep -qF 'commit or stash' '$tmp/x1.out' && ! grep -qx 0 '$tmp/x1.status' && ! grep -q '^gh ' '$tmp/x1.log'"

# --- Straight through main: main has nothing production lacks ---------------------------------------
setup straight
start_sha="$(git -C "$work" rev-parse origin/main)"
run s0 "main\n"
expect "a fix branch named main: refused" bash -c "grep -qF 'taken' '$tmp/s0.out' && ! grep -qx 0 '$tmp/s0.status'"
run s1 "urgent-fix\n"
expect "main has nothing production lacks: says the fix goes straight through main" said s1 "nothing that production lacks"
expect "... starts the fix branch off GitHub's main" bash -c "[ \"\$(git -C '$work' branch --show-current)\" = urgent-fix ] && [ \"\$(git -C '$work' rev-parse HEAD)\" = '$start_sha' ]"
expect "... printing the command in full" said s1 "+ git switch -c urgent-fix origin/main"
expect "... says to commit the fix and run it again" said s1 "run ./hotfix again"
expect "... nothing on GitHub yet" bash -c "grep -qx 0 '$tmp/s1.status' && ! grep -q '^gh ' '$tmp/s1.log' && ! git -C '$work' ls-remote --exit-code origin urgent-fix > /dev/null"

echo "v2" > "$work/apps/app.txt"
git -C "$work" commit -q -am "Fix the broken thing"
run s2 "" CHECK_EXIT=1
expect "./check fails: stops before the push" bash -c "grep -q '^check' '$tmp/s2.log' && ! grep -qx 0 '$tmp/s2.status' && ! git -C '$work' ls-remote --exit-code origin urgent-fix > /dev/null"
run s3 "yes\nno\n"
expect "the fix: ./check, push, pull request into main" bash -c "grep -q '^check' '$tmp/s3.log' && git -C '$work' ls-remote --exit-code origin urgent-fix > /dev/null && grep -q '^gh pr create --base main --head urgent-fix --title Fix the broken thing' '$tmp/s3.log'"
expect "... no to the merge: stops, main untouched" bash -c "grep -qF Stopped '$tmp/s3.out' && [ \"\$(git -C '$work' ls-remote origin refs/heads/main | cut -f1)\" = '$start_sha' ]"
run s4 "yes\nyes\nyes\n"
expect "run again: no second pull request, merges the open one (squash)" \
  bash -c "! grep -q '^gh pr create --base main' '$tmp/s4.log' && grep -q '^gh pr merge 1 --squash' '$tmp/s4.log'"
expect "... the fix is on main, squashed" bash -c "git -C '$work' fetch -q origin && [ \"\$(git -C '$work' log -1 --format=%s origin/main)\" = 'Fix the broken thing (#1)' ]"
expect "... asks whether it passed on the main environment, then promotes: pull request from main into production" \
  bash -c "grep -qF 'passed on the main environment' '$tmp/s4.out' && grep -q '^gh pr create --base production --head main' '$tmp/s4.log'"
expect "... waits for production's two checks before merging" in_order s4 "gh pr checks 2 --watch" "gh pr merge 2 --merge"
expect "... merged with a merge commit: production's second parent is main" bash -c "git -C '$work' fetch -q origin && [ \"\$(git -C '$work' rev-parse origin/production^2)\" = \"\$(git -C '$work' rev-parse origin/main)\" ]"
expect "... both merges under this checkout's commit email, not the GitHub account's" \
  bash -c "grep -q '^gh pr merge 1 --squash --author-email test@example.invalid\$' '$tmp/s4.log' && [ \"\$(git -C '$work' log -1 --format=%ae origin/main)\" = test@example.invalid ] && [ \"\$(git -C '$work' log -1 --format=%ae origin/production)\" = test@example.invalid ]"
expect "... production runs exactly main's files" bash -c "git -C '$work' diff --quiet origin/main origin/production && [ \"\$(git -C '$work' show origin/production:apps/app.txt)\" = v2 ]"
expect "... every pull request and merge printed in full before it ran" printed s4
expect "... and each push and merge asked about first" asked_first s3
expect "... (and after the run again)" asked_first s4
expect "... says it is done" bash -c "grep -qx 0 '$tmp/s4.status' && grep -qF 'Done' '$tmp/s4.out'"
run s5 ""
expect "run again afterwards: nothing to do" bash -c "grep -qx 0 '$tmp/s5.status' && grep -qF 'nothing that production lacks' '$tmp/s5.out' && ! grep -q '^gh ' '$tmp/s5.log'"

# --- With main set aside: main holds work not yet promoted ------------------------------------------
setup aside
on_github "Work under test" apps/work.txt "w"
on_github "Work under test, its entrance" modules/edge/main.tf "# edge v2"
on_github "Work under test, its cluster" modules/platform/main.tf "# platform v2"
work_sha="$(git -C "$work" rev-parse origin/main)"
git -C "$work" merge -q --ff-only origin/main
# Branches left on GitHub by an earlier fix (as the 2026-10-15 drill left set-aside and bring-back).
old="$(git -C "$work" commit-tree "origin/production^{tree}" -p origin/production -m "An earlier fix's branch")"
git -C "$work" push -q origin "$old:refs/heads/set-aside" "$old:refs/heads/bring-back"
run a0 "stop\n"
expect "main holds work: lists it, and asks whether it ships or is set aside" \
  bash -c "grep -qF 'Work under test, its cluster' '$tmp/a0.out' && grep -qF 'aside' '$tmp/a0.out' && ! grep -qx 0 '$tmp/a0.status' && ! grep -q '^gh ' '$tmp/a0.log'"
run a1 "aside\nyes\nyes\nyes\nyes\nurgent-fix\n" CLUSTERS=""
expect "aside: the bookmark main-deferred on GitHub is main as it was" \
  bash -c "[ \"\$(git -C '$work' ls-remote origin refs/heads/main-deferred | cut -f1)\" = '$work_sha' ]"
expect "... printed in full" said a1 "+ git push origin origin/main:refs/heads/main-deferred"
expect "... the set-aside branch is named after the bookmark, clear of an earlier fix's set-aside" \
  bash -c "grep -q \"^gh pr create --base main --head set-aside-${work_sha:0:7} \" '$tmp/a1.log'"
expect "... the set-aside is on main, squashed, and main's files are production's" \
  bash -c "git -C '$work' fetch -q origin && git -C '$work' log -1 --format=%s origin/main | grep -q '^Set aside, for an urgent fix' && git -C '$work' diff --quiet origin/production origin/main"
expect "... its message lists the work set aside" bash -c "git -C '$work' log -1 --format=%b origin/main | grep -qF 'Work under test, its entrance'"
expect "... applies main's edge from main, plan first, on the set-aside commit" \
  bash -c "grep -q 'envs/main/edge plan .*-detailed-exitcode' '$tmp/a1.log' && grep -q \"envs/main/edge apply -input=false tfplan-hotfix | commit=\$(git -C '$work' rev-parse origin/main)\" '$tmp/a1.log'"
expect "... skips the cluster root, main's cluster being down" \
  bash -c "grep -qF \"main's cluster is down\" '$tmp/a1.out' && ! grep -q 'envs/main/cluster' '$tmp/a1.log'"
expect "... then starts the fix branch off the new main" bash -c "[ \"\$(git -C '$work' branch --show-current)\" = urgent-fix ] && [ \"\$(git -C '$work' rev-parse HEAD)\" = \"\$(git -C '$work' rev-parse origin/main)\" ]"
expect "... every pull request and merge printed in full before it ran" printed a1
expect "... and each push, merge and apply asked about first" asked_first a1

echo "v2" > "$work/apps/app.txt"
git -C "$work" commit -q -am "Fix the broken thing"
run a2 "yes\nyes\nyes\nyes\nyes\nyes\nyes\nyes\nyes\n"
expect "the fix: pull request into main, merged; promoted with a merge commit" \
  bash -c "grep -q '^gh pr merge 2 --squash' '$tmp/a2.log' && grep -q '^gh pr create --base production --head main' '$tmp/a2.log' && grep -q '^gh pr merge 3 --merge' '$tmp/a2.log'"
expect "... production has the fix, and not the work set aside" \
  bash -c "git -C '$work' fetch -q --prune origin && [ \"\$(git -C '$work' show origin/production:apps/app.txt)\" = v2 ] && ! git -C '$work' cat-file -e origin/production:apps/work.txt 2> /dev/null"
expect "bring back: reverts the set-aside, printed in full, on a branch named after the bookmark" bash -c "grep -qF '+ git revert --no-edit' '$tmp/a2.out' && grep -q '^gh pr create --base main --head bring-back-${work_sha:0:7} --title Revert \"Set aside, for an urgent fix' '$tmp/a2.log'"
expect "... main has the work back, and the fix: it differs from the bookmark only in the fix" \
  bash -c "[ \"\$(git -C '$work' diff --name-only '$work_sha' origin/main)\" = apps/app.txt ]"
expect "... applies the same roots again from main, cluster too now that it is up" \
  bash -c "[ \"\$(grep -c 'envs/main/edge apply' '$tmp/a2.log')\" = 1 ] && [ \"\$(grep -c 'envs/main/cluster apply' '$tmp/a2.log')\" = 1 ]"
expect "... deletes the bookmark last" bash -c "! git -C '$work' ls-remote --exit-code origin main-deferred > /dev/null && grep -qF '+ git push origin --delete main-deferred' '$tmp/a2.out'"
expect "... no merge under the GitHub account's email" bash -c "! git -C '$work' log --format=%ae origin/main origin/production | grep -qxF primary@example.invalid"
expect "... every pull request and merge printed in full before it ran" printed a2
expect "... and each push, merge, apply and the deletion asked about first" asked_first a2
expect "... says it is done" bash -c "grep -qx 0 '$tmp/a2.status' && grep -qF 'Done' '$tmp/a2.out'"

# --- Something else merged into main after the bookmark, before the set-aside -----------------------
setup moved
on_github "Work under test" apps/work.txt "w"
git -C "$work" merge -q --ff-only origin/main
run m1 "aside\nyes\nno\n"
expect "bookmark saved, no to the push: stops" bash -c "grep -qF Stopped '$tmp/m1.out' && git -C '$work' ls-remote --exit-code origin main-deferred > /dev/null"
on_github "Someone else's change" apps/other.txt "o"
run m2 "yes\nyes\n"
expect "main moved since the bookmark: stops, nothing pushed or merged" \
  bash -c "grep -qF 'main has moved' '$tmp/m2.out' && ! grep -qx 0 '$tmp/m2.status' && ! grep -q '^gh pr' '$tmp/m2.log' && [ -z \"\$(git -C '$work' ls-remote origin 'refs/heads/set-aside-*')\" ]"

exit "$failed"
