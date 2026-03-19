# Infrastructure Bootstrap

OpenTofu-based bootstrap automation for K3s cluster.
Adapted from [h8s](https://github.com/okwilkins/h8s) for K3s instead of Talos.

## Directory Structure

```
01-cilium/          - Gateway API CRDs + Cilium CNI
02-argocd/          - ArgoCD + app-of-apps
03-vault-init/      - Vault init, unseal, and ESO configuration
04-vault-secrets/   - Generate and provision all secrets
scripts/            - Helper scripts (vault-bootstrap.sh)
```

## Prerequisites

- K3s running with: `--disable-kube-proxy --flannel-backend=none --disable-network-policy`
- kubeconfig at `~/.kube/config`
- Nix dev shell active: `nix develop` or `direnv allow`
- Cloudflare tunnel token and API token ready

## Quick Start

```bash
cd infrastructure
task bootstrap
```

This runs all 4 stages in order. Stage 04 will prompt for Cloudflare tokens.

## Individual Stages

```bash
task 01-cilium       # Install Cilium
task 02-argocd       # Install ArgoCD + app-of-apps
task 03-vault-init   # Init + unseal Vault
task 04-vault-secrets # Provision secrets (needs tokens)
```

## Chart Version Sync

Stages 01 and 02 read Helm chart versions directly from the ArgoCD
Application YAMLs in `ci-cd/argocd/environments/prod/apps/`. This means
Renovate bumps propagate automatically — no duplicate version pins.

## Vault Keys

Stage 03 saves Vault unseal keys and root token to
`03-vault-init/vault-keys.json`. Back this up securely and never commit it.

## After Bootstrap

- ArgoCD syncs everything from the repo automatically
- Vault must be manually unsealed after pod restarts
- GitLab runner registration is manual (see BOOTSTRAP.md)
