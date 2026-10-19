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
    PersistentVolume/chat-data PersistentVolumeClaim/chat-data PersistentVolumeClaim/chat-ollama; do
    grep -qx "$want" <<< "$have" || { echo "missing $want"; return 1; }
  done
}
# --- The chat data (accounts, chats, API keys) on the kept disk chat-data (modules/edge) ----------
# holds <env> <kind> <name> <yq condition>: that rendered object meets the condition; if not, shows it.
# In yq, | binds tighter than and: "a | b and c" reads c from the top of the object, so bracket it.
holds() {
  local o
  o="$(yq e "select(.kind == \"$2\" and .metadata.name == \"$3\")" "$tmp/chat-$1.yaml")"
  [ -n "$o" ] || { echo "no $2/$3 rendered"; return 1; }
  yq e -e "$4" <<< "$o" > /dev/null || { echo "$2/$3 does not meet: $4"; echo "$o"; return 1; }
}
tfvar() { sed -n "s/^$2 *= *\"\(.*\)\"\$/\1/p" "$1"; } # tfvar <terraform.tfvars> <name>: a quoted value
data_mounted() { # Open WebUI's data folder is on the claim chat-data
  holds "$1" StatefulSet chat-open-webui \
    '.spec.template.spec.volumes[] | select(.name == "data") | .persistentVolumeClaim.claimName == "chat-data"'
}
# The claim takes only the volume chat-data: with a storage class, the cluster would make a new, empty
# disk for it instead. And the chart makes no claim (and so no disk) of its own for Open WebUI.
claim_takes_kept_volume() {
  holds "$1" PersistentVolumeClaim chat-data \
    '.spec.volumeName == "chat-data" and .spec.storageClassName == "" and .metadata.namespace == "chat"' || return 1
  [ -z "$(yq e 'select(.kind == "PersistentVolumeClaim" and .metadata.name == "chat-open-webui")' "$tmp/chat-$1.yaml")" ] ||
    { echo "the chart still makes its own claim chat-open-webui"; return 1; }
}
volume_is_kept_disk() { # the volume is the disk chat-data, in envs/<env>/edge's project and zone
  local f="envs/$1/edge/terraform.tfvars"
  holds "$1" PersistentVolume chat-data ".spec.csi.driver == \"pd.csi.storage.gke.io\" and
    .spec.csi.volumeHandle == \"projects/$(tfvar "$f" project_id)/zones/$(tfvar "$f" zone)/disks/chat-data\""
}
volume_in_disk_zone() { # pods using it go only to nodes in the disk's zone
  holds "$1" PersistentVolume chat-data ".spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0] |
    (.key == \"topology.kubernetes.io/zone\" and .operator == \"In\" and (.values | length) == 1 and
    .values[0] == \"$(tfvar "envs/$1/edge/terraform.tfvars" zone)\")"
}
volume_retained() { # deleting the volume (at teardown) leaves the disk
  holds "$1" PersistentVolume chat-data '.spec.persistentVolumeReclaimPolicy == "Retain" and .spec.storageClassName == ""'
}
# disk_gb: the size of the disk chat-data in modules/edge, in GB (Google's GB are GiB).
disk_gb() { awk '/^resource "google_compute_disk" "chat_data"/ {on = 1} on && $1 == "size" {print $3; exit}' modules/edge/main.tf; }
data_size_is_disk() { # the volume and its claim are the disk's size
  local gb
  gb="$(disk_gb)"
  [ -n "$gb" ] || { echo "no size for chat_data in modules/edge/main.tf"; return 1; }
  holds "$1" PersistentVolume chat-data ".spec.capacity.storage == \"${gb}Gi\"" &&
    holds "$1" PersistentVolumeClaim chat-data ".spec.resources.requests.storage == \"${gb}Gi\""
}
data_schemas() { # the volume and its claim match the Kubernetes schemas (a misspelt field is an error)
  yq e 'select(.metadata.name == "chat-data")' "$tmp/chat-$1.yaml" > "$tmp/chat-$1-data.yaml" || return 1
  [ "$(grep -c '^kind:' "$tmp/chat-$1-data.yaml")" -eq 2 ] || { echo "want the volume and its claim:"; cat "$tmp/chat-$1-data.yaml"; return 1; }
  strict "$tmp/chat-$1-data.yaml"
}
# --- Ollama's GPU: Spot first, on-demand when Google has none (the compute class gpu-l4) ---------------
# pool_name <module>: the node pool's name in modules/platform.
pool_name() {
  awk -v m="$1" '$0 ~ "^module \"" m "\"" {on = 1} on && $1 == "name" {gsub(/"/, "", $3); print $3; exit}' modules/platform/main.tf
}
ollama_on_class() { # Ollama asks for the class and pins no pool of its own: a pool pin would stop the fallback
  holds "$1" Deployment chat-ollama '(.spec.template.spec.nodeSelector | to_json(0)) == "{\"cloud.google.com/compute-class\":\"gpu-l4\"}"'
}
class_order() { # gpu-l4 tries the Spot pool, then the on-demand one, by the names Terraform gives them
  local spot od
  spot="$(pool_name gpu_pool)"
  od="$(pool_name gpu_ondemand_pool)"
  [ -n "$spot" ] && [ -n "$od" ] || { echo "no pool names for gpu_pool and gpu_ondemand_pool in modules/platform"; return 1; }
  holds "$1" ComputeClass gpu-l4 "(.spec.priorities | to_json(0)) == \"[{\\\"nodepools\\\":[\\\"$spot\\\"]},{\\\"nodepools\\\":[\\\"$od\\\"]}]\""
}
# No pools of GKE's own; no move back to Spot mid-session (GKE would start the Spot node before stopping
# the on-demand one, two GPUs, and each project may hold one); and no other machine when neither pool can.
class_settings() {
  holds "$1" ComputeClass gpu-l4 '.spec.nodePoolAutoCreation.enabled == false and
    .spec.activeMigration.optimizeRulePriority == false and .spec.whenUnsatisfiable == "DoNotScaleUp"'
}
class_schema() { # the class matches GKE's schema (a misspelt field is an error)
  yq e 'select(.kind == "ComputeClass")' "$tmp/chat-$1.yaml" > "$tmp/chat-$1-class.yaml" || return 1
  [ "$(grep -c '^kind:' "$tmp/chat-$1-class.yaml")" -eq 1 ] || { echo "want one ComputeClass"; return 1; }
  strict "$tmp/chat-$1-class.yaml"
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
  check "chat ($env): Open WebUI keeps its data on the claim chat-data" data_mounted "$env"
  check "chat ($env): the claim takes only the volume chat-data, never a new disk" claim_takes_kept_volume "$env"
  check "chat ($env): the volume is the disk chat-data in envs/$env/edge's project and zone" volume_is_kept_disk "$env"
  check "chat ($env): the volume is used only in the disk's zone" volume_in_disk_zone "$env"
  check "chat ($env): deleting the volume leaves the disk (Retain)" volume_retained "$env"
  check "chat ($env): the volume and its claim match their schemas" data_schemas "$env"
  check "chat ($env): the volume and its claim are the size of the disk in modules/edge" data_size_is_disk "$env"
  check "chat ($env): Ollama asks for the compute class gpu-l4, and no pool of its own" ollama_on_class "$env"
  check "chat ($env): gpu-l4 tries the Spot pool gpu, then gpu-ondemand" class_order "$env"
  check "chat ($env): gpu-l4 makes no pools, never moves back mid-session, and waits rather than take another machine" class_settings "$env"
  check "chat ($env): gpu-l4 matches GKE's schema" class_schema "$env"
done
check "chat (main) page address is https://chat-lab-main.liveinference.com" webui_url_is main https://chat-lab-main.liveinference.com
check "chat (production) page address is https://chat-lab.liveinference.com" webui_url_is production https://chat-lab.liveinference.com
check "chat (production) keeps every setting it had (test/expected/chat-production-env.txt)" production_unchanged
check "chat (main): Open WebUI's settings differ from production's only in its page address" main_differs_only_in_address
