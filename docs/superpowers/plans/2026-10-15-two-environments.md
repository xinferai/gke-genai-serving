# Two environments, main and production: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One repository that runs two identical GKE environments, `main` and `production`, each from its own branch,
with every change travelling short-lived branch → `main` → `production`.

**Architecture:** Terraform becomes two shared modules (`platform`, `edge`) and four thin roots
(`envs/<env>/<cluster|edge>`) that differ only in `terraform.tfvars` and state location. Kubernetes files become one
shared base plus a small file or Kustomize overlay per environment (chat settings, entrance hostname, Argo CD branch).
The wrappers take the environment as a required first word, and `./tf` refuses changing commands unless the checkout
is that environment's branch, clean, and identical to GitHub. `./check` grows to cover both environments; GitHub
rulesets and one workflow enforce the branch flow.

**Tech Stack:** Terraform 1.16 with the Google provider 8.7, Helm 4.3, kubectl 1.37 (with its built-in Kustomize),
Argo CD 3.5.5 (chart `argo-cd` 10.10.5), bash 5, yq 4.54, kubeconform 0.8, shellcheck 0.11, git, GitHub CLI, GitHub
Actions (`actions/checkout` v7.0.1, pinned by commit id) and rulesets.

**Spec:** `docs/superpowers/specs/2026-10-15-two-environments-design.md` (and, for what stands from it,
`docs/superpowers/specs/2026-10-15-argocd-design.md`).

## Global Constraints

