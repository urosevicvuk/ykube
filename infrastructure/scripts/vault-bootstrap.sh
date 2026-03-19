#!/usr/bin/env bash
# Idempotent Vault init + unseal script
# Adapted from h8s (https://github.com/okwilkins/h8s)
set -euo pipefail

source "$(dirname "$0")/common.sh"

KEY_SHARES="${KEY_SHARES:-5}"
KEY_THRESHOLD="${KEY_THRESHOLD:-3}"
VAULT_KEYS_FILE="${VAULT_KEYS_FILE:-vault-keys.json}"

# Wait for vault pod to exist and be running
wait_for_pod "vault" "vault-0" 1800

# Check if vault is already initialized
INIT_STATUS=$(vault_exec vault status -format=json 2>/dev/null | jq -r '.initialized' 2>/dev/null || echo "false")

if [ "$INIT_STATUS" = "true" ]; then
  echo "Vault is already initialized."

  if [ ! -f "$VAULT_KEYS_FILE" ]; then
    echo "ERROR: Vault is initialized but $VAULT_KEYS_FILE not found."
    echo "You need to provide the unseal keys manually."
    exit 1
  fi
else
  echo "Initializing Vault with $KEY_SHARES shares, threshold $KEY_THRESHOLD..."
  INIT_OUTPUT=$(vault_exec vault operator init \
    -key-shares="$KEY_SHARES" \
    -key-threshold="$KEY_THRESHOLD" \
    -format=json)

  echo "$INIT_OUTPUT" > "$VAULT_KEYS_FILE"
  chmod 600 "$VAULT_KEYS_FILE"
  echo "Vault initialized. Keys saved to $VAULT_KEYS_FILE"
  echo "IMPORTANT: Back up $VAULT_KEYS_FILE securely."
fi

# Unseal if sealed
SEALED=$(vault_exec vault status -format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null || echo "true")

if [ "$SEALED" = "true" ]; then
  echo "Unsealing Vault..."
  THRESHOLD=$(jq -r '.unseal_threshold // empty' "$VAULT_KEYS_FILE" 2>/dev/null || echo "$KEY_THRESHOLD")
  KEYS=$(jq -r '.unseal_keys_b64[]' "$VAULT_KEYS_FILE")
  COUNT=0
  for KEY in $KEYS; do
    vault_exec vault operator unseal "$KEY" > /dev/null
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -ge "$THRESHOLD" ]; then
      break
    fi
  done
  echo "Vault unsealed."
else
  echo "Vault is already unsealed."
fi

echo "Vault bootstrap complete."
