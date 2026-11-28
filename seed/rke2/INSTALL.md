# Install: NixOS ISO → three-node cluster

The ordered, do-this-then-that version of [`PLAN.md`](PLAN.md) phases 0–3:
from a NixOS USB stick in each box to Argo CD reconciling this repo on
kiln1-3. Every step ends with a check. Don't move on until it passes.

Conventions:

- `ws$` runs on your workstation, `iso#` on a host booted from the ISO (as
  root), and `kiln1$` on an installed host as `vyke`.
- `<iso-ip>` is the DHCP address the ISO gets; `<kilnN-ip>` is the static
  address from `ynix/modules/sites/office.nix`.
- ynix is at `~/Projects/urosevicvuk/ynix`, ykube at `~/Projects/urosevicvuk/ykube`.

Rough time: half a day on site for steps 1–4, about an hour for 5–8, and
step 9 depends on how long Argo takes to pull everything.

---

## 0. Before you go (at home)

**0.1 Make the new ynix files visible to the flake.** Flakes only see files
git tracks, and everything under `modules/features/kiln/`, `modules/hosts/kiln*`,
`modules/hardware/`, `modules/sites/`, `modules/checks/` and `secrets/kiln/` is
still untracked. Staging is enough; it doesn't have to be committed:

```bash
ws$ cd ~/Projects/urosevicvuk/ynix
ws$ git add modules/features/kiln modules/hosts/kiln{1,2,3} modules/hardware \
            modules/sites modules/checks secrets/kiln modules/infra/sops.nix
ws$ nix flake check --no-build      # evaluates; kiln hosts fail the factsVerified guard, that's expected
```

(Without staging, use `--flake path:.#kilnN` everywhere below.)

**0.2 Fix the `.sops.yaml` path.** `modules/infra/sops.nix` line 25 writes it
to `~/Projects/personal/ynix/`, so this checkout's `.sops.yaml` is a dangling
link and `sops updatekeys` in step 4 would find no rules. Change it to
`Projects/urosevicvuk/ynix` and rebuild your workstation.

**0.3 Decide how the new cluster tracks Git.** This matters before step 8.
`root/app-of-apps.yaml` and every `appsets/*.yaml` point at `main`, and
firelink reconciles `main` too. So:

- If the RKE2 app changes (Cilium devices, `ceph-block-ssd`, …) are merged to
  `main`, firelink applies them as well, and they break it.
- If they aren't on `main`, the new cluster gets firelink's config.

**Recommended:** put the new cluster on its own branch until the cutover (PLAN
phase 5):

```bash
ws$ cd ~/Projects/urosevicvuk/ykube
ws$ git switch -c feat/nixos-rke2          # or keep feat/talos-multinode, see PLAN "Open decisions"
ws$ sed -i 's/\(targetRevision\|revision\): main$/\1: feat\/nixos-rke2/' root/app-of-apps.yaml appsets/*.yaml
ws$ git diff --stat                        # app-of-apps + 6 appsets, 13 lines (raf-external pins its own tag, untouched)
# commit + push this branch before step 8; at cutover, merge to main and flip them back
```

**0.4 Things to bring or prepare:**

- A USB stick with the **NixOS minimal ISO** (current unstable or 25.11; the
  ISO's version doesn't matter, because nixos-anywhere installs the flake's
  system):
  `ws$ sudo dd if=nixos-minimal-*.iso of=/dev/sdX bs=4M status=progress oflag=sync`
- The workstation on the office LAN (or a laptop with this repo, the ynix
  checkout, your age key and `nix develop` working).
- A monitor and keyboard (or IMM2/iLO remote console) for the ISO's first
  minute on each box.

---

## 1. Firmware, per host (on site)

Details per model are in PLAN phase 0. What must be true before booting the
ISO:

| | x3650 M5 (kiln1, kiln2) | DL380 Gen9 (kiln3) |
|---|---|---|
| Boot mode | UEFI only (disko makes a GPT + ESP) | UEFI only |
| RAID controller | ServeRAID M5210 → **JBOD**, old volumes deleted (kiln1 still has an 837 GB volume) | Smart Array → **HBA mode** |
| Virtualisation | VT-x + VT-d on | VT-x + VT-d on |
| Power | Restore on power loss = on; *Efficiency – Favor Performance* | Restore = on; *Static High Performance* |
| Management | IMM2 dedicated port, static IP | iLO 4 dedicated port, static IP |

Cabling: one 1G LAN cable per host, and the 25G DAC triangle (each host's two
25G ports to the other two hosts).