- Environments, exactly: `main` and `production`. No default anywhere; an unknown or missing environment stops the command before it touches anything.
- Projects: production `samwen-gke-lab`, main `samwen-gke-lab-main`. gcloud profiles: production `gke-lab`, main `gke-lab-main`.
- State: production `gs://samwen-gke-lab-tfstate`, main `gs://samwen-gke-lab-main-tfstate`; prefix = the root's own folder, `envs/<env>/<layer>`.
- Hostnames: production `chat-lab.liveinference.com`, main `chat-lab-main.liveinference.com`. Entrance resource names `chat-lab` in both projects.
- Same shape in both: zone `us-central1-a`, region `us-central1`, cluster `lab`, the same pools and internal IP ranges, the same chart versions.
- Branch per version, file per environment: everything that differs lives in `envs/<env>/*/terraform.tfvars`, `envs/<env>/*/versions.tf` (bucket and prefix only), `apps/chat/env/<env>.yaml`, `apps/chat/edge/<env>/`, `argocd/<env>/`, and production's `envs/production/edge/moved.tf`.
- Deploy keys: `~/.ssh/gke-genai-serving-argocd-main`, `~/.ssh/gke-genai-serving-argocd-production`; never in git, Terraform state, Helm, or on screen.
- Kubeconfigs: `.kube/main/config`, `.kube/production/config` (gitignored).
- `./tf` changing commands: `apply`, `destroy`, `import`, `force-unlock`, `taint`, `untaint`, `state mv`, `state rm`, `state push`, `state replace-provider`. Everything else runs on any branch.
- GitHub: `main` and `production` take changes only by pull request; no force-push, no deletion, no bypass list; `production` only from `main` or a `hotfix/...` branch that already has every change `production` has (required checks `source-allowed` and `source-has-production`, workflow `.github/workflows/into-production.yml`, run on `pull_request_target` from `main`'s copy, required once `main` has the workflow), merge commit only.
- After every merge into `production`: `git diff origin/production^2 origin/production` prints nothing. Nothing is merged back from `production` into `main` except a hotfix branch, or `production` itself to repair a squashed hotfix.
- **Gates.** Every commit, push, pull request, merge, GitHub setting, Google Cloud change, DNS change and key registration waits for Sam's word. Merging is the deploy and is always Sam's call. Gate steps are marked **GATE**.
- Lab work: "production" is an environment name inside the lab; nothing written here calls the lab production work.
- Comments match the existing files: plain English, say why, date findings.

## Adjustments to the spec (made while planning)

- The workflow file lands with the restructure (Task 7, in the `two-environments` pull request), not in a pull
  request of its own; the rulesets are created right after that merge (Gate 1). Same order of effect, one pull
  request fewer.
- Production's entrance move (spec part 4E, test P2): with `moved` blocks the first plan lists 7 "has moved to
  module.edge…" lines and "0 to add, 0 to change, 0 to destroy"; the moves are recorded by one `./tf production edge
  apply`, after which a second plan says "No changes." Both plans are part of P2.
- The field checks use exact matching (`any_c(. == "…")`) rather than yq's substring `contains`, since the checks are
  rewritten anyway (the Argo CD review's deferred minor 7).
- `./check` is split into a runner plus one file per area under `test/checks/`, because it now covers two
  environments and seven areas.

- After the build's whole-branch review (2026-10-15), two changes the task code blocks below do not show (the
  committed files and the design have them): `./tf` refuses `-var`/`-var-file` on changing commands and ties a saved
  plan to the commit it was made from (`<file>.commit`; tests in `test/wrappers_test.sh`); the workflow runs on
  `pull_request_target`, so `main`'s copy (the default branch's) judges each pull request into `production`, and
  `production`'s required checks are added at the end of Gate 1, once `main` has the workflow.

## Review Focus

1. **The environment word is missing or misspelt** (`./k get pods`, `./tf prod cluster plan`, `./bootstrap`): the
   command must stop with a usage line and touch nothing. Tests: Task 3 (`tf`, `k`, `h` without or with a wrong
   environment, and a wrong layer) and Task 6 (`bootstrap` without one).
2. **A changing command on the wrong branch, with uncommitted changes, or out of step with GitHub** (above all
   `./tf production … apply` from `main`): refused, nothing run. Tests: Task 3, the guard cases.
3. **A copy-paste slip between environments** (main's overlay left pointing at `production`'s branch, settings file
   or hostname): `./check` fails. Tests: Task 5 (hostnames exact per environment, entrances otherwise identical) and
   Task 6 (no mention of the other environment, proven on a copy with a planted slip).
4. **Moving settings into `commonEnvVars` drops or changes a production setting:** `./check` fails. Test: Task 4,
   production's Open WebUI environment compared with a snapshot taken before the change, proven by removing one
   setting on purpose.
5. **The production entrance move would destroy or recreate a resource** (a `moved` block missing or misnamed):
   caught offline before any plan. Test: Task 2, every resource production's entrance had gets a `moved` block into
   `module.edge`, and the module declares it.
6. **A fix that went through the hotfix lane is never merged into `main`, or is squashed into it:** the next
   promotion would ship a `main` that never had the fix, so `source-has-production` must block it and name the fix.
   Test: Task 7, `test/workflow_test.sh`, through the lane, a squash, the repair, and the merge.

---

### Gate 0: land the Argo CD work, create `production` (before Task 1)

All of this changes GitHub or git history: each step waits for Sam's word.

- [ ] **GATE 0.1: commit the Argo CD work on its own branch.** Only the Argo CD files; the two-environments design
  and this plan stay uncommitted and travel with the working tree.

```bash
cd ~/projects/gke-lab
git switch -c argocd
git add README.md argocd bootstrap check test \
  docs/superpowers/specs/2026-10-15-argocd-design.md docs/superpowers/plans/2026-10-15-argocd.md
./check            # Expected: 32 PASS, exit 0
git commit -m "Add Argo CD: a bootstrap script, a root app with the chat app and its entrance, and offline checks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git status --short  # Expected: only docs/superpowers/specs/2026-10-15-two-environments-design.md and docs/superpowers/plans/2026-10-15-two-environments.md
```

- [ ] **GATE 0.2: create `production` at the last setup that ran** (before the Argo CD merge, so production starts
  from what was deployed):

```bash
git push origin 7bc25dc:refs/heads/production
gh api repos/xinferai/gke-genai-serving/branches --jq '.[].name'   # Expected: main, production
```

- [ ] **GATE 0.3: push `argocd` and open its pull request into `main`.**

```bash
git push -u origin argocd
gh pr create --base main --head argocd \
  --title "Add Argo CD: bootstrap, app of apps for the chat app, offline checks" \
  --body "Argo CD for the GKE lab, one environment, as designed in docs/superpowers/specs/2026-10-15-argocd-design.md. Built and reviewed; ./check passes (32). Not run on a cluster yet; the two-environments restructure follows in its own pull request.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **GATE 0.4: Sam merges the pull request** (squash is fine into `main`). Then:

```bash
git switch main && git pull --ff-only
git switch -c two-environments
git status --short  # Expected: the two untracked two-environments documents only
```

- [ ] **GATE 0.5: ask Sam for a standing go for local commits on `two-environments` during Tasks 1 to 8** (local
  only; pushing is Gate 1). Without it, Tasks 1 to 8 run uncommitted and are committed at Gate 1.

---

### Task 1: Split `./check` into a runner and one file per area

A pure move: the same 32 checks, the same results. Later tasks rewrite the area files.

**Files:**
- Modify: `check` (becomes the runner)
- Create: `test/checks/20-chat.sh`, `test/checks/40-argocd.sh`, `test/checks/50-scripts.sh`, `test/checks/70-readme.sh`

**Interfaces:**
- Consumes: today's `check`.
- Produces: in `check`, before the parts are sourced: `here`, `tmp`, `failed`, `check "<what>" <command...>`,
  `repo`, `schemas`, `strict <files...>`, `envs=(main production)`, `other <env>` (prints the other environment).
  Area files are sourced in this order, each with a `# shellcheck source=` line:
  `10-terraform.sh` (Task 2), `20-chat.sh`, `30-edge.sh` (Task 5), `40-argocd.sh`, `50-scripts.sh`,
  `60-github.sh` (Task 7), `70-readme.sh`. A file that does not exist yet is not sourced until its task adds the line.

- [ ] **Step 1: Record today's result**

Run: `./check > "$TMPDIR/check-before.txt"; echo "exit $?"; grep -c '^PASS' "$TMPDIR/check-before.txt"`
Expected: `exit 0`, `32`.

- [ ] **Step 2: Move the sections**

Cut from `check` into new files, unchanged, each starting with these two lines:
```bash
# shellcheck shell=bash
# Sourced by ./check, which defines check(), strict(), here, tmp, repo, schemas, envs and other().
```
- `test/checks/20-chat.sh`: the section `# --- The chat app, rendered the way Argo CD renders it …` through the line
  `check "edge.yaml matches its schemas" strict apps/chat/edge.yaml`.
- `test/checks/40-argocd.sh`: the sections `# --- Argo CD's own settings …` and `# --- The three Argo CD apps …`.
- `test/checks/50-scripts.sh`: the section `# --- bootstrap …`.
- `test/checks/70-readme.sh`: the section `# --- The README describes the Argo CD way of working …`.

Then replace `check` with:

```bash
#!/usr/bin/env bash
# Offline checks for the lab, both environments (main and production). Nothing here touches a cluster,
# Google Cloud or GitHub; it downloads the Helm charts, the Google provider for Terraform, and the public
# schemas for Argo CD, Gateway API and GKE objects.
# Run before every push:   ./check
# Needs terraform, helm, kubectl, yq, kubeconform and shellcheck:   brew install yq kubeconform shellcheck
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here" || exit 1
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failed=0

# check "<what is checked>" <command...>: prints PASS or FAIL, and on a failure the command's output.
check() {
  local what="$1" out
  shift
  if out="$("$@" 2>&1)"; then
    printf 'PASS  %s\n' "$what"
  else
    printf 'FAIL  %s\n' "$what"
    printf '%s\n' "$out" | sed 's/^/      /'
    failed=1
  fi
}

envs=(main production)
# other <env>: the other environment.
other() { if [ "$1" = main ]; then echo production; else echo main; fi; }

repo=git@github.com:xinferai/gke-genai-serving.git
schemas='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
# Schema check that also rejects fields the schema does not know (a misspelt field is an error).
strict() { kubeconform -strict -summary -schema-location default -schema-location "$schemas" "$@"; }

# shellcheck source=test/checks/20-chat.sh
. test/checks/20-chat.sh
# shellcheck source=test/checks/40-argocd.sh
. test/checks/40-argocd.sh
# shellcheck source=test/checks/50-scripts.sh
. test/checks/50-scripts.sh
# shellcheck source=test/checks/70-readme.sh
. test/checks/70-readme.sh

exit "$failed"
```

In `test/checks/50-scripts.sh`, change the shellcheck line to follow the sourced files:
```bash
check "scripts pass shellcheck" shellcheck -x -e SC2329 bootstrap check test/bootstrap_test.sh
```

- [ ] **Step 3: Same result as before**

Run: `./check > "$TMPDIR/check-after.txt"; echo "exit $?"; diff "$TMPDIR/check-before.txt" "$TMPDIR/check-after.txt"`
Expected: `exit 0`; `diff` prints nothing. If shellcheck now reports `SC2154` (a variable "referenced but not
assigned") inside a part file, `-x` did not follow the `source` lines: run it from the repository root (it is) and
confirm each `# shellcheck source=` path; do not disable the warning.

- [ ] **Step 4: Commit (only with Sam's standing go from Gate 0.5)**

```bash
git add check test/checks
git commit -m "Split ./check into a runner and one file per area

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Terraform: two modules, four environment roots, production's moves

**Files:**
- Create: `modules/platform/main.tf`, `modules/platform/variables.tf`, `modules/platform/outputs.tf`
- Create: `modules/edge/main.tf`, `modules/edge/variables.tf`, `modules/edge/outputs.tf`
- Create, for `env` in `main` and `production`: `envs/<env>/cluster/{main,variables,outputs,versions}.tf`,
  `envs/<env>/cluster/terraform.tfvars`, `envs/<env>/cluster/.terraform.lock.hcl`, and the same five plus the lock
  file under `envs/<env>/edge/`
- Create: `envs/production/edge/moved.tf`, `test/expected/production-edge-resources.txt`, `test/checks/10-terraform.sh`
- Delete: `envs/lab/`, `envs/edge/` (tracked files; their local `.terraform/` folders are removed too)
- Modify: `check` (source `10-terraform.sh` first)

**Interfaces:**
- Consumes: `check`, `envs`, `tmp` (Task 1); `modules/network`, `modules/gke-cluster`, `modules/node-pool` (unchanged).
- Produces: roots at `envs/<env>/<cluster|edge>` (used by `./tf`, Task 3); `module.platform` outputs `cluster_name`,
  `cluster_location`; `module.edge` outputs `dns_records`, `address_name`, `certificate_map`, `security_policy`;
  the edge root outputs of the same names.

- [ ] **Step 1: Snapshot what production's entrance has today** (before anything moves)

```bash
mkdir -p test/expected
grep -oE '^resource "[a-z0-9_]+" "[a-z0-9_]+"' envs/edge/main.tf \
  | sed -E 's/^resource "([a-z0-9_]+)" "([a-z0-9_]+)"/\1.\2/' > test/expected/production-edge-resources.txt
cat test/expected/production-edge-resources.txt
```
Expected, exactly these 7 lines:
```
google_project_service.certificatemanager
google_compute_global_address.chat
google_certificate_manager_dns_authorization.chat
google_certificate_manager_certificate.chat
google_certificate_manager_certificate_map.chat
google_certificate_manager_certificate_map_entry.chat
google_compute_security_policy.chat
```

- [ ] **Step 2: Write the Terraform checks**

Create `test/checks/10-terraform.sh`:

```bash
# shellcheck shell=bash
# Sourced by ./check, which defines check(), strict(), here, tmp, repo, schemas, envs and other().

# --- Terraform: the four environment roots, offline ----------------------------------------------
roots=(envs/main/cluster envs/main/edge envs/production/cluster envs/production/edge)
# Providers download once into a shared cache; validation runs on a copy, initialised without a
# backend, so nothing in this folder or in the state buckets changes.
tf_cache="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"
mkdir -p "$tf_cache"
tf_copy() {
  [ -d "$tmp/tf" ] && return 0
  mkdir -p "$tmp/tf" && rsync -a --exclude .terraform envs modules "$tmp/tf/"
}
tf_valid() { # tf_valid <root>
  tf_copy || return 1
  TF_PLUGIN_CACHE_DIR="$tf_cache" terraform -chdir="$tmp/tf/$1" init -backend=false -input=false -no-color > /dev/null &&
    terraform -chdir="$tmp/tf/$1" validate -no-color
}
same_in_both() { diff "envs/main/$1/$2" "envs/production/$1/$2"; } # same_in_both <layer> <file>
# versions.tf may differ only in where the state is kept.
versions_differ_only_in_state() {
  diff <(grep -vE '^[[:space:]]*(bucket|prefix)[[:space:]]*=' "envs/main/$1/versions.tf") \
    <(grep -vE '^[[:space:]]*(bucket|prefix)[[:space:]]*=' "envs/production/$1/versions.tf")
}
state_in() { # state_in <env> <layer> <bucket>: that root keeps its state in that bucket, under its own folder
  grep -qE "^[[:space:]]*bucket[[:space:]]*=[[:space:]]*\"$3\"" "envs/$1/$2/versions.tf" &&
    grep -qE "^[[:space:]]*prefix[[:space:]]*=[[:space:]]*\"envs/$1/$2\"" "envs/$1/$2/versions.tf"
}
tfvar_is() { # tfvar_is <file> <name> <value as written>
  grep -qE "^$2[[:space:]]*=[[:space:]]*$3[[:space:]]*\$" "$1" || { echo "$1: expected $2 = $3"; return 1; }
}
# Every resource production's entrance had at the top level (test/expected/production-edge-resources.txt,
# taken from envs/edge on 2026-10-15) has a moved block into module.edge, and the module still declares it.
# A missing or misnamed block would make the first plan destroy and recreate that resource.
moves_complete() {
  local addr type name
  [ "$(grep -c '^moved {' envs/production/edge/moved.tf)" -eq "$(wc -l < test/expected/production-edge-resources.txt)" ] ||
    { echo "moved.tf has a different number of moved blocks than test/expected/production-edge-resources.txt"; return 1; }
  while read -r addr; do
    grep -qE "^[[:space:]]*from[[:space:]]*=[[:space:]]*$addr[[:space:]]*\$" envs/production/edge/moved.tf ||
      { echo "no moved block from $addr"; return 1; }
    grep -qE "^[[:space:]]*to[[:space:]]*=[[:space:]]*module\.edge\.$addr[[:space:]]*\$" envs/production/edge/moved.tf ||
      { echo "no moved block to module.edge.$addr"; return 1; }
    type="${addr%%.*}"
    name="${addr#*.}"
    grep -qE "^resource \"$type\" \"$name\"" modules/edge/main.tf || { echo "modules/edge does not declare $addr"; return 1; }
  done < test/expected/production-edge-resources.txt
}

check "Terraform files are formatted" terraform fmt -check -recursive -diff envs modules
for root in "${roots[@]}"; do
  check "$root is valid Terraform" tf_valid "$root"
done
for layer in cluster edge; do
  for f in main.tf variables.tf outputs.tf; do
    check "$layer/$f is the same in both environments" same_in_both "$layer" "$f"
  done
  check "$layer/versions.tf differs between environments only in where the state is kept" versions_differ_only_in_state "$layer"
  check "main's $layer keeps its state in main's own bucket" state_in main "$layer" samwen-gke-lab-main-tfstate
  check "production's $layer keeps its state in production's bucket" state_in production "$layer" samwen-gke-lab-tfstate
done
check "main's cluster is in project samwen-gke-lab-main" tfvar_is envs/main/cluster/terraform.tfvars project_id '"samwen-gke-lab-main"'
check "production's cluster is in project samwen-gke-lab" tfvar_is envs/production/cluster/terraform.tfvars project_id '"samwen-gke-lab"'
check "main's entrance is in project samwen-gke-lab-main" tfvar_is envs/main/edge/terraform.tfvars project_id '"samwen-gke-lab-main"'
check "production's entrance is in project samwen-gke-lab" tfvar_is envs/production/edge/terraform.tfvars project_id '"samwen-gke-lab"'
check "main's entrance answers to chat-lab-main.liveinference.com" tfvar_is envs/main/edge/terraform.tfvars hostname '"chat-lab-main.liveinference.com"'
check "production's entrance answers to chat-lab.liveinference.com" tfvar_is envs/production/edge/terraform.tfvars hostname '"chat-lab.liveinference.com"'
check "only production's entrance has moved.tf" bash -c '[ -f envs/production/edge/moved.tf ] && [ ! -e envs/main/edge/moved.tf ]'
check "production's entrance moves every resource it had into module.edge" moves_complete
```

Add to `check`, before the `20-chat.sh` lines:
```bash
# shellcheck source=test/checks/10-terraform.sh
. test/checks/10-terraform.sh
```

- [ ] **Step 3: Run it to see the new checks fail**

Run: `./check 2>&1 | grep -E '^(PASS|FAIL)' | head -30; echo; ./check > /dev/null; echo "exit $?"`
Expected: every Terraform check FAILs (the roots do not exist; `fmt` may PASS on the existing folders); the 32 older
checks PASS; `exit 1`.

- [ ] **Step 4: Create `modules/platform`**

`modules/platform/main.tf` (today's `envs/lab/main.tf`, with module paths relative to `modules/platform`):

```hcl
# One environment's network, node service account, cluster and node pools. Called by
# envs/<env>/cluster with the environment's project; everything else is the same in every
# environment.

module "network" {
  source = "../network"

  name          = "lab"
  region        = var.region
  nodes_cidr    = "10.10.0.0/20"
  pods_cidr     = "10.20.0.0/16"
  services_cidr = "10.30.0.0/20"
}

# Nodes run as their own service account with only what nodes need, not as the
# project's default Compute Engine account.
resource "google_service_account" "nodes" {
  account_id   = "gke-nodes"
  display_name = "GKE nodes (lab)"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/container.defaultNodeServiceAccount",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

module "cluster" {
  source = "../gke-cluster"

  name                = "lab"
  project_id          = var.project_id
  location            = var.zone
  network_id          = module.network.network_id
  subnet_id           = module.network.subnet_id
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name
  admin_cidr          = var.admin_cidr
}

# Cluster add-ons and system pods (DNS, metrics) live here, and Argo CD, on on-demand nodes.
module "system_pool" {
  source = "../node-pool"

  name            = "system"
  cluster_id      = module.cluster.id
  location        = var.zone
  machine_type    = "e2-standard-2"
  min_nodes       = 1
  max_nodes       = 2
  spot            = false
  service_account = google_service_account.nodes.email
  labels          = { pool = "system" }
}

# Tenant workloads. Spot VMs and scale-to-zero keep the lab cheap; the cluster
# autoscaler adds nodes only when pods are waiting for room.
module "apps_pool" {
  source = "../node-pool"

  name            = "apps"
  cluster_id      = module.cluster.id
  location        = var.zone
  machine_type    = "e2-standard-2"
  min_nodes       = 0
  max_nodes       = 3
  spot            = true
  service_account = google_service_account.nodes.email
  labels          = { pool = "apps" }

  # Without this taint, system pods that could not fit elsewhere landed here during
  # cluster creation and kept the pool off zero for over an hour (seen 2026-10-14).
  # Tenant pods must tolerate it: key workload, value apps, effect NoSchedule.
  taints = [{ key = "workload", value = "apps", effect = "NO_SCHEDULE" }]
}

# One NVIDIA L4 (24 GB) per node, for model serving. Scales from zero, and each
# project's GPU quota allows only one GPU at a time, so the max is 1.
module "gpu_pool" {
  source = "../node-pool"

  name            = "gpu"
  cluster_id      = module.cluster.id
  location        = var.zone
  machine_type    = "g2-standard-4"
  min_nodes       = 0
  max_nodes       = 1
  spot            = true
  service_account = google_service_account.nodes.email
  labels          = { pool = "gpu" }
  disk_size_gb    = 50
  gpu             = { type = "nvidia-l4", count = 1 }
}
```

`modules/platform/variables.tf`:

```hcl
variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "zone" {
  description = "A zonal cluster: GKE waives the management fee for one per billing account."
  type        = string
}

variable "admin_cidr" {
  description = "The only address range allowed to reach the cluster's control plane."
  type        = string
}
```

`modules/platform/outputs.tf`:

```hcl
output "cluster_name" {
  value = module.cluster.name
}

output "cluster_location" {
  value = module.cluster.location
}
```

- [ ] **Step 5: Create `modules/edge`**

`modules/edge/main.tf` (today's `envs/edge/main.tf`, names from `var.name`):

```hcl
# The long-lived half of the chat app's public entrance, for one environment. The load balancer
# itself is created by the Gateway in the cluster (apps/chat/edge/) and goes away with the
# cluster; these stay, so the IP address, the certificate and the DNS records survive
# ./tf <env> cluster destroy.

resource "google_project_service" "certificatemanager" {
  service            = "certificatemanager.googleapis.com"
  disable_on_destroy = false
}

# The load balancer's fixed public IP. The DNS A record points here.
resource "google_compute_global_address" "chat" {
  name = var.name
}

# Google proves control of the hostname through a CNAME record under it, then issues the
# certificate and renews it on its own. The AWS equivalent is ACM with DNS validation.
resource "google_certificate_manager_dns_authorization" "chat" {
  name   = var.name
  domain = var.hostname

  depends_on = [google_project_service.certificatemanager]
}

resource "google_certificate_manager_certificate" "chat" {
  name = var.name

  managed {
    domains            = [var.hostname]
    dns_authorizations = [google_certificate_manager_dns_authorization.chat.id]
  }
}

# The Gateway picks its certificate through this map, by name.
resource "google_certificate_manager_certificate_map" "chat" {
  name = var.name

  depends_on = [google_project_service.certificatemanager]
}

resource "google_certificate_manager_certificate_map_entry" "chat" {
  name         = var.name
  map          = google_certificate_manager_certificate_map.chat.name
  hostname     = var.hostname
  certificates = [google_certificate_manager_certificate.chat.id]
}

# Cloud Armor, checked at Google's edge before any request reaches the cluster: allowed_cidrs
# get through, everyone else gets a 403. The AWS equivalent is a WAF web ACL with an IP set.
resource "google_compute_security_policy" "chat" {
  name = var.name

  rule {
    description = "Allowed callers"
    action      = "allow"
    priority    = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = var.allowed_cidrs
      }
    }
  }

  rule {
    description = "Everyone else"
    action      = "deny(403)"
    priority    = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}
```

`modules/edge/variables.tf`:

```hcl
variable "name" {
  description = "Name of the IP, certificate, certificate map and Cloud Armor policy. Names are unique per project, so both environments use the default."
  type        = string
  default     = "chat-lab"
}

variable "hostname" {
  description = "The public name of the chat app. Its DNS lives in Route 53, outside the project."
  type        = string
}

variable "allowed_cidrs" {
  description = "Callers Cloud Armor lets through. Everyone else gets a 403 at Google's edge."
  type        = list(string)
}
```

`modules/edge/outputs.tf`:

```hcl
# The two records to add to the liveinference.com zone in Route 53.
output "dns_records" {
  value = {
    a = {
      name  = var.hostname
      type  = "A"
      value = google_compute_global_address.chat.address
    }
    certificate_check = {
      name  = google_certificate_manager_dns_authorization.chat.dns_resource_record[0].name
      type  = google_certificate_manager_dns_authorization.chat.dns_resource_record[0].type
      value = google_certificate_manager_dns_authorization.chat.dns_resource_record[0].data
    }
  }
}

# Names the Gateway manifest refers to.
output "address_name" {
  value = google_compute_global_address.chat.name
}

output "certificate_map" {
  value = google_certificate_manager_certificate_map.chat.name
}

output "security_policy" {
  value = google_compute_security_policy.chat.name
}
```

- [ ] **Step 6: Create production's two roots**

`envs/production/cluster/main.tf`:

```hcl
# One environment's cluster. This file is the same in envs/main and envs/production (./check compares
# them): the environments differ only in terraform.tfvars and in where versions.tf keeps the state.
module "platform" {
  source = "../../../modules/platform"

  project_id = var.project_id
  region     = var.region
  zone       = var.zone
  admin_cidr = var.admin_cidr
}
```

`envs/production/cluster/variables.tf`: the exact content of `modules/platform/variables.tf` above.

`envs/production/cluster/outputs.tf`:

```hcl
output "cluster_name" {
  value = module.platform.cluster_name
}

output "cluster_location" {
  value = module.platform.cluster_location
}
```

`envs/production/cluster/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.7"
    }
  }

  # State lives in Cloud Storage, in the environment's own project, under this folder's path.
  # The bucket is versioned, and the gcs backend locks the state on its own (S3 needed a
  # DynamoDB table or a lock file for this).
  backend "gcs" {
    bucket = "samwen-gke-lab-tfstate"
    prefix = "envs/production/cluster"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
```

`envs/production/cluster/terraform.tfvars`:

```hcl
project_id = "samwen-gke-lab"
region     = "us-central1"
zone       = "us-central1-a"

# Sam's public IP on 2026-10-14. If it changes, kubectl times out: update this and apply.
admin_cidr = "203.0.113.7/32"
```

`envs/production/edge/main.tf`:

```hcl
# One environment's public entrance. This file is the same in envs/main and envs/production (./check
# compares them): the environments differ only in terraform.tfvars and in where versions.tf keeps
# the state. Production also has moved.tf.
module "edge" {
  source = "../../../modules/edge"

  hostname      = var.hostname
  allowed_cidrs = var.allowed_cidrs
}
```

`envs/production/edge/variables.tf`:

```hcl
variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "hostname" {
  description = "The public name of the chat app. Its DNS lives in Route 53, outside this project."
  type        = string
}

variable "allowed_cidrs" {
  description = "Callers Cloud Armor lets through. Everyone else gets a 403 at Google's edge."
  type        = list(string)
}
```

`envs/production/edge/outputs.tf`:

```hcl
# The two records to add to the liveinference.com zone in Route 53.
output "dns_records" {
  value = module.edge.dns_records
}

# Names the Gateway manifest refers to.
output "address_name" {
  value = module.edge.address_name
}

output "certificate_map" {
  value = module.edge.certificate_map
}

output "security_policy" {
  value = module.edge.security_policy
}
```

`envs/production/edge/versions.tf`: the exact content of `envs/production/cluster/versions.tf` above, with
`prefix = "envs/production/edge"`.

`envs/production/edge/terraform.tfvars`:

```hcl
project_id    = "samwen-gke-lab"
region        = "us-central1"
hostname      = "chat-lab.liveinference.com"
allowed_cidrs = ["203.0.113.7/32"]
```

`envs/production/edge/moved.tf`:

```hcl
# Production's entrance was built on 2026-10-14 by envs/edge, with its resources at the top level.
# These blocks tell Terraform they now live in module.edge, so nothing is destroyed or recreated: the
# first plan lists seven moves and 0 to add, 0 to change, 0 to destroy, and one apply records them.
# Only production has this file; main's entrance is built in the module from the start.

moved {
  from = google_project_service.certificatemanager
  to   = module.edge.google_project_service.certificatemanager
}

moved {
  from = google_compute_global_address.chat
  to   = module.edge.google_compute_global_address.chat
}

moved {
  from = google_certificate_manager_dns_authorization.chat
  to   = module.edge.google_certificate_manager_dns_authorization.chat
}

moved {
  from = google_certificate_manager_certificate.chat
  to   = module.edge.google_certificate_manager_certificate.chat
}

moved {
  from = google_certificate_manager_certificate_map.chat
  to   = module.edge.google_certificate_manager_certificate_map.chat
}

moved {
  from = google_certificate_manager_certificate_map_entry.chat
  to   = module.edge.google_certificate_manager_certificate_map_entry.chat
}

moved {
  from = google_compute_security_policy.chat
  to   = module.edge.google_compute_security_policy.chat
}
```

- [ ] **Step 7: Create main's two roots**

```bash
for layer in cluster edge; do
  mkdir -p envs/main/$layer
  cp envs/production/$layer/main.tf envs/production/$layer/variables.tf envs/production/$layer/outputs.tf envs/main/$layer/
  sed -e 's/"samwen-gke-lab-tfstate"/"samwen-gke-lab-main-tfstate"/' \
      -e "s#\"envs/production/$layer\"#\"envs/main/$layer\"#" \
      envs/production/$layer/versions.tf > envs/main/$layer/versions.tf
done
```

`envs/main/cluster/terraform.tfvars`:

```hcl
project_id = "samwen-gke-lab-main"
region     = "us-central1"
zone       = "us-central1-a"

# Sam's public IP on 2026-10-14. If it changes, kubectl times out: update this and apply.
admin_cidr = "203.0.113.7/32"
```

`envs/main/edge/terraform.tfvars`:

```hcl
project_id    = "samwen-gke-lab-main"
region        = "us-central1"
hostname      = "chat-lab-main.liveinference.com"
allowed_cidrs = ["203.0.113.7/32"]
```

- [ ] **Step 8: Lock the provider for each root** (committed, so `init` never changes a tracked file and the
  `./tf` guard's "no uncommitted changes" holds)

```bash
for root in envs/main/cluster envs/main/edge envs/production/cluster envs/production/edge; do
  TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache" terraform -chdir="$root" providers lock \
    -platform=darwin_arm64 -platform=linux_amd64 > /dev/null && echo "locked $root"
done
```
Expected: four `locked …` lines and a `.terraform.lock.hcl` in each root.

- [ ] **Step 9: Retire the old roots**

```bash
git rm -r -q envs/lab envs/edge
rm -rf envs/lab envs/edge    # their ignored local .terraform folders
ls envs                      # Expected: main  production
```

- [ ] **Step 10: Run it to see everything pass**

Run: `./check > "$TMPDIR/t2.txt" 2>&1; echo "exit $?"; grep -c '^PASS' "$TMPDIR/t2.txt"; grep -A8 '^FAIL' "$TMPDIR/t2.txt"`
Expected: `exit 0`; no FAIL lines. (The first run downloads the Google provider once into the cache.)

- [ ] **Step 11: Prove the move check can fail**

Run: `cp envs/production/edge/moved.tf "$TMPDIR/moved.bak" && sed -i '' 's/to   = module.edge.google_compute_global_address.chat/to   = module.edge.google_compute_global_address.chatx/' envs/production/edge/moved.tf; ./check 2>&1 | grep -A1 'moves every resource'; cp "$TMPDIR/moved.bak" envs/production/edge/moved.tf; git diff --stat envs/production/edge/moved.tf`
Expected: `FAIL  production's entrance moves every resource it had into module.edge` with `no moved block to
module.edge.google_compute_global_address.chat`; then no diff (the file is back; it is new, so `git diff` prints
nothing either way, and `./check` passes again).

- [ ] **Step 12: Commit (standing go only)**

```bash
git add -A modules envs test/expected/production-edge-resources.txt test/checks/10-terraform.sh check
git commit -m "Terraform per environment: platform and edge modules, four roots, production's entrance moved into the module

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The wrappers take the environment; `./tf` guards changing commands

**Files:**
- Create: `lib/env.sh`, `test/wrappers_test.sh`
- Modify: `tf`, `k`, `h` (full rewrites below), `test/checks/50-scripts.sh`

**Interfaces:**
- Consumes: the roots `envs/<env>/<layer>` (Task 2).
- Produces: `lib/env.sh` with `use_env <env>` (sets `lab_env`, exports `CLOUDSDK_ACTIVE_CONFIG_NAME` and
  `KUBECONFIG="$here/.kube/<env>/config"`; exits 2 with a usage line on anything but `main` or `production`) and
  `ensure_kubeconfig` (fetches the cluster's credentials into `$KUBECONFIG` if it is empty). The caller must set
  `here` first. Command lines: `./tf <env> <cluster|edge> <terraform args>`, `./k <env> <kubectl args>`,
  `./h <env> <helm args>`. Exit codes: 2 usage, 3 refused by the guard.

- [ ] **Step 1: Write the wrapper tests**

Create `test/wrappers_test.sh`:

```bash
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
echo "$(basename "$0") $* | profile=${CLOUDSDK_ACTIVE_CONFIG_NAME:-} kubeconfig=${KUBECONFIG:-}" >> "$LOG"
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
printf 'tfplan*\n.kube/\n' > "$work/.gitignore"
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

# Read-only commands run on any branch (here: feature), each with its own profile and folder.
run planmain ./tf main cluster plan
run planprod ./tf production edge plan
run statelist ./tf main cluster state list
expect "plan main cluster from a short-lived branch: runs in envs/main/cluster as gke-lab-main" \
  called planmain "terraform -chdir=$work/envs/main/cluster plan | profile=gke-lab-main"
expect "plan production edge from a short-lived branch: runs in envs/production/edge as gke-lab" \
  called planprod "terraform -chdir=$work/envs/production/edge plan | profile=gke-lab"
expect "state list from a short-lived branch: runs" called statelist "terraform -chdir=$work/envs/main/cluster state list"

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
run applyprod ./tf production cluster apply
expect "apply production from main: refused, names the production branch" refused applyprod "production branch"

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
```

In `test/checks/50-scripts.sh`, replace the shellcheck line and add the new test:

```bash
# lib/env.sh and test/checks/*.sh are checked through the scripts that source them (-x), where
# the variables they use are defined.
check "scripts pass shellcheck" shellcheck -x -e SC2329 check tf k h bootstrap test/bootstrap_test.sh test/wrappers_test.sh
check "tf, k and h, run against stand-ins in a scratch repository" test/wrappers_test.sh
```

- [ ] **Step 2: Run it to see it fail**

Run: `chmod +x test/wrappers_test.sh && test/wrappers_test.sh; echo "exit $?"`
Expected: `cp: …/lib/env.sh: No such file or directory`, then FAIL lines for every case (the old wrappers take no
environment); `exit 1`.

- [ ] **Step 3: Create `lib/env.sh`**

```bash
# shellcheck shell=bash
# Shared by ./tf, ./k, ./h and ./bootstrap. The environment is always the first word and there is no
# default, so nothing reaches production unless "production" is typed. The caller sets $here first.

# use_env <env>: sets lab_env, the gcloud profile and the environment's own kubeconfig.
use_env() {
  case "${1:-}" in
    main) CLOUDSDK_ACTIVE_CONFIG_NAME=gke-lab-main ;;
    production) CLOUDSDK_ACTIVE_CONFIG_NAME=gke-lab ;;
    *)
      echo "The first word must be the environment: main or production (got '${1:-}')." >&2
      exit 2
      ;;
  esac
  lab_env="$1"
  export CLOUDSDK_ACTIVE_CONFIG_NAME
  export KUBECONFIG="$here/.kube/$lab_env/config"
}

# ensure_kubeconfig: fetches the cluster's address and certificate into the environment's kubeconfig
# on first use. A rebuilt cluster has a new address: delete .kube/<env> after a teardown.
ensure_kubeconfig() {
  if [ ! -s "$KUBECONFIG" ]; then
    mkdir -p "$(dirname "$KUBECONFIG")"
    gcloud container clusters get-credentials lab --zone us-central1-a > /dev/null
  fi
}
```

- [ ] **Step 4: Rewrite `tf`**

```bash
#!/usr/bin/env bash
# Terraform for one environment and one layer, as the account named by that environment's gcloud
# profile:
#   ./tf <main|production> <cluster|edge> <terraform arguments>
#   ./tf main cluster plan -out=tfplan      ./tf main cluster apply tfplan
# Commands that change an environment (apply, destroy, import, force-unlock, taint, untaint, and
# state mv/rm/push/replace-provider) run only from the branch named after the environment, with no
# uncommitted changes, and identical to GitHub's copy: what reaches an environment is exactly what is
# on its branch. Everything else (plan, validate, output, show, state list/show/pull, init) runs on any
# branch, so a change can be previewed from a short-lived branch.
# It passes a short-lived token instead of Application Default Credentials, because this Mac's
# default credentials may belong to another account.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/env.sh
. "$here/lib/env.sh"
use_env "${1:-}"
layer="${2:-}"
case "$layer" in
  cluster | edge) ;;
  *)
    echo "The second word must be the layer: cluster or edge (got '$layer')." >&2
    exit 2
    ;;
esac
shift 2

changes_things() {
  case "${1:-}" in
    apply | destroy | import | force-unlock | taint | untaint) return 0 ;;
    state)
      case "${2:-}" in
        mv | rm | push | replace-provider) return 0 ;;
      esac
      ;;
  esac
  return 1
}

if changes_things "$@"; then
  branch="$(git -C "$here" rev-parse --abbrev-ref HEAD)"
  if [ "$branch" != "$lab_env" ]; then
    echo "Refused: '$*' on $lab_env runs only from the $lab_env branch; this checkout is on '$branch'." >&2
    exit 3
  fi
  if [ -n "$(git -C "$here" status --porcelain)" ]; then
    echo "Refused: there are uncommitted changes; '$1' applies only what is committed on $lab_env." >&2
    exit 3
  fi
  git -C "$here" fetch --quiet origin "$lab_env"
  if [ "$(git -C "$here" rev-parse HEAD)" != "$(git -C "$here" rev-parse "origin/$lab_env")" ]; then
    echo "Refused: $lab_env here is not identical to GitHub's $lab_env; pull or push first." >&2
    exit 3
  fi
fi

# A freshly refreshed token, good for a full hour. print-access-token can hand back a cached
# token close to expiry, and on 2026-10-14 one ran out partway through a destroy.
GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud config config-helper --force-auth-refresh --format='value(credential.access_token)')"
export GOOGLE_OAUTH_ACCESS_TOKEN
exec terraform -chdir="$here/envs/$lab_env/$layer" "$@"
```

- [ ] **Step 5: Rewrite `k` and `h`**

`k`:

```bash
#!/usr/bin/env bash
# kubectl for one environment's cluster, with that environment's own kubeconfig (.kube/<env>/config),
# so ~/.kube/config is never touched and the two clusters never mix. Fetches the cluster's
# credentials on first use.   ./k main get nodes
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/env.sh
. "$here/lib/env.sh"
use_env "${1:-}"
shift
ensure_kubeconfig
exec kubectl "$@"
```

`h`:

```bash
#!/usr/bin/env bash
# Helm for one environment's cluster, with the same kubeconfig as ./k.   ./h main list -A
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/env.sh
. "$here/lib/env.sh"
use_env "${1:-}"
shift
ensure_kubeconfig
exec helm "$@"
```

- [ ] **Step 6: Run it to see it pass**

Run: `test/wrappers_test.sh; echo "exit $?"; ./check > "$TMPDIR/t3.txt" 2>&1; echo "check exit $?"; grep -A8 '^FAIL' "$TMPDIR/t3.txt"`
Expected: every line `ok`, `exit 0`; `./check` exit 0. (The old `bootstrap` still passes its stand-in test:
the stand-ins ignore the missing environment word. Task 6 makes it take one.)

- [ ] **Step 7: Commit (standing go only)**

```bash
git add lib/env.sh tf k h test/wrappers_test.sh test/checks/50-scripts.sh
git commit -m "Wrappers take the environment as a required first word; ./tf refuses changing commands off the environment's branch

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The chat settings, shared and per environment

**Files:**
- Create: `test/expected/chat-production-env.txt`, `apps/chat/env/main.yaml`, `apps/chat/env/production.yaml`
- Modify: `apps/chat/values.yaml` (the `extraEnvVars` block), `test/checks/20-chat.sh` (full rewrite)

**Interfaces:**
- Consumes: `check`, `envs`, `tmp` (Task 1).
- Produces: `apps/chat/env/<env>.yaml` (read by Argo CD in Task 6 as `$values/apps/chat/env/<env>.yaml`, after
  `values.yaml`); rendered files `$tmp/chat-<env>.yaml`.

- [ ] **Step 1: Snapshot production's settings before anything moves**

```bash
helm template chat open-webui --repo https://helm.openwebui.com --version 17.0.0 -n chat \
  -f apps/chat/values.yaml --skip-tests \
  | yq e 'select(.kind == "StatefulSet" and .metadata.name == "chat-open-webui") | .spec.template.spec.containers[] | select(.name == "open-webui") | .env[] | .name + "=" + (.value // "(from elsewhere)")' \
  | sort > test/expected/chat-production-env.txt
grep -c . test/expected/chat-production-env.txt
grep '^WEBUI_URL=' test/expected/chat-production-env.txt
```
Expected: a count of at least 11 (the 11 variables set in `values.yaml`, plus any the chart adds), and
`WEBUI_URL=https://chat-lab.liveinference.com`.

- [ ] **Step 2: Write the per-environment chat checks**

Replace `test/checks/20-chat.sh` with:

```bash
# shellcheck shell=bash
# Sourced by ./check, which defines check(), strict(), here, tmp, repo, schemas, envs and other().

# --- The chat app per environment, rendered the way Argo CD renders it (argocd/base/apps/chat.yaml) -
render_chat() { # render_chat <env>: values.yaml, then the environment's own file on top
  helm template chat open-webui --repo https://helm.openwebui.com --version 17.0.0 -n chat \
    -f apps/chat/values.yaml -f "apps/chat/env/$1.yaml" --skip-tests > "$tmp/chat-$1.yaml"
}
# The names apps/chat/edge and the NetworkPolicy rely on.
chat_names() { # chat_names <env>
  local have want
  [ -s "$tmp/chat-$1.yaml" ] || { echo "nothing rendered"; return 1; }
  have="$(yq e '.kind + "/" + .metadata.name' "$tmp/chat-$1.yaml")" || return 1
  for want in Service/chat-open-webui StatefulSet/chat-open-webui Deployment/chat-ollama \
    Service/chat-ollama NetworkPolicy/ollama-only-from-open-webui \
    PersistentVolumeClaim/chat-open-webui PersistentVolumeClaim/chat-ollama; do
    grep -qx "$want" <<< "$have" || { echo "missing $want"; return 1; }
  done
}
# webui_env <env>: the Open WebUI container's environment variables, one name=value per line, sorted.
webui_env() {
  [ -s "$tmp/chat-$1.yaml" ] || { echo "nothing rendered for $1"; return 1; }
  yq e 'select(.kind == "StatefulSet" and .metadata.name == "chat-open-webui") | .spec.template.spec.containers[] | select(.name == "open-webui") | .env[] | .name + "=" + (.value // "(from elsewhere)")' "$tmp/chat-$1.yaml" | sort
}
webui_url_is() { # webui_url_is <env> <url>: exactly one WEBUI_URL, with this value
  local urls
  urls="$(webui_env "$1" | grep '^WEBUI_URL=')"
  [ "$urls" = "WEBUI_URL=$2" ] || { echo "got: $urls"; return 1; }
}
# Production keeps every setting it had before the settings were split (test/expected/chat-production-env.txt,
# taken on 2026-10-15 from the single values.yaml).
production_unchanged() { diff test/expected/chat-production-env.txt <(webui_env production); }
main_differs_only_in_address() {
  diff <(webui_env production | grep -v '^WEBUI_URL=') <(webui_env main | grep -v '^WEBUI_URL=')
}

for env in "${envs[@]}"; do
  check "chat ($env) renders with values.yaml and env/$env.yaml" render_chat "$env"
  check "chat ($env) keeps the names the entrance and the NetworkPolicy use" chat_names "$env"
done
check "chat (main) page address is https://chat-lab-main.liveinference.com" webui_url_is main https://chat-lab-main.liveinference.com
check "chat (production) page address is https://chat-lab.liveinference.com" webui_url_is production https://chat-lab.liveinference.com
check "chat (production) keeps every setting it had (test/expected/chat-production-env.txt)" production_unchanged
check "chat (main) differs from production only in its page address" main_differs_only_in_address
```

- [ ] **Step 3: Run it to see it fail**

Run: `./check 2>&1 | grep -E '^(PASS|FAIL)  chat'`
Expected: `FAIL  chat (main) renders…` and `FAIL  chat (production) renders…` (no `env/` files yet), and the checks
after them FAIL too.

- [ ] **Step 4: Split the settings**

In `apps/chat/values.yaml`, replace the line `extraEnvVars:` with the comment and key below, and delete the last
entry of that list (the `WEBUI_URL` name/value pair); every other entry stays exactly as it is:

```yaml
# Settings the same in every environment. The chart adds these after extraEnvVars, which
# apps/chat/env/<env>.yaml sets to what differs per environment (a list set in a second values file
# replaces the first file's list rather than adding to it, hence two lists).
commonEnvVars:
```

The comment above `ENABLE_SIGNUP` keeps its first sentence only: `# No one can create an account from the sign-in page;
the admin adds users in the Admin Panel.` (the page's address now lives in the environment files).

Create `apps/chat/env/main.yaml`:

```yaml
# main's own chat settings, read after apps/chat/values.yaml. Only what differs from production.
extraEnvVars:
  # The page is public at this address (apps/chat/edge/main).
  - name: WEBUI_URL
    value: https://chat-lab-main.liveinference.com
```

Create `apps/chat/env/production.yaml`:

```yaml
# production's own chat settings, read after apps/chat/values.yaml. Only what differs from main.
extraEnvVars:
  # The page is public at this address (apps/chat/edge/production).
  - name: WEBUI_URL
    value: https://chat-lab.liveinference.com
```

- [ ] **Step 5: Run it to see it pass**

Run: `./check 2>&1 | grep -E '^(PASS|FAIL)  chat'`
Expected: all eight chat lines PASS.

- [ ] **Step 6: Prove the snapshot check catches a dropped setting**

Run: `cp apps/chat/values.yaml "$TMPDIR/values.bak" && sed -i '' '/name: ENABLE_SIGNUP/,+1d' apps/chat/values.yaml; ./check 2>&1 | grep -A3 'keeps every setting'; cp "$TMPDIR/values.bak" apps/chat/values.yaml; git diff --stat apps/chat/values.yaml`
Expected: `FAIL  chat (production) keeps every setting it had…` with a diff line `< ENABLE_SIGNUP=False`; afterwards
`git diff --stat` shows only this task's intended change to `values.yaml` (the `commonEnvVars` split).

- [ ] **Step 7: Commit (standing go only)**

```bash
git add apps/chat/values.yaml apps/chat/env test/expected/chat-production-env.txt test/checks/20-chat.sh
git commit -m "Chat settings: shared in values.yaml, the page address per environment

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: The entrance, a base and one overlay per environment

**Files:**
- Create: `apps/chat/edge/base/edge.yaml` (moved from `apps/chat/edge.yaml`), `apps/chat/edge/base/kustomization.yaml`,
  `apps/chat/edge/main/kustomization.yaml`, `apps/chat/edge/production/kustomization.yaml`, `test/checks/30-edge.sh`
- Delete: `apps/chat/edge.yaml`
- Modify: `check` (source `30-edge.sh` after `20-chat.sh`)

**Interfaces:**
- Consumes: `check`, `strict`, `envs`, `tmp` (Task 1).
- Produces: Kustomize folders `apps/chat/edge/<env>` (Argo CD's `chat-edge` reads them in Task 6).

- [ ] **Step 1: Write the entrance checks**

Create `test/checks/30-edge.sh`:

```bash
# shellcheck shell=bash
# Sourced by ./check, which defines check(), strict(), here, tmp, repo, schemas, envs and other().

# --- The public entrance per environment (apps/chat/edge/<env>) -----------------------------------
build_edge() { kubectl kustomize "apps/chat/edge/$1" > "$tmp/edge-$1.yaml"; } # build_edge <env>
edge_hostname_is() { # edge_hostname_is <env> <hostname>: both routes carry exactly this one hostname
  local got
  [ -s "$tmp/edge-$1.yaml" ] || { echo "nothing built"; return 1; }
  got="$(yq e 'select(.kind == "HTTPRoute") | .metadata.name + " " + (.spec.hostnames | join(","))' "$tmp/edge-$1.yaml" | sort)" || return 1
  [ "$got" = "chat $2"$'\n'"chat-redirect $2" ] || { echo "got:"; echo "$got"; return 1; }
}
edges_differ_only_in_hostname() {
  diff <(yq e 'del(.spec.hostnames)' "$tmp/edge-main.yaml") <(yq e 'del(.spec.hostnames)' "$tmp/edge-production.yaml")
}

for env in "${envs[@]}"; do
  check "entrance ($env) builds" build_edge "$env"
  check "entrance ($env) matches its schemas" strict "$tmp/edge-$env.yaml"
done
check "entrance (main) answers only to chat-lab-main.liveinference.com" edge_hostname_is main chat-lab-main.liveinference.com
check "entrance (production) answers only to chat-lab.liveinference.com" edge_hostname_is production chat-lab.liveinference.com
check "the two entrances differ only in their hostname" edges_differ_only_in_hostname
```

Add to `check`, after the `20-chat.sh` lines:
```bash
# shellcheck source=test/checks/30-edge.sh
. test/checks/30-edge.sh
```

- [ ] **Step 2: Run it to see it fail**

Run: `./check 2>&1 | grep -E '^(PASS|FAIL)  (entrance|the two entrances)'`
Expected: all seven FAIL (`apps/chat/edge/main` does not exist).

- [ ] **Step 3: Move and split the entrance**

```bash
mkdir -p apps/chat/edge/base apps/chat/edge/main apps/chat/edge/production
git mv apps/chat/edge.yaml apps/chat/edge/base/edge.yaml
```

In `apps/chat/edge/base/edge.yaml`:
- Replace the header's first line `# Public HTTPS entrance to the chat app: https://chat-lab.liveinference.com` with
  `# Public HTTPS entrance to the chat app, shared by both environments. Each environment's overlay`
  `# (apps/chat/edge/<env>) adds its hostname to the two routes; Argo CD applies the overlay as the app chat-edge.`
- Replace the header line `#   ./k apply -f ~/projects/gke-lab/apps/chat/edge.yaml` with
  `# The IP address, certificate map and Cloud Armor policy are named chat-lab in both projects.`
- Delete both `hostnames:` keys and their `- chat-lab.liveinference.com` lines (in `HTTPRoute chat` and
  `HTTPRoute chat-redirect`).

`apps/chat/edge/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - edge.yaml
```

`apps/chat/edge/main/kustomization.yaml`:

```yaml
# main's public entrance: the shared base, answering to main's hostname on both routes.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base
patches:
  - target:
      kind: HTTPRoute
    patch: |-
      - op: add
        path: /spec/hostnames
        value: [chat-lab-main.liveinference.com]
```

`apps/chat/edge/production/kustomization.yaml`:

```yaml
# production's public entrance: the shared base, answering to production's hostname on both routes.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base
patches:
  - target:
      kind: HTTPRoute
    patch: |-
      - op: add
        path: /spec/hostnames
        value: [chat-lab.liveinference.com]
```

- [ ] **Step 4: Run it to see it pass**

Run: `./check 2>&1 | grep -E '^(PASS|FAIL)  (entrance|the two entrances)'`
Expected: all seven PASS.

- [ ] **Step 5: Prove the hostname check catches a slip**

Run: `cp apps/chat/edge/main/kustomization.yaml "$TMPDIR/k.bak" && sed -i '' 's/chat-lab-main.liveinference.com/chat-lab.liveinference.com/' apps/chat/edge/main/kustomization.yaml; ./check 2>&1 | grep -E '^FAIL  (entrance|the two)'; cp "$TMPDIR/k.bak" apps/chat/edge/main/kustomization.yaml`
Expected: `FAIL  entrance (main) answers only to chat-lab-main.liveinference.com`; afterwards the file is restored.

- [ ] **Step 6: Commit (standing go only)**

```bash
git add -A apps/chat/edge apps/chat/edge.yaml test/checks/30-edge.sh check
git commit -m "Entrance: one shared base, and a Kustomize overlay per environment for its hostname

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Argo CD per environment, and `./bootstrap <env>`

**Files:**
- Create: `argocd/base/root/root.yaml`, `argocd/base/root/kustomization.yaml`, `argocd/base/apps/chat.yaml`,
  `argocd/base/apps/chat-edge.yaml`, `argocd/base/apps/kustomization.yaml`, `argocd/main/kustomization.yaml`,
  `argocd/main/apps/kustomization.yaml`, `argocd/production/kustomization.yaml`,
  `argocd/production/apps/kustomization.yaml`
- Delete: `argocd/root.yaml`, `argocd/apps/chat.yaml`, `argocd/apps/chat-edge.yaml`
- Modify: `bootstrap`, `test/bootstrap_test.sh` (full rewrites below), `test/checks/40-argocd.sh` (the apps section)

**Interfaces:**
- Consumes: `lib/env.sh` `use_env` (Task 3); `apps/chat/env/<env>.yaml` (Task 4); `apps/chat/edge/<env>` (Task 5).
- Produces: `./bootstrap <env>`; Kustomize folders `argocd/<env>` (the root app) and `argocd/<env>/apps` (chat,
  chat-edge); the placeholder `OVERLAY-MUST-SET` in the base, which no built overlay may contain.

- [ ] **Step 1: Rewrite the bootstrap test**

Replace `test/bootstrap_test.sh` with:

```bash
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
```

- [ ] **Step 2: Rewrite the apps section of `test/checks/40-argocd.sh`**

Keep the `# --- Argo CD's own settings …` section as it is. Replace everything from `# --- The three Argo CD apps …`
to the end of the file with:

```bash
# --- Argo CD's apps per environment (argocd/<env> and argocd/<env>/apps, over argocd/base) -------
build_argocd() { # build_argocd <env>: the root app, and the apps it keeps running
  kubectl kustomize "argocd/$1" > "$tmp/argocd-$1-root.yaml" &&
    kubectl kustomize "argocd/$1/apps" > "$tmp/argocd-$1-apps.yaml"
}
app() { yq e -e "select(.metadata.name == \"$2\") | $3" "$1"; } # app <built file> <app name> <yq condition>
no_placeholder() { # the base's OVERLAY-MUST-SET was replaced everywhere
  [ -s "$tmp/argocd-$1-apps.yaml" ] || { echo "nothing built"; return 1; }
  ! grep -n OVERLAY-MUST-SET "$tmp/argocd-$1-root.yaml" "$tmp/argocd-$1-apps.yaml"
}
# mentions_other <env> <files...>: the files name the other environment's branch, settings file,
# entrance folder or apps folder.
mentions_other() {
  local o
  o="$(other "$1")"
  shift
  grep -nE "targetRevision: $o\$|env/$o\.yaml|edge/$o\$|argocd/$o/" "$@"
}
no_other_env() { [ -s "$tmp/argocd-$1-apps.yaml" ] && ! mentions_other "$1" "$tmp/argocd-$1-root.yaml" "$tmp/argocd-$1-apps.yaml"; }
# Prove mentions_other catches a slip: main's apps overlay with one branch set to production.
slip_caught() {
  rm -rf "$tmp/slip" && mkdir -p "$tmp/slip" && cp -R argocd "$tmp/slip/" || return 1
  sed 's/value: main$/value: production/' argocd/main/apps/kustomization.yaml > "$tmp/slip/argocd/main/apps/kustomization.yaml"
  kubectl kustomize "$tmp/slip/argocd/main/apps" > "$tmp/slip/built.yaml" || return 1
  mentions_other main "$tmp/slip/built.yaml" > /dev/null
}
# The cluster drops fields it does not know without an error, so a misspelt selfHeal would quietly
# switch self-heal off. The strict schema check catches that; prove it on a copy with a typo.
typo_caught() {
  [ -s argocd/base/apps/chat-edge.yaml ] || { echo "argocd/base/apps/chat-edge.yaml missing"; return 1; }
  sed 's/selfHeal/selfheal/' argocd/base/apps/chat-edge.yaml > "$tmp/typo.yaml"
  ! strict "$tmp/typo.yaml" > /dev/null 2>&1
}

check "a misspelt field in an app is caught" typo_caught
check "a slip naming the other environment is caught" slip_caught
for env in "${envs[@]}"; do
  root="$tmp/argocd-$env-root.yaml"
  apps="$tmp/argocd-$env-apps.yaml"
  check "Argo CD ($env): root and apps build" build_argocd "$env"
  check "Argo CD ($env): apps match their schemas" strict "$root" "$apps"
  check "Argo CD ($env): nothing left of the base's OVERLAY-MUST-SET" no_placeholder "$env"
  check "Argo CD ($env): nothing of $(other "$env")'s branch, settings, entrance or apps" no_other_env "$env"
  for name in root chat chat-edge; do
    f="$apps"
    [ "$name" = root ] && f="$root"
    check "$env/$name: in namespace argocd, project default" \
      app "$f" "$name" '.kind == "Application" and .metadata.namespace == "argocd" and .spec.project == "default"'
    check "$env/$name: deleting it removes what it made (finalizer)" \
      app "$f" "$name" '.metadata.finalizers | any_c(. == "resources-finalizer.argocd.argoproj.io")'
    check "$env/$name: syncs by itself, prunes and self-heals" \
      app "$f" "$name" '.spec.syncPolicy.automated.prune == true and .spec.syncPolicy.automated.selfHeal == true'
    check "$env/$name: tries a failed sync again" app "$f" "$name" '.spec.syncPolicy.retry.limit > 0'
  done
  check "$env/root: keeps argocd/$env/apps on branch $env running" app "$root" root \
    ".spec.source.repoURL == \"$repo\" and .spec.source.targetRevision == \"$env\" and .spec.source.path == \"argocd/$env/apps\" and .spec.destination.namespace == \"argocd\""
  check "$env/chat: chart open-webui 17.0.0 as release chat, into namespace chat" app "$apps" chat \
    '.spec.sources[0].repoURL == "https://helm.openwebui.com" and .spec.sources[0].chart == "open-webui" and .spec.sources[0].targetRevision == "17.0.0" and .spec.sources[0].helm.releaseName == "chat" and .spec.destination.namespace == "chat"'
  check "$env/chat: values.yaml then env/$env.yaml, from branch $env" app "$apps" chat \
    ".spec.sources[0].helm.valueFiles[0] == \"\$values/apps/chat/values.yaml\" and .spec.sources[0].helm.valueFiles[1] == \"\$values/apps/chat/env/$env.yaml\" and (.spec.sources[0].helm.valueFiles | length) == 2 and .spec.sources[1].repoURL == \"$repo\" and .spec.sources[1].targetRevision == \"$env\" and .spec.sources[1].ref == \"values\""
  check "$env/chat: Helm test pods skipped" app "$apps" chat '.spec.sources[0].helm.skipTests == true'
  check "$env/chat-edge: apps/chat/edge/$env from branch $env" app "$apps" chat-edge \
    ".spec.source.repoURL == \"$repo\" and .spec.source.targetRevision == \"$env\" and .spec.source.path == \"apps/chat/edge/$env\" and .spec.destination.namespace == \"chat\""
  for name in chat chat-edge; do
    check "$env/$name: creates namespace chat if missing" \
      app "$apps" "$name" '.spec.syncPolicy.syncOptions | any_c(. == "CreateNamespace=true")'
  done
done
```

- [ ] **Step 3: Run it to see it fail**

Run: `./check > "$TMPDIR/t6.txt" 2>&1; echo "exit $?"; grep -E '^FAIL' "$TMPDIR/t6.txt" | head -12; test/bootstrap_test.sh | grep -c FAIL`
Expected: `exit 1`; the Argo CD apps checks FAIL (`argocd/main` does not exist); the bootstrap stand-in run FAILs;
`test/bootstrap_test.sh` reports FAIL lines for the normal-run cases.

- [ ] **Step 4: Create the base**

```bash
mkdir -p argocd/base/root argocd/base/apps argocd/main/apps argocd/production/apps
git mv argocd/root.yaml argocd/base/root/root.yaml
git mv argocd/apps/chat.yaml argocd/base/apps/chat.yaml
git mv argocd/apps/chat-edge.yaml argocd/base/apps/chat-edge.yaml
```

`argocd/base/root/root.yaml` (full content):

```yaml
# The root app, shared by both environments: keeps the environment's apps folder (argocd/<env>/apps,
# on the branch named after the environment) running. Its overlay, argocd/<env>, sets both; the
# placeholder below makes a missing overlay value fail loudly instead of tracking a default branch.
# ./bootstrap <env> applies argocd/<env>; Argo CD makes the rest from git. Deleting it removes
# everything the apps made (the finalizer), which is how a session ends: README, "End of a session".
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: git@github.com:xinferai/gke-genai-serving.git
    targetRevision: OVERLAY-MUST-SET
    path: OVERLAY-MUST-SET
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    # Automated sync does not try a failed sync again for the same commit unless told to.
    retry:
      limit: 5
      backoff: {duration: 30s, factor: 2, maxDuration: 5m}
```

`argocd/base/apps/chat.yaml` (full content):

```yaml
# The chat app: Open WebUI and Ollama, from the open-webui chart with our values from git: the shared
# apps/chat/values.yaml, then the environment's own file, which the overlay names (argocd/<env>/apps),
# together with the branch. Release name "chat" keeps the object names (chat-open-webui, chat-ollama)
# that the entrance and the NetworkPolicy rely on.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: chat
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: https://helm.openwebui.com
      chart: open-webui
      targetRevision: 17.0.0
      helm:
        releaseName: chat
        valueFiles:
          - $values/apps/chat/values.yaml
          - OVERLAY-MUST-SET
        # The Ollama sub-chart ships a test pod for `helm test`; it is not part of the app.
        skipTests: true
    - repoURL: git@github.com:xinferai/gke-genai-serving.git
      targetRevision: OVERLAY-MUST-SET
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: chat
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 5
      backoff: {duration: 30s, factor: 2, maxDuration: 5m}
    syncOptions:
      - CreateNamespace=true
```

`argocd/base/apps/chat-edge.yaml` (full content):

```yaml
# The public entrance: the environment's Kustomize folder apps/chat/edge/<env> (the Gateway that GKE
# turns into the load balancer, the routes, the health check, the Cloud Armor attachment). The overlay
# (argocd/<env>/apps) sets the folder and the branch. Its own app, so the entrance can be removed on
# its own.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: chat-edge
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: git@github.com:xinferai/gke-genai-serving.git
    targetRevision: OVERLAY-MUST-SET
    path: OVERLAY-MUST-SET
  destination:
    server: https://kubernetes.default.svc
    namespace: chat
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 5
      backoff: {duration: 30s, factor: 2, maxDuration: 5m}
    # If this app arrives before chat has made the namespace.
    syncOptions:
      - CreateNamespace=true
```

`argocd/base/root/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - root.yaml
```

`argocd/base/apps/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - chat.yaml
  - chat-edge.yaml
```

- [ ] **Step 5: Create the overlays**

`argocd/main/kustomization.yaml`:

```yaml
# main's root app: watches branch main and keeps argocd/main/apps running. ./bootstrap main applies this.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base/root
patches:
  - target:
      kind: Application
      name: root
    patch: |-
      - op: replace
        path: /spec/source/targetRevision
        value: main
      - op: replace
        path: /spec/source/path
        value: argocd/main/apps
```

`argocd/main/apps/kustomization.yaml`:

```yaml
# main's apps: branch main, main's settings file, main's entrance.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/apps
patches:
  - target:
      kind: Application
      name: chat
    patch: |-
      - op: replace
        path: /spec/sources/0/helm/valueFiles/1
        value: $values/apps/chat/env/main.yaml
      - op: replace
        path: /spec/sources/1/targetRevision
        value: main
  - target:
      kind: Application
      name: chat-edge
    patch: |-
      - op: replace
        path: /spec/source/targetRevision
        value: main
      - op: replace
        path: /spec/source/path
        value: apps/chat/edge/main
```

`argocd/production/kustomization.yaml`: the content of `argocd/main/kustomization.yaml` with every `main` replaced
by `production`:

```yaml
# production's root app: watches branch production and keeps argocd/production/apps running. ./bootstrap production applies this.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../base/root
patches:
  - target:
      kind: Application
      name: root
    patch: |-
      - op: replace
        path: /spec/source/targetRevision
        value: production
      - op: replace
        path: /spec/source/path
        value: argocd/production/apps
```

`argocd/production/apps/kustomization.yaml`:

```yaml
# production's apps: branch production, production's settings file, production's entrance.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/apps
patches:
  - target:
      kind: Application
      name: chat
    patch: |-
      - op: replace
        path: /spec/sources/0/helm/valueFiles/1
        value: $values/apps/chat/env/production.yaml
      - op: replace
        path: /spec/sources/1/targetRevision
        value: production
  - target:
      kind: Application
      name: chat-edge
    patch: |-
      - op: replace
        path: /spec/source/targetRevision
        value: production
      - op: replace
        path: /spec/source/path
        value: apps/chat/edge/production
```

- [ ] **Step 6: Rewrite `bootstrap`**

```bash
#!/usr/bin/env bash
# Hands a new cluster to Argo CD, for one environment. Run once after ./tf <env> cluster apply;
# running it again is safe.
#   ./bootstrap <main|production>
# 1. Installs Argo CD with Helm (chart argo-cd 10.10.5, which is Argo CD 3.5.5), settings in
#    argocd/values.yaml, and waits until it is ready.
# 2. Gives it read access to this private repository with the environment's own deploy key. The key
#    goes straight from its file into a Kubernetes Secret: never into git, Terraform state, or Helm
#    (which would copy it into every release revision).
# 3. Applies the environment's root app (argocd/<env>). Argo CD then installs everything else from
#    GitHub, from the branch named after the environment: merge first, or it installs what was there
#    before.
# Designs: docs/superpowers/specs/2026-10-15-argocd-design.md and
# docs/superpowers/specs/2026-10-15-two-environments-design.md
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/env.sh
. "$here/lib/env.sh"
use_env "${1:-}"
# K and H can name stand-ins for ./k and ./h; test/bootstrap_test.sh uses that to run this
# without a cluster.
k="${K:-$here/k}"
h="${H:-$here/h}"
key="${ARGOCD_DEPLOY_KEY:-$HOME/.ssh/gke-genai-serving-argocd-$lab_env}"
repo=git@github.com:xinferai/gke-genai-serving.git

if [ ! -s "$key" ]; then
  cat >&2 <<EOF
No deploy key at $key. Make it once on this Mac, then add its public half to GitHub (read-only):
  ssh-keygen -t ed25519 -N '' -C 'argocd-lab-$lab_env read-only deploy key' -f $key
  gh repo deploy-key add $key.pub --repo xinferai/gke-genai-serving --title "argocd-lab-$lab_env (read-only)"
EOF
  exit 1
fi

"$h" "$lab_env" upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.10.5 \
  -n argocd --create-namespace -f "$here/argocd/values.yaml" --wait --timeout 10m

# Made locally and applied, so a second run updates the secret instead of failing on it.
"$k" "$lab_env" -n argocd create secret generic repo-gke-genai-serving \
  --from-literal=type=git --from-literal=url="$repo" --from-file=sshPrivateKey="$key" \
  --dry-run=client -o yaml |
  "$k" "$lab_env" label --local -f - argocd.argoproj.io/secret-type=repository -o yaml |
  "$k" "$lab_env" apply -f -

"$k" "$lab_env" apply -k "$here/argocd/$lab_env"
echo "Argo CD is installing $lab_env's apps from GitHub, branch $lab_env. Watch: ./k $lab_env -n argocd get applications -w"
```

- [ ] **Step 7: Run it to see it pass**

Run: `test/bootstrap_test.sh; echo "exit $?"; ./check > "$TMPDIR/t6.txt" 2>&1; echo "check exit $?"; grep -A8 '^FAIL' "$TMPDIR/t6.txt"`
Expected: all 15 bootstrap lines `ok`, `exit 0`; `./check` exit 0. (The README still describes one environment,
and the old README check still passes; Task 8 rewrites both.)

- [ ] **Step 8: Commit (standing go only)**

```bash
git add -A argocd bootstrap test/bootstrap_test.sh test/checks/40-argocd.sh
git commit -m "Argo CD per environment: a shared base with an overlay per branch; ./bootstrap takes the environment

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The GitHub workflow that decides what may be merged into `production`

Two required checks on every pull request into `production` (design part 3): `source-allowed` (the source is `main`,
or a `hotfix/...` branch: the emergency lane) and `source-has-production` (the source already has every change
`production` has, merge commits left out, so a lane fix must be merged into `main` before `main` can be promoted
again). The history check's script is tested by running it in a scratch repository through the histories it must
tell apart.

**Files:**
- Create: `.github/workflows/into-production.yml`, `test/checks/60-github.sh`, `test/workflow_test.sh`
- Modify: `check` (source `60-github.sh` after `50-scripts.sh`), `test/checks/50-scripts.sh` (the shellcheck line)

**Interfaces:**
- Consumes: `check` (Task 1); the shellcheck line in `test/checks/50-scripts.sh` (Task 3).
- Produces: the job ids `source-allowed` and `source-has-production`, which are the required checks' names in the
  `production` ruleset (Gate 1); the branch prefix `hotfix/` (README, Task 8).

- [ ] **Step 1: Write the workflow checks and the history test**

Create `test/checks/60-github.sh`:

```bash
# shellcheck shell=bash
# Sourced by ./check, which defines check(), strict(), here, tmp, repo, schemas, envs and other().

# --- GitHub: what may be merged into production ----------------------------------------------------
wf=.github/workflows/into-production.yml
# run_script <job>: the job's own script, as written in the workflow.
run_script() { yq e ".jobs[\"$1\"].steps[] | select(has(\"run\")) | .run" "$wf"; }
from_branch() { # from_branch <head branch>: runs source-allowed's script the way GitHub would
  local script
  script="$(run_script source-allowed)" && [ -n "$script" ] || return 1
  HEAD_REF="$1" bash -e -o pipefail -c "$script"
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

check "production workflow: runs on pull requests into production" \
  yq e -e '(.on.pull_request.branches | length) == 1 and .on.pull_request.branches[0] == "production"' "$wf"
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
check "production workflow: source-allowed passes a pull request from a hotfix/ branch" from_branch hotfix/ingress-timeout
check "production workflow: source-allowed fails any other branch" \
  rejects feature hotfix/ hotfixes/x main-old my/hotfix/x 'main; true'
check "production workflow: source-has-production, run on scratch branch histories" test/workflow_test.sh
```

Create `test/workflow_test.sh` (then `chmod +x test/workflow_test.sh`):

```bash
#!/usr/bin/env bash
# Runs the script of the production workflow's source-has-production check in a scratch git
# repository, through the histories it must tell apart: promotions, the hotfix lane, and the fix's
# merge into main, squashed or not. Part of ./check; touches no real repository and no GitHub.
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
merge_into() { g switch -q "$1" && g merge -q --no-ff -m "Merge $2 into $1" "$2"; }
published() { g update-ref refs/remotes/origin/production production; }
# passes <branch>: the check, run as GitHub runs it (bash -e, pipefail) for a pull request from <branch>.
passes() {
  (cd "$repo" && HEAD_SHA="$(git rev-parse "$1")" bash -e -o pipefail -c "$script") > "$tmp/out" 2>&1
}
fails() { ! passes "$1"; }
names() { grep -q " $1\$" "$tmp/out"; }   # the failure lists the missing commit by its subject
# same <branch>: after a merge, the branch's files are exactly those of what it merged in (<branch>^2).
same() { g diff --quiet "$1^2" "$1"; }
differs() { ! same "$1"; }

change start
g branch production
change feature-a
merge_into production main                     # the first promotion: a merge commit only production has
g switch -q main && change feature-b           # main moves on, and is under test
published
expect "a promotion passes: production's only extra commit is a promotion merge" passes main

g switch -q -c hotfix/x production && change fix
g switch -q -c hotfix/stale 'production^1' && change stale-fix
expect "a hotfix branch from today's production passes" passes hotfix/x
expect "a hotfix branch from an older production fails" fails hotfix/stale
expect "... and names what it lacks" names feature-a

merge_into production hotfix/x                 # the lane: the fix goes live before main has it
published
expect "after the lane, main cannot be promoted" fails main
expect "... and the failure names the fix" names fix
g switch -q -c too-early production && g merge -q --no-ff -m "Promote main without the fix" main
expect "a promotion made anyway shows up: production's files are not main's" differs too-early

g switch -q -c squashed main && g merge -q --squash hotfix/x > /dev/null 2>&1 && g commit -q -m "fix, squashed"
expect "a squash of the fix into main does not count" fails squashed
merge_into squashed production
expect "... merging production into main afterwards puts it right" passes squashed

merge_into main hotfix/x                       # the fix merged into main with a merge commit
expect "after the fix is merged into main, main can be promoted again" passes main
merge_into production main                     # the next promotion
expect "after that promotion, production's files are exactly main's" same production
exit "$failed"
```

Add to `check`, after the `50-scripts.sh` lines:
```bash
# shellcheck source=test/checks/60-github.sh
. test/checks/60-github.sh
```

In `test/checks/50-scripts.sh`, add `test/workflow_test.sh` to the end of the shellcheck line:
```bash
check "scripts pass shellcheck" shellcheck -x -e SC2329 check tf k h bootstrap test/bootstrap_test.sh test/wrappers_test.sh test/workflow_test.sh
```

- [ ] **Step 2: Run it to see it fail**

Run: `./check 2>&1 | grep -E '^(PASS|FAIL)  (production workflow|scripts pass shellcheck)'`
Expected: all eleven `production workflow` lines FAIL (the workflow does not exist; `source-allowed fails any other
branch` fails too, because it first requires the script to exist); `scripts pass shellcheck` PASS.

- [ ] **Step 3: Create the workflow**

`.github/workflows/into-production.yml` (the checkout commit id is `actions/checkout` v7.0.1, looked up on 2026-10-15
with `gh api repos/actions/checkout/commits/v7.0.1 --jq .sha`):

```yaml
# Every pull request into production gets two checks, both required on the production branch (GitHub
# ruleset):
# - source-allowed: the source is main (a promotion) or a hotfix/ branch (the emergency lane, for when
#   production needs a fix now and main cannot be promoted yet).
# - source-has-production: the source already has every change production has. Promotion merge
#   commits are the only commits production has that main lacks, so merge commits are left out; a fix
#   that came through the lane is not, so main cannot be promoted until the fix is merged into it, and
#   a hotfix branch must start from today's production.
# Branch names and commit ids reach the scripts through environment variables, never pasted into them,
# so a branch named like a shell command cannot run.
name: into-production
on:
  pull_request:
    branches: [production]
permissions: {}
jobs:
  source-allowed:
    runs-on: ubuntu-latest
    steps:
      - name: The pull request comes from main or a hotfix branch
        env:
          HEAD_REF: ${{ github.head_ref }}
        run: |
          case "$HEAD_REF" in
            main)
              echo "From main: a promotion." ;;
            hotfix/?*)
              echo "From $HEAD_REF: the hotfix lane. Once the main environment is free, merge this branch into main"
              echo "too, with a merge commit (not squash); main cannot be promoted until then." ;;
            *)
              echo "This pull request comes from '$HEAD_REF'. Only main, or a branch named hotfix/..., may be"
              echo "merged into production."
              exit 1 ;;
          esac
  source-has-production:
    runs-on: ubuntu-latest
    # Reading the repository is all it needs; it changes nothing.
    permissions:
      contents: read
    steps:
      # v7.0.1, pinned to its commit id: a tag can be moved to other code, a commit id cannot.
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          fetch-depth: 0             # every branch's full history, so origin/production is there to compare
          persist-credentials: false # the token is not left in the checkout's git settings
      - name: The source branch has every change production has
        env:
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        run: |
          missing="$(git log --no-merges --format='%h %s' "$HEAD_SHA..origin/production")"
          if [ -n "$missing" ]; then
            echo "production has changes this branch does not:"
            echo "$missing"
            echo "From main: merge the hotfix branch into main first, with a merge commit. From a hotfix branch:"
            echo "start it again from today's production."
            exit 1
          fi
          echo "This branch has every change production has."
```

- [ ] **Step 4: Run it to see it pass**

Run: `test/workflow_test.sh; echo "exit $?"; ./check 2>&1 | grep -E '^(PASS|FAIL)  production workflow'`
Expected: eleven `ok` lines and `exit 0`; then all eleven `production workflow` lines PASS.

- [ ] **Step 5: Prove the history test catches a broken script**

Run: `sed 's/--no-merges //' .github/workflows/into-production.yml > "$TMPDIR/broken.yml"; WF="$TMPDIR/broken.yml" test/workflow_test.sh | grep FAIL`
Expected: exactly two lines, `FAIL  a promotion passes: production's only extra commit is a promotion merge` and
`FAIL  after the fix is merged into main, main can be promoted again` (without `--no-merges`, the promotion merge
commits that only `production` has would block every promotion).

- [ ] **Step 6: Commit (standing go only)**

```bash
git add .github/workflows/into-production.yml test/checks/60-github.sh test/workflow_test.sh test/checks/50-scripts.sh check
git commit -m "Let production take pull requests only from main or a hotfix branch that has everything production has

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: README, ignore list, design status lines, progress note

**Files:**
- Modify: `README.md` (full rewrite below), `.gitignore`, `test/checks/70-readme.sh` (full rewrite),
  `docs/superpowers/specs/2026-10-15-argocd-design.md` (status line),
  `docs/superpowers/specs/2026-10-15-two-environments-design.md` (status line),
  the session notes outside this repository (Session 3 progress)

**Interfaces:**
- Consumes: every command and path from Tasks 2 to 7.
- Produces: nothing other tasks use.

- [ ] **Step 1: Rewrite the README check**

Replace `test/checks/70-readme.sh` with:

```bash
# shellcheck shell=bash
# Sourced by ./check, which defines check(), strict(), here, tmp, repo, schemas, envs and other().

# --- The README describes the two-environment way of working ---------------------------------------
readme_current() {
  local want stale
  for want in './tf main cluster plan' './bootstrap main' './k main get nodes' './check' 'delete application root' \
    'replicaCount: 0' 'ollama.replicaCount' "switch off automatic sync on \`root\`" 'never squash' \
    'apps/chat/env/<env>.yaml' '.kube/<env>/config' 'chat-lab-main.liveinference.com' 'hotfix branches off' \
    'always promotable' 'into-production.yml' 'source-allowed' 'source-has-production' 'hotfix/<what>' \
    'merge commit, not squash' 'production^2' '--first-parent'; do
    grep -qF -- "$want" README.md || { echo "README does not mention: $want"; return 1; }
  done
  stale="$(grep -nE 'source-is-main|production-only-from-main|TF_ENV|\.kubeconfig|h install chat|h uninstall chat|scale deploy/chat-ollama|apply -f .*edge\.yaml|\./(k|h) -n |\./(k|h|tf) (get|list|plan|apply|destroy|install|upgrade)( |$)|\./bootstrap *($|#)' README.md)"
  [ -z "$stale" ] || { echo "README still says:"; echo "$stale"; return 1; }
}
check "README describes the two-environment way of working" readme_current
```

- [ ] **Step 2: Run it to see it fail**

Run: `./check 2>&1 | grep -A2 '^FAIL  README'`
Expected: `FAIL  README describes the two-environment way of working` with `README does not mention: ./tf main
cluster plan`.

- [ ] **Step 3: Rewrite `README.md`** with exactly this content:

````markdown
# GKE lab

A pilot POC project. This is lab work, not production:
"production" below is the name of one of the lab's two environments.

## Two environments, two branches

| | main | production |
|---|---|---|
| Branch | `main`: testing, collecting changes, the checkpoint | `production`: changes only by pull request from `main` |
| GCP project | `samwen-gke-lab-main` | `samwen-gke-lab` |
| gcloud profile | `gke-lab-main` | `gke-lab` |
| Terraform state | `gs://samwen-gke-lab-main-tfstate` | `gs://samwen-gke-lab-tfstate` |
| Public address | https://chat-lab-main.liveinference.com | https://chat-lab.liveinference.com |

Every change goes: a short-lived branch off `main` (a hotfix branches off `production`, so it starts from what is
live) → pull request into `main` → test on the main environment → pull request from `main` into `production` (merge
commit, never squash: a squash makes a commit `main` never had, and the branches drift apart) → production. After each
promotion, `git diff origin/production^2 origin/production` prints nothing: production runs exactly the files the
main environment tested. The two branches never share a commit id (the promotion merge commit is only on
`production`), and nothing is merged back: `git log --first-parent origin/production` lists every promotion and
hotfix, and each one's `^2` is the commit it brought in.

GitHub enforces it: no direct pushes to either branch, and two required checks (`.github/workflows/into-production.yml`)
on every pull request into `production`: `source-allowed` (it comes from `main` or a `hotfix/...` branch) and
`source-has-production` (it already has every change `production` has, merge commits left out). Design:
`docs/superpowers/specs/2026-10-15-two-environments-design.md`.

Keep `main` always promotable: promotion moves all of `main` at once, so merge into it only what would ship once it
passes on the main environment. If something there fails, revert it on `main` before the next promotion, or it blocks
everything behind it. Promote often, so the gap between `main` and `production` stays small.

A hotfix that cannot wait for `main` (it is under test, or holds something broken): branch `hotfix/<what>` off
`production`, run `./check`, and open a pull request straight into `production`; merging it (merge commit) deploys
the fix to production only. When the main environment is free, open a pull request from the same branch into `main`
and merge it with a merge commit, not squash; then re-check the main environment. Until then `source-has-production`
blocks every promotion. If it was squashed by mistake, a pull request from `production` into `main` (merge commit)
puts it right without changing any file. After a hotfix merge, re-run the checks on an open promotion pull request:
GitHub re-runs them only when the pull request's own branch changes. The price of the lane: the fix reaches
production having passed only `./check`. When `main` can be promoted, a hotfix goes through `main` like any change.

The environments are exact copies, GPU included. What differs lives in files named after the environment, present on
both branches, so a merge from `main` never carries main's settings into production: `envs/<env>/*/terraform.tfvars`,
the bucket and prefix in `envs/<env>/*/versions.tf`, `apps/chat/env/<env>.yaml`, `apps/chat/edge/<env>/`, and
`argocd/<env>/`.

## Commands

The environment is always the first word; there is no default.

```
./tf main cluster plan -out=tfplan    # Terraform for one environment and one layer (cluster or edge)
./tf main cluster apply tfplan
./bootstrap main                      # install Argo CD; it installs the apps from GitHub, branch main
./k main get nodes                    # kubectl for that environment's cluster
./h main list -A                      # Helm, same cluster
./check                               # offline checks for both environments; run before every push
```

- `./tf` runs Terraform as the account the environment's gcloud profile names, in `envs/<env>/<layer>`. Commands
  that change an environment (`apply`, `destroy`, `import`, `force-unlock`, `taint`, `untaint`, `state
  mv/rm/push/replace-provider`) run only from that environment's branch, with no uncommitted changes, and identical to
  GitHub's copy. `plan` and the other read-only commands run anywhere, so a change can be previewed from a short-lived
  branch. The first time in a folder, run `./tf <env> <layer> init`.
- `./k` and `./h` use `.kube/<env>/config`, so `~/.kube/config` is never touched and the two clusters never mix.

Layout: `modules/` holds `network`, `gke-cluster`, `node-pool`, `platform` (one environment's network, cluster and
pools) and `edge` (the long-lived half of its public entrance); `envs/<env>/cluster` and `envs/<env>/edge` are the four
Terraform roots, identical apart from `terraform.tfvars` and where `versions.tf` keeps the state (`./check` compares
them); `apps/` holds what runs on the clusters; `argocd/` holds Argo CD's settings and its apps; `docs/superpowers/`
holds designs and build plans; `test/` holds what `./check` runs. Lab answers go in `notes.md`. Give each saved plan
its own name (`-out=tfplan-gpu`), so an applied plan is never mistaken for a new one.

Node pools, the same in both: `system` (cluster add-ons and Argo CD, on-demand, 1–2 nodes), `apps` (tenant workloads,
Spot, 0–3, tainted `workload=apps:NoSchedule`), `gpu` (one NVIDIA L4 per node, Spot, 0–1, tainted by GKE with
`nvidia.com/gpu`).

## Argo CD

`./bootstrap <env>`, after `./tf <env> cluster apply`, installs Argo CD (chart `argo-cd` 10.10.5, which is Argo CD
3.5.5; settings in `argocd/values.yaml`, all on the `system` pool), gives it read access to this repository, and
applies `argocd/<env>`, the root app. The root app keeps `argocd/<env>/apps` running from the branch named after the
environment: `chat` (Open WebUI and Ollama) and `chat-edge` (the public entrance). Running it again is safe. Design:
`docs/superpowers/specs/2026-10-15-argocd-design.md`.

Read access is one deploy key per environment, made once: its private half is `~/.ssh/gke-genai-serving-argocd-<env>` on
this Mac only, its public half is on GitHub as a read-only deploy key. `./bootstrap` puts it straight into a Kubernetes
Secret, never into git, Terraform or Helm. If the key is missing, `./bootstrap` stops and prints the two commands that
make and register it.

Argo CD's screen: `./k <env> -n argocd port-forward svc/argocd-server 8081:443`, then http://localhost:8081, user
`admin`. The password, copied to the clipboard without showing it:

```
./k main -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d | pbcopy
```

Changing an app: each Argo CD deploys what is on its own branch on GitHub, not what is in this folder. Change the file
on a short-lived branch, run `./check`, push, and open a pull request into `main`; merging it deploys to main within
about 3 minutes (Refresh in Argo CD's screen makes it look now). A pull request from `main` into `production` then
deploys to production. Pods whose settings changed restart, which ends a running port-forward; start it again. To undo
a change, revert it on `main` and promote again. A change made by hand with `./k` is put back within seconds. For an
emergency fix by hand, in Argo CD's screen first switch off automatic sync on `root`, then on the app itself: `root`
keeps the apps' own settings as they are in git, so with `root` still on, the app's sync is switched back on within
seconds and the fix is undone. Afterwards switch `root` back on; that also switches the app's sync back on, from git.

Whoever can merge into a branch can change that environment: its Argo CD applies whatever is there.

## The chat app

Open WebUI (a chat page, on `apps`) talking to Ollama (the model server, on `gpu`), with one Qwen model that stays
loaded on the GPU all the time: `qwen3.5:9b`, the default, which also runs the page's background jobs (titles, tags,
follow-up suggestions). The settings shared by both environments are in `apps/chat/values.yaml` (Open WebUI's
environment variables under `commonEnvVars`); each environment's own are in `apps/chat/env/<env>.yaml` (today only
`WEBUI_URL`). The page takes them from there on every start. Reach it through a port-forward, or publicly over HTTPS
(below).

```
./k main -n argocd get applications -w     # root, chat, chat-edge: wait for Synced and Healthy
./k main -n chat get pods -o wide -w       # watch the GPU node appear and the models download
./k main -n chat port-forward svc/chat-open-webui 8080:80
```

Then open http://localhost:8080. The first account created there becomes the admin; sign-up is off for everyone after
that. The first start downloads the model (6.6 GB) onto the Ollama disk, loads it into GPU memory, sends it a warm-up
question, and checks that it is 100% on the GPU (if not, the container restarts instead of running on the CPU). The
Ollama pod stays in `ContainerCreating` until all of that is done, a few minutes on the first start. Thinking is off
by default, so answers start right away.

Calling the model from code, two ways, both OpenAI-compatible:
- Through Open WebUI, with a key from Settings > Account > API keys (keys may call only `/api/models` and
  `/api/chat/completions`): `http://localhost:8080/api/chat/completions` with `Authorization: Bearer <key>`.
  Thinking is off by default here.
- Straight to Ollama, which has no authentication and is reachable only inside the cluster:
  `./k main -n chat port-forward svc/chat-ollama 11435:11434`, then `http://localhost:11435/v1/chat/completions`.
  Thinking is on by default here; send `"reasoning_effort": "none"` to turn it off.

Only Open WebUI may reach Ollama (a NetworkPolicy in `values.yaml`, installed with the chart). To see it work, call
Ollama from Open WebUI and from a throwaway pod; the first answers, the second times out:

```
./k main -n chat exec chat-open-webui-0 -c open-webui -- curl -s -m 5 http://chat-ollama:11434/api/version
./k main -n chat run probe --rm -i --restart=Never --image=curlimages/curl -- curl -s -m 5 http://chat-ollama:11434/api/version
```

To free one environment's GPU without removing anything, add this to `apps/chat/env/<env>.yaml` (the setting is
`ollama.replicaCount`; nested one level deeper, under `ollama.ollama`, it would be silently ignored), then merge it
through the usual pull requests:

