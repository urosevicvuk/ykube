# Cluster Bootstrap

Run these commands once after setting up a new K3s cluster.

## Prerequisites

- K3s running with Cilium flags: `--disable-kube-proxy --flannel-backend=none --disable-network-policy`
- kubectl working: `kubectl get nodes`
- Nix dev shell: `nix develop` (provides kubectl, helm, cilium-cli, argocd, task, etc.)

## 1. Install Gateway API CRDs

```bash
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

## 2. Install Cilium

```bash
helm repo add cilium https://helm.cilium.io
helm install cilium cilium/cilium --version 1.17.0 \
  --namespace kube-system \
  -f networking/cilium/environments/prod/values.yaml
```

Wait for Cilium to be ready:
```bash
cilium status --wait
```

## 3. Install ArgoCD

```bash
kubectl create namespace argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd --version 7.7.16 \
  --namespace argocd \
  -f ci-cd/argocd/environments/prod/values.yaml
```

Wait for pods:
```bash
kubectl get pods -n argocd -w
```

## 4. Apply app-of-apps

```bash
kubectl apply -f ci-cd/argocd/environments/prod/app-of-apps.yaml
```

ArgoCD takes over from here and deploys everything in the repo.

## 5. Initialize Vault

Vault will deploy but stay 0/1 (sealed). Initialize and unseal it:

```bash
# Initialize — SAVE THIS OUTPUT SECURELY (not in git)
kubectl exec -n vault vault-0 -- vault operator init -key-shares=5 -key-threshold=3

# Unseal with any 3 of the 5 keys
kubectl exec -n vault vault-0 -- vault operator unseal <key1>
kubectl exec -n vault vault-0 -- vault operator unseal <key2>
kubectl exec -n vault vault-0 -- vault operator unseal <key3>
```

### Configure Vault for External Secrets Operator

```bash
kubectl exec -n vault vault-0 -- vault login <root-token>

# Enable KV v2 secrets engine
kubectl exec -n vault vault-0 -- vault secrets enable -path=secret kv-v2

# Enable Kubernetes auth
kubectl exec -n vault vault-0 -- vault auth enable kubernetes

kubectl exec -n vault vault-0 -- vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# Create policy for ESO
kubectl exec -n vault vault-0 -- sh -c \
  'echo "path \"secret/data/*\" { capabilities = [\"read\"] }" | vault policy write external-secrets -'

# Create role for ESO service account
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets-vault-auth \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets \
  ttl=1h
```

### Populate Vault secrets

```bash
# Cloudflared tunnel token
kubectl exec -n vault vault-0 -- vault kv put secret/cloudflared \
  token="<your-tunnel-token>"

# Cloudflare API token (for cert-manager DNS-01)
kubectl exec -n vault vault-0 -- vault kv put secret/cloudflare \
  api-token="<your-cf-api-token>"

# CloudNativePG database passwords
kubectl exec -n vault vault-0 -- vault kv put secret/cloudnative-pg/gitlab \
  username=gitlab password="<password>"

kubectl exec -n vault vault-0 -- vault kv put secret/cloudnative-pg/harbor \
  username=harbor password="<password>"

kubectl exec -n vault vault-0 -- vault kv put secret/cloudnative-pg/authelia \
  username=authelia password="<password>"

# Authelia secrets
kubectl exec -n vault vault-0 -- vault kv put secret/authelia \
  encryption-key="<random-64-char>" \
  session-secret="<random-64-char>" \
  storage-encryption-key="<random-64-char>" \
  hmac-secret="<random-64-char>" \
  users-database="<yaml-content>"

# Authelia OIDC
kubectl exec -n vault vault-0 -- vault kv put secret/authelia/oidc \
  private-key="<rsa-private-key-pem>"

kubectl exec -n vault vault-0 -- vault kv put secret/authelia/oidc/clients \
  argocd-secret="<random>" \
  grafana-secret="<random>"

# Harbor
kubectl exec -n vault vault-0 -- vault kv put secret/harbor \
  secret-key="<random>" \
  admin-password="<password>"

# Cosign
kubectl exec -n vault vault-0 -- vault kv put secret/cosign \
  private-key="<cosign-private-key>" \
  public-key="<cosign-public-key>" \
  password="<cosign-password>"

# Pocket-ID
kubectl exec -n vault vault-0 -- vault kv put secret/pocket-id \
  encryption-key="<random>"

# SearXNG
kubectl exec -n vault vault-0 -- vault kv put secret/searxng \
  secret-key="<random>"
```

Note: Vault must be unsealed after every pod restart.

## 6. Create cert-manager Cloudflare secret

The Cloudflare API token for DNS-01 challenges needs to be in the cert-manager namespace:

```bash
kubectl create secret generic cloudflare-api-token \
  -n cert-manager \
  --from-literal=api-token="<your-cf-api-token>"
```

Or store it in Vault and create an ExternalSecret for it.

## 7. Access ArgoCD UI

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Access via `argocd.urosevicvuk.dev` with user `admin`.
Once Authelia OIDC is configured, use SSO login instead.

## 8. GitLab post-deploy

Get the initial root password:
```bash
kubectl get secret gitlab-gitlab-initial-root-password -n gitlab \
  -o jsonpath='{.data.password}' | base64 -d
```

Login at `git.urosevicvuk.dev` with user `root`.

### Register GitLab Runner

1. In GitLab UI: Admin > CI/CD > Runners > New instance runner
2. Copy the authentication token (`glrt-...`)
3. Update the runner secret:
```bash
kubectl create secret generic gitlab-gitlab-runner-secret -n gitlab \
  --from-literal=runner-token="<glrt-token-from-ui>" \
  --dry-run=client -o yaml | kubectl apply -f -
```
4. Restart the runner pod:
```bash
kubectl delete pod -n gitlab -l app=gitlab-gitlab-runner
```

## Domains

Ensure these DNS records exist in Cloudflare (CNAME to tunnel):
- `argocd.urosevicvuk.dev`
- `auth.urosevicvuk.dev`
- `cloud.urosevicvuk.dev`
- `dashboard.urosevicvuk.dev`
- `draw.urosevicvuk.dev`
- `git.urosevicvuk.dev`
- `harbor.urosevicvuk.dev`
- `hubble.urosevicvuk.dev`
- `id.urosevicvuk.dev`
- `pdf.urosevicvuk.dev`
- `registry.urosevicvuk.dev`
- `search.urosevicvuk.dev`
- `vault.urosevicvuk.dev`