**Check:** each management controller answers on its IP. In the controller
config, every Ceph disk shows up as its own JBOD/HBA disk.

---

## 2. Boot all three hosts from the ISO

All three at once, because step 3 tests the cables between them.

On each console (the ISO logs in as `nixos` automatically):

```bash
iso$ sudo -i
iso# passwd                               # temporary root password for SSH, the ISO only
iso# ip -4 addr                           # note <iso-ip> (DHCP on whichever port has the LAN cable)
iso# [ -d /sys/firmware/efi ] && echo UEFI || echo "LEGACY: fix firmware boot mode"
```

From the workstation:

```bash
ws$ ssh-copy-id root@<iso-ip>             # so nixos-anywhere doesn't ask for the password again
```

**Check:** `ssh root@<iso-ip>` works for all three, and each prints `UEFI`.

---

## 3. Facts, disks and cables (from the ISO)

**3.1 Hardware facts** (per host):

```bash
ws$ cd ~/Projects/urosevicvuk/ynix
ws$ ssh root@<iso-ip> 'bash -s' < modules/features/kiln/_collect-facts.sh | tee /tmp/facts-kilnN.txt
ws$ ssh root@<iso-ip> nixos-generate-config --no-filesystems --show-hardware-config | tee /tmp/hw-kilnN.nix
```

From the output, edit `modules/hosts/kilnN/configuration.nix`:

| Option | Take from facts |
|---|---|
| `ykube.node.bootDisk` | the boot disk's `/dev/disk/by-id/...` path (not `/dev/sda`, which can move) |
| `ykube.node.nics.lan.path` | `ID_PATH` of the port with `carrier=1` that got `<iso-ip>` |
| `ykube.node.nics.meshA.path`, `meshB.path` | `ID_PATH` of the two 25G ports (driver `mlx5_core` on the M5s) |
| `ykube.node.factsVerified` | `true`, only after the three above are filled in |

Compare `boot.initrd.availableKernelModules` in `/tmp/hw-kilnN.nix` with
`modules/hardware/x3650m5.nix` / `dl380g9.nix`, and add anything missing,
especially the storage and NIC drivers for kiln3, which was never checked.

**3.2 Wipe the Ceph disks** (per host). Rook only takes disks with no
partitions or filesystems. **Double-check the list against `bootDisk`; this is
irreversible.**

```bash
iso# lsblk -d -o NAME,SIZE,ROTA,MODEL,SERIAL
iso# for d in sdb sdc ...; do wipefs -a /dev/$d && sgdisk --zap-all /dev/$d; done
```

**3.3 Jumbo frames over every DAC.** This is the check that matters most. In
the VM test, a mesh claiming MTU 9000 over a path that dropped big frames made
etcd joins hang silently. Bring the 25G ports up at 9000 on **all three**
hosts, then from each host ping across each of its two cables. IPv6 link-local
needs no addressing:

```bash
iso# for p in <meshA-name> <meshB-name>; do ip link set $p mtu 9000 up; done   # on all three
iso# ping -6 -c3 -M do -s 8952 ff02::1%<meshA-name>     # 8952 + 48 header bytes = 9000
iso# ping -6 -c3 -M do -s 8952 ff02::1%<meshB-name>
```

**Check:** on every port, replies from one peer (`fe80::...`, besides your own
address), with no `message too long` and no loss. A port with no replies has a
bad or unseated cable; a port that answers small pings but not 8952 can't do
jumbo frames. Either way, fix it before installing. If jumbo frames can't work,
set `ykube.cluster.mesh.mtu = 1500` in `office.nix` instead.

**3.4 IP plan.** Read the office LAN off the ISO (`ip route`,
`resolvectl status`), find out the DHCP range, and pick three host addresses,
the API VIP and a Cilium LB range, all outside DHCP. Then write them into:

- `ynix/modules/sites/office.nix`: `gateway`, `nameservers`, `prefixLength`,
  `apiVip`, `nodes.kilnN.lanAddress`. Keep `bootstrapNode = "kiln1"`.
- `ykube/apps/system/networking/cilium/lb-ip-pool.yaml`: the LB range.

Make sure `vrrpRouterId` (51) isn't already used on that LAN. Office
routers/firewalls sometimes run VRRP:
`iso# tcpdump -c5 -ni <lan-if> vrrp` should show nothing for ~10 s.

**Check:**

```bash
ws$ nix build .#checks.x86_64-linux.kiln-hosts      # all three evaluate with the real facts
```

---

## 4. Host keys and the cluster token

The hosts decrypt the RKE2 token with their own SSH host key, so the key has
to exist, and the token has to be encrypted to it, before first boot.

