#!/usr/bin/env bash
# Initialises and unseals Vault. Idempotent — re-running is a no-op once
# Vault is initialised. With raft HA (3 replicas) we unseal vault-0 first,
# then unseal the followers as they auto-join the raft cluster.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

load_tf_kube_env
create_cert_dir

REPLICAS=("vault-0" "vault-1" "vault-2")

echo "Waiting for ${REPLICAS[0]} pod to be created..."
kubectl_wrapper wait --for=create "pod/${REPLICAS[0]}" -n "$NAMESPACE" --timeout=1800s >/dev/null

echo "Waiting for ${REPLICAS[0]} to reach Running phase (still sealed)..."
kubectl_wrapper wait --for=jsonpath='{.status.phase}'=Running "pod/${REPLICAS[0]}" -n "$NAMESPACE" --timeout=1800s >/dev/null

# Check whether vault-0 is already initialised.
STATUS_JSON="$(
  kubectl_wrapper exec "${REPLICAS[0]}" -n "$NAMESPACE" -- vault status -format=json 2>/dev/null || true
)"

if jq -e '.initialized == true' >/dev/null 2>&1 <<<"$STATUS_JSON"; then
  echo "Vault is already initialised — running unseal pass on each replica."
  if [[ ! -f "$OUT_FILE" ]]; then
    echo "ERROR: $OUT_FILE missing but vault is initialised — restore it from your backup before continuing." >&2
    exit 1
  fi
else
  mkdir -p "$(dirname "$OUT_FILE")"
  umask 077
  echo "Initialising Vault (5 unseal keys, threshold 3) on ${REPLICAS[0]}..."
  INIT_JSON="$(
    kubectl_wrapper exec "${REPLICAS[0]}" -n "$NAMESPACE" -- \
      vault operator init -key-shares=5 -key-threshold=3 -format=json
  )"
  printf '%s\n' "$INIT_JSON" > "$OUT_FILE"
  chmod 600 "$OUT_FILE"
  echo "Vault initialised. Unseal keys + root token saved to $OUT_FILE — back this up to Bitwarden NOW."
fi

THRESHOLD="$(jq -r '.unseal_threshold' "$OUT_FILE")"

for pod in "${REPLICAS[@]}"; do
  # Followers join raft on first unseal — they may take a few seconds to appear.
  if ! kubectl_wrapper get "pod/$pod" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "  $pod not present yet, skipping (raft will catch it on next reconcile)"
    continue
  fi

  POD_STATUS="$(kubectl_wrapper exec "$pod" -n "$NAMESPACE" -- vault status -format=json 2>/dev/null || true)"
  if jq -e '.sealed == false' >/dev/null 2>&1 <<<"$POD_STATUS"; then
    echo "  $pod already unsealed."
    continue
  fi

  echo "Unsealing $pod..."
  jq -r '.unseal_keys_b64[]' "$OUT_FILE" | head -n "$THRESHOLD" | while IFS= read -r KEY; do
    kubectl_wrapper exec "$pod" -n "$NAMESPACE" -- vault operator unseal "$KEY" >/dev/null
  done
done

echo "Vault unseal pass complete."
