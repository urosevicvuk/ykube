# Rebuild plan: bare-metal NixOS + RKE2

> **Status (2026-11-26):** decided, and the code for phases 1–3 is written
> and tested in VMs (see [Testing](#testing)). Nothing is deployed yet: the
> hosts are being moved to the office. Supersedes the Proxmox + Talos design
> in [`seed/talos/`](../talos/README.md), which is retired once this cluster
> is up. The live cluster is still k3s on `firelink`
> ([`seed/k3s/`](../k3s/README.md)) until the migration in phase 5.
> Runbook: [`README.md`](README.md). First install, step by step:
> [`INSTALL.md`](INSTALL.md).

## Decision

Three bare-metal NixOS hosts, each one an **RKE2 server**: control plane,
etcd member and workload node. **CIS-hardened from day one.** Everything
on the hosts is declared in `ynix`. Everything in the cluster is reconciled
from this repo by Argo CD, as before.

| Considered | Why not |
|---|---|
| Proxmox + Talos VMs | Three layers. Hosts aren't Nix. Kiln (the thesis) needs bare-metal NixOS hosts, and its numbers are meaningless under nested virtualisation. |
| NixOS + k3s | Fine, but RKE2 is equally well supported in nixpkgs (shared `rancher` module and test suite) and adds a kubeadm-style static-pod control plane plus a CIS profile, which matter for a commercial platform. Nothing k3s offers is used here. |
| NixOS + kubeadm | No nixpkgs module. Imperative `init`/`join`/`upgrade` outside Nix. High effort for production. Kept for **certification practice** in disposable VMs instead (phase 6). |
| NixOS `services.kubernetes` | Built around a single master (`etcdEndpoints` is just `masterAddress`), easyCerts not production-grade, no kubeadm layout. |

What this buys:

- **Nix all the way down.** Reinstall any host with `nixos-anywhere`. Every
  hardware quirk (NIC names, fan control, mesh, DNS) is a module, not a
  runbook.
- **Upstream Kubernetes, kubeadm-shaped.** Static pods in
  `/var/lib/rancher/rke2/agent/pod-manifests`, etcd as a static pod,
  `crictl`/`etcdctl` preconfigured, so daily operation matches what CKA/CKS
  test.
- **A path to Kiln.** The same hosts later run KubeVirt (phase 7) and Kiln
  (thesis), side by side with RKE2.

## Target architecture

```
          kiln1                      kiln2                      kiln3
   x3650 M5 (IMM2)            x3650 M5 (IMM2)            DL380 Gen9 (iLO 4)
  ┌──────────────────┐       ┌──────────────────┐       ┌──────────────────┐
  │ NixOS            │       │ NixOS            │       │ NixOS            │
  │ rke2-server      │       │ rke2-server      │       │ rke2-server      │
  │  cp + etcd + wl  │       │  cp + etcd + wl  │       │  cp + etcd + wl  │
  │ Ceph OSDs (JBOD) │       │ Ceph OSDs (JBOD) │       │ Ceph OSDs (HBA)  │
  │ mesh0 10.10.0.1  │═══════│ mesh0 10.10.0.2  │═══════│ mesh0 10.10.0.3  │
  │ lan0 192.168.1.11│  25G  │ lan0 192.168.1.12│  25G  │ lan0 192.168.1.13│
  └────────┬─────────┘       └────────┬─────────┘       └────────┬─────────┘
           │  ╚════════════ 25G DAC (kiln1 ↔ kiln3) ═══════════╝  │
           └─────────── 1G ───────────┴─────────── 1G ────────────┘
                  office LAN 192.168.1.0/24 (placeholder, TODO on-site)
                  API VIP 192.168.1.10 (keepalived) · Cilium LB pool .2-.9
```

| Concern | Choice |
|---|---|
| OS | NixOS from `ynix` (nixos-unstable), LTS kernel (`pkgs.linuxPackages`) |
| Install | `nixos-anywhere` + `disko`. Works straight over SSH from any Linux on the box (kexec), so no USB needed. |
| Deploy | `nixos-rebuild switch --flake .#kilnN --target-host vyke@kilnN --sudo`, **one host at a time** |
| Kubernetes | `services.rke2`, `package = pkgs.rke2_1_36` (Cilium 1.20 is tested up to 1.36), `role = "server"` on all three |
| Hardening | `cisHardening = true` (`--profile=cis`, etcd user, kernel params) |
| Pod Security | Own admission config: enforce `baseline` by default, audit/warn `restricted`, `kube-system` exempt. (The CIS default would enforce `restricted` on every unlabelled namespace.) Namespaces that need more label themselves `privileged`. |
| CNI | `cni = "none"`; Cilium installed by `seed/rke2`, then owned by Argo |
| kube-proxy | Disabled (`disable-kube-proxy`); Cilium kube-proxy replacement. Cilium reaches the API on each node's own `127.0.0.1:6443`. |
| Bundled charts | Disable `rke2-ingress-nginx` (Envoy Gateway instead). **Keep** `rke2-coredns`, `rke2-metrics-server`, and `rke2-snapshot-controller` (+ CRD + webhook), which Ceph CSI and CNPG volume snapshots need. |
| Control-plane endpoint | keepalived VIP on `lan0`, unicast VRRP between the three nodes. A node holds it only while its own API server accepts connections. `tls-san` = VIP + hostnames + LAN/mesh IPs |
| Node IPs | `node-ip` = mesh address (10.10.0.x); `node-external-ip` = LAN address |
| Zone labels | `node-label = topology.kubernetes.io/zone=kilnN` (failure domain = host) |
| Site addressing | All addresses (host LAN IPs, gateway, DNS, API VIP) live in **one** file, `ynix/modules/sites/office.nix`; the Cilium LB pool is `apps/system/networking/cilium/lb-ip-pool.yaml`. Both are placeholders until the office LAN is known. |
| etcd backups | RKE2 built-in: every 6 h, 28 kept locally, plus `etcd-s3-*` to **Cloudflare R2** once enabled (`ykube.cluster.etcdS3`). Verify RKE2's S3 client against R2 in phase 2. |
| Off-site backups | Cloudflare R2 (S3-compatible, no egress fees, which matters on restore): etcd snapshots, CNPG `barmanObjectStore` backups, later Velero/restic for PVC data. One bucket per purpose, scoped API tokens. |
| Secrets on hosts | sops-nix (`ynix/secrets/kiln/cluster.yaml`): the RKE2 cluster token now; R2 credentials for etcd snapshots later. Decrypted with each host's SSH host key. |
| Images | `services.rke2.images` = the core air-gap tarball, so the control plane needs no registry pull at boot |

### The mesh

Same 25G triangle as the Talos design: each host's two DAC ports form one L2
segment `10.10.0.0/24` with MTU 9000. Three hosts in a triangle make a loop,
so spanning tree blocks one cable.

**Linux kernel bridge with STP**, declared with systemd-networkd
(`ynix/modules/features/kiln/network.nix`). The first version used Open
vSwitch with RSTP (the Proxmox wiki recipe), but in the VM test the OVS bridge
never delivered frames from the mesh ports to its own internal port, so the
nodes couldn't reach each other, whether with RSTP, classic STP or no spanning
tree at all. A plain kernel bridge on the same virtual cables worked first time.

The price is classic STP instead of RSTP: after a cable failure the blocked
link opens after max-age + 2 × forward-delay. The timers are tuned to the
kernel's minimum (hello 1 s, max-age 6 s, forward-delay 4 s). In the VM test
failover took **22 s**, a worst case because a VM link going down doesn't
drop carrier on the far end. A real DAC pull drops it on both ends, so expect
less. Meanwhile etcd keeps quorum through the third node; Ceph's OSD heartbeat
grace is 20 s, so OSDs on the cut pair may be marked down briefly and come
back. If that matters in practice: RSTP on the kernel bridge via `mstpd`.

Why still L2: Cilium native routing with `autoDirectNodeRoutes` and Ceph's
cluster network both want every node directly reachable on one subnet.
Later, KubeVirt VMs (phase 7) can bridge onto it too. A routed mesh (all
three links active) stays a possible later optimisation, not needed: one
25G path between any pair is far more than the disks can fill.

### Storage

- **OS + etcd:** each host's boot disk (kiln1: the Samsung PM963 NVMe,
  447 GB). disko layout: ESP 1G + LVM with `/` 64G and the rest as
  `/var/lib/rancher` (etcd, images). No swap.
- **Ceph:** every other data disk, **raw**. x3650 M5: ServeRAID M5210 in
  JBOD mode (UEFI → System Settings → Storage → controller → JBOD). DL380
  Gen9: Smart Array in **HBA mode** (System Utilities → Smart Array config).
  Delete old RAID volumes and wipe the disks (`wipefs -a`, `sgdisk --zap-all`).
  kiln1 currently has an 837 GB M5210 RAID volume with old partitions, which
  needs breaking up.
- Rook-Ceph on host networking bound to the mesh, failure domain `zone`
  (= host).
- **Separate pools by disk type.** The hardware is mixed: 900 GB SAS HDDs,
  some smaller SSDs, and bigger HDDs to be added later. Ceph labels every
  OSD `hdd` or `ssd`, and each pool is pinned to one type. A mixed pool runs
  every write at HDD speed.

  | StorageClass | Device class | Copies | Used by |
  |---|---|---|---|
  | `ceph-block` (default) | hdd | 3 | Immich library, OpenCloud, Forgejo repos, n8n data |
  | `ceph-block-2x` | hdd | 2 | Harbor registry, Immich ML cache, ntfy, Stirling-PDF |
  | `ceph-block-ssd` | ssd | 2 | every CNPG Postgres, Vault, Prometheus/Alertmanager/Grafana, Loki, Tempo, Pyroscope |
  | `ceph-bucket` (EC 2+1) | hdd | 1.5x | S3 |

  The SSD tier keeps 2 copies because the SSDs are small, and everything on
  it is already replicated by its app (CNPG replica, Vault raft) or
  regenerable. Don't use an SSD as DB/WAL device for the HDDs: one SSD
  failure would take every HDD OSD behind it down with it.
- **Capacity is bounded by the smallest host**, because each pool keeps one
  copy per host. Spread the 900 GB disks evenly and buy new HDDs in sets of
  three. Example: 2 × 900 GB HDD per host gives ≈1.4 TB usable on a 3x pool
  after Ceph's ~15–20% safety headroom. OSDs: every empty `sdX` (the
  `deviceFilter`); switch to explicit `/dev/disk/by-id` lists per node once
  the disks are inventoried.

