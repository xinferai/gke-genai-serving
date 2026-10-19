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