```
ollama:
  replicaCount: 0
```

The autoscaler removes the empty GPU node about 10 minutes later. Taking the lines out again brings it back, and the
model is still on its disk. Scaling by hand with `./k` no longer works: Argo CD puts it back.

If no Spot L4 is available, the Ollama pod stays `Pending` and the autoscaler events say so
(`./k <env> -n chat describe pod -l app.kubernetes.io/name=ollama`). Set `spot = false` on `gpu_pool` in
`modules/platform/main.tf` (both environments) and apply.

## Public HTTPS

The page and its API, behind Cloud Armor (only `allowed_cidrs` in `envs/<env>/edge/terraform.tfvars` get through;
everyone else gets a 403 at Google's edge) and a Google-managed certificate. Sign-up is off. Ollama stays internal.

Two halves with different lifetimes, per environment:
- `envs/<env>/edge` (Terraform, kept between sessions): the fixed IP, the certificate and its DNS check, the
  certificate map, the Cloud Armor policy, all named `chat-lab` in the environment's project. Its `dns_records` output
  lists the two records in the liveinference.com zone in Route 53 (AWS profile `xinfer.ai`): an A record to the IP,
  and a CNAME Google uses to issue and renew the certificate.
- `apps/chat/edge/<env>` (Kubernetes, comes and goes with the cluster): a Kustomize overlay that adds the
  environment's hostname to the shared `apps/chat/edge/base` (the Gateway, which GKE turns into the load balancer, the
  routes, the load balancer's health check and the Cloud Armor attachment). Argo CD applies it as the app
  `chat-edge`. The load balancer takes about 5 to 10 minutes to start answering.

## End of a session

Delete the root app first: Argo CD then removes everything it made, the Gateway (and with it the load balancer), the
chat app and both its disks (the 40 GB model disk included). Then give GKE a few minutes to remove the load balancer;
a cluster destroyed while it still exists leaves it behind, still billing, and holding on to the IP and certificate
map. Deleting things one by one with `./k` does not work: Argo CD puts them back. `./tf <env> cluster destroy` runs
only from that environment's branch, clean and identical to GitHub.

```
./k main -n argocd delete application root      # waits until Argo CD has removed it all
gcloud --configuration=gke-lab-main compute forwarding-rules list   # wait until empty
./tf main cluster destroy
rm -r ~/projects/gke-lab/.kube/main             # the next cluster has a new address
gcloud --configuration=gke-lab-main compute disks list   # should be empty: no disks left behind
```

For production, the same with `production` and `--configuration=gke-lab`, from the `production` branch.

Each environment's `edge` stays: roughly $15 a month each at list prices (about $7 for an idle fixed IP, about $7 for
a Cloud Armor policy with two rules). To remove one as well: `./tf <env> edge destroy`, then delete its two records in
Route 53.
````

