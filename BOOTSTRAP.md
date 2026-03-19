# Cluster Bootstrap

## Automated (Recommended)

The `infrastructure/` directory contains OpenTofu configs that automate the full bootstrap.

### Prerequisites

- K3s running with Cilium flags: `--disable-kube-proxy --flannel-backend=none --disable-network-policy`
- kubectl working: `kubectl get nodes`
- Nix dev shell active: `nix develop` or `direnv allow`
- Cloudflare tunnel token and API token ready

### Run Bootstrap

```bash
cd infrastructure
task bootstrap
```

This runs 4 stages in order:

1. **01-cilium** — Installs Gateway API CRDs and Cilium CNI
2. **02-argocd** — Installs ArgoCD and applies app-of-apps (ArgoCD takes over from here)
3. **03-vault-init** — Waits for Vault pod, initializes, unseals, configures K8s auth + ESO policy
4. **04-vault-secrets** — Generates random passwords/keys and provisions all secrets into Vault

Stage 04 will prompt for `cloudflared_tunnel_token` and `cloudflare_api_token` (the only manual inputs).

Vault unseal keys and root token are saved to `infrastructure/03-vault-init/vault-keys.json`.
Back this up securely.

### Individual Stages

```bash
cd infrastructure
task 01-cilium
task 02-argocd
task 03-vault-init
task 04-vault-secrets
```

## Post-Bootstrap (Manual)

### Access ArgoCD UI

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Access via `argocd.urosevicvuk.dev` with user `admin`.
Once Authelia OIDC is working, use SSO login instead.

### GitLab Runner Registration

1. Get initial root password:
```bash
kubectl get secret gitlab-gitlab-initial-root-password -n gitlab \
  -o jsonpath='{.data.password}' | base64 -d
```

2. Login at `git.urosevicvuk.dev` with user `root`

3. Admin > CI/CD > Runners > New instance runner, copy token (`glrt-...`)

4. Update runner secret:
```bash
kubectl create secret generic gitlab-gitlab-runner-secret -n gitlab \
  --from-literal=runner-token="<glrt-token-from-ui>" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl delete pod -n gitlab -l app=gitlab-gitlab-runner
```

### Vault Unseal After Restart

Vault must be manually unsealed after every pod restart:

```bash
KUBECONFIG=~/.kube/config ./infrastructure/scripts/vault-bootstrap.sh
```

Or with the unseal keys directly:

```bash
kubectl exec -n vault vault-0 -- vault operator unseal <key1>
kubectl exec -n vault vault-0 -- vault operator unseal <key2>
kubectl exec -n vault vault-0 -- vault operator unseal <key3>
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
