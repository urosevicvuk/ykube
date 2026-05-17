#!/usr/bin/env bash
# Common helpers used by every seed-k3s/scripts/*.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_K3S_DIR="$(dirname "${SCRIPT_DIR}")"
REPO_ROOT="$(cd "${SEED_K3S_DIR}/.." && pwd)"
SECRETS_DIR="${SEED_K3S_DIR}/secrets"

# Stable Vault address inside the cluster, exposed via port-forward for the
# seed scripts. We don't go through the Gateway because that requires DNS +
# cert-manager + ESO all converged, which is the chicken-and-egg this script breaks.
export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but not on PATH"
}

wait_for_pods_ready() {
  local namespace="$1"
  local selector="$2"
  local timeout="${3:-300s}"
  log "Waiting for pods in ${namespace} matching ${selector} (timeout ${timeout})"
  kubectl -n "${namespace}" wait --for=condition=Ready pod -l "${selector}" --timeout="${timeout}"
}

vault_port_forward_start() {
  local ns="${1:-vault}"
  local svc="${2:-vault}"
  local port="${3:-8200}"
  kubectl -n "${ns}" port-forward "svc/${svc}" "${port}:${port}" >/dev/null 2>&1 &
  echo $!
}

vault_port_forward_stop() {
  local pid="$1"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" 2>/dev/null || true
  fi
}
