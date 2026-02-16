# Cluster Bootstrap

Run these commands once after `nixos-rebuild switch` on a new cluster.

## Prerequisites
- K3s running: `systemctl status k3s`
- kubectl working: `kubectl get nodes`

## 1. Create namespaces
```bash
kubectl create namespace argocd
kubectl create namespace system-security
```

## 2. Install Gateway API CRDs
```bash
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
```

## 3. Install ArgoCD
```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side=true --force-conflicts
```

Wait for pods:
```bash
kubectl get pods -n argocd -w
```

## 4. Install Sealed Secrets
```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets -n system-security
```

## 5. Restore sealed-secrets key (if migrating from another cluster)
```bash
kubectl apply -f ~/.sealed-secrets-key-backup.yaml
kubectl delete pod -n system-security -l app.kubernetes.io/name=sealed-secrets
```
Skip this step if setting up a fresh cluster (but then re-seal all secrets).

## 6. Apply root application
```bash
kubectl apply -f argocd/root.yaml
```

ArgoCD takes over from here and deploys everything in the repo.

## 7. Access ArgoCD UI
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
Login at https://localhost:8080 with user `admin`.
