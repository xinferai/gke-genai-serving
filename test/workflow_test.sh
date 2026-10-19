#!/usr/bin/env bash
# Walks the git histories of the promotion flow in a scratch repository: the production workflow's
# source-has-production script, run as GitHub runs it, and the urgent-fix steps ("set main aside" in
# docs/release-process.md): bookmark, set aside, fix, promote, bring back. The set-aside and bring-back
# commands are that document's, with production and main-deferred in place of origin/production and origin/main-deferred;
# keep the two in step. Part of ./check; touches no real repository and no GitHub.
# WF can name another copy of the workflow (used once, to prove this test catches a broken script).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
wf="${WF:-$here/.github/workflows/into-production.yml}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failed=0

# expect "<what>" <command...>: prints ok or FAIL.
expect() {
  local what="$1"
  shift
  if "$@"; then printf 'ok    %s\n' "$what"; else printf 'FAIL  %s\n' "$what"; failed=1; fi
}

script="$(yq e '.jobs["source-has-production"].steps[] | select(has("run")) | .run' "$wf")"
[ -n "$script" ] || { echo "FAIL  no source-has-production script in $wf"; exit 1; }

# The scratch repository plays GitHub's checkout: origin/production is set by hand, the way the
# workflow's full-history checkout has it.
repo="$tmp/repo"
git init -q -b main "$repo"
g() {
  git -C "$repo" -c user.name=lab -c user.email=lab@example.invalid -c commit.gpgsign=false \
    -c core.hooksPath=/dev/null "$@"
}
# change <name>: one commit adding the file <name>.txt, so no two changes ever conflict.
change() { echo "$1" > "$repo/$1.txt" && g add "$1.txt" && g commit -q -m "$1"; }
# edit <name> <text>: one commit setting <name>.txt to <text>.
edit() { echo "$2" > "$repo/$1.txt" && g add "$1.txt" && g commit -q -m "$1: $2"; }
merge_into() { g switch -q "$1" && g merge -q --no-ff -m "Merge $2 into $1" "$2"; }
# squash_into <target> <branch>: the branch as one new commit on <target>, the way GitHub squashes: the
# subject is the branch's last commit's, plus the pull request number (here "(squashed)").
squash_into() {
  local subject
  subject="$(g log -1 --format=%s "$2")" &&
    g switch -q "$1" && g merge -q --squash "$2" > /dev/null 2>&1 && g commit -q -m "$subject (squashed)"
}
published() { g update-ref refs/remotes/origin/production "${1:-production}"; }
# passes <branch>: the check, run as GitHub runs it (bash -e, pipefail) for a pull request from <branch>.
passes() {
  (cd "$repo" && HEAD_SHA="$(git rev-parse "$1")" bash -e -o pipefail -c "$script") > "$tmp/out" 2>&1
}
fails() { ! passes "$1"; }
names() { grep -q " $1\$" "$tmp/out"; }   # the failure lists the missing commit by its subject
# same <branch>: after a merge, the branch's files are exactly those of what it merged in (<branch>^2).
same() { g diff --quiet "$1^2" "$1"; }
files_equal() { g diff --quiet "$1" "$2"; }
has_file() { g cat-file -e "$1:$2" 2> /dev/null; } # has_file <commit> <path>
lacks_file() { ! has_file "$1" "$2"; }
# changed_between <a> <b> "<paths>": exactly these paths differ between a and b.
changed_between() { [ "$(g diff --name-only "$1" "$2" | LC_ALL=C sort | xargs)" = "$3" ]; }
mid_revert() { g rev-parse -q --verify REVERT_HEAD > /dev/null; }

# The urgent-fix steps, as docs/release-process.md has them.
set_aside() { # set_aside <branch>: off main, one commit returning every file to production's
  [ -z "$(g status --porcelain)" ] && g switch -q -c "$1" main 2> /dev/null &&
    g restore --source=production --staged --worktree :/ &&
    g commit -q -m "Set aside, for an urgent fix: main's files return to production's"
}
# --topo-order: with a merge commit, the set-aside commit (the merge's parent) must come before the merge.
aside_commit() { g rev-list --reverse --topo-order --ancestry-path main-deferred..main | head -1; }
bring_back() { # bring_back <branch>: off main, the revert of the set-aside commit, once its subject says so
  local aside
  [ -z "$(g status --porcelain)" ] && aside="$(aside_commit)" && [ -n "$aside" ] &&
    case "$(g log -1 --format=%s "$aside")" in "Set aside, for an urgent fix"*) ;; *) false ;; esac &&
    g switch -q -c "$1" main && g revert --no-edit "$aside" > /dev/null 2>&1
}

# --- The source-has-production check -----------------------------------------------------------
change start && g tag start
edit config original
g branch production
change feature-a
merge_into production main                     # the first promotion: a merge commit only production has
g switch -q main && change feature-b           # main moves on
published
expect "a promotion passes: production's only extra commit is a promotion merge" passes main

