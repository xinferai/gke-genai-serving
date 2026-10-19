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
  [ -f "envs/main/$1/versions.tf" ] && [ -f "envs/production/$1/versions.tf" ] || { echo "a versions.tf is missing"; return 1; }
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

# --- Who may connect stays off GitHub: access.tfvars, ignored by git, read by ./tf ------------------
# terraform.tfvars would override the TF_VAR_ values ./tf passes, so no root may set them there.
no_access_in_tfvars() {
  ! grep -nE '^[[:space:]]*(admin_cidr|allowed_cidrs)[[:space:]]*=' envs/*/*/terraform.tfvars
}
# The example has both lines in the shape ./tf reads, with an address from a documentation-only range.
access_example_reads() {
  grep -qE '^admin_cidr *= *"203\.0\.113\.[0-9]+/32" *$' access.tfvars.example &&
    grep -qE '^allowed_cidrs *= *\["203\.0\.113\.[0-9]+/32"\] *$' access.tfvars.example
}
check "access.tfvars is never committed" git check-ignore -q access.tfvars
check "no terraform.tfvars sets admin_cidr or allowed_cidrs (they come from access.tfvars)" no_access_in_tfvars
check "access.tfvars.example has both lines, with a documentation-only address" access_example_reads
# A real address must not reach GitHub again: a /32 anywhere in git is from the documentation-only ranges
# (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) or it fails here.
no_real_address() {
  ! git grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}/32' | grep -vE '(192\.0\.2|198\.51\.100|203\.0\.113)\.[0-9]+/32'
}
check "no real /32 address is committed (only documentation-only ones)" no_real_address
# No email address reaches GitHub either. Allowed: GitHub's ssh user (git@github.com), the commit
# trailer's noreply@anthropic.com, and the tests' made-up ones at example.invalid. Each address is
# judged on its own, so an allowed one cannot hide another on the same line.
no_email_address() {
  ! git grep -noE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' |
    grep -vE ':(git@github\.com|noreply@anthropic\.com|[^:@]+@example\.invalid)$'
}
check "no email address is committed (only git@github.com, the commit trailer's, made-up ones)" no_email_address
check "production's entrance moves every resource it had into module.edge" moves_complete

# --- The chat data disk (modules/edge): kept between sessions, with the entrance ------------------
# A zonal disk attaches only to nodes in its own zone, so the entrance's zone must be the cluster's.
zone_of() { sed -n 's/^zone *= *"\(.*\)"$/\1/p' "$1"; } # zone_of <terraform.tfvars>
same_zone() { # same_zone <env>
  local edge cluster
  edge="$(zone_of "envs/$1/edge/terraform.tfvars")"
  cluster="$(zone_of "envs/$1/cluster/terraform.tfvars")"
  [ -n "$edge" ] && [ "$edge" = "$cluster" ] || { echo "entrance zone '$edge', cluster zone '$cluster'"; return 1; }
}
# The disk is named chat-data (the chat app's PersistentVolume refers to it by that name), and has
# prevent_destroy: a plan that would delete or replace it fails instead.
data_disk_kept() {
  awk '/^resource "google_compute_disk" "chat_data"/ {on = 1} on {print} on && /^}/ {exit}' modules/edge/main.tf > "$tmp/disk.tf"
  [ -s "$tmp/disk.tf" ] || { echo "modules/edge declares no google_compute_disk.chat_data"; return 1; }
  grep -qE '^[[:space:]]*name[[:space:]]*=[[:space:]]*"chat-data"' "$tmp/disk.tf" || { echo "not named chat-data"; return 1; }
  grep -qE '^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true' "$tmp/disk.tf" || { echo "no prevent_destroy = true"; return 1; }
}
# pd-balanced takes 10 GB at least (validDiskSize 10GB-65536GB, gcloud compute disk-types describe
# pd-balanced, 2026-10-16); a smaller size fails only at apply.
data_disk_size_valid() {
  local size
  [ -s "$tmp/disk.tf" ] || { echo "no disk block read"; return 1; }
  grep -qE '^[[:space:]]*type[[:space:]]*=[[:space:]]*"pd-balanced"' "$tmp/disk.tf" || { echo "not pd-balanced"; return 1; }
  size="$(sed -n 's/^[[:space:]]*size[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$tmp/disk.tf")"
  [ "${size:-0}" -ge 10 ] || { echo "size ${size:-not set} GB; pd-balanced takes 10 GB at least"; return 1; }
}
for env in "${envs[@]}"; do
  check "$env's chat data disk is in the zone of $env's cluster" same_zone "$env"
