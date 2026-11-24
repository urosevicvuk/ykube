# seed/talos/

> **Status:** the target cluster. Until the move, the live cluster is still
> k3s/firelink — see [`seed/k3s/`](../k3s/README.md).

OpenTofu/Terraform pipeline that takes the cluster from "three fresh Proxmox
boxes" to "ArgoCD reconciling the GitOps repo". Reference: h8s
(github.com/okwilkins/h8s) — this is a ykube-adapted lift of their bootstrap
chain.

After this pipeline finishes, **everything else** is GitOps-managed. The
files in `apps/` and `appsets/` are reconciled by the ArgoCD installed in
stage 05.

## Topology

```
          pve-1                     pve-2                     pve-3
  ┌──────────────────┐      ┌──────────────────┐      ┌──────────────────┐
  │ cp-1             │      │ cp-2             │      │ cp-3             │
  │ wk-1a  wk-1b     │      │ wk-2a  wk-2b     │      │ wk-3a  wk-3b     │
  │ vmbr1 (mesh)     │══════│ vmbr1 (mesh)     │══════│ vmbr1 (mesh)     │
  │ vmbr0 (uplink)   │      │ vmbr0 (uplink)   │      │ vmbr0 (uplink)   │
  └───────┬──────────┘      └───────┬──────────┘      └───────┬──────────┘
          │  ╚═══════════════ 20G mesh (pve-1 ↔ pve-3) ════════╝  │
          └──────────── 1G ─────────┴──────────── 1G ─────────────┘
                                 router / switch
```

- **9 VMs**: per Proxmox host, 1 controlplane (tainted, no workloads) and 2
  workers (workloads + one Ceph OSD disk each).
- **Failure domain = Proxmox host.** Every node carries
  `topology.kubernetes.io/zone=<pve_node>`. Ceph CRUSH, Vault raft, CNPG
  and the HA'd system pods spread across zones, not just nodes — two VMs on
  one host are not independent.
- **Two NICs per VM.** `ens18` (net0 → `vmbr0`): 1G uplink, DHCP, default
  route, the Talos API VIP and Cilium's LAN LoadBalancer IPs. `ens19`
  (net1 → `vmbr1`): the 20G mesh, static IPs on `mesh_cidr`
  (10.10.0.0/24), jumbo frames. Kubelet node IPs and etcd advertise on the
  mesh, so pod-to-pod and all Ceph traffic stay off the 1G link.

## Prerequisites

- 3 Proxmox VE hosts in one Proxmox cluster, reachable over SSH as `root`
  with key-only auth.