## What was built (2026-11-26)

### `ynix`

```
modules/features/kiln/
  options.nix          ykube.cluster.* (addresses, node table, versions, token, etcd S3)
                       ykube.node.*    (name, zone, NICs by MAC/PCI path, boot disk, reservations)
  network.nix          networkd: NIC renaming (.link), lan0, kernel-bridge STP mesh, firewall
  rke2.nix             services.rke2 (pinned, CIS, cni none, PSA config, metrics, snapshots),
                       keepalived VIP, kernel modules (rbd ceph), sysctls, crictl/etcdctl env
  disk.nix             disko layout for the boot disk
  node.nix             kilnNode = core + disk + ynix base (users, ssh, nix, tailscale, shell) + sops
                       + guard: refuses to build until ykube.node.factsVerified = true
  _collect-facts.sh    prints NIC MACs/paths and disk IDs from a live machine
modules/hardware/
  server.nix           IPMI, watchdog, rasdaemon, smartd, tooling
  x3650m5.nix          initrd modules + kiln-fanctl service (CPU-driven fan curve)
  _kiln-fanctl.sh      the fan controller (from seed/hosts/x3650-m5, now with tests)
  dl380g9.nix          initrd modules (hpsa); fan behaviour TBD after install
modules/sites/office.nix     all site addresses (placeholders)
modules/hosts/kiln{1,2,3}/   host definitions (kiln1 facts from Proxmox, kiln2/3 TODO)
modules/checks/kiln.nix      the tests below
secrets/kiln/cluster.yaml    RKE2 token (sops; add host keys before install, see README there)
```

