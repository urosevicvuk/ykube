#!/usr/bin/env bash
# 03-argocd.sh — install Argo CD and apply root/app-of-apps.yaml.
#
# Chart version and values come from root/ (the root Application renders the
# same chart, so Argo CD manages itself from here on). After this, Argo
# creates the AppProjects and ApplicationSets and the cluster converges.

source "$(dirname "$0")/common.sh"
require_cmd kubectl helm yq
require_cluster

ARGOCD_VERSION="$(chart_version "${REPO_ROOT}/root/kustomization.yaml" argo-cd)"

kubectl get ns argocd >/dev/null 2>&1 || kubectl create ns argocd

if helm -n argocd status argocd >/dev/null 2>&1; then
  warn "Argo CD release already exists — not reinstalling (it manages itself)."
else
  log "Installing Argo CD (chart ${ARGOCD_VERSION}) with root/values.yaml"
  helm install argocd argo-cd \
    --repo https://argoproj.github.io/argo-helm \
    --version "${ARGOCD_VERSION}" \
    --namespace argocd \
    --values "${REPO_ROOT}/root/values.yaml" \
    --wait --timeout 15m
fi

kubectl -n argocd rollout status deploy/argocd-server --timeout=10m

log "Applying root/app-of-apps.yaml — GitOps takes over from here"
kubectl apply -f "${REPO_ROOT}/root/app-of-apps.yaml"

log "Watch it converge: kubectl -n argocd get applications -w"
log "UI until the gateways are up: kubectl -n argocd port-forward svc/argocd-server 8080:80"
