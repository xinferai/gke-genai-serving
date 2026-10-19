# Urgent fixes through `main` ("set `main` aside"): implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `production` takes pull requests from `main` only, and an urgent fix reaches it through `main` and the main
environment by setting `main` aside, so no change ever reaches production untested.

**Architecture:** The workflow's `source-allowed` accepts `main` only; `source-has-production` stays as a guard. The
set-aside procedure is plain git and pull requests, written in the README and walked offline in a scratch repository
by `test/workflow_test.sh`, which `./check` runs. A drill on the main environment (D1 to D5) proves it live.

**Tech Stack:** bash, git, yq, GitHub Actions (`pull_request_target`), GitHub rulesets, Argo CD, Kustomize.

**Spec:** `docs/superpowers/specs/2026-10-15-two-environments-design.md` (part 3 "An urgent fix while `main` holds
unpromoted work: set `main` aside", part 4 step F, part 5 offline tests and the urgent-fix drill D1 to D5).

## Global Constraints

- Work on branch `set-main-aside`, made from `origin/main` (`c8c7371`); the design change already sits there,
  uncommitted.
- Every commit, push, pull request, merge, GitHub setting and live drill step waits for Sam's word. Merging is the
  deploy and always his call. Local commits on `set-main-aside` need a standing go (asked at the handoff).
- Never force-push `main` and never switch a ruleset off: every set-aside step is an ordinary pull request.
- The workflow keeps `pull_request_target`, `permissions: {}` (contents read for the history check only), the checkout
  pinned to `3d3c42e5aac5ba805825da76410c181273ba90b1`, and names and commit ids passed as environment variables.
- Names, verbatim: the procedure is "set `main` aside"; the bookmark branch is `main-deferred`; the set-aside commit's
  subject is `Set aside, for an urgent fix: main's files return to production's`.
- The README's set-aside and bring-back commands and `test/workflow_test.sh`'s are the same commands (the test uses
  `production` and `main-deferred` where the README has `origin/production` and `origin/main-deferred`).
- Plain developer vocabulary in every comment and document.

## Review Focus

1. Deferred work that deleted a file production has: the set-aside must bring the file back (Task 2, "files it
   deleted are back").
2. Ignored files in the checkout (`.terraform/`, `.kube/`, plan files): the set-aside must leave them alone and never
   commit them (Task 2, "an ignored file in the checkout is left alone", "... and is not committed").
3. More than one fix merged before the bring-back: the bring-back must still find the set-aside commit and return the
   deferred work (Task 2, "a second fix before the bring-back").
4. The set-aside pull request merged with a merge commit instead of a squash (`main` allows both): the bring-back must
   still find it (Task 2, "a set-aside merged with a merge commit is still found").
5. Branch names close to `main` (`Main`, `main-old`, `my/main`, `main; true`, an empty name) and any `hotfix/...`
   branch: `source-allowed` must reject them all (Task 1).

---

### Task 1: Only `main` may be merged into `production`

**Files:**
- Modify: `test/checks/60-github.sh` (the `source-allowed` checks at the end)
- Modify: `.github/workflows/into-production.yml` (header comment lines 1 to 8; the `source-allowed` job)
- Commit first: `docs/superpowers/specs/2026-10-15-two-environments-design.md` (the approved design change)

**Interfaces:**
- Consumes: `check`, `from_branch`, `rejects` (already in `60-github.sh`).
- Produces: the job id `source-allowed` (unchanged: it is a required check's name on `production`).

- [ ] **Step 1: Commit the approved design change (standing go only)**

```bash
cd ~/projects/gke-lab && git switch set-main-aside
git add docs/superpowers/specs/2026-10-15-two-environments-design.md docs/superpowers/plans/2026-10-15-set-main-aside.md
git commit -m "Design: urgent fixes go through main (set main aside), replacing the hotfix lane

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 2: Write the failing check**

In `test/checks/60-github.sh`, delete the line

```bash
check "production workflow: source-allowed passes a pull request from a hotfix/ branch" from_branch hotfix/ingress-timeout
```

and replace the `rejects` check with:

```bash
check "production workflow: source-allowed fails any other branch, hotfix/ included" \
  rejects feature hotfix/ingress-timeout hotfix/ hotfixes/x main-old Main my/main 'main; true' ''
```

- [ ] **Step 3: Run it to see it fail**

Run: `./check 2>&1 | grep -A1 'source-allowed fails'`
Expected: `FAIL  production workflow: source-allowed fails any other branch, hotfix/ included` with `accepted:
hotfix/ingress-timeout`.

- [ ] **Step 4: Make `source-allowed` accept `main` only**

In `.github/workflows/into-production.yml`, replace the header's first eight lines with:

```yaml
# Every pull request into production gets two checks, both required on the production branch (GitHub
# ruleset):
# - source-allowed: the source is main. Every change reaches production through main and the main
#   environment, urgent fixes included (README, "An urgent fix": set main aside, fix, promote, bring back).
# - source-has-production: main already has every change production has. Promotion merge commits are
#   the only commits production has that main lacks, so merge commits are left out. With main the only
#   source this holds by construction; the check guards against a main rewritten by force, or a
#   production changed while a rule was off.
```

and the `source-allowed` job's step with:

```yaml
      - name: The pull request comes from main
        env:
          HEAD_REF: ${{ github.head_ref }}
        run: |
          if [ "$HEAD_REF" = main ]; then
            echo "From main: a promotion."
          else
            echo "This pull request comes from '$HEAD_REF'. Only main may be merged into production. For an"
            echo "urgent fix while main holds work not yet promoted, set main aside first (README, \"An urgent fix\")."
            exit 1
          fi
```

- [ ] **Step 5: Run it to see it pass**

Run: `./check > "$TMPDIR/check.log" 2>&1; echo "exit $?"; grep -c '^PASS' "$TMPDIR/check.log"; grep '^FAIL' "$TMPDIR/check.log"`
Expected: `exit 0`, `109` (one check fewer: the hotfix pass is gone), no FAIL lines.

- [ ] **Step 6: Commit (standing go only)**

```bash
git add .github/workflows/into-production.yml test/checks/60-github.sh
git commit -m "Let production take pull requests from main only

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The history test walks the set-aside steps

**Files:**
- Modify: `test/workflow_test.sh` (full rewrite)

**Interfaces:**
- Consumes: the `source-has-production` script in `.github/workflows/into-production.yml` (read with yq); `WF` to
  name another copy of the workflow.
- Produces: `test/workflow_test.sh`, exit 0 when every line is `ok` (`./check` runs it as "production workflow:
  source-has-production, run on scratch branch histories"; the check's name stays).

- [ ] **Step 1: Rewrite the test**

Replace `test/workflow_test.sh` with:

```bash
#!/usr/bin/env bash
# Walks the git histories of the promotion flow in a scratch repository: the production workflow's
# source-has-production script, run as GitHub runs it, and the urgent-fix steps ("set main aside" in the
# README): bookmark, set aside, fix, promote, bring back. The set-aside and bring-back commands are the
# README's, with production and main-deferred in place of origin/production and origin/main-deferred;
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
# squash_into <target> <branch>: the branch as one new commit on <target>, the way GitHub squashes.
squash_into() { g switch -q "$1" && g merge -q --squash "$2" > /dev/null && g commit -q -m "$2 (squashed)"; }
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

# The urgent-fix steps, as the README has them.
set_aside() { # set_aside <branch>: off main, one commit returning every file to production's
  g switch -q -c "$1" main && g restore --source=production --staged --worktree :/ &&
    g commit -q -m "Set aside, for an urgent fix: main's files return to production's"
}
# --topo-order: with a merge commit, the set-aside commit (the merge's parent) must come before the merge.
aside_commit() { g rev-list --reverse --topo-order --ancestry-path main-deferred..main | head -1; }
bring_back() { # bring_back <branch>: off main, the revert of the set-aside commit
  local aside
  aside="$(aside_commit)" && [ -n "$aside" ] &&
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
  test "$(g log -1 --format=%s "$(aside_commit)")" = "set-aside (squashed)"
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
exit "$failed"
```

- [ ] **Step 2: Run it**

Run: `bash test/workflow_test.sh; echo "exit $?"`
Expected: 24 lines, all `ok`, `exit 0`.

- [ ] **Step 3: Prove it catches a broken history check**

Run: `yq e '.jobs["source-has-production"].steps[1].run |= sub("--no-merges "; "")' .github/workflows/into-production.yml > "$TMPDIR/wf-broken.yml" && WF="$TMPDIR/wf-broken.yml" bash test/workflow_test.sh | grep '^FAIL' | head -3`
Expected: at least `FAIL  a promotion passes: production's only extra commit is a promotion merge` (counting
promotion merges as missing breaks every promotion).

- [ ] **Step 4: Prove it catches the classic set-aside mistake**

`git checkout production -- .` looks like a set-aside but leaves the files main added in place.

Run: `sed 's|g restore --source=production --staged --worktree :/|g checkout production -- .|' test/workflow_test.sh > "$TMPDIR/wt-broken.sh" && WF="$PWD/.github/workflows/into-production.yml" bash "$TMPDIR/wt-broken.sh" | grep '^FAIL' | head -3`
Expected: `FAIL  set aside: main's files equal production's` and `FAIL  ... files the deferred work added are gone`.

- [ ] **Step 5: Run the whole suite**

Run: `./check > "$TMPDIR/check.log" 2>&1; echo "exit $?"; grep -c '^PASS' "$TMPDIR/check.log"; grep '^FAIL' "$TMPDIR/check.log"; bash test/wrappers_test.sh | tail -1; bash test/bootstrap_test.sh | tail -1`
Expected: `exit 0`, `109`, no FAIL lines; both other test scripts end with an `ok` line.

- [ ] **Step 6: Commit (standing go only)**

```bash
git add test/workflow_test.sh
git commit -m "Walk the set-aside steps in the history test: set aside, fix, promote, bring back

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The README tells the new way, with the exact commands

**Files:**
- Modify: `test/checks/70-readme.sh` (the wanted and stale lists)
- Modify: `README.md` (section "Two environments, two branches")
- Modify: `docs/superpowers/specs/2026-10-15-two-environments-design.md` (status line)
- Modify: the session notes outside this repository (a progress note; not committed here)

**Interfaces:**
- Consumes: the set-aside and bring-back commands of Task 2 (with `origin/`).
- Produces: README text the drill (Task 4) follows step by step.

- [ ] **Step 1: Write the failing README check**

In `test/checks/70-readme.sh`, replace the `for want in ...; do` list with:

```bash
  for want in './tf main cluster plan' './bootstrap main' './k main get nodes' './check' 'delete application root' \
    'replicaCount: 0' 'ollama.replicaCount' "switch off automatic sync on \`root\`" 'never squash' \
    'apps/chat/env/<env>.yaml' '.kube/<env>/config' 'chat-lab-main.liveinference.com' 'set `main` aside' \
    'always promotable' 'into-production.yml' 'source-allowed' 'source-has-production' 'main-deferred' \
    'git restore --source=origin/production --staged --worktree :/' \
    'git rev-list --reverse --topo-order --ancestry-path origin/main-deferred..origin/main | head -1' 'never force-push' \
    'production^2' '--first-parent'; do
```

and add `|hotfix` to the end of the `stale` pattern (inside the quotes, after `\./bootstrap *($|#)`).

- [ ] **Step 2: Run it to see it fail**

Run: `./check 2>&1 | grep -A2 'README describes'`
Expected: `FAIL  README describes the two-environment way of working` with `README does not mention: set \`main\` aside`.

- [ ] **Step 3: Rewrite the README's flow paragraphs**

In `README.md`, replace the paragraph that starts `Every change goes: a short-lived branch off \`main\` (a hotfix`
with:

```markdown
Every change goes: a short-lived branch off `main` → pull request into `main` → test on the main environment → pull
request from `main` into `production` (merge commit, never squash: a squash makes a commit `main` never had, and the
branches drift apart) → production. Urgent fixes too (below). After each promotion, `git diff origin/production^2
origin/production` prints nothing: production runs exactly the files the main environment tested. The promotion merge
commit is only on `production`, so the two branch tips are never the same commit, and `production` is never merged
into `main`: `git log --first-parent origin/production` lists every promotion, and each one's `^2` is the commit it
brought in.
```

In the paragraph that starts `GitHub enforces it`, replace `` `source-allowed` (it comes from `main` or a `hotfix/...`
branch) and `` with `` `source-allowed` (it comes from `main`) and `` and `(it already has every change \`production\`
has, merge commits left out)` with `` (`main` already has every change `production` has, merge commits left out) ``.

Replace the paragraph that starts `A hotfix that cannot wait for \`main\`` with:

````markdown
**An urgent fix while `main` holds work not yet promoted** (under test, or known to be broken): set `main` aside, fix
and test on the main environment, promote, then bring the work back. Each step is an ordinary pull request; never
force-push `main`. If `main` can be promoted now, skip all this: the fix goes through `main` like any change, just fast.

```bash
git fetch origin
# 1. Bookmark what is set aside.
git push origin origin/main:refs/heads/main-deferred
# 2. Set aside: one commit returning every file to production's (files main added are deleted).
git switch -c set-aside origin/main
git restore --source=origin/production --staged --worktree :/
git commit -m "Set aside, for an urgent fix: main's files return to production's" \
  -m "$(git log --no-merges --format='- %h %s' origin/production..origin/main)"
git diff --quiet origin/production HEAD && echo "files equal production's"
#    Push, pull request into main, merge. Then, from main, apply each Terraform root this lists, so the main
#    environment matches production: git diff --name-only origin/production origin/main-deferred -- envs/main modules
# 3. The fix: a short-lived branch off main, ./check, pull request into main, merge; test it on the main environment.
# 4. Promote main → production as usual.
# 5. Bring back: revert the set-aside commit, the first commit on main after main-deferred.
git fetch origin && git switch -c bring-back origin/main
git revert --no-edit "$(git rev-list --reverse --topo-order --ancestry-path origin/main-deferred..origin/main | head -1)"
#    A conflict means the fix touched the same lines: resolve it here. Push, pull request into main, merge.
git fetch origin && git diff --stat origin/main-deferred origin/main   # the fix, and nothing else
git push origin --delete main-deferred
```

Then start the interrupted test again on the main environment. Merging `main-deferred` back would do nothing: its
commits are still in `main`'s history. The revert is what brings the files back. The price: the test that was running
starts over, and step 5 can conflict. For relief while the fix is on its way, roll production back by hand in Argo CD
(see "Argo CD": switch off automatic sync on `root` first).
````

- [ ] **Step 4: Run it to see it pass**

Run: `./check > "$TMPDIR/check.log" 2>&1; echo "exit $?"; grep -c '^PASS' "$TMPDIR/check.log"; grep '^FAIL' "$TMPDIR/check.log"; grep -n -i hotfix README.md`
Expected: `exit 0`, `109`, no FAIL lines, and no README line mentions hotfix.

- [ ] **Step 5: Status line and progress note**

In the design, replace the status sentence `Change proposed 2026-10-15 at Sam's request, waiting for his review: urgent
fixes go through \`main\` ("set \`main\` aside", part 3) instead of the hotfix lane; not built.` with `Change approved by
Sam on 2026-10-15: urgent fixes go through \`main\` ("set \`main\` aside", part 3) instead of the hotfix lane; built on
branch \`set-main-aside\` (plan: docs/superpowers/plans/2026-10-15-set-main-aside.md), not yet merged.`

In the session notes outside this repository, after the last "Progress, 2026-10-15" note, add:

```markdown
Progress, 2026-10-15 (night, last): Sam replaced the hotfix lane: every change reaches `production` through `main` and
the main environment. For an urgent fix while `main` holds untested work, `main` is set aside to production's version
by a pull request (bookmark `main-deferred`), the fix is tested on the main environment and promoted, and a revert of
the set-aside commit brings the work back; no force-push. Built offline on branch `set-main-aside` (`./check` 109,
`test/workflow_test.sh` 24); the drill D1 to D5 on the main environment follows its merge.
```

- [ ] **Step 6: Commit (standing go only)**

```bash
git add README.md test/checks/70-readme.sh docs/superpowers/specs/2026-10-15-two-environments-design.md
git commit -m "README: urgent fixes go through main, with the set-aside and bring-back commands

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Hand over the gates: merge, promote, and the drill

No code. Report to Sam, in this order, each step on his word. D1 to D5 are the design's part 5 drill.

- [ ] **GATE A: into `main`, then promoted.**

```bash
./check                                    # Expected: exit 0, 109 PASS
git push -u origin set-main-aside
gh pr create --base main --head set-main-aside \
  --title "Urgent fixes go through main: set main aside, fix, promote, bring back" \
  --body "Implements the change to docs/superpowers/specs/2026-10-15-two-environments-design.md (part 3, set main aside; plan: docs/superpowers/plans/2026-10-15-set-main-aside.md). production now takes pull requests from main only. ./check passes offline.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
# Sam merges (squash is fine). From then on main's copy of the workflow judges every pull request into production.
git fetch origin && git switch main && git pull --ff-only
gh pr create --base production --head main --title "Promote main to production: urgent fixes go through main" \
  --body "Promotion. Merge with a merge commit.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
gh pr checks main --watch                 # Expected: source-allowed pass, source-has-production pass
# Sam merges with a merge commit. Then:
git fetch origin && git diff --stat 'origin/production^2' origin/production   # Expected: prints nothing
```

- [ ] **GATE B: D5, a pull request from a branch other than `main`** (no cluster needed).

```bash
git switch -c hotfix/drill origin/production
git commit --allow-empty -m "Drill D5: a pull request from a branch other than main (never merged)"
git push -u origin hotfix/drill
gh pr create --base production --head hotfix/drill --title "Test only, do not merge: drill D5" \
  --body "Drill D5 of docs/superpowers/specs/2026-10-15-two-environments-design.md. Closed without merging.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
gh pr checks hotfix/drill --watch          # Expected: source-allowed fail ("Only main may be merged into production")
gh pr view hotfix/drill --json mergeStateStatus --jq .mergeStateStatus   # Expected: BLOCKED
git switch main && gh pr close hotfix/drill --delete-branch
```

- [ ] **GATE C: D1 to D4 on the main environment** (main's cluster up; production's too, to see D3 arrive there).
  Every pull request into `main` is merged by Sam (squash); every promotion by merge commit. Wait for an annotation
  with `until [ "$(./k <env> -n chat get httproute <route> -o jsonpath='{.metadata.annotations.lab\.liveinference\.com/<key>}')" = <value> ]; do sleep 15; done`
  (Argo CD looks at GitHub about every 3 minutes).

D1, a harmless change standing in for work under test: branch `drill-d1` off `origin/main`; in
`apps/chat/edge/base/edge.yaml`, `HTTPRoute chat`, after `namespace: chat` add

```yaml
  annotations:
    lab.liveinference.com/drill: d1
```

`./check`, commit `Drill D1: an annotation on the chat route, standing in for work under test`, push, pull request
into `main`, merge. Expected: `./k main -n chat get httproute chat` carries `lab.liveinference.com/drill: d1`.

D2, bookmark and set aside: the README's steps 1 and 2, verbatim. Expected: `git diff origin/production origin/main`
prints nothing after the merge; `git diff --name-only origin/production origin/main-deferred -- envs/main modules`
prints nothing (no Terraform to apply); the `d1` annotation leaves `HTTPRoute chat` on the main environment.

D3, the fix: branch `drill-fix` off `origin/main`; in `HTTPRoute chat-redirect`, after `namespace: chat` add

```yaml
  annotations:
    lab.liveinference.com/drill-fix: d3
```

`./check`, commit `Drill D3: an annotation on the redirect route, standing in for the urgent fix`, push, pull request
into `main`, merge. Expected: the main environment's `chat-redirect` carries `drill-fix: d3`. Then the promotion pull
request `main` → `production`, merge commit. Expected: `git diff --stat 'origin/production^2' origin/production`
prints nothing; production's `chat-redirect` carries `drill-fix: d3`; production's `chat` has no `drill` annotation.

D4, bring back: the README's step 5, verbatim. Expected: `git diff origin/main-deferred origin/main` shows only the two
`drill-fix` lines; the main environment's `chat` carries `drill: d1` again and `chat-redirect` keeps `drill-fix: d3`;
`main-deferred` deleted.

Clean up: branch `drill-cleanup` off `origin/main` removing both annotations, `./check`, pull request into `main`,
merge, promote (merge commit). Expected: `git diff --stat 'origin/production^2' origin/production` prints nothing,
and neither environment's routes carry a drill annotation.

Timings and findings go into `plan.md`'s progress notes.
