#!/usr/bin/env bash
# 02-cilium.sh — install Cilium (CNI + kube-proxy replacement + L2 LB).
#
# RKE2 runs with `cni: none` and `disable-kube-proxy`, so nodes are NotReady
# and nothing (Argo CD included) can schedule until this runs. It installs the
# chart version pinned in apps/system/networking/cilium/kustomization.yaml with
# the SAME values.yaml Argo CD reconciles, so Argo adopts it without drift.
# Installs once: if the release exists it's left alone (Argo owns upgrades).

source "$(dirname "$0")/common.sh"
require_cmd kubectl helm yq
require_cluster

CILIUM_DIR="${REPO_ROOT}/apps/system/networking/cilium"
CILIUM_VERSION="$(chart_version "${CILIUM_DIR}/kustomization.yaml" cilium)"

if helm -n kube-system status cilium >/dev/null 2>&1; then
  warn "Cilium release already exists — not reinstalling (Argo CD owns upgrades)."
else
  log "Installing Cilium ${CILIUM_VERSION} with ${CILIUM_DIR}/values.yaml"
  helm install cilium cilium \
    --repo https://helm.cilium.io \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --values "${CILIUM_DIR}/values.yaml" \
    --wait --timeout 15m
fi

log "Waiting for the Cilium agents and nodes"
kubectl -n kube-system rollout status ds/cilium --timeout=10m
kubectl wait --for=condition=Ready nodes --all --timeout=10m

log "Applying the LB IP pool, L2 announcement policy and kube-system policy"
for f in lb-ip-pool.yaml l2-announcement-policy.yaml kube-system-allow-cluster.yaml; do
  kubectl apply -f "${CILIUM_DIR}/${f}"
done

log "Cilium status:"
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief || true
kubectl get nodes -o wide