The k3s module (`features/server/cluster.nix`) stays for firelink until
phase 5. The kiln modules fix its problems: no world-readable kubeconfig,
pinned package, HA join via the VIP, Ceph kernel modules instead of
iSCSI/NFS, firewall for the mesh, kubelet reservations, LTS kernel.

### `ykube`

| Path | Change |
|---|---|
| `seed/rke2/` | New bootstrap (Taskfile + scripts): kubeconfig → CRDs → Cilium → Argo CD → Vault init/unseal/configure → bootstrap secrets, plus `check`. Versions are read from the same kustomizations Argo reconciles. |
| `apps/system/networking/cilium/` | Talos specifics removed. `k8sServiceHost: 127.0.0.1:6443`, `devices: [lan0, mesh0]`, L2 announcements on `lan0` from any node. New `kube-system-allow-cluster.yaml`: RKE2's CIS NetworkPolicy only admits same-namespace traffic into kube-system. |
| `apps/system/storage/rook-ceph/` | Pools pinned to `hdd`/`ssd`, new `ceph-block-ssd` class, bare-metal comments. |
| CNPG clusters, Vault, observability | Moved to `ceph-block-ssd`. |
| `apps/system/observability/kube-prometheus-stack/` | Control-plane scraping for RKE2 (chart defaults: `component=` labels, etcd metrics on `:2381`). |
| Comments | Talos/Proxmox references updated across apps. |
| `seed/talos/`, `seed/talos/PROXMOX.md` | Still there. Delete once phase 4 passes. |

