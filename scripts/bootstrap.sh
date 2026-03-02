#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARGOCD_CHART_VERSION="9.4.5"

echo "=== Cluster Bootstrap ==="

# 1. Create namespaces
echo "Creating namespaces..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace system-security --dry-run=client -o yaml | kubectl apply -f -

# 2. Install Gateway API CRDs
echo "Installing Gateway API CRDs..."
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml

# 3. Install ArgoCD via Helm (same chart + values as system-argocd.yaml)
# This ensures labels/selectors match when ArgoCD later manages itself.
echo "Installing ArgoCD via Helm (chart ${ARGOCD_CHART_VERSION})..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version "${ARGOCD_CHART_VERSION}" \
  --values "${REPO_ROOT}/system/argocd/values.yaml" \
  --wait --timeout 5m

# 4. Apply root application
echo "Applying root application..."
kubectl apply -f "${REPO_ROOT}/root.yaml"

echo ""
echo "=== Bootstrap complete ==="
echo "ArgoCD will now manage all applications from git."
echo "ArgoCD manages its own Helm upgrades — labels match from day one."
echo ""
echo "Next steps:"
echo "  1. Install Sealed Secrets: helm install sealed-secrets sealed-secrets/sealed-secrets -n system-security"
echo "  2. Seal secrets (see BOOTSTRAP.md step 5)"
echo "  3. Get ArgoCD admin password:"
echo "     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
