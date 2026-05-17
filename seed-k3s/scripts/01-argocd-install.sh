#!/usr/bin/env bash
# 01-argocd-install.sh — install ArgoCD and apply root/app-of-apps.yaml.
#
# After this, Argo manages itself. Subsequent chart upgrades happen via the
# `root/` kustomization (the same one Argo just took over).

set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd kubectl
require_cmd helm

ARGOCD_VERSION="9.5.13"
ARGOCD_VALUES="${REPO_ROOT}/root/values.yaml"

log "Creating argocd namespace if missing"
kubectl get ns argocd >/dev/null 2>&1 || kubectl create ns argocd

log "Adding ArgoCD helm repo"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update argo >/dev/null

if helm -n argocd status argocd >/dev/null 2>&1; then
  warn "ArgoCD helm release already exists — skipping install."
else
  log "Installing ArgoCD ${ARGOCD_VERSION} with values from ${ARGOCD_VALUES}"
  helm -n argocd install argocd argo/argo-cd \
    --version "${ARGOCD_VERSION}" \
    --values "${ARGOCD_VALUES}" \
    --wait \
    --timeout 10m
fi

log "Waiting for argocd-server"
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m

log "Applying root/app-of-apps.yaml — GitOps takeover begins now"
kubectl apply -f "${REPO_ROOT}/root/app-of-apps.yaml"

log "Argo will now reconcile the rest of the tree. Watch with:"
log "  kubectl -n argocd get applications -w"
