# ykube Development Guide

## Repository Structure

```
├── applications/       # User-facing apps (excalidraw, opencloud, stirling-pdf, searxng)
├── ci-cd/              # ArgoCD app-of-apps, GitLab config
├── infrastructure/     # Talos + Proxmox template (future migration)
├── namespaces/         # Namespace definitions (kustomize)
├── networking/         # Cilium, cert-manager, cloudflared, gateways
├── observability/      # Prometheus, Grafana operator, Loki, Promtail
├── security/           # Vault, ESO, Authelia, Cosign, Pocket-ID
├── storage/            # Longhorn, CloudNativePG, Harbor
├── flake.nix           # Nix dev shell
├── Taskfile.yaml       # Build/push/sign tasks
└── BOOTSTRAP.md        # Cluster bootstrap instructions
```

## Architecture

- **GitOps**: ArgoCD app-of-apps pattern. All changes go through git.
- **Networking**: Cilium CNI + Gateway API. Single HTTP gateway for Cloudflare tunnel traffic.
- **Secrets**: HashiCorp Vault + External Secrets Operator. No SealedSecrets.
- **Databases**: CloudNativePG operator for PostgreSQL (GitLab, Harbor, Authelia).
- **Storage**: Longhorn (single replica, single node).
- **Auth**: Authelia SSO with OIDC for ArgoCD and Grafana.
- **Monitoring**: Prometheus stack + Grafana Operator + Loki + Promtail.
- **Certificates**: Let's Encrypt via cert-manager with Cloudflare DNS-01.

## Patterns

### Kustomize base/environments
Apps with raw manifests use `base/` + `environments/prod/` pattern:
- `base/` contains the manifests
- `environments/prod/kustomization.yaml` references the base (and can add patches)

### Helm apps
Helm-based apps have `environments/prod/values.yaml` consumed by ArgoCD multi-source Applications.
Extra resources (CRs, secrets) go in a separate `-resources` ArgoCD app.

### Secrets
All secrets are ExternalSecrets pulling from Vault (`vault-backend` ClusterSecretStore).
Secret paths follow: `secret/<component>/<sub-path>`.

### Sync waves
- `-10000`: Namespaces
- `-1000`: Core infra (Longhorn, ESO)
- `-800` to `-500`: Security + networking (Vault, cert-manager, CloudNativePG)
- `-100` to `-80`: Cilium + gateways
- `0` (default): Applications and monitoring
- `+100`: ArgoCD self-management

## Domains

| Domain | Service |
|--------|---------|
| `argocd.urosevicvuk.dev` | ArgoCD |
| `auth.urosevicvuk.dev` | Authelia |
| `cloud.urosevicvuk.dev` | OpenCloud |
| `dashboard.urosevicvuk.dev` | Grafana |
| `draw.urosevicvuk.dev` | Excalidraw |
| `git.urosevicvuk.dev` | GitLab |
| `harbor.urosevicvuk.dev` | Harbor |
| `hubble.urosevicvuk.dev` | Hubble UI |
| `id.urosevicvuk.dev` | Pocket-ID |
| `pdf.urosevicvuk.dev` | Stirling PDF |
| `registry.urosevicvuk.dev` | GitLab Registry |
| `search.urosevicvuk.dev` | SearXNG |
| `vault.urosevicvuk.dev` | Vault |

## Adding a new application

1. Create `applications/<name>/base/` with deployment, service, kustomization
2. Create `applications/<name>/environments/prod/kustomization.yaml`
3. Add HTTPRoute in `networking/gateways/base/http-routes/<name>.yaml`
4. Update `networking/gateways/base/kustomization.yaml`
5. Add namespace in `namespaces/base/<name>.yaml` and update kustomization
6. Create ArgoCD Application in `ci-cd/argocd/environments/prod/apps/<name>.yaml`
7. Push to git — ArgoCD handles the rest