- [ ] **Step 4: Ignore list**

In `.gitignore`, add the line `.kube/` after `.kubeconfig` (the old file names stay listed, in case they are still on
disk).

- [ ] **Step 5: Status lines**

In `docs/superpowers/specs/2026-10-15-argocd-design.md`, add after its status line:
`Extended to two environments on 2026-10-15 by docs/superpowers/specs/2026-10-15-two-environments-design.md, whose
"What changes in the Argo CD design" replaces the single-environment details here.`

In `docs/superpowers/specs/2026-10-15-two-environments-design.md`, replace the first sentence of the status line
(`Status: design, for review. Nothing here is built yet.`) with
`Status: design approved by Sam Wen on 2026-10-15; the repository restructure is built and ./check passes offline;
GitHub rules, the main project and both environments are not set up yet. Build plan:
docs/superpowers/plans/2026-10-15-two-environments.md.`

- [ ] **Step 6: Progress note** in the session notes outside this repository, after the Session 3
  progress paragraph of 2026-10-15:

```
Progress, 2026-10-15 (later): Sam chose two long-lived branches, `main` (the checkpoint) and `production`, every change
going short-lived branch → `main` → `production`, with one GKE environment per branch: separate projects
(`samwen-gke-lab` = production, new `samwen-gke-lab-main`), main an exact copy including the GPU, main's entrance kept
standing (`chat-lab-main.liveinference.com`). For a fix that cannot wait while `main` is under test, an emergency
lane: a `hotfix/...` branch straight into `production`, merged into `main` afterwards; a required check blocks the
next promotion until it is. Design: `gke-lab/docs/superpowers/specs/2026-10-15-two-environments-design.md`;
build plan: `gke-lab/docs/superpowers/plans/2026-10-15-two-environments.md`. The repository restructure is built and
checked offline. Not yet: GitHub rules, the main project, either environment running, the first promotion.
```

