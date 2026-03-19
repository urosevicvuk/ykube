#!/usr/bin/env bash
# Common functions for bootstrap scripts
# Adapted from h8s (https://github.com/okwilkins/h8s)
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

kubectl_wrapper() {
  kubectl --kubeconfig "$KUBECONFIG" "$@"
}

vault_exec() {
  kubectl_wrapper exec -n vault vault-0 -- "$@"
}

wait_for_pod() {
  local namespace="$1"
  local pod_name="$2"
  local timeout="${3:-300}"
  local interval=5
  local elapsed=0

  echo "Waiting for pod $pod_name in namespace $namespace..."

  while [ "$elapsed" -lt "$timeout" ]; do
    STATUS=$(kubectl_wrapper get pod -n "$namespace" "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$STATUS" = "Running" ]; then
      echo "Pod $pod_name is running."
      return 0
    fi
    echo "  Pod status: ${STATUS:-NotFound} ($elapsed/${timeout}s)"
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "ERROR: Timed out waiting for pod $pod_name"
  return 1
}
