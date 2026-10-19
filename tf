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
# A saved plan holds the configuration it was made from, not what is on disk when it is applied, so
# plan -out=<file> also writes <file>.commit (the commit it was made from, only when nothing was
# uncommitted), and apply <file> runs only when that is the commit checked out now. Changing
# commands also refuse -var and -var-file: their values would not be on the branch. The one value
# kept off the branch is who may connect: access.tfvars, ignored by git (below).
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

root="$here/envs/$lab_env/$layer"
# in_root <path>: a path as Terraform sees it, relative to the layer's folder (it runs with -chdir).
in_root() { case "$1" in /*) echo "$1" ;; *) echo "$root/$1" ;; esac; }
# plan_out <arguments...>: the file a plan is saved to (-out=<file> or -out <file>), if any.
plan_out() {
  local a next=""
  for a in "$@"; do
    [ -n "$next" ] && { echo "$a"; return; }
    case "$a" in
      -out=* | --out=*) echo "${a#*=}"; return ;;
      -out | --out) next=1 ;;
    esac
  done
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
  for a in "${@:2}"; do
    case "$a" in
      -var | -var=* | --var | --var=* | -var-file | -var-file=* | --var-file | --var-file=*)
        echo "Refused: '$a' brings in values that are not on the $lab_env branch; put them in terraform.tfvars." >&2
        exit 3
        ;;
      -*) ;;
      *)
        if [ "$1" = apply ] && [ -f "$(in_root "$a")" ] &&
          [ "$(cat "$(in_root "$a").commit" 2> /dev/null)" != "$(git -C "$here" rev-parse HEAD)" ]; then
          echo "Refused: the saved plan '$a' was not made from this commit with nothing uncommitted;" \
            "make it again here: ./tf $lab_env $layer plan -out=$a" >&2
          exit 3
        fi
        ;;
    esac
  done
fi

# Who may connect stays off GitHub: access.tfvars (copy access.tfvars.example) holds admin_cidr (the
# control plane) and allowed_cidrs (Cloud Armor). They reach Terraform as TF_VAR_ environment variables,
# so each layer takes the one it declares, and terraform.tfvars, which would override them, sets neither.
# ./startup and ./teardown copy the file into their fresh copy of GitHub's branch.
case "${1:-}" in
  plan | apply | destroy | import | refresh | console)
    access="$here/access.tfvars"
    if [ ! -s "$access" ]; then
      echo "Refused: no access.tfvars. Copy access.tfvars.example to access.tfvars and put your public address in it." >&2
      exit 3
    fi
    TF_VAR_admin_cidr="$(sed -n 's/^admin_cidr *= *"\([^"]*\)" *$/\1/p' "$access")"
    TF_VAR_allowed_cidrs="$(sed -n 's/^allowed_cidrs *= *\(\[.*\]\) *$/\1/p' "$access")"
    if [ -z "$TF_VAR_admin_cidr" ] || [ -z "$TF_VAR_allowed_cidrs" ] ||
      [[ "$TF_VAR_admin_cidr$TF_VAR_allowed_cidrs" == *$'\n'* ]]; then
      echo "Refused: access.tfvars needs admin_cidr and allowed_cidrs, one line each, as in access.tfvars.example." >&2
      exit 3
    fi
    export TF_VAR_admin_cidr TF_VAR_allowed_cidrs
    ;;
esac

# A freshly refreshed token, good for a full hour. print-access-token can hand back a cached
# token close to expiry, and on 2026-10-14 one ran out partway through a destroy.
GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud config config-helper --force-auth-refresh --format='value(credential.access_token)')"
export GOOGLE_OAUTH_ACCESS_TOKEN

out=""
[ "${1:-}" = plan ] && out="$(plan_out "$@")"
if [ -z "$out" ]; then
  exec terraform -chdir="$root" "$@"
fi
# A saved plan: stamp it with this commit, so apply can tell where it came from.
stamp="$(in_root "$out").commit"
rm -f "$stamp"
status=0
terraform -chdir="$root" "$@" || status=$?
if [ "$status" -eq 0 ] || [ "$status" -eq 2 ]; then # 2: -detailed-exitcode's "there are changes"
  if [ -z "$(git -C "$here" status --porcelain)" ]; then
    git -C "$here" rev-parse HEAD > "$stamp"
  else
    echo "Note: there are uncommitted changes, so this saved plan cannot be applied; commit, then plan again." >&2
  fi
fi
exit "$status"
