# shellcheck shell=bash
# Sourced by lib/session.sh. Before ./startup or ./teardown clones or changes anything, it checks what
# they need from outside this repository, and lists the commands that put right whatever is missing:
# - each environment's gcloud profile names an account and the environment's project, and gets a fresh
#   token without asking for anything (a run must not stop halfway for a password);
# - kubectl's GKE sign-in plugin, through which kubectl reaches the cluster;
# - this Mac's public address is in access.tfvars, or kubectl times out and the page answers 403;
# - for ./startup, each environment's Argo CD deploy key is on this Mac and GitHub accepts it for this
#   repository (./bootstrap needs it, about 12 minutes in).
# GKE_AUTH_PLUGIN can name a stand-in for the plugin; test/startup_teardown_test.sh uses that.

# fail <what is wrong> <fix>...: one condition not met. Each fix is a command, or a "# " line saying
# what to do by hand; the same fix is listed once, however many conditions need it.
fail() {
  local fix have
  checked+=("  NO  $1")
  shift
  for fix in "$@"; do
    for have in ${fixes[@]+"${fixes[@]}"}; do [ "$have" != "$fix" ] || continue 2; done
    fixes+=("$fix")
  done
}
pass() { checked+=("  ok  $1"); }
# reason <output>: a tool's error in one line, for a NO line: gcloud's ERROR line without its prefix,
# or else the last line that is not empty.
reason() {
  local line
  line="$(sed -n 's/^ERROR: ([^)]*) //p' <<< "$1" | head -1)"
  [ -n "$line" ] || line="$(sed '/^[[:space:]]*$/d' <<< "$1" | tail -1)"
  cut -c1-160 <<< "$line"
}

# profile_ready <env>: the environment's gcloud profile names an account (whichever it is: the one it
# names is the one checked), points at the environment's project (envs/<env>/cluster/terraform.tfvars),
# and gets a fresh token with no prompt, as ./tf asks for one.
profile_ready() {
  local env="$1" profile account project want out
  profile="$(use_env "$env" && echo "$CLOUDSDK_ACTIVE_CONFIG_NAME")"
  want="$(sed -n 's/^project_id *= *"\(.*\)"$/\1/p' "$here/envs/$env/cluster/terraform.tfvars")"
  if ! account="$(CLOUDSDK_ACTIVE_CONFIG_NAME="$profile" gcloud config configurations describe "$profile" \
    --format='value(properties.core.account)' 2> /dev/null < /dev/null)"; then
    fail "gcloud has no profile $profile ($env's)" \
      "gcloud config configurations create $profile --no-activate" \
      "# Put your Google account in place of ACCOUNT:" \
      "gcloud config set account ACCOUNT --configuration=$profile" \
      "gcloud config set project $want --configuration=$profile" \
      "gcloud auth login ACCOUNT --no-activate"
    return
  fi
  if [ -z "$account" ]; then
    fail "gcloud profile $profile names no account" \
      "# Put your Google account in place of ACCOUNT:" \
      "gcloud config set account ACCOUNT --configuration=$profile" \
      "gcloud auth login ACCOUNT --no-activate"
    return
  fi
  project="$(CLOUDSDK_ACTIVE_CONFIG_NAME="$profile" gcloud config configurations describe "$profile" \
    --format='value(properties.core.project)' 2> /dev/null < /dev/null)"
  if [ "$project" != "$want" ]; then
    fail "gcloud profile $profile points at project '${project:-none}', not $want" \
      "gcloud config set project $want --configuration=$profile"
  fi
  if out="$(CLOUDSDK_ACTIVE_CONFIG_NAME="$profile" CLOUDSDK_CORE_DISABLE_PROMPTS=1 \
    gcloud config config-helper --force-auth-refresh --format='value(credential.access_token)' 2>&1 < /dev/null)"; then
    pass "gcloud profile $profile: $account, signed in"
  else
    fail "gcloud profile $profile: $account must sign in again (gcloud: $(reason "$out"))" \
      "gcloud auth login $account --no-activate"
  fi
}

plugin_ready() {
  if command -v "${GKE_AUTH_PLUGIN:-gke-gcloud-auth-plugin}" > /dev/null; then
    pass "kubectl's GKE sign-in plugin (gke-gcloud-auth-plugin)"
  else
    fail "kubectl's GKE sign-in plugin (gke-gcloud-auth-plugin) is not installed" \
      "gcloud components install gke-gcloud-auth-plugin"
  fi
}

