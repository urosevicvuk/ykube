# seed/talos/

> **Status:** the target cluster. Until the move, the live cluster is still
> k3s/firelink — see [`seed/k3s/`](../k3s/README.md).

OpenTofu pipeline that takes the cluster from "three fresh Proxmox boxes" to
"ArgoCD reconciling the GitOps repo". Reference: h8s
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
  │ (+ Ceph disks)   │      │ (+ Ceph disks)   │      │ (+ Ceph disks)   │
  │ vmbr1 (mesh)     │══════│ vmbr1 (mesh)     │══════│ vmbr1 (mesh)     │
  │ vmbr0 (uplink)   │ 25G  │ vmbr0 (uplink)   │ 25G  │ vmbr0 (uplink)   │
  └───────┬──────────┘      └───────┬──────────┘      └───────┬──────────┘
          │  ╚═══════════════ 25G DAC (pve-1 ↔ pve-3) ═════════╝  │
          └──────────── 1G ─────────┴──────────── 1G ─────────────┘
                                 router / switch
```

- **9 VMs**: per Proxmox host, 1 controlplane (tainted, no workloads) and 2
  workers (workloads + that host's Ceph disks, passed through physically).
- **Failure domain = Proxmox host.** Every node carries
  `topology.kubernetes.io/zone=<pve_node>`. Ceph CRUSH, Vault raft, CNPG
  and the HA'd system pods spread across zones, not just nodes — two VMs on
  one host are not independent.
- **Two NICs per VM.** `ens18` (net0 → `vmbr0`): 1G uplink, DHCP, default
  route, the Talos API VIP and Cilium's LAN LoadBalancer IPs. `ens19`
  (net1 → `vmbr1`): the 25G mesh, static IPs on `mesh_cidr`
  (10.10.0.0/24), jumbo frames (MTU 9000). Kubelet node IPs, etcd and Ceph
  live on the mesh; nothing but internet/LAN traffic touches the 1G link.

## Versions

Pinned to one tested-together set (2026-11). The binding constraint is
Cilium: 1.20 is tested up to Kubernetes 1.36, so the cluster runs 1.36 even
though Talos 1.14 could do 1.37.

| Layer | Version | Where it's pinned |
|-------|---------|-------------------|
| Talos | v1.14.7 | `shared/variables.tf` → `talos_version` |
| Kubernetes | 1.36.6 | `shared/variables.tf` → `kubernetes_version` |
| Cilium | 1.20.5 | `apps/system/networking/cilium/kustomization.yaml` |
| Rook / Ceph | v1.21.3 / Ceph 20 (Tentacle) | `apps/system/storage/rook-ceph/kustomization.yaml` |
| Argo CD | 3.6 (chart 10.19.1) | `root/kustomization.yaml` |
| Gateway API CRDs | v1.6.1 (via Envoy Gateway 1.10.0) | follows `apps/system/networking/envoy/kustomization.yaml` |
| Prometheus Operator CRDs | v0.95.2 | `04-cilium/main.tf` — must equal kube-prometheus-stack's appVersion |
| Providers | talos 0.12.0, bpg/proxmox 0.123.x | `shared/providers.tf` |
| Tooling | talosctl 1.14, OpenTofu 1.13, Helm 4 | `flake.lock` (`nix flake update`) |

"Latest" doesn't stay latest: Renovate opens PRs for the app charts. Bump
the bootstrap-only pins (Talos, Kubernetes, the two CRD sets) by hand, and
check the compatibility notes in `kubernetes_version`'s description first.

## Prerequisites

- 3 Proxmox VE 9 hosts in one Proxmox cluster, reachable over SSH as `root`
  with key-only auth. All three need the same datastore name for the VMs' OS
  disks (`proxmox_disk_datastore`, default `local-lvm`).
- An SSH agent with the key for Proxmox `root` loaded.
- Tooling from the dev shell (`nix develop` from repo root): `tofu`,
  `talosctl`, `kubectl`, `helm`, `jq`, `nc`, `task`, `cilium`, `vault`,
  `argocd`.
- A static IP plan on the LAN: 9 node IPs (DHCP-reserved by MAC) + a free IP
  for the Talos API VIP + the LB pool in
  `apps/system/networking/cilium/lb-ip-pool.yaml`, the last two outside the
  DHCP scope.
- **Do not enable Proxmox HA for the Talos VMs.** Kubernetes is the HA
  layer; a VM failover would leave its zone label pointing at the wrong host
  (and workers can't move anyway — their Ceph disks are physically in one box).

### The mesh (configured on the hosts by hand)

Each host has two 25G DAC ports, cabled directly to the other two hosts. The
two ports are joined into one Open vSwitch bridge, `vmbr1`, running RSTP —
the "RSTP Loop Setup" from the Proxmox wiki's *Full Mesh Network for Ceph
Server* page, plus jumbo frames. Three hosts in a triangle form a loop, so
RSTP blocks one of the three cables; traffic between that pair goes through
the third host's bridge instead (still 25G, a few µs extra). If any cable or
host fails, RSTP unblocks the spare path within a few seconds.

Why this and not a routed mesh (where all three cables carry traffic): the
VMs need to sit on **one shared L2 network** — Cilium's native routing and
Ceph both assume every node can reach every other node directly on
`10.10.0.0/24`. The routed setups (static routes, OpenFabric) only connect
the hosts themselves. Getting all-links-active *and* a shared VM network
means Proxmox SDN fabrics with a VXLAN/EVPN overlay on top (tech preview,
50 bytes of encapsulation per packet, more moving parts) — not worth it when
one 25G path between any two hosts is far more than the disks can fill.

On every host: `apt install openvswitch-switch`, then in
`/etc/network/interfaces` (NIC names and the `.1/.2/.3` address differ per
host — check yours with `ip link`):

```
auto enp1s0f0np0
iface enp1s0f0np0 inet manual
    ovs_type OVSPort
    ovs_bridge vmbr1
    ovs_mtu 9000
    ovs_options other_config:rstp-enable=true other_config:rstp-path-cost=150 other_config:rstp-port-admin-edge=false other_config:rstp-port-auto-edge=false other_config:rstp-port-mcheck=true vlan_mode=native-untagged

