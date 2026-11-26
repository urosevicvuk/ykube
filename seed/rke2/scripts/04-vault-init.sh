#!/usr/bin/env bash
# 04-vault-init.sh — initialise and unseal Vault (3 raft replicas), then
# configure kv-v2, Kubernetes auth and the External Secrets role.
#
# Argo CD deploys Vault; this waits for it. Idempotent: an initialised Vault is
# only unsealed and (re)configured. Everything runs via `kubectl exec`.
#
# Output: seed/rke2/secrets/vault-init.json (5 unseal keys, threshold 3, root
# token). BACK IT UP TO BITWARDEN IMMEDIATELY — without it a sealed Vault is
# unrecoverable.

source "$(dirname "$0")/common.sh"
require_cmd kubectl jq
require_cluster

log "Waiting for Argo CD to create the vault StatefulSet"
for _ in $(seq 1 120); do
  kubectl -n vault get sts vault >/dev/null 2>&1 && break
  sleep 10
done
kubectl -n vault get sts vault >/dev/null 2>&1 || die "vault StatefulSet did not appear in 20 min. Check the Argo CD vault Application."

log "Waiting for vault-0 to be Running (it stays sealed and unready until unsealed)"
kubectl -n vault wait --for=create pod/vault-0 --timeout=20m >/dev/null
kubectl -n vault wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=20m >/dev/null

if jq -e '.initialized == true' >/dev/null 2>&1 <<<"$(vault_status_json vault-0)"; then
  log "Vault is already initialised."
  [[ -f "${VAULT_INIT_FILE}" ]] || die "Vault is initialised but ${VAULT_INIT_FILE} is missing. Restore it from Bitwarden."
else
  mkdir -p "${SECRETS_DIR}"
  umask 077
  log "Initialising Vault on vault-0 (5 key shares, threshold 3)"
  kubectl -n vault exec vault-0 -- vault operator init -key-shares=5 -key-threshold=3 -format=json >"${VAULT_INIT_FILE}"
  chmod 600 "${VAULT_INIT_FILE}"
  warn "Unseal keys + root token written to ${VAULT_INIT_FILE}. BACK THIS UP TO BITWARDEN NOW."
fi

log "Unsealing every replica (followers join raft once unsealed)"
for attempt in $(seq 1 30); do
  sealed=0
  for pod in $(vault_pods); do
    if [[ "$(kubectl -n vault get pod "${pod}" -o jsonpath='{.status.phase}')" != Running ]]; then
      sealed=1
      continue
    fi
    vault_unseal_pod "${pod}" || sealed=1
    jq -e '.sealed == false' >/dev/null 2>&1 <<<"$(vault_status_json "${pod}")" || sealed=1
  done
  [[ "$(vault_pods | wc -l)" -ge 3 && "${sealed}" -eq 0 ]] && break
  log "  not all three replicas are up and unsealed yet (attempt ${attempt}/30)"
  sleep 10
done

log "Configuring kv-v2, Kubernetes auth and the external-secrets role (on vault-0)"
# Kubernetes auth without a token_reviewer_jwt: Vault runs in-cluster and uses
# its own (auto-rotated) ServiceAccount token for TokenReview, so there is no
# long-lived reviewer token to expire (the k3s bootstrap's 1-year token did).
vault_root_sh vault-0 '
set -e
vault secrets list -format=json | grep -q "\"kv/\"" || vault secrets enable -path=kv kv-v2
vault auth list -format=json | grep -q "\"kubernetes/\"" || vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443" >/dev/null
vault policy write external-secrets - >/dev/null <<EOF
path "kv/data/*" {
  capabilities = ["read"]
}
path "kv/metadata/*" {
  capabilities = ["list", "read"]
}
EOF
vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets \
  ttl=24h >/dev/null
vault operator raft list-peers
'

log "Vault is initialised, unsealed and ready for External Secrets."
log "Next: task -d seed/rke2 vault:secrets"
