#!/usr/bin/env bash
# Wait for Kubernetes API to be reachable
# Adapted from h8s (https://github.com/okwilkins/h8s)
set -euo pipefail

source "$(dirname "$0")/common.sh"

TIMEOUT="${TIMEOUT:-300}"
INTERVAL=5
ELAPSED=0

echo "Waiting for Kubernetes API..."

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  if kubectl_wrapper get nodes &>/dev/null; then
    echo "Kubernetes API is reachable."
    exit 0
  fi
  echo "  API not ready yet ($ELAPSED/${TIMEOUT}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "ERROR: Timed out waiting for Kubernetes API"
exit 1
