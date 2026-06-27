#!/usr/bin/env bash
# Prints `vault status` for vault-0..2 — useful after a node reboot when raft
# replicas reseal and need to be unsealed again (run vault-bootstrap.sh).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

load_tf_kube_env
create_cert_dir

for pod in vault-0 vault-1 vault-2; do
  echo "=== $pod ==="
  kubectl_wrapper exec "$pod" -n "$NAMESPACE" -- vault status 2>/dev/null || echo "  (pod not present or sealed-and-unreachable)"
  echo
done