done
check "the chat data disk is named chat-data, and no plan can delete it (prevent_destroy)" data_disk_kept
check "the chat data disk is pd-balanced and at least 10 GB, the smallest Google makes" data_disk_size_valid

# --- The apps pool, where the chat page runs (modules/platform) ------------------------------------
# On Spot, Google takes the machine back at any time, and a zone with no Spot e2-standard-2 left keeps
# the page down until one comes back (2026-10-16, 13:22: ZONE_RESOURCE_POOL_EXHAUSTED). On-demand
# machines are not taken back.
apps_pool_on_demand() {
  awk '/^module "apps_pool"/ {on = 1} on {print} on && /^}/ {exit}' modules/platform/main.tf > "$tmp/apps-pool.tf"
  [ -s "$tmp/apps-pool.tf" ] || { echo "modules/platform declares no module apps_pool"; return 1; }
  grep -qE '^[[:space:]]*spot[[:space:]]*=[[:space:]]*false' "$tmp/apps-pool.tf" || { echo "the apps pool is not spot = false"; return 1; }
}
check "the apps pool, where the chat page runs, is on-demand: Google does not take its machines back" apps_pool_on_demand

# --- The GPU pools (modules/platform): Spot first, on-demand when Google has no Spot L4 ---------------
# The compute class gpu-l4 (apps/chat/values.yaml) tries the pool gpu (Spot) first, then gpu-ondemand
# (2026-10-16: no Spot L4 in the zone, ZONE_RESOURCE_POOL_EXHAUSTED, and the model never started). A pool
# takes part only with the class's label and taint, and only these two may carry them: a pod that asks
# for no class could not run anywhere if every pool did.
pool_block() { awk -v m="$1" '$0 ~ "^module \"" m "\"" {on = 1} on {print} on && /^}/ {exit}' modules/platform/main.tf; }
in_class() { # in_class <block>: the label and the taint of the compute class gpu-l4
  grep -qE '"cloud\.google\.com/compute-class"[[:space:]]*=[[:space:]]*"gpu-l4"' <<< "$1" &&
    grep -qE 'key[[:space:]]*=[[:space:]]*"cloud\.google\.com/compute-class",[[:space:]]*value[[:space:]]*=[[:space:]]*"gpu-l4",[[:space:]]*effect[[:space:]]*=[[:space:]]*"NO_SCHEDULE"' <<< "$1"
}
same_machine() { grep -E '^[[:space:]]*(cluster_id|location|machine_type|min_nodes|max_nodes|service_account|disk_size_gb|gpu)[[:space:]]*=' <<< "$1" | tr -s ' '; }
gpu_pools_fall_back() {
  local spot od
  spot="$(pool_block gpu_pool)"
  od="$(pool_block gpu_ondemand_pool)"
  [ -n "$spot" ] && [ -n "$od" ] || { echo "want module gpu_pool and module gpu_ondemand_pool"; return 1; }
  grep -qE '^[[:space:]]*name[[:space:]]*=[[:space:]]*"gpu"$' <<< "$spot" && grep -qE '^[[:space:]]*spot[[:space:]]*=[[:space:]]*true$' <<< "$spot" ||
    { echo "gpu_pool: want name \"gpu\", spot = true"; return 1; }
  grep -qE '^[[:space:]]*name[[:space:]]*=[[:space:]]*"gpu-ondemand"$' <<< "$od" && grep -qE '^[[:space:]]*spot[[:space:]]*=[[:space:]]*false$' <<< "$od" ||
    { echo "gpu_ondemand_pool: want name \"gpu-ondemand\", spot = false"; return 1; }
  in_class "$spot" || { echo "gpu_pool lacks the label or taint of the compute class gpu-l4"; return 1; }
  in_class "$od" || { echo "gpu_ondemand_pool lacks the label or taint of the compute class gpu-l4"; return 1; }
  diff <(same_machine "$spot") <(same_machine "$od") || { echo "the two GPU pools differ in more than name and Spot"; return 1; }
  [ "$(grep -c '"cloud\.google\.com/compute-class"[[:space:]]*=' modules/platform/main.tf)" -eq 2 ] ||
    { echo "only the two GPU pools may carry the compute class's label"; return 1; }
}
check "GPU pools: gpu (Spot) and gpu-ondemand, the same machine, both and only they in the compute class gpu-l4" gpu_pools_fall_back
