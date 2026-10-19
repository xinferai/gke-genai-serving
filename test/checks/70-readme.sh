# shellcheck shell=bash
# Sourced by ./check, which defines check(), strict(), here, tmp, repo, schemas, envs and other().

# The documentation: README.md, the overview, and the documents under docs/ that hold the details.
docs=(README.md docs/*.md)

# --- The README and docs describe the two-environment way of working -------------------------------
docs_current() {
  local want stale
  for want in './tf main cluster plan' './bootstrap main' './k main get nodes' './check' 'delete application root' \
    'replicaCount: 0' 'ollama.replicaCount' "switch off automatic sync on \`root\`" 'never squash' \
    'apps/chat/env/<env>.yaml' '.kube/<env>/config' 'Each environment has' 'set `main` aside' \
    'always promotable' 'into-production.yml' 'source-allowed' 'source-has-production' 'main-deferred' \
    'git restore --source=origin/production --staged --worktree :/' \
    'git rev-list --reverse --topo-order --ancestry-path origin/main-deferred..origin/main | head -1' 'never force-push' \
    'git status --porcelain' 'git switch -c set-aside origin/main &&' '"Set aside, for an urgent fix"*)' \
    'git diff --stat origin/production origin/main' 'git diff --stat origin/main-deferred HEAD' \
    'apply the same Terraform roots again' \
    'production^2' '--first-parent' './startup main' './teardown main' './startup both' '.logs/' \
    '## Start of a session' '`chat-data`' 'prevent_destroy' 'Retain' '(10 GB)' 'on-demand, 0–3' 'still waiting' 'FailedScaleUp' 'gpu-ondemand' 'compute class `gpu-l4`' './hotfix' \
    'Before anything changes' 'lib/preflight.sh' 'gke-gcloud-auth-plugin'; do
    grep -qF -- "$want" "${docs[@]}" || { echo "neither the README nor docs/*.md mentions: $want"; return 1; }
  done
  stale="$(grep -nE 'source-is-main|production-only-from-main|TF_ENV|\.kubeconfig|h install chat|h uninstall chat|scale deploy/chat-ollama|apply -f .*edge\.yaml|\./(k|h) -n |\./(k|h|tf) (get|list|plan|apply|destroy|install|upgrade)( |$)|\./bootstrap *($|#)|hotfix/|hotfix branch|hotfix lane|both its disks|today only `WEBUI_URL`|should be empty: no disks' "${docs[@]}")"
  [ -z "$stale" ] || { echo "The documentation still says:"; echo "$stale"; return 1; }
}
check "README and docs describe the two-environment way of working" docs_current

# --- Every link between the documents leads to a file, and to a heading there when it names one -------
# GitHub's heading anchors: lower case, punctuation dropped, spaces as hyphens ("The model's GPU" is
# the-models-gpu).
anchors_of() { sed -n 's/^#\{1,6\} //p' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 _-]//g; s/ /-/g'; }
docs_links() {
  local doc link file anchor
  for doc in "${docs[@]}"; do
    while read -r link; do
      case "$link" in http://* | https://* | mailto:*) continue ;; esac
      file="${link%%#*}" anchor=""
      [ "$file" = "$link" ] || anchor="${link#*#}"
      [ -n "$file" ] && file="$(dirname "$doc")/$file" || file="$doc"
      [ -e "$file" ] || { echo "$doc: the link $link leads to no file"; return 1; }
      [ -z "$anchor" ] || anchors_of "$file" | grep -qxF -- "$anchor" ||
        { echo "$doc: the link $link names no heading in $file"; return 1; }
    done < <(grep -oE '\]\([^)]+\)' "$doc" | sed 's/^](//; s/)$//')
  done
}
check "Every link in the README and docs leads to a file, and to a heading there" docs_links

# --- The file map (docs/repository-map.md) names every file and folder, two levels down --------------
docs_map() {
  local map path top next
  map="$(awk '/^```/ { if (inmap) exit; next } $0 == "gke-genai-serving/" { inmap = 1 } inmap' docs/repository-map.md)"
  [ -n "$map" ] || { echo "docs/repository-map.md has no file map (a code block that starts gke-genai-serving/)"; return 1; }
  while read -r path; do
    top="${path%%/*}"
    grep -qE -- "── ${top//./\\.}(/| |$)" <<< "$map" || { echo "The file map does not name: $top"; return 1; }
    [ "$path" != "$top" ] || continue
    next="${path#*/}"
    grep -qE -- "── (${top//./\\.}/)?${next//./\\.}(/| |,|$)" <<< "$map" ||
      { echo "The file map does not name: $top/$next"; return 1; }
  done < <(git ls-files | cut -d/ -f1-2 | sort -u)
}
check "The file map (docs/repository-map.md) names every file and folder, two levels down" docs_map
