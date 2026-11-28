#!/usr/bin/env bash
# check.sh — the phase 3 exit checks from PLAN.md, in one place. Read-only.

source "$(dirname "$0")/common.sh"
require_cmd kubectl
require_cluster

section() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }

section "Nodes (Ready, InternalIP on the mesh, zone label)"
kubectl get nodes -L topology.kubernetes.io/zone -o wide

section "Control plane static pods"
kubectl -n kube-system get pods -l tier=control-plane -o wide

section "Cilium"
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief || true
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep -E 'KubeProxyReplacement|Routing|Masquerading|Devices' || true

section "Argo CD applications not Synced/Healthy"
kubectl -n argocd get applications -o json 2>/dev/null |
  jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | "\(.metadata.name)\t\(.status.sync.status)\t\(.status.health.status)"' || true

section "Vault"
for pod in $(vault_pods); do
  printf '%s: ' "${pod}"
  vault_status_json "${pod}" | jq -c '{initialized, sealed, ha_enabled}' 2>/dev/null || echo "unreachable"
done

section "Ceph"
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status 2>/dev/null || echo "rook-ceph-tools not ready"
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree 2>/dev/null || true

section "Pod Security rejections (should be empty)"
kubectl get events -A --field-selector reason=FailedCreate -o json 2>/dev/null |
  jq -r '.items[] | select(.message | test("PodSecurity")) | "\(.metadata.namespace)\t\(.involvedObject.name)\t\(.message)"' || true
