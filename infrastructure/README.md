# Infrastructure - Talos + Proxmox

Template for future migration from K3s to Talos Linux on Proxmox.

## Directory Structure

```
00-talos-factory/       - Talos factory image configuration
01-proxmox-provision/   - Proxmox VM provisioning (OpenTofu)
02-talos-provision/     - Talos machine config generation
03-talos-bootstrap/     - Talos cluster bootstrap
04-sealed-secrets-provision/ - (unused - using Vault + ESO)
05-argocd-provision/    - ArgoCD bootstrap on Talos
06-external-secrets-provision/ - ESO + Vault bootstrap
07-vault-resources-provision/  - Vault policies and auth config
platform-config/        - Shared platform configuration
scripts/                - Helper scripts
shared/                 - Shared OpenTofu modules
```

## Prerequisites

- Proxmox VE host accessible via SSH
- Talos factory image built for your hardware
- OpenTofu installed (via `nix develop`)
- `talosctl` installed (via `nix develop`)

## Usage

Each numbered directory is applied in order. Copy `secrets.auto.tfvars.example`
to `secrets.auto.tfvars` and fill in values before running.

```bash
task infra:apply -- 01-proxmox-provision
```

## Notes

This is a template adapted from [h8s](https://github.com/okwilkins/h8s).
Customize for your hardware before use.