- [ ] **Step 7: Run everything**

Run: `./check > "$TMPDIR/t8.txt" 2>&1; echo "exit $?"; grep -c '^PASS' "$TMPDIR/t8.txt"; grep -A8 '^FAIL' "$TMPDIR/t8.txt"; git status --short`
Expected: `exit 0`, no FAIL lines. `git status` lists only this plan's files (README, `.gitignore`, `check`, `tf`,
`k`, `h`, `bootstrap`, `lib/`, `modules/`, `envs/`, `apps/chat/`, `argocd/`, `.github/`, `test/`, `docs/`).

- [ ] **Step 8: Commit (standing go only)**

```bash
git add README.md .gitignore test/checks/70-readme.sh docs/superpowers/specs docs/superpowers/plans/2026-10-15-two-environments.md
git commit -m "README for two environments, and the designs' status lines

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Hand over the gates for GitHub, the main project and the first promotion

No code. Report to Sam, in this order, each step on his word. The checks named G1–G2, M1–M6 and P1–P6 are the
design's part 5 tables.

- [ ] **GATE 1: the restructure into `main`, then the GitHub rules.**

```bash
./check                                   # Expected: exit 0
git push -u origin two-environments
gh pr create --base main --head two-environments \
  --title "Two environments, main and production: per-environment Terraform, settings, entrance and Argo CD" \
  --body "Implements docs/superpowers/specs/2026-10-15-two-environments-design.md (plan: docs/superpowers/plans/2026-10-15-two-environments.md). ./check passes offline. Nothing here is applied: the main project, GitHub rules and both environments follow, each on Sam's word.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
