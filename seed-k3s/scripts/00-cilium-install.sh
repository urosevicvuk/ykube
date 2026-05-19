#!/usr/bin/env bash
# 00-cilium-install.sh — install Cilium onto k3s/firelink.
#
# Reads the SAME values file that ArgoCD will reconcile
# (apps/system/networking/cilium/values.yaml) so seed-install and GitOps stay
# in sync. After this runs, Argo can take over without fighting drift
# (CRDs already created, the helm release stays under Argo management).

set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd kubectl
require_cmd helm

CILIUM_VERSION="1.19.3"
CILIUM_VALUES="${REPO_ROOT}/apps/system/networking/cilium/values.yaml"

if ! kubectl get ns kube-system >/dev/null 2>&1; then
  die "k3s is not reachable. Set KUBECONFIG and try again."
fi

log "Adding Cilium helm repo"
helm repo add cilium https://helm.cilium.io >/dev/null
helm repo update cilium >/dev/null

if helm -n kube-system status cilium >/dev/null 2>&1; then
  warn "Cilium helm release already exists — skipping install."
  log "If you need to upgrade, run 'helm -n kube-system upgrade cilium ...' manually."
else
  log "Installing Cilium ${CILIUM_VERSION} with values from ${CILIUM_VALUES}"
  helm -n kube-system install cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --values "${CILIUM_VALUES}" \
    --wait \
    --timeout 10m
fi

log "Waiting for Cilium DaemonSet to be ready"
kubectl -n kube-system rollout status ds/cilium --timeout=5m

# Gateway API CRDs must exist before root/argocd-route.yaml (an HTTPRoute) can
# be applied. The Argo `gateway` Application (apps/system/networking/gateway/)
# is pinned to the same URL — installing once here unblocks the root sync, then
# Argo adopts it via server-side apply.
GATEWAY_API_URL=$(grep -oE 'https://github.com/kubernetes-sigs/gateway-api/releases/download/v[0-9.]+/standard-install.yaml' \
  "${REPO_ROOT}/apps/system/networking/gateway/kustomization.yaml")
log "Pre-installing Gateway API CRDs (${GATEWAY_API_URL})"
kubectl apply -f "${GATEWAY_API_URL}"

log "Applying Cilium LB IP pool + L2 announcement policy"
kubectl apply -f "${REPO_ROOT}/apps/system/networking/cilium/lb-ip-pool.yaml"
kubectl apply -f "${REPO_ROOT}/apps/system/networking/cilium/l2-announcement-policy.yaml"

log "Cilium status:"
kubectl -n kube-system exec ds/cilium -- cilium status --brief || true

log "Done."