auto enp1s0f1np1
iface enp1s0f1np1 inet manual
    ovs_type OVSPort
    ovs_bridge vmbr1
    ovs_mtu 9000
    ovs_options other_config:rstp-enable=true other_config:rstp-path-cost=150 other_config:rstp-port-admin-edge=false other_config:rstp-port-auto-edge=false other_config:rstp-port-mcheck=true vlan_mode=native-untagged

auto vmbr1
iface vmbr1 inet static
    address 10.10.0.1/24
    ovs_type OVSBridge
    ovs_ports enp1s0f0np0 enp1s0f1np1
    ovs_mtu 9000
    up ovs-vsctl set Bridge ${IFACE} rstp_enable=true other_config:rstp-priority=32768 other_config:rstp-forward-delay=4 other_config:rstp-max-age=6
    post-up sleep 10
```

Then `ifreload -a` and check:

- `ovs-appctl rstp/show` — one port on one host should be `Discarding`
  (the blocked link); everything else `Forwarding`.
- `ping -M do -s 8972 10.10.0.2` (and `.3`) from each host — must succeed;
  that proves 9000-byte frames make it through unfragmented. Repeat between
  two VMs on different hosts after stage 03.

Mesh addresses: hosts `.1-.3`, controlplanes `.11-.13`, workers `.21-.26`.
Corosync: put link 0 on the mesh (`10.10.0.x`) and link 1 on the uplink, so
the Proxmox cluster keeps quorum if either network fails.

## Storage (Rook-Ceph)

- **Disks:** whole physical disks on each host, listed per worker as
  `ceph_disks` in `shared/secrets.auto.tfvars` and passed through to the VM
  (stage 02). One disk = one Ceph OSD. Every pool stores one copy per host,
  so usable space is capped by the smallest host — keep the hosts roughly
  equal. Disks must be empty (`wipefs -a` + `sgdisk --zap-all` on the host);
  Rook skips anything with partitions on it.
- **Networking:** Ceph runs on host networking bound to the mesh, so
  replication goes host-to-host at 9000 MTU and bypasses the pod network
  (pods are capped at 1500 because the uplink is 1500).
- **Two block tiers:**

  | StorageClass | Copies | Survives | Used for |
  |---|---|---|---|
  | `ceph-block` (default) | 3, one per host | one host down, with a spare copy left | Vault, Immich library, OpenCloud, Forgejo repos, Vaultwarden data, n8n data |
  | `ceph-block-2x` | 2, on different hosts | one host down, no spare copy until it's back | every CNPG Postgres (already replicated by Postgres itself), Prometheus/Loki/Tempo/Pyroscope/Grafana, Harbor, caches |

  Pick the class per PVC; it can't be changed on an existing PVC (new PVC +
  copy). S3 (`ceph-bucket`) is erasure-coded 2+1 — 2x-tier protection at
  1.5x cost.
- **Neither tier is a backup.** Anything irreplaceable also needs a copy off
  this cluster.
- Adding a disk to a running worker: `qm set <vmid> -scsi<N>
  /dev/disk/by-id/<id>,backup=0,replicate=0,ssd=1,iothread=1,aio=native`, then
  add it to `secrets.auto.tfvars` too. Stage 02 ignores disk changes after
  creation (see its header comment); Rook picks the new disk up on its own.

## One-time setup

1. Set up the mesh (above) on all three hosts.

2. Copy the secrets template and fill it in:

   ```bash
   cp shared/secrets.auto.tfvars.example shared/secrets.auto.tfvars
   ```

   `shared/secrets.auto.tfvars` is gitignored. Per-stage tasks pass it with
   `-var-file`, so every stage sees the same values. (`common.auto.tfvars`
   is reserved for future shared non-secret values; it's currently unused.)

3. `INFRA_ROOT` must point at this directory so the helper scripts can find
   each other. The dev shell sets it; outside it:

   ```bash
   export INFRA_ROOT="$(pwd)"
   ```

4. Generate a LAN MAC per node and reserve each as a static DHCP lease on
   your router (the mesh NIC uses a static IP and a Proxmox-generated MAC):

   ```bash
   for i in $(seq 9); do printf "BC:24:11:%02X:%02X:%02X\n" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)); done
   ```

5. Pick the Ceph disks on each host and add them to the workers' `ceph_disks`
   (the template shows how to list them).

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

First-boot checks worth doing once:

```bash
cilium status --wait                        # all green, KubeProxyReplacement True
kubectl -n kube-system get pods -l k8s-app=kube-dns   # CoreDNS Running (the DNS fix)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status    # HEALTH_OK, all OSDs up
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree  # 3 zones, OSDs under the right hosts
```

## What each stage does

| Stage | Imperative for a reason |
|-------|--------------------------|
| `00-talos-factory` | Registers a schematic at factory.talos.dev with the qemu-guest-agent extension. Rook-Ceph needs nothing extra — rbd/ceph ship in the stock Talos kernel. |
| `01-proxmox-iso-upload` | Downloads the schematic ISO into each Proxmox host's `local` storage. Proxmox local storage isn't shared, so each host gets its own copy. |
| `02-proxmox-provision` | Creates the 9 VMs (UEFI, host CPU, virtio OS disk, EFI disk, serial console), each with two NICs (uplink + mesh); workers also get their physical Ceph disks passed through on SCSI. `lifecycle.ignore_changes = [cdrom, boot_order, disk]` so re-running stage 01 with a new Talos version doesn't brick existing VMs (the upgrade footgun documented in h8s), and passthrough disks don't show perpetual diffs. |
| `03-talos-configure` | Generates per-node machine configs (Talos 1.14 multi-document format) and applies them. Controlplanes keep their NoSchedule taint and float the VIP on the uplink. Every node gets its static mesh IP, its node IP pinned to the mesh, and the zone label; etcd advertises on the mesh; controller-manager / scheduler / etcd metrics are exposed for Prometheus; Flannel and kube-proxy are off; CoreDNS stops forwarding through the host DNS cache (breaks under Cilium's BPF masquerade). Bootstraps etcd on the first controlplane. |
| `04-cilium` | `helm install cilium` into kube-system, reading the **same** `apps/system/networking/cilium/values.yaml` that ArgoCD will reconcile. `lifecycle.ignore_changes = all` on the helm release means TF installs once and never fights Argo on subsequent chart bumps. Also applies the LB IP pool + L2 announcement policy and pre-installs the CRDs nothing else owns: Gateway API + Envoy Gateway (from the envoy chart's version) and the Prometheus Operator. |
| `05-argocd` | `helm install argo-cd` into argocd, then `kubectl apply -f root/app-of-apps.yaml`. Same drift-free trick as cilium. The root app is the GitOps pivot — Argo creates AppProjects + AppSets, AppSets generate Applications, and the cluster starts converging. |
| `06-vault-init` | Polls until Vault pods are Running (sealed), runs `vault operator init` (5 keys, threshold 3), saves `vault-init.json`, unseals all 3 raft replicas, mounts kv-v2 at `kv/`, enables k8s auth, creates the ESO policy + role. |
| `07-vault-resources-provision` | Writes the bootstrap secrets that the cluster needs to converge. Right now: just the Cloudflare API token used by cert-manager DNS-01. Add more `null_resource` blocks here as new ExternalSecrets are added to the repo. |

## After bootstrap

The cluster is now driven by GitOps. To change anything:

1. Edit `apps/...` in the repo.
2. Commit + push. Argo picks up the change.

There's no longer a reason to `tofu apply` any of these stages, with these exceptions:

- **`vault:status` / `vault:unseal`** when nodes reboot. Vault's raft replicas
  reseal on restart and need the unseal pass replayed:
  ```bash
  task -d seed/talos vault:status
  task -d seed/talos vault:unseal
  ```
- **Stage 07** when you add a new ExternalSecret that needs a new kv path.
- **Talos upgrades** — but **NOT** by changing `var.talos_version`. Use
  `talosctl upgrade --image factory.talos.dev/metal-installer/<schematic-id>:<new-version>`
  one node at a time. See the upgrade footgun note in `02-proxmox-provision/main.tf`.
- **Kubernetes upgrades** — `talosctl upgrade-k8s --to <version>`, after
  checking Cilium supports it.

## Backup checklist

Before you tear down the workstation that ran bootstrap, make sure these are
in Bitwarden (or equivalent):

- [ ] `seed/talos/shared/secrets.auto.tfvars`
- [ ] All `seed/talos/states/*.tfstate` (especially `03-talos-configure.tfstate` — contains cluster PKI)
- [ ] `seed/talos/03-talos-configure/secrets/talosconfig.yaml`
- [ ] `seed/talos/03-talos-configure/secrets/kubeconfig.yaml`
- [ ] `seed/talos/06-vault-init/secrets/vault-init.json`

Without these, recovery from a workstation loss requires rebuilding the
cluster from scratch.