# Sam merges (squash is fine into main). Then:
git switch main && git pull --ff-only
```

The two rulesets, created with `gh api -X POST repos/xinferai/gke-genai-serving/rulesets --input <file>`:

`main` (file `$TMPDIR/ruleset-main.json`):
```json
{
  "name": "main: changes only by pull request",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}},
  "bypass_actors": [],
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 0,
      "dismiss_stale_reviews_on_push": false,
      "require_code_owner_review": false,
      "require_last_push_approval": false,
      "required_review_thread_resolution": false,
      "allowed_merge_methods": ["squash", "merge"]}}
  ]
}
```

`production` (file `$TMPDIR/ruleset-production.json`):
```json
{
  "name": "production: only from main or a hotfix branch, by merge commit",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/production"], "exclude": []}},
  "bypass_actors": [],
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 0,
      "dismiss_stale_reviews_on_push": false,
      "require_code_owner_review": false,
      "require_last_push_approval": false,
      "required_review_thread_resolution": false,
      "allowed_merge_methods": ["merge"]}}
  ]
}
```
Expected: `gh api repos/xinferai/gke-genai-serving/rulesets --jq '.[].name'` lists both. If the API rejects
`allowed_merge_methods`, create the rule without it and set "Allow merge commits" only, per branch, in the ruleset's
web page; report that to Sam rather than skipping it. Then the GitHub checks G1–G2. Once Sam has merged the
restructure, `main` has the workflow, and `production`'s two checks are made required (on Sam's word): the workflow
runs on `pull_request_target`, so every pull request into `production` gets its checks from `main`'s copy (GitHub
takes it from the default branch since 2025-12-08).
```bash
id="$(gh api repos/xinferai/gke-genai-serving/rulesets --jq '.[] | select(.name | startswith("production")) | .id')"
gh api "repos/xinferai/gke-genai-serving/rulesets/$id" --jq '{name, target, enforcement, conditions, bypass_actors,
  rules: (.rules + [{"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false,
  "required_status_checks": [{"context": "source-allowed"}, {"context": "source-has-production"}]}}])}' \
  > "$TMPDIR/ruleset-production-checks.json"