## Testing

All in `ynix`, runnable on any x86_64 machine with KVM:

| Check | What it proves | Result |
|---|---|---|
| `checks.x86_64-linux.kiln-fanctl` | Fan curve and every safety rule (11 cases), shellcheck | pass |
| `checks.x86_64-linux.kiln-hosts` | kiln1-3 evaluate fully (types, assertions, disko, sops) | pass |
| `checks.x86_64-linux.kiln-mesh` | 3 VMs wired as the real triangle: NIC renaming by MAC, bridge + STP converges with exactly one blocked port (not on the root), jumbo MTU end to end (as far as the test network carries), names, cable cut → reroute via the third node → re-block when back | pass (failover 22 s) |
| `checks.x86_64-linux.kiln-rke2` | 3 VMs: kiln1 bootstraps and takes the VIP, kiln2/3 join through it, CIS profile, static-pod control plane on every node, no kube-proxy, etcd 3 members peering on the mesh as user `etcd`, node IPs/labels, PSA rejects privileged pods by default, etcd snapshot, VIP fails over when kiln1 crashes | pass (bootstrap ~3.5 min, joins ~4 min) |

The RKE2 test overrides three things for the 2-core, 2.5 GB test VMs, and
each one was a real failure first: kubelet reservations and the eviction
threshold (production values left too little memory to admit the API
server), and the mesh MTU (the test network drops frames much over 1500
bytes, which silently black-holed etcd's TLS handshakes until the mesh MTU
matched it). Production keeps 9000 and the server-sized reservations.

Not testable in VMs, checked on hardware in phase 1/2: 9000-byte frames on
the real DACs (if `ping -M do -s 8972` fails anywhere, etcd joins will hang
exactly like in the test, so check this before RKE2), PCI-path NIC renaming,
disko on the real boot disks, the fan service, etcd snapshots to R2.

Seen in the test, harmless with internet access: before RKE2 finishes
importing its air-gap image bundle, the kubelet tries to pull the `pause`
image from Docker Hub once.

In `ykube`: shellcheck on `seed/rke2/scripts`, `kustomize build --enable-helm`
of every changed app (renders Cilium against its values schema), and the
kubeconfig/version helpers against real data.

## Phases

Each phase has an exit check. Don't start the next one until it passes.

### 0. Hardware prep (per host)

- BIOS/UEFI: virtualisation on, power-restore = on, operating mode
  *Efficiency – Favor Performance* (M5), UEFI boot.
- RAID → JBOD (M5) / HBA mode (Gen9). Old volumes deleted, disks wiped.
- Management controller on the network with a static IP (IMM2 dedicated
  port; iLO 4 dedicated port).
- Cabling: 1G LAN per host + 25G DAC triangle.
- Office LAN: check the DHCP range, then pick the 3 host IPs, the API VIP and
  the Cilium LB pool outside it. Put them in `ynix/modules/sites/office.nix`
  and `apps/system/networking/cilium/lb-ip-pool.yaml`.

**Exit:** all disks visible individually (model/serial) from a live Linux.
Management controllers reachable. IP plan written into `ynix`.

### 1. NixOS on the hosts (no Kubernetes yet)

- Per host: run `_collect-facts.sh`, fill in `modules/hosts/kilnN`, set
  `factsVerified = true`; pre-generate the SSH host key and add it to sops
  (`ynix/secrets/kiln/README.md`); `nixos-anywhere --flake .#kilnN
  --extra-files <dir> root@<ip>`.

**Exit:**

- `ssh kilnN` works and the hosts resolve each other.
- `bridge link show` across the three hosts: exactly one port `blocking`.
- `ping -M do -s 8972 10.10.0.x` works between all pairs.
- Fans quiet on the M5s (`journalctl -u kiln-fanctl`), and the DL380 fan
  behaviour has been looked at.

### 2. RKE2 HA

RKE2 starts with the system: kiln1 (`bootstrapNode`) creates the cluster,
kiln2/3 join through the VIP. Then set `bootstrapNode = null` and redeploy
kiln1.

**Exit:**

