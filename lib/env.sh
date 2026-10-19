# shellcheck shell=bash
# Shared by ./tf, ./k, ./h and ./bootstrap. The environment is always the first word and there is no
# default, so nothing reaches production unless "production" is typed. The caller sets $here first.

# This repository on GitHub, which Argo CD reads with a deploy key (./bootstrap).
lab_repo=xinferai/gke-genai-serving

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
