# infrastructure/

OpenTofu/Terraform pipeline that takes the cluster from "three fresh Proxmox
boxes" to "ArgoCD reconciling the GitOps repo". Reference: h8s
(github.com/okwilkins/h8s) — this is a ykube-adapted lift of their bootstrap
chain.

After this pipeline finishes, **everything else** is GitOps-managed. The
files in `apps/` and `appsets/` are reconciled by the ArgoCD installed in
stage 05.

## Prerequisites

- 3 Proxmox VE hosts on the same L2 segment, reachable over SSH as `root`
  with key-only auth.
- A static IP plan: per-node IPs (DHCP-reserved by MAC) + a free IP for the
  Talos API VIP + a contiguous LB pool for `apps/system/networking/cilium/lb-ip-pool.yaml`.
- An SSH agent with the key for Proxmox `root` loaded.
- Tooling from the dev shell (`nix develop` from repo root): `tofu`, `talosctl`,
  `kubectl`, `helm`, `jq`, `nc`, `task`, `cilium`, `vault`, `argocd`.

## One-time setup

1. Copy the secrets template and fill it in:

   ```bash
   cp shared/secrets.auto.tfvars.example shared/secrets.auto.tfvars
   ```

   `shared/secrets.auto.tfvars` is gitignored. Per-stage `secrets.auto.tfvars`
   is a symlink into `shared/`, so each stage picks up the same values
   automatically. (`common.auto.tfvars` is reserved for future shared
   non-secret values; it's currently unused.)

2. Set `INFRA_ROOT` so the helper scripts know where to find each other:

   ```bash
   export INFRA_ROOT="$(pwd)"
   ```

   (Add to your dev-shell hook or `direnv` if you'll be running this often.)

3. Generate three MAC addresses for your nodes and reserve them as static
   DHCP leases on your router:

   ```bash
   for i in 1 2 3; do printf "BC:24:11:%02X:%02X:%02X\n" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)); done
   ```

   Drop them into `shared/secrets.auto.tfvars` next to the matching node IPs.

## Bootstrap

```bash
task -d infrastructure cluster:bootstrap
```

This runs stages 00 → 07 in order. Roughly 15-30 minutes start to finish; the
slow steps are the ISO download to Proxmox (~600 MB × 3) and Talos installing
to disk and rebooting on each node.

After it finishes:

- Kubeconfig is at `infrastructure/03-talos-configure/secrets/kubeconfig.yaml`.
  Either point `KUBECONFIG` at it or merge into `~/.kube/config`.
- Vault unseal keys + root token are at `infrastructure/06-vault-init/secrets/vault-init.json`.
  **Back this up to Bitwarden right now.**
- ArgoCD is reachable via `kubectl -n argocd port-forward svc/argocd-server 8080:80`
  until you wire up the Cilium Gateway.
- Apps under `apps/system/foundation/...` are still TODO stubs as of writing —
  expect ESO + cert-manager to be Pending until those values are filled in.

## What each stage does

| Stage | Imperative for a reason |
|-------|--------------------------|
| `00-talos-factory` | Registers a schematic at factory.talos.dev with the iscsi-tools / util-linux-tools / qemu-guest-agent extensions. **Longhorn requires the iscsi extensions baked into the image** — can't be installed later. |
| `01-proxmox-iso-upload` | SFTPs the schematic ISO to each Proxmox host's `local` storage. Proxmox local storage isn't shared, so each host gets its own copy. |
| `02-proxmox-provision` | Creates the 3 VMs (UEFI + virtio + EFI disk + serial console). `lifecycle.ignore_changes = [cdrom, boot_order]` so re-running stage 01 with a new Talos version doesn't brick existing VMs (the upgrade footgun documented in h8s). |
| `03-talos-configure` | Generates per-node machine configs and applies them. All 3 nodes are control-plane with `allowSchedulingOnControlPlanes=true` — that's how 3 boxes give you HA without doubling the VM count. KubePrism is enabled, kube-proxy is disabled, the longhorn `extraMount` is added, and the cluster VIP is floated across all controlplanes. |
| `04-cilium` | `helm install cilium` into kube-system, reading the **same** `apps/system/networking/cilium/values.yaml` that ArgoCD will reconcile. `lifecycle.ignore_changes = all` on the helm release means TF installs once and never fights Argo on subsequent chart bumps. Also applies the LB IP pool and L2 announcement policy. |
| `05-argocd` | `helm install argo-cd` into argocd, then `kubectl apply -f bootstrap/root-app.yaml`. Same drift-free trick as cilium. The root app is the GitOps pivot — Argo creates AppProjects + AppSets, AppSets generate Applications, and the cluster starts converging. |
| `06-vault-init` | Polls until Vault pods are Running (sealed), runs `vault operator init` (5 keys, threshold 3), saves `vault-init.json`, unseals all 3 raft replicas, mounts kv-v2 at `kv/`, enables k8s auth, creates the ESO policy + role. |
| `07-vault-resources-provision` | Writes the bootstrap secrets that the cluster needs to converge. Right now: just the Cloudflare API token used by cert-manager DNS-01. Add more `null_resource` blocks here as new ExternalSecrets are added to the repo. |

## After bootstrap

The cluster is now driven by GitOps. To change anything:

1. Edit `apps/...` in the repo.
2. Commit + push. Argo picks up the change.

There's no longer a reason to `tofu apply` any of these stages, with three exceptions:

- **`vault:status` / `vault:unseal`** when nodes reboot. Vault's raft replicas
  reseal on restart and need the unseal pass replayed:
  ```bash
  task -d infrastructure vault:status
  task -d infrastructure vault:unseal
  ```
- **Stage 07** when you add a new ExternalSecret that needs a new kv path.
- **Talos upgrades** — but **NOT** by changing `var.talos_version`. Use
  `talosctl upgrade --image factory.talos.dev/installer/<schematic-id>:<new-version>`
  one node at a time. See the upgrade footgun note in `02-proxmox-provision/main.tf`.

## Backup checklist

Before you tear down the workstation that ran bootstrap, make sure these are
in Bitwarden (or equivalent):

- [ ] All `infrastructure/states/*.tfstate` (especially `03-talos-configure.tfstate` — contains cluster PKI)
- [ ] `infrastructure/03-talos-configure/secrets/talosconfig.yaml`
- [ ] `infrastructure/03-talos-configure/secrets/kubeconfig.yaml`
- [ ] `infrastructure/06-vault-init/secrets/vault-init.json`

Without these, recovery from a workstation loss requires rebuilding the
cluster from scratch.
