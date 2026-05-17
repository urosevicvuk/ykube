#!/usr/bin/env bash
# Polls the Kubernetes API until it responds. Used by stages 04+ which run
# right after Talos bootstrap, when the API briefly returns "connection refused".

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

load_tf_kube_env
create_cert_dir

echo "Waiting for Kubernetes API at https://${SERVER}:6443 ..."

MAX_ATTEMPTS=60
for ((i = 1; i <= MAX_ATTEMPTS; i++)); do
  if kubectl_wrapper get namespace kube-system >/dev/null 2>&1; then
    echo "Kubernetes API is ready."
    exit 0
  fi
  echo "  attempt $i/$MAX_ATTEMPTS — not ready, retrying in 5s"
  sleep 5
done

echo "ERROR: Kubernetes API did not become ready within $((MAX_ATTEMPTS * 5))s" >&2
exit 1
