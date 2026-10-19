# Releasing: two environments, two branches

## The path of every change

Every change goes: a short-lived branch off `main` → pull request into `main` → test on the main environment → pull
request from `main` into `production` (merge commit, never squash: a squash makes a commit `main` never had, and the
branches drift apart) → production. Urgent fixes too (below). After each promotion, `git diff origin/production^2
origin/production` prints nothing: production runs exactly the files the main environment tested. The promotion merge
commit is only on `production`, so the two branch tips are never the same commit, and `production` is never merged
into `main`: `git log --first-parent origin/production` lists every promotion, and each one's `^2` is the commit it
brought in. What each environment has, and the files that set it: the table in the
[README](../README.md#two-environments).

GitHub enforces it: no direct pushes to either branch, and two required checks (`.github/workflows/into-production.yml`)
on every pull request into `production`: `source-allowed` (it comes from `main`) and `source-has-production` (`main`
already has every change `production` has, merge commits left out). They run from
`main`'s copy of the workflow (`pull_request_target` takes the default branch's copy), so a pull request cannot change
the checks that judge it; whatever is merged into `main` can. Design:
[superpowers/specs/2026-10-15-two-environments-design.md](superpowers/specs/2026-10-15-two-environments-design.md).

Keep `main` always promotable: promotion moves all of `main` at once, so merge into it only what would ship once it
passes on the main environment. If something there fails, revert it on `main` before the next promotion, or it blocks
everything behind it. Promote often, so the gap between `main` and `production` stays small.

## An urgent fix

When `main` holds work not yet promoted (under test, or known to be broken): set `main` aside, fix and
test on the main environment, promote, then bring the work back. Each step is an ordinary pull request, and you
never force-push `main`. If `main` can be promoted now, skip all this: the fix goes through `main` like any change,
just fast.

`./hotfix` walks either way, in this checkout (nothing uncommitted). Run it, do what it says, and run it again: each
time it reads from GitHub where the fix stands and goes on from there. If `main` holds work `production` lacks, it lists
it and asks whether it ships now (`promote`) or is set aside (`aside`). It prints every command in full before running
it (`+ git push origin …`), and asks for `yes` before each push, pull request, merge, apply and deletion; any other
answer stops it, and the next run picks up where it stopped. It makes the fix's branch off `main` and stops for you to
commit the fix; the next run runs `./check`, opens the pull request, and asks whether the fix passed on the main
environment before it promotes. A conflict in step 5 stops it with what to do. Its own branches are named after the
bookmark (`set-aside-<commit>`, `bring-back-<commit>`), so branches an earlier fix left on GitHub never get in the
way. The steps by hand, which it follows:

Start from a clean checkout: the set-aside rewrites every tracked file. Paste each block whole; `&&` stops it at the
first failure.

1 and 2. Bookmark what is set aside, then one commit returning every file to production's (files `main` added are
deleted):

```bash
[ -z "$(git status --porcelain)" ] || { echo "stop: commit or stash your changes first"; false; } &&
  git fetch origin &&
  git push origin origin/main:refs/heads/main-deferred &&
  git switch -c set-aside origin/main &&
  git restore --source=origin/production --staged --worktree :/ &&
  git commit -m "Set aside, for an urgent fix: main's files return to production's" \
    -m "$(git log --no-merges --format='- %h %s' origin/production..origin/main)" &&
  git diff --stat origin/production HEAD   # prints nothing: the files equal production's
```

Push, pull request into `main`, merge. Then check that `main` equals production (nothing else was merged meanwhile),
and list the Terraform roots the set-aside work had changed:

```bash
git fetch origin && git diff --stat origin/production origin/main   # prints nothing
git diff --name-only origin/production origin/main-deferred -- envs/main modules
```

A path under `envs/main/<root>/` belongs to that root, `modules/edge/` to `edge`, and any other module to `cluster`.
Apply each of those roots from `main` (`./tf main <root> plan -out=<file>`, then `apply <file>`), so the main
environment matches production.

3. The fix: a short-lived branch off `main`, `./check`, pull request into `main`, merge; test it on the main
environment.

4. Promote `main` → `production` as usual.

5. Bring back: revert the set-aside commit, the first commit on `main` after `main-deferred`:

```bash
[ -z "$(git status --porcelain)" ] || { echo "stop: commit or stash your changes first"; false; } &&
  git fetch origin &&
  aside="$(git rev-list --reverse --topo-order --ancestry-path origin/main-deferred..origin/main | head -1)" &&
  git log -1 --format='reverting %h %s' "$aside" &&
  case "$(git log -1 --format=%s "$aside")" in
    "Set aside, for an urgent fix"*) ;;
    *) echo "stop: that is not the set-aside commit (was something else merged into main first?)"; false ;;
  esac &&
  git switch -c bring-back origin/main &&
  git revert --no-edit "$aside" &&
  git diff --stat origin/main-deferred HEAD   # the fix, and nothing else
```

A conflict means the fix touched the same lines: resolve it, `git revert --continue`, and check with `git diff --stat
origin/main-deferred HEAD`. Push, pull request into `main`, merge. Then apply the same Terraform roots again from
`main` (the list from step 2), so the main environment runs the set-aside work again, and start the interrupted test
over. Last, once all is well: `git push origin --delete main-deferred`.

Merging `main-deferred` back would do nothing: its commits are still in `main`'s history. The revert is what brings
the files back. The price: the test that was running starts over, and step 5 can conflict. For relief while the fix
is on its way, roll production back by hand in Argo CD ([argocd.md](argocd.md): switch off automatic sync on `root`
first).

## What differs between the environments

The environments are exact copies, GPU included. What differs lives in files named after the environment, present on
both branches, so a merge from `main` never carries main's settings into production: `envs/<env>/*/terraform.tfvars`,
the bucket and prefix in `envs/<env>/*/versions.tf`, `apps/chat/env/<env>.yaml`, `apps/chat/edge/<env>/`, and
`argocd/<env>/`.