```bash
ws$ K=~/.local/share/kiln-install; umask 077
ws$ for h in kiln1 kiln2 kiln3; do
      mkdir -p $K/$h/etc/ssh
      ssh-keygen -q -t ed25519 -N "" -C "root@$h" -f $K/$h/etc/ssh/ssh_host_ed25519_key
      echo "$h: $(ssh-to-age < $K/$h/etc/ssh/ssh_host_ed25519_key.pub)"
    done
```

1. Add the three `age1...` keys to the `secrets/kiln/` rule in
   `modules/infra/sops.nix`, and rebuild the workstation so `.sops.yaml`
   picks them up (step 0.2).
2. `ws$ sops updatekeys secrets/kiln/cluster.yaml`, then `git add` it.
3. Store the three private keys in Bitwarden. Delete `$K` after step 6.

**Check:** `ws$ grep -c 'recipient: age1' secrets/kiln/cluster.yaml` prints `4`
(you + 3 hosts).

---

## 5. Install kiln1 (creates the cluster)

One host at a time, kiln1 first: it's `bootstrapNode`, so it starts a new etcd
the moment it boots, and the others join through it.

```bash
ws$ cd ~/Projects/urosevicvuk/ynix
ws$ nixos-anywhere --flake .#kiln1 --extra-files ~/.local/share/kiln-install/kiln1 \
      --phases kexec,disko,install root@<kiln1-iso-ip>
```

`--phases` leaves out `reboot` so the new system is still mounted at `/mnt`.
The ISO is already NixOS, so kexec is skipped. Now give `vyke` a password.
The config has none, so without this sudo can't work, and root can't log in
over SSH:

```bash
ws$ ssh -t root@<kiln1-iso-ip> 'nixos-enter --root /mnt -c "passwd vyke"'
ws$ ssh root@<kiln1-iso-ip> reboot          # pull the USB stick (or fix boot order) first
```

It comes back on `<kiln1-ip>` (static, from `office.nix`), not the DHCP
address.

```bash
ws$ ssh vyke@<kiln1-ip>
kiln1$ systemctl is-active rke2-server keepalived kiln-fanctl   # rke2 can take 3-5 min on first boot
kiln1$ ip -br addr show lan0                  # <kiln1-ip> AND the API VIP
kiln1$ sudo -i
kiln1# kubectl get nodes                      # kiln1, NotReady (no CNI yet: expected)
kiln1# crictl ps                              # etcd, kube-apiserver, kube-scheduler, kube-controller-manager
kiln1# tailscale up                           # optional: reach the hosts from home
```

If `rke2-server` isn't active after ~10 min: `journalctl -u rke2-server -b`.
`sops-install-secrets` failing means the host key isn't in the recipients
(step 4).

**Check:** kiln1 listed (NotReady), VIP on kiln1, fans quiet.

---

## 6. Install kiln2, then kiln3 (join)

Same as step 5 with `kiln2`, wait for it to join, then `kiln3`. Don't join
both at once: etcd adds members one at a time.

```bash
ws$ nixos-anywhere --flake .#kiln2 --extra-files ~/.local/share/kiln-install/kiln2 \
      --phases kexec,disko,install root@<kiln2-iso-ip>
ws$ ssh -t root@<kiln2-iso-ip> 'nixos-enter --root /mnt -c "passwd vyke"'
ws$ ssh root@<kiln2-iso-ip> reboot
```

Watch the join from kiln1:

```bash
kiln1# watch kubectl get nodes                # kiln2 appears within a few minutes
kiln1# etcdctl member list -w table           # 2 members, peer URLs on 10.10.0.x
```

A join stuck on `MemberAdd request timed out` / TLS handshake errors in
`journalctl -u rke2-server` on kiln2 means big frames are being dropped on the
mesh. Go back to 3.3.

Then kiln3 the same way.

**Check (all three up):**

```bash
kiln1# kubectl get nodes -o wide              # 3 nodes, INTERNAL-IP 10.10.0.x, EXTERNAL-IP the LAN address
kiln1# etcdctl member list -w table           # 3 members
kiln1# bridge link show                       # on the three hosts together: exactly one port "blocking"
kiln1# ping -c3 -M do -s 8972 kiln2-mesh; ping -c3 -M do -s 8972 kiln3-mesh
```

---

## 7. Retire the bootstrap flag

kiln1 must stop being `bootstrapNode`. If it lost its etcd data later, it
would otherwise start a second, empty cluster instead of rejoining.

In `ynix/modules/sites/office.nix`: `bootstrapNode = null;`, then:

