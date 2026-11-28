#!/usr/bin/env bash
# 01-crds.sh — pre-install the CRDs that nothing else owns at bootstrap time.
#
#   Gateway API + Envoy Gateway CRDs: the envoy app's gateway-helm chart no
#     longer ships them, and the very first Argo sync (root/argocd-route.yaml,
#     an HTTPRoute) needs them. Experimental channel: the repo uses ListenerSet
#     and TCPRoute. Server-side apply: HTTPRoute's schema is too large for
#     client-side apply's last-applied annotation. The bootstrap owns these; see
#     apps/system/networking/envoy/kustomization.yaml for updating them.
#   Prometheus Operator CRDs: most system charts render ServiceMonitors and
#     would SyncFail until kube-prometheus-stack lands. Pre-installing decouples
#     the order; kube-prometheus-stack adopts them via server-side apply.
#   External Secrets CRDs: root/ itself carries ExternalSecrets, and the root
#     app can't even dry-run them before the external-secrets app (which root
#     creates) has installed its CRDs. The chart adopts them later (same
#     server-side apply).
#
# Versions come from the repo: the Envoy CRD chart from the envoy
# kustomization, the Prometheus Operator from kube-prometheus-stack's chart
# appVersion, ESO from the external-secrets kustomization. Idempotent.

source "$(dirname "$0")/common.sh"
require_cmd kubectl helm yq
require_cluster

ENVOY_VERSION="$(chart_version "${REPO_ROOT}/apps/system/networking/envoy/kustomization.yaml" gateway-helm)"
KPS_VERSION="$(chart_version "${REPO_ROOT}/apps/system/observability/kube-prometheus-stack/kustomization.yaml" kube-prometheus-stack)"
ESO_VERSION="$(chart_version "${REPO_ROOT}/apps/system/security/external-secrets/kustomization.yaml" external-secrets)"
PROM_OPERATOR_VERSION="$(helm show chart kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts --version "${KPS_VERSION}" | yq -r .appVersion)"

log "Gateway API + Envoy Gateway CRDs (gateway-crds-helm ${ENVOY_VERSION}, experimental channel)"
helm template gateway-crds oci://docker.io/envoyproxy/gateway-crds-helm \
  --version "${ENVOY_VERSION}" \
  --set crds.gatewayAPI.enabled=true \
  --set crds.gatewayAPI.channel=experimental \
  --set crds.envoyGateway.enabled=true |
  kubectl apply --server-side --force-conflicts -f -

log "Prometheus Operator CRDs (${PROM_OPERATOR_VERSION} = kube-prometheus-stack ${KPS_VERSION} appVersion)"
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/prometheus-operator/prometheus-operator/releases/download/${PROM_OPERATOR_VERSION}/stripped-down-crds.yaml"

log "External Secrets CRDs (external-secrets chart ${ESO_VERSION})"
helm template external-secrets external-secrets \
  --repo https://charts.external-secrets.io \
  --version "${ESO_VERSION}" \
  --include-crds |
  yq 'select(.kind == "CustomResourceDefinition")' |
  kubectl apply --server-side --force-conflicts -f -

log "Done."
