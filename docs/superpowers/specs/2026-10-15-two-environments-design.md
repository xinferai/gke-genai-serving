# Two environments for the GKE lab, main and production: design

Status: design approved by Sam Wen on 2026-10-15; built and running (both environments up on 2026-10-15, the first
promotion done, checks G1, M1, M2 and P1 to P6 passed). Build plan: docs/superpowers/plans/2026-10-15-two-environments.md.
Change approved by Sam on 2026-10-15: urgent fixes go through `main` ("set `main` aside", part 3) instead of the
hotfix lane; built on branch `set-main-aside` (plan: docs/superpowers/plans/2026-10-15-set-main-aside.md), not yet
merged. Pilot POC work, not production work: "production"
is the name of an environment inside the lab, and nothing written about Sam calls this lab production.

Builds on `docs/superpowers/specs/2026-10-15-argocd-design.md` (Argo CD, one environment). Where the two disagree,
this design wins: it turns that single setup into two (see "What changes in the Argo CD design").

## What this is for

Sam's model, 2026-10-15: two long-lived branches, `main` (testing, collecting changes, the checkpoint) and
`production`; any number of short-lived branches; every change goes short-lived branch → `main` → `production`; two
GKE setups, one per branch.

Decided by Sam Wen on 2026-10-15:
- **Separate Google Cloud projects** per environment. The existing `samwen-gke-lab` becomes production and keeps
  `chat-lab.liveinference.com`; a new project holds main.
- **main is an exact copy of production**, GPU included (same Spot L4, same model, same settings except the hostname).
- **main's public entrance stays up between sessions**, like production's (about $15 a month more).
- **Approach 1: a folder per environment, a branch per version.** The branch decides which version runs; a folder or
  file named after the environment decides which environment's settings apply. Both branches carry both
  environments' files, so a merge from `main` into `production` never carries `main`'s settings across.
