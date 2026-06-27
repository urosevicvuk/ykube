#!/usr/bin/env bash
# vault-unseal.sh — replay the unseal pass after a node reboot.

set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd vault
require_cmd jq

VAULT_INIT_FILE="${SECRETS_DIR}/vault-init.json"
if [[ ! -f "${VAULT_INIT_FILE}" ]]; then
  die "Missing ${VAULT_INIT_FILE} — restore from backup before retrying."
fi

log "Waiting for vault-0 pod to be Running"
kubectl -n vault wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=5m

log "Starting port-forward"
pf_pid="$(vault_port_forward_start vault vault 8200)"
trap 'vault_port_forward_stop "${pf_pid}"' EXIT
sleep 3

if vault status -format=json | jq -e '.sealed == false' >/dev/null 2>&1; then
  log "Vault is already unsealed."
  exit 0
fi

for i in 0 1 2; do
  key=$(jq -r ".unseal_keys_b64[${i}]" "${VAULT_INIT_FILE}")
  vault operator unseal "${key}" >/dev/null
done

log "Vault unsealed."
vault status
