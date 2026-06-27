#!/usr/bin/env bash
# 02-vault-init.sh — wait for Vault to come up (via Argo), init + unseal,
# configure Kubernetes auth method + ESO policy/role.
#
# Idempotent: skips init if Vault is already initialized.

set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd kubectl
require_cmd vault
require_cmd jq

VAULT_INIT_FILE="${SECRETS_DIR}/vault-init.json"
mkdir -p "${SECRETS_DIR}"

log "Waiting for vault namespace + StatefulSet to exist (Argo creates it)"
for _ in $(seq 1 60); do
  if kubectl -n vault get sts vault >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

log "Waiting for vault-0 pod to be Running (still sealed)"
kubectl -n vault wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=5m

log "Starting port-forward to vault svc"
pf_pid="$(vault_port_forward_start vault vault 8200)"
trap 'vault_port_forward_stop "${pf_pid}"' EXIT

sleep 3   # let port-forward settle

INIT_STATUS=$(vault status -format=json 2>/dev/null || true)
if echo "${INIT_STATUS}" | jq -e '.initialized == true' >/dev/null 2>&1; then
  log "Vault already initialized."
  if [[ ! -f "${VAULT_INIT_FILE}" ]]; then
    die "Vault is initialized but ${VAULT_INIT_FILE} is missing. Cannot proceed without unseal keys. Restore from backup."
  fi
else
  log "Initializing Vault (5 keys, threshold 3)"
  vault operator init \
    -key-shares=5 \
    -key-threshold=3 \
    -format=json > "${VAULT_INIT_FILE}"
  chmod 600 "${VAULT_INIT_FILE}"
  log "Unseal keys + root token written to ${VAULT_INIT_FILE}"
  warn "BACK THIS FILE UP RIGHT NOW. Losing it means losing the cluster."
fi

# Unseal (replay 3 of the 5 keys).
log "Unsealing Vault"
for i in 0 1 2; do
  key=$(jq -r ".unseal_keys_b64[${i}]" "${VAULT_INIT_FILE}")
  vault operator unseal "${key}" >/dev/null
done

ROOT_TOKEN=$(jq -r .root_token "${VAULT_INIT_FILE}")
export VAULT_TOKEN="${ROOT_TOKEN}"

log "Enabling kv-v2 at kv/ (if missing)"
if ! vault secrets list -format=json | jq -e '."kv/"' >/dev/null; then
  vault secrets enable -path=kv kv-v2
fi

log "Enabling Kubernetes auth method (if missing)"
if ! vault auth list -format=json | jq -e '."kubernetes/"' >/dev/null; then
  vault auth enable kubernetes
fi

log "Configuring Kubernetes auth against the in-cluster API server"
# 1-year token. Default `kubectl create token` is 1h — Vault uses this as its
# token-reviewer credential to call TokenReview when other workloads log in,
# so when it expires every k8s-auth login starts returning 403 permission denied.
# Symptom: ESO's ClusterSecretStore fails with "unable to log in" any time
# >1h after a fresh bootstrap.
TOKEN_REVIEWER_JWT=$(kubectl -n vault create token vault --duration=8760h)
K8S_HOST="https://kubernetes.default.svc"
K8S_CA_CERT=$(kubectl -n vault get cm kube-root-ca.crt -o jsonpath='{.data.ca\.crt}')
vault write auth/kubernetes/config \
  token_reviewer_jwt="${TOKEN_REVIEWER_JWT}" \
  kubernetes_host="${K8S_HOST}" \
  kubernetes_ca_cert="${K8S_CA_CERT}" \
  disable_iss_validation=true

log "Writing ESO policy + role"
vault policy write external-secrets - <<'EOF'
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
  ttl=24h

log "Vault is initialized, unsealed, and ESO can authenticate."
log "Next: task -d seed-k3s vault:secrets"