gh api -X PUT "repos/xinferai/gke-genai-serving/rulesets/$id" --input "$TMPDIR/ruleset-production-checks.json" > /dev/null
gh api "repos/xinferai/gke-genai-serving/rulesets/$id" --jq '[.rules[].type]'   # Expected: includes "required_status_checks"
```

- [ ] **GATE 2: the main project, by hand once** (repeats Session 0 in `plan.md`; Sam's login first:
  `! gcloud --configuration=gke-lab auth login`).

```bash
gcloud projects describe samwen-gke-lab --configuration gke-lab --format='value(parent.type,parent.id)'   # the xinfer.ai organization's id
gcloud projects create samwen-gke-lab-main --name="GKE lab (main)" --organization=<that id> --configuration gke-lab
gcloud billing projects link samwen-gke-lab-main --billing-account=<billing-account-id> --configuration gke-lab
gcloud services list --enabled --project samwen-gke-lab --configuration gke-lab --format='value(config.name)' > "$TMPDIR/services.txt"
gcloud services enable $(cat "$TMPDIR/services.txt") --project samwen-gke-lab-main --configuration gke-lab
gcloud billing budgets create --billing-account=<billing-account-id> --display-name="GKE lab (main)" \
  --budget-amount=50USD --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0 \
  --filter-projects=projects/samwen-gke-lab-main --configuration gke-lab