- **The mesh**, configured on the hosts (not managed here): the two 20G NICs
  of each host cabled directly to the other two hosts, joined into an Open
  vSwitch bridge `vmbr1` with RSTP enabled (the "RSTP Loop Setup" from the
  Proxmox wiki's *Full Mesh Network for Ceph Server* page), MTU 9000 on the
  NICs and the bridge. RSTP blocks one of the three links to break the loop;
  the result is one L2 segment the VMs bridge onto. Cilium's native routing
  depends on that — a *routed* mesh (OpenFabric/OSPF) would not work as-is.
- Corosync: put link 0 on the mesh and link 1 on the uplink, so the Proxmox
  cluster keeps quorum if either network fails.
- **Do not enable Proxmox HA for the Talos VMs.** Kubernetes is the HA
  layer; a VM failover would leave its zone label pointing at the wrong host.
- A static IP plan on the LAN: 9 node IPs (DHCP-reserved by MAC) + a free IP
  for the Talos API VIP + the LB pool in
  `apps/system/networking/cilium/lb-ip-pool.yaml`, the last two outside the
  DHCP scope.
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

2. `INFRA_ROOT` must point at this directory so the helper scripts can find
   each other. The dev shell sets it; outside it:

   ```bash
   export INFRA_ROOT="$(pwd)"
   ```

3. Generate a LAN MAC per node and reserve each as a static DHCP lease on
   your router (the mesh NIC uses a static IP and a Proxmox-generated MAC):

   ```bash
   for i in $(seq 9); do printf "BC:24:11:%02X:%02X:%02X\n" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)); done
   ```

   Drop them into `shared/secrets.auto.tfvars` next to the matching node IPs.

## Bootstrap

```bash
task -d seed/talos cluster:bootstrap
```

This runs stages 00 → 07 in order. Roughly 15-30 minutes start to finish; the
slow steps are the ISO download to Proxmox (~600 MB × 3) and Talos installing
to disk and rebooting on each node.

After it finishes:

- Kubeconfig is at `seed/talos/03-talos-configure/secrets/kubeconfig.yaml`.
  Either point `KUBECONFIG` at it or merge into `~/.kube/config`.
- Vault unseal keys + root token are at `seed/talos/06-vault-init/secrets/vault-init.json`.
  **Back this up to Bitwarden right now.**
- ArgoCD is reachable via `kubectl -n argocd port-forward svc/argocd-server 8080:80`
  until the gateways are up.
- Stage 07 only writes the cert-manager Cloudflare token. The other bootstrap
  secrets (external-dns token, cloudflared credentials, Grafana / Forgejo /
  Harbor admin, ...) are still written by hand — see
  `seed/k3s/scripts/03-vault-secrets-provision.sh` for the full list.

## What each stage does

| Stage | Imperative for a reason |
|-------|--------------------------|
| `00-talos-factory` | Registers a schematic at factory.talos.dev with the qemu-guest-agent extension. Rook-Ceph needs nothing extra — rbd/ceph ship in the stock Talos kernel. |
| `01-proxmox-iso-upload` | SFTPs the schematic ISO to each Proxmox host's `local` storage. Proxmox local storage isn't shared, so each host gets its own copy. |
| `02-proxmox-provision` | Creates the 9 VMs (UEFI + virtio + EFI disk + serial console), each with two NICs (uplink + mesh); workers get an extra empty virtio1 disk for their Ceph OSD. `lifecycle.ignore_changes = [cdrom, boot_order]` so re-running stage 01 with a new Talos version doesn't brick existing VMs (the upgrade footgun documented in h8s). |
| `03-talos-configure` | Generates per-node machine configs (controlplane or worker) and applies them. Controlplanes keep their NoSchedule taint and float the VIP on the uplink. Every node gets its static mesh IP, `kubelet.nodeIP` pinned to the mesh, and the `topology.kubernetes.io/zone` label; etcd advertises on the mesh, and controller-manager / scheduler / etcd metrics are exposed for Prometheus. KubePrism is enabled and kube-proxy disabled. Bootstraps etcd on the first controlplane. |
| `04-cilium` | `helm install cilium` into kube-system, reading the **same** `apps/system/networking/cilium/values.yaml` that ArgoCD will reconcile. `lifecycle.ignore_changes = all` on the helm release means TF installs once and never fights Argo on subsequent chart bumps. Also applies the LB IP pool + L2 announcement policy and pre-installs the Prometheus Operator CRDs. |
| `05-argocd` | `helm install argo-cd` into argocd, then `kubectl apply -f root/app-of-apps.yaml`. Same drift-free trick as cilium. The root app is the GitOps pivot — Argo creates AppProjects + AppSets, AppSets generate Applications, and the cluster starts converging. |
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
  task -d seed/talos vault:status
  task -d seed/talos vault:unseal
  ```
- **Stage 07** when you add a new ExternalSecret that needs a new kv path.
- **Talos upgrades** — but **NOT** by changing `var.talos_version`. Use
  `talosctl upgrade --image factory.talos.dev/installer/<schematic-id>:<new-version>`
  one node at a time. See the upgrade footgun note in `02-proxmox-provision/main.tf`.

## Backup checklist

Before you tear down the workstation that ran bootstrap, make sure these are
in Bitwarden (or equivalent):

- [ ] All `seed/talos/states/*.tfstate` (especially `03-talos-configure.tfstate` — contains cluster PKI)
- [ ] `seed/talos/03-talos-configure/secrets/talosconfig.yaml`
- [ ] `seed/talos/03-talos-configure/secrets/kubeconfig.yaml`
- [ ] `seed/talos/06-vault-init/secrets/vault-init.json`

Without these, recovery from a workstation loss requires rebuilding the
cluster from scratch.
