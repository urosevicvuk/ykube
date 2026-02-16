# Cluster Bootstrap

Run these commands once after `nixos-rebuild switch` on a new cluster.

## Prerequisites
- K3s running: `systemctl status k3s`
- kubectl working: `kubectl get nodes`
- Helm installed
- `kubeseal` CLI installed

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
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.0/manifests/install.yaml --server-side=true --force-conflicts
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

## 5. Create secrets

### Restore sealed-secrets key (if migrating from another cluster)
```bash
kubectl apply -f ~/.sealed-secrets-key-backup.yaml
kubectl delete pod -n system-security -l app.kubernetes.io/name=sealed-secrets
```
Skip this step if setting up a fresh cluster — but then you must re-seal ALL secrets below.

### Re-seal secrets for fresh cluster
On a fresh cluster, the sealed-secrets controller generates a new key pair, so all existing SealedSecret manifests in git won't decrypt. You need to re-seal each one:

```bash
# Nextcloud secrets (apps-external namespace)
kubectl create secret generic nextcloud-secrets -n apps-external \
  --from-literal=admin-user='admin' \
  --from-literal=admin-password='<your-password>' \
  --from-literal=postgres-user='nextcloud' \
  --from-literal=postgres-password='<your-password>' \
  --dry-run=client -o yaml | \
  kubeseal --controller-name=sealed-secrets --controller-namespace=system-security --format yaml \
  > apps-external/nextcloud/secrets.yaml

# GitLab DB credentials (system-cicd namespace)
kubectl create secret generic gitlab-db-credentials -n system-cicd \
  --from-literal=postgres-password='<your-password>' \
  --dry-run=client -o yaml | \
  kubeseal --controller-name=sealed-secrets --controller-namespace=system-security --format yaml \
  > system-cicd/gitlab/secrets.yaml

# Cloudflared credentials (system-ingress namespace)
# Copy your tunnel credentials JSON, then:
kubectl create secret generic cloudflared-credentials -n system-ingress \
  --from-file=credentials.json=<path-to-tunnel-credentials> \
  --dry-run=client -o yaml | \
  kubeseal --controller-name=sealed-secrets --controller-namespace=system-security --format yaml \
  > system-ingress/cloudflared/secrets.yaml

# Cloudflare API token (system-ingress namespace)
kubectl create secret generic cloudflare-api-token -n system-ingress \
  --from-literal=api-token='<your-cf-api-token>' \
  --dry-run=client -o yaml | \
  kubeseal --controller-name=sealed-secrets --controller-namespace=system-security --format yaml \
  > system-ingress/cert-manager/secrets.yaml

# Grafana admin credentials (system-monitoring namespace)
kubectl create secret generic grafana-admin-credentials -n system-monitoring \
  --from-literal=admin-user='admin' \
  --from-literal=admin-password='<your-password>' \
  --dry-run=client -o yaml | \
  kubeseal --controller-name=sealed-secrets --controller-namespace=system-security --format yaml \
  > system-monitoring/kube-prometheus-stack/secrets.yaml
```

Commit and push all re-sealed secrets before proceeding.

## 6. Apply root application
```bash
kubectl apply -f argocd/root.yaml
```

ArgoCD takes over from here and deploys everything in the repo.
Wait for all apps to sync:
```bash
kubectl get applications -n argocd -w
```

## 7. Initialize Vault

Vault will deploy but stay 0/1 (sealed). Initialize and unseal it:

```bash
# Initialize — SAVE THIS OUTPUT SECURELY (not in git)
kubectl exec -n system-security vault-0 -- vault operator init -key-shares=5 -key-threshold=3

# Unseal with any 3 of the 5 keys
kubectl exec -n system-security vault-0 -- vault operator unseal <key1>
kubectl exec -n system-security vault-0 -- vault operator unseal <key2>
kubectl exec -n system-security vault-0 -- vault operator unseal <key3>
```

### Configure Vault for External Secrets Operator
```bash
kubectl exec -n system-security vault-0 -- vault login <root-token>

kubectl exec -n system-security vault-0 -- vault secrets enable -path=secret kv-v2

kubectl exec -n system-security vault-0 -- vault auth enable kubernetes

kubectl exec -n system-security vault-0 -- vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

kubectl exec -n system-security vault-0 -- sh -c \
  'echo "path \"secret/data/*\" { capabilities = [\"read\"] }" | vault policy write external-secrets -'

kubectl exec -n system-security vault-0 -- vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=system-security \
  policies=external-secrets \
  ttl=1h
```

Note: Vault must be unsealed after every pod restart. Consider auto-unseal with a cloud KMS for production.

## 8. GitLab post-deploy

Once GitLab pods are running, get the initial root password:
```bash
kubectl get secret gitlab-gitlab-initial-root-password -n system-cicd \
  -o jsonpath='{.data.password}' | base64 -d
```

Login at `git.urosevicvuk.dev` with user `root`.

### Register GitLab Runner
1. In GitLab UI: Admin > CI/CD > Runners > New instance runner
2. Copy the authentication token (`glrt-...`)
3. Update the runner secret:
```bash
kubectl create secret generic gitlab-gitlab-runner-secret -n system-cicd \
  --from-literal=runner-token="<glrt-token-from-ui>" \
  --dry-run=client -o yaml | kubectl apply -f -
```
4. Restart the runner pod:
```bash
kubectl delete pod -n system-cicd -l app=gitlab-gitlab-runner
```

## 9. Access ArgoCD UI
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```
Access via `argocd.urosevicvuk.dev` or port-forward:
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
Login with user `admin`.

## Cloudflare setup

If ExternalDNS doesn't auto-create records, manually add CNAME records in Cloudflare pointing to the tunnel:
- `cloud.urosevicvuk.dev`
- `dashboard.urosevicvuk.dev`
- `argocd.urosevicvuk.dev`
- `git.urosevicvuk.dev`
- `registry.urosevicvuk.dev`
- `vault.urosevicvuk.dev`