```bash
ws$ nixos-rebuild switch --flake .#kiln1 --target-host vyke@<kiln1-ip> --sudo --ask-sudo-password
```

This restarts `rke2-server` on kiln1 with `--server https://<VIP>:9345`. The
VIP moves to kiln2 for the ~1 min kiln1's API is down, then back. kiln2/3
don't change (they already have `serverAddr`), so they don't need a rebuild.

**Check:** `etcdctl member list` still 3, and `kubectl get nodes` from kiln2
works throughout. Then the failover test from PLAN phase 2: power kiln1 off,
`kubectl --server https://<VIP>:6443 get nodes` from kiln2 still answers,
power kiln1 back on.

Also take one etcd snapshot by hand: `kiln1# rke2 etcd-snapshot save`, then
`rke2 etcd-snapshot ls`.

---

## 8. Platform bootstrap (from the workstation)

Before you start:

- The ykube branch from step 0.3 is **pushed**, with the real
  `lb-ip-pool.yaml` in it. Argo deploys what's on GitHub, not your checkout.
- Ceph disks wiped (3.2).
- **No second copy of public traffic.** Until the cutover (PLAN phase 5),
  firelink serves the tunnel and owns the DNS records. When step 05 prompts
  for the **cloudflared credentials** and the **external-dns token**, give it
  placeholders (an empty `{}` JSON file, a dummy token). If it gets the real
  ones, Cloudflare load-balances visitors onto a cluster with empty apps.
  Those two pods crash-loop until the cutover, which is fine. Everything
  else can be real.

```bash
ws$ cd ~/Projects/urosevicvuk/ykube && nix develop
ws$ API_VIP=<vip> NODE=<kiln1-ip> task -d seed/rke2 kubeconfig   # sudo asks vyke's password
ws$ export KUBECONFIG=$PWD/seed/rke2/secrets/kubeconfig.yaml
ws$ task -d seed/rke2 cluster:bootstrap      # 01 CRDs → 02 Cilium → 03 Argo CD → 04 Vault init → 05 secrets
```

Right after stage 04: **copy `seed/rke2/secrets/vault-init.json` into
Bitwarden.** Every reboot needs those unseal keys.

Stage 04 waits for Vault, which Argo can only schedule once Ceph is up
(Vault's volumes are `ceph-block-ssd`). If it sits there, look at
`kubectl -n rook-ceph get pods` and `kubectl -n argocd get applications`.

---

## 9. Done when

```bash
ws$ task -d seed/rke2 check
```

plus, by eye:

- `cilium status`: all OK, KubeProxyReplacement True.
- `kubectl -n argocd get applications`: everything Synced/Healthy, except
  cloudflared and external-dns (placeholders until cutover).
- `kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status`:
  HEALTH_OK, OSDs from all three hosts. `ceph osd tree` shows 3 zones.
  `ceph osd crush class ls` shows `hdd` and `ssd`.
- `vault status` on all three replicas: unsealed (`task -d seed/rke2 vault:status`).
- `kubectl get events -A | grep -i 'violates PodSecurity'`: nothing.

That's the end of PLAN phase 3. Next come the failure drills (phase 4), then
the firelink migration and cutover (phase 5).

---

## When something goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `nixos-anywhere`: "does not provide attribute" | flake can't see untracked files | step 0.1 (`git add`) or `--flake path:.#kilnN` |
| Build fails on `factsVerified is false` | facts not filled in | step 3.1 |
| Host boots but no network | wrong `nics.lan.path` | console in: `networkctl`, `ip link`; compare `udevadm info /sys/class/net/* \| grep ID_PATH` |
| `sops-install-secrets` failed, rke2 has no token | host key not a recipient | step 4, then `nixos-rebuild switch` that host |
| `sudo` refuses | password not set | the host's ISO step was skipped: boot the ISO, `mount /dev/sys/root /mnt`, `nixos-enter --root /mnt -c "passwd vyke"` |
| Join hangs, etcd `MemberAdd` timeouts | MTU black hole on the mesh | step 3.3; temporary workaround `mesh.mtu = 1500` |
| Two nodes both hold the VIP | VRRP traffic blocked between them on the LAN, or router ID clash | `tcpdump -ni lan0 vrrp` on both; change `vrrpRouterId` |
| Fans ramp up on an M5 | `kiln-fanctl` stopped (stop resets the IMM to auto) | `journalctl -u kiln-fanctl` |
| Reinstalling one host later | | delete the node (`kubectl delete node`, `etcdctl member remove`), wipe its Ceph OSDs out of Rook, then steps 3–6 for that host only; `bootstrapNode` stays `null` |