- `kubectl get nodes` shows 3 nodes (NotReady until there's a CNI, which is expected).
- `crictl ps` on each host shows etcd, kube-apiserver, scheduler and
  controller-manager static pods.
- `etcdctl member list` shows 3 members (the env is preset on the hosts).
- The API still answers on the VIP with kiln1 powered off.
- An etcd snapshot has been taken and uploaded off-cluster.

### 3. Bootstrap the platform

`API_VIP=… task -d seed/rke2 kubeconfig`, then `task -d seed/rke2
cluster:bootstrap`, then `task -d seed/rke2 check`.

**Exit:**

- `cilium status` all green, KubeProxyReplacement on.
- Argo CD syncing all AppSets.
- Vault initialised and unsealed, and `vault-init.json` stored in Bitwarden.
- `ceph status` HEALTH_OK, `ceph osd tree` shows 3 zones.
- No Pod Security rejections in events.

### 4. Prove failure handling

- Drain and reboot each host in turn (Ceph `noout`, Vault unseal).
- Pull one DAC (mesh failover; time it against the 22 s from the VM test).
- Power off a whole host (Ceph degraded but serving, etcd quorum held, API on the VIP).
- Restore etcd from a snapshot into a scratch cluster (proves the backups are usable).

**Exit:** all four done without data loss. Runbooks written for each.

### 5. Migrate from firelink

- Copy the Vault values that must not change (`seed/rke2/scripts/05-vault-secrets.sh`
  lists them: n8n encryption key, OpenCloud service account, …).
- Postgres (CNPG): restore from backups or `pg_dump` into the new cluster's CNPG.
- PVC data (Immich, OpenCloud, Vaultwarden, Forgejo, …): copy with
  restic/rsync while the app is scaled to zero on firelink.
- Cut-over: stop firelink's external-dns and cloudflared, then let the new
  cluster take the records (same `txtOwnerId`) and the tunnel. Keep firelink
  read-only for a week as the fallback.

**Exit:** all tenants served from the new cluster. firelink's k3s
disabled. `cluster.nix` removed from `ynix`.

### 6. CKA/CKS lab (any time after phase 1)

A small flake (in `ynix` or its own repo) that starts **three disposable
NixOS VMs with kubeadm, kubelet and containerd pinned**, via microvm.nix on
a kiln host (with cgroup limits) or plain QEMU on the laptop.
`lab up/down/reset`. Practise there, never on production:

- `kubeadm init`/`join`, HA control plane, `kubeadm upgrade` across minor versions
- `etcdctl snapshot save/restore`, `kubeadm certs renew`
- Broken kubelet / static pod / CNI troubleshooting
- RBAC, NetworkPolicy, PSA. For CKS: AppArmor, seccomp, audit logs, Falco,
  image scanning

### 7. Later

- **KubeVirt** via Argo: VMs as a product (rentable, Windows), Ceph RBD
  disks, live migration. Multus + bridge on the LAN for VMs that need
  their own IPs.
- **Kiln** (thesis): phases 0–2 on one host with strict cgroup limits.
  Risky kernel/DAX experiments on off-cluster hardware. Phase 4 across all
  three hosts, with KubeVirt as the image-based baseline.

## Operations (steady state)

| Task | How |
|---|---|
| OS update | `nix flake update` in `ynix` → rebuild one host at a time: drain, Ceph `noout`, switch, reboot if needed, uncordon, `noout` off, Vault unseal |
| Kubernetes minor upgrade | Bump `rke2Package` (`rke2_1_36` → `rke2_1_37`, one minor at a time, after checking Cilium/Rook support) → same rolling procedure, kiln1 first |
| App changes | Git → Argo, unchanged |
| etcd backup | Automatic snapshots (+ R2 once enabled). Restore drill in phase 4 and yearly after |
| Host reinstall | `nixos-anywhere` → RKE2 rejoins with the token → Rook re-creates that host's OSDs |

## Open decisions

- [ ] Office addressing: host IPs, API VIP and LB pool, outside the office DHCP range (on-site, into `ynix/modules/sites/office.nix` and `lb-ip-pool.yaml`)
- [ ] Ceph disks per host: inventory the 900 GB SAS HDDs and SSDs, spread evenly; later HDD purchases in sets of three
- [ ] DL380 Gen9: boot disk, Smart Array model (HBA mode support), NIC layout, fan behaviour with third-party cards
- [x] Off-site backup target: Cloudflare R2 (buckets + scoped tokens to create; RKE2 etcd-S3 compatibility to verify)
- [ ] Keep `rke2-metrics-server` or let kube-prometheus-stack's adapter replace it
- [ ] Mesh failover: accept classic STP's ~15-22 s, or add RSTP via mstpd after measuring on the DACs
- [ ] Whether to keep this branch (`feat/talos-multinode`) and rework it, or start `feat/nixos-rke2` from `main` and carry over the app changes (CNPG/PVC/Ceph storage classes) that are platform-independent