- **Urgent fixes go through `main` too** (Sam, 2026-10-15, replacing the hotfix lane built that day). When production
  needs a fix now and `main` cannot be promoted yet (Sam's case: `main` is several commits ahead and two hours into a
  test on the main environment), `main` is set aside to production's version by a pull request, the fix goes into
  `main` and is tested on the main environment, `main` is promoted, and the set-aside work is brought back (part 3).
  The lane it replaces sent a `hotfix/...` branch straight into `production`, so a fix reached production having
  passed `./check` only, never the main environment (Sam's objection).
- The five design parts below were approved one at a time in chat.

Assumed, and not corrected:
- Each environment is a full copy: its own cluster, Argo CD, chat app and public entrance; each Argo CD watches its
  own branch.
- Promotion is a pull request from `main` into `production`, protected by GitHub rules.
- Terraform stays a hand-run `./tf` per environment; running it from CI on merge is Session 4.
- The Argo CD work (built 2026-10-15, not committed) is the first change through the flow.
- Every step that changes GitHub, Google Cloud or DNS waits for Sam's word; merging is the deploy and is always his
  call.

Approaches not taken: everything in the branch (production simply holds different file contents: every promotion
either conflicts or carries main's settings into production, the classic failure of branch-per-environment); one
branch with a folder per environment and no `production` branch (often preferred by GitOps practitioners: promotion is
changing production's folder to the version main ran; it does not fit the branch model chosen, and the short
answer is that branches make promotion a reviewable pull request with a clear checkpoint, while the per-environment
files avoid that model's usual problem).

## 1. Google Cloud and Terraform

**The two projects.**

| | production | main |
|---|---|---|
| Project | `samwen-gke-lab` (existing) | new: `samwen-gke-lab-main` if that ID is free |
| Billing, account | "XInfer AI", your Google account | the same |
| gcloud profile | `gke-lab` (existing) | `gke-lab-main` (new) |
| Terraform state | `gs://samwen-gke-lab-tfstate` | `gs://samwen-gke-lab-main-tfstate`, in its own project |
| GPU quota ("GPUs (all regions)") | 1, approved 2026-10-14 | new request, 0 → 1 |
| Budget alert | "GKE lab", $50, 50/90/100% emails (existing) | the same, its own |
| Public address | `chat-lab.liveinference.com` | `chat-lab-main.liveinference.com` |

The new project is set up by hand once, like Session 0 (create, link billing, the same APIs, budget, state bucket,
profile, quota request), because the project must exist before Terraform can keep state in it. At a company a
separate "foundation" Terraform layer (a project factory) usually creates projects; not worth building for two lab
projects.

**Terraform layout.**
```
modules/
  network/  gke-cluster/  node-pool/    unchanged
  platform/   new: network + node service account and its roles + cluster + the system, apps and gpu pools
              (today's envs/lab/main.tf as a module)
  edge/       new: today's envs/edge/main.tf as a module; inputs: project, name (default "chat-lab"), hostname,
              allowed_cidrs
envs/
  production/cluster/   production/edge/
  main/cluster/         main/edge/
```
- Each environment root: `versions.tf` (provider and state location: its project's bucket, prefix = its own folder,
  e.g. `envs/main/cluster`), `main.tf` (one module call), `variables.tf`, `outputs.tf`, `terraform.tfvars` (project,
  region, zone, Sam's IP for the cluster; hostname and allowed IPs for the entrance).
- `main.tf` is identical between the two environments of a layer; `versions.tf` differs only in bucket and prefix.
  The difference between the environments is therefore exactly the difference between their `tfvars` files (checked
  by `./check`, part 5).
- Same shape everywhere: the same pools, zone (`us-central1-a`), cluster name (`lab`) and internal IP ranges. The
  projects' networks are separate and never joined, so the ranges cannot clash.
- The entrance keeps the resource names `chat-lab` in both projects (names are unique per project), so the hostname
  is its only difference.

**Moving what exists, without rebuilding anything.**
- `envs/lab`: its state has been empty since the teardown on 2026-10-14; the folder is retired.
- `envs/edge` (production's live entrance: the Certificate Manager API, the fixed IP 136.81.128.150, the DNS
  authorization, the certificate, the certificate map and its entry, the Cloud Armor policy; 7 resources) becomes
  `envs/production/edge`. A separate file there, `moved.tf`, holds one `moved` block per resource
  (`google_compute_global_address.chat` → `module.edge.google_compute_global_address.chat`, and so on), so
  `main.tf` stays identical to main's. The state file is copied from prefix `envs/edge` to `envs/production/edge` in
  the same bucket. Success: `./tf production edge plan` says No changes (0 to add, 0 to change, 0 to destroy).

**`./tf <env> <layer> <terraform arguments>`**, e.g. `./tf production edge plan`, `./tf main cluster apply tfplan`.
Both words are required (no default); `TF_ENV` goes away. It picks the profile (`gke-lab` or `gke-lab-main`) and the
folder `envs/<env>/<layer>`, and keeps the fresh-token handling it has today. The branch guard is in part 3.

## 2. The cluster side, per environment

The same rule throughout: one shared base, plus a small file per environment holding only what differs.

**The chat app's settings.**
```
apps/chat/values.yaml          everything shared: all of today's settings
apps/chat/env/main.yaml        WEBUI_URL = https://chat-lab-main.liveinference.com
apps/chat/env/production.yaml  WEBUI_URL = https://chat-lab.liveinference.com
```
The chart (open-webui 17.0.0) has two lists for this: `commonEnvVars` ("common across environments") and
`extraEnvVars`. Today's environment variables move to `commonEnvVars` in `values.yaml`, without `WEBUI_URL`; each
environment file sets `extraEnvVars` to `WEBUI_URL` alone. (A list set in a second values file replaces the first
file's list rather than adding to it, which is why the split is needed.)

**The entrance.**
```
apps/chat/edge/base/          today's edge.yaml, with no hostnames on the two routes
apps/chat/edge/main/          Kustomize: adds chat-lab-main.liveinference.com to both routes
apps/chat/edge/production/    Kustomize: adds chat-lab.liveinference.com to both routes
```

**Argo CD, one per cluster.**
```
argocd/values.yaml                           Argo CD's own settings, shared (unchanged)
argocd/base/root/   argocd/base/apps/        the root app; the chat and chat-edge apps; no branch, no environment
argocd/main/        argocd/main/apps/        Kustomize: branch main, env/main.yaml, edge/main
argocd/production/  argocd/production/apps/  the same for production
```
- `./bootstrap <env>` installs Argo CD in that environment's cluster and applies `argocd/<env>` (the root app only);
  the root app keeps `argocd/<env>/apps` running from branch `<env>`.
- In environment X: every app's `targetRevision` is X; `chat` reads `$values/apps/chat/values.yaml` then
  `$values/apps/chat/env/X.yaml`; `chat-edge` reads `apps/chat/edge/X` (a Kustomize folder, so the `include` filter
  goes away). Everything else (finalizers, automated sync with prune and self-heal, retry, `CreateNamespace`,
  `skipTests`, release name `chat`) is in the base and identical.
- One read-only deploy key per environment: `~/.ssh/gke-genai-serving-argocd-main` and
  `~/.ssh/gke-genai-serving-argocd-production`, so either can be revoked without the other. A deploy key cannot be limited
  to a branch: main's key can also read the `production` branch, read-only, which is harmless.

**Wrappers.** `./k <env> …`, `./h <env> …`, `./bootstrap <env>`: the environment is required, there is no default.
Each environment has its own kubeconfig in its own folder, `.kube/main/config` and `.kube/production/config`
(gitignored), so the gcloud auth plugin's token cache, which it writes next to the kubeconfig, is not shared either.

## 3. The promotion flow and GitHub rules

**How a change travels.**
1. Short-lived branch off `main`. `./check` passes. Pull request into `main`.
2. Merge into `main`: main's Argo CD deploys it within about 3 minutes (if main's cluster is up). Terraform changes
   are applied to the main environment from the `main` branch.
3. Test on the main environment.
4. Pull request from `main` into `production`. Merging it is the release: production's Argo CD deploys it;
   production's Terraform is applied from the `production` branch.
5. Afterwards `git diff production^2 production` prints nothing: `production^2` is the `main` commit just promoted, so
   production runs exactly the files the main environment tested.

**An urgent fix while `main` holds unpromoted work: set `main` aside** (Sam, 2026-10-15). It replaces the hotfix lane,
which sent a `hotfix/...` branch straight into `production`, past the main environment. For when production needs a
fix now and `main` cannot be promoted as it is: its work is still under test, or known to be broken. If `main` can be
promoted now, the fix takes the normal route above, just fast.
1. **Bookmark.** Branch `main-deferred` at `main`'s current commit. It marks what is being set aside.
2. **Set aside.** A pull request into `main` with one commit that returns every file to `production`'s version (files
   `main` added are deleted); its message lists the commits set aside. It starts only from a checkout with no
   uncommitted changes, since it rewrites every tracked file. After the merge, `git diff origin/production
   origin/main` prints nothing (anything else means something else was merged meanwhile: stop). Main's Argo CD
   redeploys production's version, and any Terraform root whose files changed is applied from `main`, so the main
   environment matches production again.
3. **Fix.** Short-lived branch off `main`, `./check`, pull request into `main`. The main environment deploys it; test
   it there.
4. **Promote** `main` → `production` as usual. Step 5 above holds, so production runs exactly what the main
   environment tested: what was live, plus the fix.
5. **Bring back.** A pull request into `main` that reverts the set-aside commit, so the deferred work returns on top
   of the fix. Before reverting, the commit's subject must be the set-aside's, or it stops. If the fix touched the
   same lines, the conflict is resolved in this pull request. Before the pull request, `git diff main-deferred` shows
   the fix and nothing else (plus any conflict resolution). After the merge, the Terraform roots applied in step 2
   are applied again from `main`, the interrupted test starts over on the main environment, and `main-deferred` is
   deleted last.

Merging `main-deferred` back would do nothing: its commits are still in `main`'s history (the set-aside commit only
came after them), so git finds nothing to merge. Reverting the set-aside commit is what brings the files back.

Why not move `main` back by force-push: `main`'s rule blocks it on purpose, and switching the rule off to do it
rewrites a shared branch. Branches made from `main` after the set-aside work would be left on commits `main` no longer
has, and the history would not show what happened. Every step above is an ordinary pull request.

The price: the test running on the main environment is interrupted and starts over after step 5; step 5 can
conflict; and the fix waits for one pass through the main environment (deployed in about 3 minutes, plus the test).
When even that is too slow, Argo CD's manual rollback gives immediate relief (below), and the fix follows through
these steps. At a company, a third environment (a short-lived copy of production per fix) would avoid interrupting
the test; in the lab, building one takes about 35 minutes, too slow for an urgent fix.

**Nothing on `production` is ever missing from `main`.** A pull request into `production` must come from `main`, and
`main` must already have every change `production` has: `git log --no-merges main..origin/production` prints nothing.
Promotion merge commits are the only commits `production` has that `main` lacks, and they are left out. With `main`
the only source this holds by construction; the check stays as a guard against a `main` rewritten by force, or a
`production` changed while a rule was off.
- No back-merge after a promotion: the promotion merge commit lives only on `production`, so the two branch tips are
  never the same commit; their files are the same (step 5). `git log --first-parent production` lists every
  promotion, and each one's `^2` is the commit it brought in.
- `production` moves only by promotion, and only one promotion pull request is open at a time, so its check results
  cannot go stale.

**GitHub rules** (rulesets; available on this private repository, checked 2026-10-15):

| | `main` | `production` |
|---|---|---|
| Direct pushes | blocked: changes only by pull request | blocked: changes only by pull request |
| Where changes come from | any short-lived branch | `main` only: the workflow `.github/workflows/into-production.yml` has two required checks, `source-allowed` (the source is `main`) and `source-has-production` (the rule above), run from `main`'s copy of the workflow (`pull_request_target` takes the default branch's copy) |
| Approvals | none required (GitHub does not let you approve your own pull request) | none required |
| Merge method | squash allowed | merge commit only |
| Force-push, deletion | blocked | blocked |

- Merge commits only into `production`: a squash creates a commit `main` never had, the branches drift apart, and the
  next promotion shows old changes again or conflicts. "Never squash a promotion."
- The checks run on `pull_request_target`, so GitHub runs the default branch's copy of the workflow, which is
  `main`'s (since 2025-12-08 GitHub takes it from the default branch, whichever branch the pull request targets): a
  pull request that edits the workflow cannot change the checks that judge it (on `pull_request`, the copy in the pull
  request's merge result would run; found in the build's review, 2026-10-15). It is safe because no code from the
  pull request runs: the checkout keeps `main`'s code, and the history check only reads commits. The cost: the checks
  are only as safe as `main`, since whatever is merged into `main` changes them; at a company, changes under
  `.github/` would need a second person's approval. They become required as soon as `main` has the workflow (part 4,
  A); until then, pull requests into `production` rest on Sam's merge alone.