g switch -q -c drifted production && change direct-push
published drifted                              # production changed while a rule was off
expect "a production changed while a rule was off blocks the next promotion" fails main
expect "... and the failure names the change" names direct-push
published

g switch -q -c rewritten start && change redo  # main rewritten by force, from before the promotion
expect "a main rewritten by force fails: it dropped a change production has" fails rewritten
expect "... and names what it dropped" names feature-a

# --- An urgent fix while main holds work not yet promoted: set main aside ----------------------
g switch -q main && g rm -q config.txt && g commit -q -m "drop config" # the deferred work deletes a file
change feature-c                                                     # ... and adds one
echo '*.local' >> "$repo/.git/info/exclude" && echo scratch > "$repo/plan.local" # an ignored file
g branch main-deferred main                                          # step 1: bookmark
set_aside set-aside                                                  # step 2
expect "set aside: main's files equal production's" files_equal set-aside production
expect "... files the deferred work added are gone" lacks_file set-aside feature-c.txt
expect "... files it deleted are back" has_file set-aside config.txt
expect "... an ignored file in the checkout is left alone" test -f "$repo/plan.local"
expect "... and is not committed" lacks_file set-aside plan.local
squash_into main set-aside
expect "after the set-aside, main can be promoted" passes main

g switch -q -c fix main && change fix && squash_into main fix         # step 3
merge_into production main                                           # step 4
published
expect "after the promotion, production's files are exactly main's" same production
expect "... it has the fix" has_file production fix.txt
expect "... and none of the set-aside work" lacks_file production feature-c.txt
g switch -q -c fix-2 main && change fix-two && squash_into main fix-2 # a second fix before the bring-back
expect "the set-aside commit is the first commit on main after main-deferred" \
  test "$(g log -1 --format=%s "$(aside_commit)")" = "Set aside, for an urgent fix: main's files return to production's (squashed)"
bring_back bring-back && squash_into main bring-back                 # step 5
expect "bring back: the deferred work returns" has_file main feature-c.txt
expect "... the file it deleted is deleted again" lacks_file main config.txt
expect "... main-deferred to main is the fixes and nothing else" changed_between main-deferred main "fix-two.txt fix.txt"
before="$(g rev-parse main)"
g merge -q main-deferred > /dev/null 2>&1
expect "merging main-deferred back changes nothing" test "$(g rev-parse main)" = "$before"
expect "after the bring-back, main can be promoted" passes main
merge_into production main
expect "... and after that promotion production's files are exactly main's" same production

# The set-aside pull request merged with a merge commit instead of a squash (main allows both).
g branch -D -q main-deferred
g switch -q main && change feature-d
g branch main-deferred main
set_aside set-aside-2 && merge_into main set-aside-2
g switch -q -c fix-3 main && change fix-three && squash_into main fix-3
bring_back bring-back-2 && squash_into main bring-back-2
expect "a set-aside merged with a merge commit is still found and brought back" has_file main feature-d.txt
expect "... main-deferred to main is the fix and nothing else" changed_between main-deferred main "fix-three.txt"

# A fix on the same lines as the deferred work: the bring-back stops for a hand resolution.
g branch -D -q main-deferred
edit start deferred
g branch main-deferred main
set_aside set-aside-3 && squash_into main set-aside-3
g switch -q -c fix-4 main && edit start fixed && squash_into main fix-4
bring_back bring-back-3
expect "a fix on the same lines as the deferred work stops the bring-back for a hand resolution" mid_revert
g revert --abort > /dev/null 2>&1

# --- What the document's guards must stop -------------------------------------------------------
stopped() { if "$@"; then return 1; else return 0; fi; } # stopped <command...>: it refused
g switch -q main && echo unsaved >> "$repo/start.txt"
expect "uncommitted changes stop the set-aside" stopped set_aside set-aside-4
expect "... and are still there" grep -q unsaved "$repo/start.txt"
g checkout -q -- start.txt
g switch -q -c my-feature main && change wip
expect "a branch name left over stops the set-aside before anything changes" stopped set_aside set-aside
expect "... the checked-out branch and its files are untouched" \
  test "$(g branch --show-current)" = my-feature -a -f "$repo/wip.txt"

# A pull request merged into main between the bookmark and the set-aside's merge.
g branch -D -q main-deferred
g switch -q main && change feature-e
g branch main-deferred main
set_aside set-aside-5
g switch -q -c other main && change other-work && squash_into main other
squash_into main set-aside-5
expect "a change merged meanwhile shows in the after-merge check: main is not production" \
  stopped files_equal main production
expect "... and the bring-back stops before it reverts the wrong commit" stopped bring_back bring-back-5
expect "... having changed nothing" test "$(g branch --show-current)" = main
exit "$failed"
