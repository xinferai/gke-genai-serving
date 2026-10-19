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