gcloud storage buckets create gs://samwen-gke-lab-main-tfstate --project samwen-gke-lab-main --location us-central1 \
  --uniform-bucket-level-access --public-access-prevention --configuration gke-lab
gcloud storage buckets update gs://samwen-gke-lab-main-tfstate --versioning --configuration gke-lab
gcloud config configurations create gke-lab-main --no-activate
gcloud config set account ACCOUNT --configuration gke-lab-main
gcloud config set project samwen-gke-lab-main --configuration gke-lab-main
gcloud config set compute/region us-central1 --configuration gke-lab-main
gcloud config set compute/zone us-central1-a --configuration gke-lab-main
gcloud beta quotas preferences create --preference-id=gpus-all-regions-1 --quota-id=GPUS-ALL-REGIONS-per-project \
  --service=compute.googleapis.com --preferred-value=1 --email=ACCOUNT \
  --project=samwen-gke-lab-main --billing-project=samwen-gke-lab-main --configuration gke-lab-main
```
Expected: the project linked to "XInfer AI"; the same APIs on as production; the budget; a versioned private bucket;
the profile; a pending quota preference (check later with `gcloud beta quotas preferences describe
gpus-all-regions-1 --project=samwen-gke-lab-main --billing-project=samwen-gke-lab-main --configuration gke-lab-main`,
granted when `grantedValue` is 1). The quota id is the one Session 0 used; confirm it from that day's command if the
API rejects it. If the quota is refused, main runs without its GPU until granted, and Sam is told.

- [ ] **GATE 3: the main environment, from the `main` branch** (`git switch main && git pull --ff-only`).

```bash
./tf main edge init
./tf main edge plan -out=tfplan-edge && ./tf main edge apply tfplan-edge
./tf main edge output -json dns_records
# Two Route 53 records in the liveinference.com zone (AWS profile xinfer.ai), on Sam's word:
#   A     chat-lab-main.liveinference.com            -> the "a" value
#   CNAME the "certificate_check" name               -> the "certificate_check" value
gcloud --configuration=gke-lab-main certificate-manager certificates describe chat-lab --format='value(managed.state)'   # wait for ACTIVE (about 18 minutes)
./tf main cluster init
./tf main cluster plan -out=tfplan-cluster && ./tf main cluster apply tfplan-cluster
ssh-keygen -t ed25519 -N '' -C 'argocd-lab-main read-only deploy key' -f ~/.ssh/gke-genai-serving-argocd-main
gh repo deploy-key add ~/.ssh/gke-genai-serving-argocd-main.pub --repo xinferai/gke-genai-serving --title "argocd-lab-main (read-only)"
./bootstrap main
```
Then the main session's checks M1–M6, timings into `plan.md`.

- [ ] **GATE 4: the first promotion and production's entrance move.**

```bash
gh pr create --base production --head main --title "Promote main to production: two environments" \
  --body "First promotion through the new flow. Merge with a merge commit.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
# Sam merges with a merge commit (the only method offered: G2). Then:
git fetch origin && git switch production 2>/dev/null || git switch -c production --track origin/production
git pull --ff-only
git diff --stat 'origin/production^2' origin/production   # P1. Expected: prints nothing
gcloud storage cp gs://samwen-gke-lab-tfstate/envs/edge/default.tfstate \
  gs://samwen-gke-lab-tfstate/envs/production/edge/default.tfstate --configuration gke-lab
./tf production edge init
./tf production edge plan -out=tfplan-move
```
Expected: seven "has moved to module.edge…" lines and `0 to add, 0 to change, 0 to destroy`. Anything else: stop,
delete the copied object, and report. Then, on Sam's word:
```bash
./tf production edge apply tfplan-move      # records the moves; Expected: 0 added, 0 changed, 0 destroyed
./tf production edge plan                   # Expected: "No changes."
gcloud compute addresses describe chat-lab --global --configuration gke-lab --format='value(address)'   # Expected: 136.81.128.150
gcloud certificate-manager certificates describe chat-lab --configuration gke-lab --format='value(managed.state)'   # Expected: ACTIVE
```
Only after that, on Sam's word: `gcloud storage rm gs://samwen-gke-lab-tfstate/envs/edge/default.tfstate
gs://samwen-gke-lab-tfstate/envs/lab/default.tfstate --configuration gke-lab`.

P3 to P5, the checks on GitHub, on Sam's word. Three throwaway branches; all three pull requests are closed without
merging and their branches deleted. P3's branch changes `source-allowed` to accept any branch: the check must still
fail, because GitHub runs `main`'s copy (the default branch's), not the pull request's.
```bash
git switch -c scratch/check-test origin/main
sed -i '' 's/exit 1 ;;/exit 0 ;;/' .github/workflows/into-production.yml   # source-allowed now accepts anything
git commit -qam "Test: a pull request that rewrites its own check (never merged)"
git push -u origin scratch/check-test
git switch -c hotfix/check-test origin/production
git commit --allow-empty -m "Test the hotfix lane's checks from today's production (never merged)"
git push -u origin hotfix/check-test
git switch -c hotfix/stale-test 'origin/production^1'
git commit --allow-empty -m "Test the hotfix lane's checks from an older production (never merged)"
git push -u origin hotfix/stale-test
git switch production
for b in scratch/check-test hotfix/check-test hotfix/stale-test; do
  gh pr create --base production --head "$b" --title "Test only, do not merge: the production checks ($b)" \
    --body "Checks P3 to P5 of docs/superpowers/specs/2026-10-15-two-environments-design.md. Closed without merging.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
done
gh pr checks scratch/check-test --watch  # P3. Expected: source-allowed fail (main's copy ran); merge blocked
gh pr checks hotfix/check-test --watch   # P4. Expected: source-allowed pass, source-has-production pass
gh pr checks hotfix/stale-test --watch   # P5. Expected: source-allowed pass, source-has-production fail, listing
                                         #     the commits the first promotion brought in; merge blocked
gh pr close scratch/check-test --delete-branch
gh pr close hotfix/check-test --delete-branch
gh pr close hotfix/stale-test --delete-branch
```
Then P6, production's cluster, when wanted.
