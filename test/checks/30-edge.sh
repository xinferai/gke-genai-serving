# shellcheck shell=bash
# Sourced by ./check, which defines check(), strict(), here, tmp, repo, schemas, envs and other().

# --- The public entrance per environment (apps/chat/edge/<env>) -----------------------------------
build_edge() { kubectl kustomize "apps/chat/edge/$1" > "$tmp/edge-$1.yaml"; } # build_edge <env>
edge_hostname_is() { # edge_hostname_is <env> <hostname>: both routes carry exactly this one hostname
  local got
  [ -s "$tmp/edge-$1.yaml" ] || { echo "nothing built"; return 1; }
  got="$(yq e -N 'select(.kind == "HTTPRoute") | .metadata.name + " " + (.spec.hostnames | join(","))' "$tmp/edge-$1.yaml" | sort)" || return 1
  [ "$got" = "chat $2"$'\n'"chat-redirect $2" ] || { echo "got:"; echo "$got"; return 1; }
}
edge_schemas() { # edge_schemas <env>: what was built matches the schemas (an empty build is a failure)
  [ -s "$tmp/edge-$1.yaml" ] || { echo "nothing built"; return 1; }
  strict "$tmp/edge-$1.yaml"
}
edges_differ_only_in_hostname() {
  [ -s "$tmp/edge-main.yaml" ] && [ -s "$tmp/edge-production.yaml" ] || { echo "nothing built"; return 1; }
  diff <(yq e 'del(.spec.hostnames)' "$tmp/edge-main.yaml") <(yq e 'del(.spec.hostnames)' "$tmp/edge-production.yaml")
}

for env in "${envs[@]}"; do
  check "entrance ($env) builds" build_edge "$env"
  check "entrance ($env) matches its schemas" edge_schemas "$env"
done
check "entrance (main) answers only to chat-lab-main.liveinference.com" edge_hostname_is main chat-lab-main.liveinference.com
check "entrance (production) answers only to chat-lab.liveinference.com" edge_hostname_is production chat-lab.liveinference.com
check "the two entrances differ only in their hostname" edges_differ_only_in_hostname
