#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARGOCD_VERSION="v3.3.0"

echo "=== Cluster Bootstrap ==="

# 1. Create namespaces
echo "Creating namespaces..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace system-security --dry-run=client -o yaml | kubectl apply -f -

# 2. Install Gateway API CRDs
echo "Installing Gateway API CRDs..."
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml

# 3. Install ArgoCD (imperative — chicken-and-egg)
echo "Installing ArgoCD ${ARGOCD_VERSION}..."
kubectl apply -n argocd --server-side --force-conflicts -f \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "Waiting for ArgoCD to be ready..."
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deployment/argocd-applicationset-controller --timeout=300s

# 4. Apply root application
echo "Applying root application..."
kubectl apply -f "${REPO_ROOT}/root.yaml"

echo ""
echo "=== Bootstrap complete ==="
echo "ArgoCD will now manage all applications from git."
echo "After first sync, ArgoCD manages its own Helm-based upgrades."
echo ""
echo "Next steps:"
echo "  1. Install Sealed Secrets: helm install sealed-secrets sealed-secrets/sealed-secrets -n system-security"
echo "  2. Seal secrets (see BOOTSTRAP.md step 5)"
echo "  3. Get ArgoCD admin password:"
echo "     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