# ip_number <a.b.c.d>: the address as one number. in_cidr <ip> <a.b.c.d/n>: the address is in the range.
ip_number() {
  local IFS=. a b c d
  read -r a b c d <<< "$1"
  echo $(((a << 24) + (b << 16) + (c << 8) + d))
}
in_cidr() {
  local mask
  [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || return 1
  mask=$(((0xFFFFFFFF << (32 - ${2#*/})) & 0xFFFFFFFF))
  [ $(($(ip_number "$1") & mask)) -eq $(($(ip_number "${2%/*}") & mask)) ]
}
# in_any_cidr <ip> <list>: the address is in one of the ranges in the list (["a/n", "b/n"]).
in_any_cidr() {
  local cidr
  for cidr in $(grep -oE '[0-9.]+/[0-9]+' <<< "$2"); do in_cidr "$1" "$cidr" && return 0; done
  return 1
}

# address_ready <command> <envs...>: this Mac's public address is admin_cidr in access.tfvars (who may
# reach the control plane) and in its allowed_cidrs (who Cloud Armor lets in). If not, the fix is the
# file, then the Terraform that holds the old address: for ./startup the entrance (the new cluster takes
# the file as it is), for ./teardown the cluster.
address_ready() {
  local cmd="$1" ip admin allowed env layer
  shift
  ip="$(curl -s --max-time 10 https://checkip.amazonaws.com < /dev/null | tr -d '[:space:]')"
  if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "this Mac's public address is unknown: https://checkip.amazonaws.com did not answer" \
      "# Check the network, then run it again."
    return
  fi
  admin="$(sed -n 's/^admin_cidr *= *"\([^"]*\)" *$/\1/p' "$here/access.tfvars")"
  allowed="$(sed -n 's/^allowed_cidrs *= *\(\[.*\]\) *$/\1/p' "$here/access.tfvars")"
  if in_cidr "$ip" "$admin" && in_any_cidr "$ip" "$allowed"; then
    pass "your public address, $ip, is in access.tfvars"
    return
  fi
  layer=edge
  [ "$cmd" = startup ] || layer=cluster
  local fixes_for=("# In access.tfvars: admin_cidr = \"$ip/32\", and \"$ip/32\" in allowed_cidrs. Then:")
  for env in "$@"; do
    fixes_for+=("git switch $env && git pull --ff-only" "./tf $env $layer plan -out=tfplan-access"
      "./tf $env $layer apply tfplan-access")
  done
  fail "your public address, $ip, is not in access.tfvars (admin_cidr ${admin:-none}, allowed_cidrs ${allowed:-none})" \
    "${fixes_for[@]}"
}

# key_ready <env>: Argo CD's deploy key for the environment is on this Mac, and GitHub accepts it for
# this repository (to a deploy key, GitHub's ssh answers "Hi <repository>!").
key_ready() {
  local env="$1" key reply add
  key="${ARGOCD_DEPLOY_KEY:-$HOME/.ssh/gke-genai-serving-argocd-$env}"
  add="gh repo deploy-key add $key.pub --repo $lab_repo --title \"argocd-lab-$env (read-only)\""
  if [ ! -s "$key" ]; then
    fail "Argo CD's deploy key for $env is not on this Mac ($key)" \
      "ssh-keygen -t ed25519 -N '' -C 'argocd-lab-$env read-only deploy key' -f $key" \
      "# Add the public half of $env's key to GitHub, read-only, signed in to gh as the repository's owner:" "$add"
    return
  fi
  reply="$(ssh -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 < /dev/null)"
  case "$reply" in
    *"Hi $lab_repo!"*) pass "Argo CD's deploy key for $env: GitHub accepts it for $lab_repo" ;;
    *)
      fail "GitHub does not accept Argo CD's deploy key for $env for $lab_repo (ssh: $(reason "$reply"))" \
        "# Add the public half of $env's key to GitHub, read-only, signed in to gh as the repository's owner:" "$add"
      ;;
  esac
}

# preflight <command> <envs...>: every check, then the list; status 1 if anything is missing.
preflight() {
  local cmd="$1" env line again="$2"
  shift
  [ "$#" -eq 1 ] || again=both
  checked=()
  fixes=()
  for env in "$@"; do profile_ready "$env"; done
  plugin_ready
  address_ready "$cmd" "$@"
  if [ "$cmd" = startup ]; then
    for env in "$@"; do key_ready "$env"; done
  fi
  echo "Before anything changes:"
  printf '%s\n' "${checked[@]}"
  [ "${#fixes[@]}" -gt 0 ] || return 0
  echo
  echo "Not ready, and nothing was changed. Run these, then ./$cmd $again again:"
  for line in "${fixes[@]}"; do echo "  $line"; done
  return 1
}
