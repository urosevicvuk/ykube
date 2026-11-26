#!/usr/bin/env bash
# vault-unseal.sh — unseal every Vault replica. Run after node reboots: raft
# replicas come back sealed (no auto-unseal). Raft keeps serving as long as
# 2 of 3 members are unsealed.

source "$(dirname "$0")/common.sh"
require_cmd kubectl jq
require_cluster

pods="$(vault_pods)"
[[ -n "${pods}" ]] || die "No Vault pods found in namespace vault."

for pod in ${pods}; do
  if [[ "$(kubectl -n vault get pod "${pod}" -o jsonpath='{.status.phase}')" != Running ]]; then
    warn "  ${pod}: not Running yet, skipping (re-run once it is)"
    continue
  fi
  vault_unseal_pod "${pod}"
done

log "Done."