- No bypass list. Urgent fixes set `main` aside (above); for anything else a rule is switched off and back on, which
  leaves a record.
- `./check` as a required check on every pull request is CI: Session 4. Until then it is run by hand before every
  push.

**`./tf` enforces the same flow on Sam's Mac.**
- Every command not in the list below runs on any branch (for example `plan`, `validate`, `output`, `show`, `state
  list`, `state show`, `state pull`), so a change can be previewed from a short-lived branch.
- Changing commands (`apply`, `destroy`, `import`, `force-unlock`, `taint`, `untaint`, `state mv`, `state rm`, `state
  push`, `state replace-provider`) run only when the checked-out branch is the environment's (`./tf production …`
  only on `production`), there are no uncommitted changes, and the branch is identical to GitHub's copy (after a
  `git fetch`). Otherwise it stops and says which of the three failed.
- Changing commands also refuse `-var` and `-var-file` (values that are not on the branch). A saved plan holds the
  configuration it was made from, not what is on disk: `plan -out=<file>` writes `<file>.commit` (the commit, only if
  nothing was uncommitted), and `apply <file>` runs only when that is the commit checked out (found in the build's
  review, 2026-10-15: without it, a plan saved on a short-lived branch could be applied from the environment's).

**Keep `main` always promotable** (what makes this model work). Promotion moves all of `main` at once, so only what
would ship once it passes on the main environment is merged into `main`; if something there fails, it is reverted on
`main` before the next promotion, or it blocks everything behind it. An urgent fix that cannot wait for that sets
`main` aside. Promote often, so the gap between `main` and `production` stays small.

**Fixes and rollbacks.** An urgent fix branches off `main`. If `main` can be promoted now, the fix goes pull request
into `main` → test → promote, just fast; if not, `main` is set aside first. Undoing a release is a revert on `main`,
promoted again (with `main` set aside first if it holds unpromoted work). For immediate relief, Argo CD can roll production back to its previous sync by hand; that switches auto-sync
off on that app (so `root` first, as in the README), and the git fix still has to follow.

**Who does what.** Claude prepares branches and opens pull requests, each on Sam's word. Merging is the deploy:
Sam's call, every time.

## 4. Getting there from today, and costs

Each step that changes GitHub, Google Cloud or DNS waits for Sam's word.

- **A. Git and GitHub (no cloud, no cost).**
  1. Create `production` from today's `main` (7bc25dc, the last setup that ran).
  2. The Argo CD work as branch `argocd` → pull request → `main`. It never runs in its single-environment form.
  3. The workflow file arrives on `main` by pull request (with B); then the two rulesets, and `production`'s two
     required checks as soon as `main` has the workflow.
- **B. The restructure:** branch `two-environments` → pull request → `main`. Everything in parts 1 to 3: the
  `platform` and `edge` modules, the four environment roots (with `moved.tf` in production's edge), the
  per-environment chat and entrance files, Argo CD's base and overlays, the wrappers, `./check`, the README, and an
  update to the Argo CD design's status line pointing here.
- **C. The new project for main, by hand once** (about 30 minutes): create, billing, APIs, budget, state bucket,
  `gke-lab-main` profile, GPU quota request. If the quota is not granted, main runs without its GPU until it is, and
  Sam is told; the design is not quietly changed.
- **D. Main environment up, from the `main` branch:** `./tf main edge apply`, two Route 53 records
  (`chat-lab-main.liveinference.com` A, and the certificate's CNAME from the `dns_records` output), about 18 minutes
  for the certificate; `./tf main cluster apply`; main's deploy key; `./bootstrap main`; the main session (part 5).
- **E. First promotion:** pull request `main` → `production`, merge. Then, from the `production` branch: copy the
  entrance's state file to its new prefix; `./tf production edge plan` must say No changes; only then are the old
  state files (`envs/edge`, and the empty `envs/lab`) deleted, on Sam's word. Production's cluster comes up the same
  way when wanted.
- **F. Urgent fixes through `main`** (Sam, 2026-10-15): `source-allowed` takes `main` only; the tests and the README
  follow part 3; a pull request into `main`, then a promotion. Then the drill (part 5).

**Costs, at list prices.**

| | Standing (always) | While up |
|---|---|---|
| production | entrance about $15/month (as today) | about $0.60/hour (GPU node $0.42), plus possibly $0.07/hour if Argo CD needs a second `system` node |
| main | entrance about $15/month (new) | the same |
| Together | about $30/month | about $1.25/hour only if both are up at once |

Each project has its own $50 budget alert.

## 5. Testing

**Offline, in `./check`, before anything is pushed.**
- Terraform: `terraform fmt -check` and `validate` (initialised without a backend) on the four roots; the two
  `main.tf` files of each layer identical; `versions.tf` differing only in bucket and prefix.
- The chat app per environment: renders with its own `WEBUI_URL` and no other; production's render keeps every
  setting it has today: its list of Open WebUI environment variables (names and values, `WEBUI_URL` included) equals
  a saved copy taken from today's render (`test/expected/chat-production-env.txt`), so moving settings into
  `commonEnvVars` cannot silently drop one.
- The entrance per environment: builds with `kubectl kustomize`, matches the schemas (strict), and carries its own
  hostname on both routes and no other.
- Argo CD per environment: builds; every app points at its own branch, settings file and entrance folder; no app of
  one environment mentions the other environment's branch, file, folder or hostname. All of the Argo CD design's
  checks (fields, finalizers, retry, the typo check) run for both.
- The wrappers, against stand-ins: `./tf`, `./k`, `./h` and `./bootstrap` refuse to run without an environment (and
  touch nothing); `./tf` refuses changing commands on the wrong branch, with uncommitted changes, or out of step with
  GitHub, with `-var` or `-var-file`, or with a saved plan made on another commit or with uncommitted changes;
  read-only commands run anywhere.
- The workflow file: parses; runs on `pull_request_target` with a checkout that keeps `main`'s code;
  `source-allowed` passes `main` and fails any other branch, `hotfix/...` included; `source-has-production`'s script,
  run in a scratch repository, passes a promotion and fails a `main` that lacks a commit `production` has. The
  set-aside steps, run in a scratch repository: after step 2 `main`'s files equal `production`'s, after step 4 `git
  diff production^2 production` prints nothing, after step 5 `git diff main-deferred main` shows only the fix, and
  merging `main-deferred` changes nothing. Its action is pinned to a full commit id.

**On GitHub (no cloud).**

| # | Check | Expected |
|---|---|---|
| G1 | Push straight to `main`, and to `production` | Both refused |
| G2 | A pull request `main` → `production` | Only "merge commit" offered |

**Main environment session** (about 2 hours, roughly $1.30).

| # | Check | Expected |
|---|---|---|
| M1 | Entrance, DNS, cluster, `./bootstrap main` | Certificate ACTIVE; `root`, `chat`, `chat-edge` Synced and Healthy |
| M2 | The public checks on `chat-lab-main.liveinference.com` | 200 from Sam's Mac; http 301; `/api/models` without a key 401; the Cloud NAT address 403; backend HEALTHY |
| M3 | NetworkPolicy and labels | Pods carry `app.kubernetes.io/instance: chat`; Open WebUI reaches Ollama, a throwaway pod times out |
| M4 | The Argo CD design's checks 4 to 8, each change through a pull request into `main` | Deploy by commit; `git revert`; drift put back (including auto-sync switched off on `chat` alone, put back by `root`); GPU off by commit; no OutOfSync noise left unexplained |
| M5 | The `./tf` guard for real | `./tf production edge apply` from `main` refused; `./tf main cluster apply` with an uncommitted change refused |
| M6 | Teardown | Delete `root`; forwarding rules clear; `./tf main cluster destroy`; no disks left |

**First promotion.**

| # | Check | Expected |
|---|---|---|
| P1 | Merge `main` → `production` | A merge commit; `git diff origin/production^2 origin/production` prints nothing |
| P2 | Production's entrance moved | `./tf production edge plan` says No changes; the IP is still 136.81.128.150; the certificate is still ACTIVE |
| P3 | After the required checks: a pull request from a scratch branch off `main` that also changes `source-allowed` to accept any branch, closed unmerged | `source-allowed` fails all the same (`main`'s copy ran); merge blocked |
| P4 | After P1: a pull request from `hotfix/check-test` (off `production`, one harmless commit) into `production`, closed unmerged | Both checks pass: the history check sees `origin/production` on GitHub (passed 2026-10-15; it tested the hotfix lane, since replaced) |
| P5 | The same from `hotfix/stale-test`, made from `production^1` (the commit before the promotion), closed unmerged | `source-has-production` fails and names the commits missing; merge blocked (passed 2026-10-15) |
| P6 | Production's cluster, when wanted | `./bootstrap production`; the public checks on `chat-lab.liveinference.com`; teardown |

P3 to P5 run after the first promotion, once the checks are required: P5 needs a `production` older than today's to
start from, and P4's branch starts from `production` as the promotion left it.

**Urgent-fix drill** (after F, on the main environment; each step on Sam's word).

| # | Check | Expected |
|---|---|---|
| D1 | A harmless change merged into `main`, standing in for work under test | It shows on the main environment |
| D2 | Bookmark and set aside (part 3, steps 1 and 2) | `git diff origin/production origin/main` prints nothing; D1's change gone from the main environment |
| D3 | A harmless fix into `main`, tested there, then promoted | The fix shows on the main environment, then on production; `git diff production^2 production` prints nothing |
| D4 | Bring back (step 5) | `git diff main-deferred main` shows only the fix; D1's change back on the main environment; `main-deferred` deleted |
| D5 | A pull request into `production` from any branch but `main` (`hotfix/...` included), closed unmerged | `source-allowed` fails; merge blocked |

Pass: everything as expected. A failure in G1, M5, M6, P2, P3, P4, P5 or D2 to D5 stops the work until it is fixed: those
protect the flow itself, production's live entrance, and the bill. Timings and findings go into `plan.md`'s progress
notes.

## What changes in the Argo CD design

Its single-environment details are replaced: `argocd/root.yaml` and `argocd/apps/` become `argocd/base/` plus the two
overlays; `chat-edge` reads a Kustomize folder instead of `edge.yaml` with an `include` filter; `./bootstrap` takes the
environment; one deploy key per environment instead of `~/.ssh/gke-genai-serving-argocd`; `./k` and `./h` take the
environment and use `.kube/<env>/config` instead of `.kubeconfig`. Everything else in it stands (the app-of-apps
shape, finalizers, self-heal, retry, `skipTests`, the security notes, the teardown order, the gotchas).

## Not in this design

CI running `./check` and Terraform on merge (Session 4); a Terraform project factory; tenants and per-tenant Argo CD
projects (Session 2); Secret Manager for the deploy keys (Session 5); multi-region (Session 7); one Argo CD managing
both clusters; promoting container images by tag (the chat app uses public images pinned in `values.yaml`).
