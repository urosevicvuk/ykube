#!/usr/bin/env bash
# vault-status.sh — seal/HA status of every Vault replica.

source "$(dirname "$0")/common.sh"
require_cmd kubectl
require_cluster

for pod in $(vault_pods); do
  echo "=== ${pod} ==="
  kubectl -n vault exec "${pod}" -- vault status 2>/dev/null || echo "  (sealed, or not reachable)"
  echo
done
