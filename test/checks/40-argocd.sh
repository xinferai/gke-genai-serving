# shellcheck shell=bash
# Sourced by ./check, which defines check(), strict(), here, tmp, repo, schemas, envs and other().

# --- Argo CD's own settings (argocd/values.yaml) ---------------------------------------------
render_argocd() {
  helm template argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.10.5 \
    -n argocd -f argocd/values.yaml > "$tmp/argocd.yaml"
}
workloads='select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "Job")'
argocd_on_system_pool() {
  local off
  [ -s "$tmp/argocd.yaml" ] || { echo "nothing rendered"; return 1; }
  off="$(yq e "$workloads | select(.spec.template.spec.nodeSelector.pool != \"system\") | .metadata.name" "$tmp/argocd.yaml")" || return 1
  [ -z "$off" ] || { echo "not on the system pool: $off"; return 1; }
}
argocd_unused_parts_off() {
  local names found
  [ -s "$tmp/argocd.yaml" ] || { echo "nothing rendered"; return 1; }
  names="$(yq e "$workloads | .metadata.name" "$tmp/argocd.yaml")" || return 1
  found="$(grep -E 'dex|notifications' <<< "$names")"
  [ -z "$found" ] || { echo "still installed: $found"; return 1; }
}
argocd_requests_set() {
  local missing
  [ -s "$tmp/argocd.yaml" ] || { echo "nothing rendered"; return 1; }
  missing="$(yq e 'select(.kind == "Deployment" or .kind == "StatefulSet") | select(.spec.template.spec.containers[0].resources.requests.cpu == null) | .metadata.name' "$tmp/argocd.yaml")" || return 1
  [ -z "$missing" ] || { echo "no resource requests: $missing"; return 1; }
}
check "Argo CD chart renders with argocd/values.yaml" render_argocd
check "Argo CD runs only on the system pool" argocd_on_system_pool
check "Argo CD: single sign-on and notifications not installed" argocd_unused_parts_off
check "Argo CD: every component has resource requests" argocd_requests_set
check "Argo CD screen is plain HTTP behind the port-forward" \
  yq e -e 'select(.kind == "ConfigMap" and .metadata.name == "argocd-cmd-params-cm") | .data["server.insecure"] == "true"' "$tmp/argocd.yaml"

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
