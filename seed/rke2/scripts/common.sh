#!/usr/bin/env bash
# Common helpers for seed/rke2/scripts/*.sh. Sourced, not executed.
# shellcheck disable=SC2034  # variables are used by the scripts that source this

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_DIR="$(dirname "${SCRIPT_DIR}")"
REPO_ROOT="$(cd "${SEED_DIR}/../.." && pwd)"
SECRETS_DIR="${SEED_DIR}/secrets"
VAULT_INIT_FILE="${SECRETS_DIR}/vault-init.json"

# Every stage talks to the cluster through this kubeconfig (written by
# 00-kubeconfig.sh, pointing at the API VIP). Override by exporting KUBECONFIG.
export KUBECONFIG="${KUBECONFIG:-${SECRETS_DIR}/kubeconfig.yaml}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} is required but not on PATH (run inside \`nix develop\`)"
  done
}

require_cluster() {
  [[ -f "${KUBECONFIG}" ]] || die "No kubeconfig at ${KUBECONFIG}. Run \`task -d seed/rke2 kubeconfig\` first."
  kubectl get --raw /readyz >/dev/null 2>&1 || die "The API server at $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}') is not reachable/ready."
}

# chart_version <kustomization.yaml> <chart name>
# Reads the pinned chart version from a kustomization's helmCharts, so the
# seed installs exactly what Argo CD will later reconcile.
chart_version() {
  local version
  version="$(yq -r ".helmCharts[] | select(.name == \"$2\") | .version" "$1")"
  [[ -n "${version}" && "${version}" != "null" ]] || die "No helmCharts entry named $2 in $1"
  printf '%s' "${version}"
}

# --- Vault --------------------------------------------------------------
# The chart runs Vault with VAULT_ADDR=http://127.0.0.1:8200 in each pod, so
# everything goes through `kubectl exec`: no port-forward, no local vault CLI.

vault_pods() {
  kubectl -n vault get pods -l app.kubernetes.io/name=vault,component=server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort
}

vault_status_json() {
  kubectl -n vault exec "$1" -- vault status -format=json 2>/dev/null || true
}

# vault_unseal_pod <pod>: replay the threshold of unseal keys on one replica.
vault_unseal_pod() {
  local pod="$1" threshold key
  [[ -f "${VAULT_INIT_FILE}" ]] || die "Missing ${VAULT_INIT_FILE}. Restore it from Bitwarden before unsealing."
  if jq -e '.sealed == false' >/dev/null 2>&1 <<<"$(vault_status_json "${pod}")"; then
    log "  ${pod}: already unsealed"
    return 0
  fi
  threshold="$(jq -r '.unseal_threshold' "${VAULT_INIT_FILE}")"
  log "  ${pod}: unsealing (${threshold} keys)"
  while IFS= read -r key; do
    kubectl -n vault exec "${pod}" -- vault operator unseal "${key}" >/dev/null
  done < <(jq -r '.unseal_keys_b64[]' "${VAULT_INIT_FILE}" | head -n "${threshold}")
}

# vault_root_sh <pod> <script>: run a shell script inside the pod with the
# root token in VAULT_TOKEN. The token goes over stdin, never into argv.
vault_root_sh() {
  local pod="$1" script="$2"
  jq -r '.root_token' "${VAULT_INIT_FILE}" |
    kubectl -n vault exec -i "${pod}" -- sh -c "read -r VAULT_TOKEN; export VAULT_TOKEN; ${script}"
}
