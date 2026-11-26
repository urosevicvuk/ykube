# Proxmox VE 9.2: from ISO to a three-node cluster

This guide takes three blank machines and leaves them as **one Proxmox VE 9.2
cluster** that meets every item on the [`README.md`](README.md) *Prerequisites*
list. After that, `task -d seed/talos cluster:bootstrap` builds the Talos and
Kubernetes layers.

Everything here runs once per host, by hand. Proxmox itself isn't managed by
OpenTofu in this repo. Only the VMs on top of it are.

```
 Phase 0  Plan              names, IPs, disks — decide before touching anything
 Phase 1  Prepare           BIOS/UEFI, USB stick
 Phase 2  Install           ×3, identical except hostname/IP
 Phase 3  First boot        reach :8006, repos, full-upgrade, SSH keys
 Phase 4  Networking        verify vmbr0, build the vmbr1 25G mesh
 Phase 5  Storage           confirm datastore names, wipe Ceph disks
 Phase 6  Cluster           create on pve-1, join pve-2 and pve-3
 Phase 7  Verify            the checklist that gates the Talos bootstrap
 Phase 8  Day-2             updates, reboots, what NOT to turn on
 Appendix                   troubleshooting (incl. "can't reach :8006")
```

### What's in 9.2

| Component | 9.2 default |
|---|---|
| Base OS | Debian 13.5 "Trixie" |
| Kernel | Linux 7.0 |
| QEMU / LXC / ZFS | 11.0 / 7.0 / 2.4 |
| Ceph (Proxmox-managed) | Tentacle 20.2 (Squid 19.2 still available) |

New in 9.2: a dynamic cluster load balancer, WireGuard as an SDN fabric
protocol, BGP/EVPN route maps, custom CPU models in the GUI, HA arm/disarm,
and enrollment of the Microsoft UEFI 2023 Secure Boot certificates.
**This setup needs none of them.** We don't use Proxmox HA, Proxmox Ceph or
SDN, because Kubernetes and Rook already handle HA and storage inside the VMs.

---

## Phase 0: Plan before you install

Some choices are hard or impossible to change once a node joins a cluster.
Write them down first.

### 0.1 Names (can't be changed later)

| Host | Hostname (FQDN in installer) | Proxmox node name |
|---|---|---|
| 1 | `pve-1.home.arpa` | `pve-1` |
| 2 | `pve-2.home.arpa` | `pve-2` |
| 3 | `pve-3.home.arpa` | `pve-3` |

- The node name is the part before the first dot. It has to match `pve_node`
  in `shared/secrets.auto.tfvars` **exactly**, because it becomes the
  `topology.kubernetes.io/zone` label that Ceph and Vault spread across.
- Renaming a node after it joins a cluster is a manual, error-prone
  procedure. Get it right in the installer.
- `home.arpa` is the reserved domain for home networks. Any domain works,
  as long as it's not one you use publicly.
- **Cluster name:** `ykube` (or anything). It also can't be changed after
  creation.

### 0.2 IP plan

Your LAN is `192.168.0.0/24` with the router at `192.168.0.1`. Find the
router's DHCP pool range first. Everything below must be **outside** it, or
reserved by MAC.

| What | Address | Notes |
|---|---|---|
| pve-1 management | `192.168.0.5/24` | static, on `vmbr0` |
| pve-2 management | `192.168.0.6/24` | static, on `vmbr0` |
| pve-3 management | `192.168.0.7/24` | static, on `vmbr0` |
| Gateway / DNS | `192.168.0.1` | |
| pve-1/2/3 mesh | `10.10.0.1` / `.2` / `.3` | on `vmbr1`, set up in Phase 4 |
| Talos controlplanes (mesh) | `10.10.0.11-13` | set by stage 03 |
| Talos workers (mesh) | `10.10.0.21-26` | set by stage 03 |
| 9 Talos LAN IPs | DHCP-reserved by MAC | README one-time setup, step 4 |
| Talos API VIP | one free LAN IP outside DHCP | `talos_cluster_vip` |
| Cilium LB pool | a free range outside DHCP | `apps/system/networking/cilium/lb-ip-pool.yaml` |

### 0.3 Disks, per host

Every host needs:

1. **A boot/OS disk** for Proxmox itself and the VMs' OS and EFI disks
   (the `local-lvm` or `local-zfs` datastore). An SSD with at least 256 GB
   is comfortable. The 3 VMs per host need about 250 GB together (50 + 100 + 100).
2. **One or more Ceph disks.** These are whole disks passed through to the
   two worker VMs. Proxmox must **not** use them for anything.
   Keep the total Ceph capacity about the same on all three hosts.

Decide which physical disk is which **before** installing. Note model and
serial number. The installer shows them, and picking the wrong target disk
erases it.

### 0.4 Choose a filesystem, the same on all three hosts

| Choice | Datastore for VM disks | When to pick it |
|---|---|---|
| **ext4 (LVM-thin)** | `local-lvm` | One boot disk. Matches the tfvars default, so there's nothing to change. |
| **ZFS RAID1** | `local-zfs` | Two boot disks and you want the OS mirrored. Set `proxmox_disk_datastore = "local-zfs"` in tfvars. |

**Use the same choice on all three hosts.** Storage config is cluster-wide.
When a node joins, its own `/etc/pve/storage.cfg` is replaced by the
cluster's. If pve-1 is ZFS and pve-2 is LVM, pve-2's `local-lvm` entry
disappears on join, and stage 02 fails because the datastore name differs
per host.

### 0.5 NICs, per host

Each host has (at least) three ports that matter:

| Port | Goes to | Used for |
|---|---|---|
| 1G onboard | router/switch | management (`vmbr0`), LAN/internet for VMs |
| 25G port A | DAC to next host | mesh (`vmbr1`) |
| 25G port B | DAC to the other host | mesh (`vmbr1`) |

With several NICs present, the installer may pick the wrong one as
management. **Write down the MAC address of the 1G port** (on a sticker,
in the BIOS, or from the switch's MAC table) so you can recognise it in the
installer's dropdown.

Cabling, a triangle:

```
pve-1 port B ──── pve-2 port A
pve-2 port B ──── pve-3 port A
pve-3 port B ──── pve-1 port A
```

The exact ports don't matter, since OVS/RSTP figures it out. Each host just
needs one DAC to each of the other two.

---

## Phase 1: Prepare the hardware and installer

### 1.1 BIOS/UEFI settings (each host)

- **Virtualisation:** Intel VT-x or AMD SVM **enabled**. Without it, KVM VMs
  won't start.
- **VT-d / AMD-Vi (IOMMU):** enabling it is harmless. This repo passes disks
  through with `qm set -scsiN /dev/disk/by-id/...`, which is *disk*
  passthrough and does **not** need IOMMU. You only need IOMMU if you later
  pass a whole PCIe device (HBA, NVMe controller, GPU) to a VM.
- **Boot mode:** UEFI. Secure Boot can stay on, since Proxmox ships signed
  bootloaders.
- **Restore on AC power loss:** *Power On*, so a power cut doesn't leave a
  host off.
- **Boot order:** USB first for the install, then the boot disk.
- Optional: turn off unused onboard devices (audio, serial) and set fans and
  power to taste.

### 1.2 Download and verify the ISO

From <https://www.proxmox.com/en/downloads>, get the **Proxmox VE 9.2 ISO
Installer** and its SHA256 checksum.

```bash
sha256sum proxmox-ve_9.2-*.iso   # must match the checksum on the download page
```

### 1.3 Write it to a USB stick

```bash
lsblk                                   # identify the stick, e.g. /dev/sdX — double-check!
sudo dd if=proxmox-ve_9.2-*.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

Write to the whole device (`/dev/sdX`), not a partition (`/dev/sdX1`).
Ventoy or balenaEtcher also work. Rufus works only in **DD mode**.

---

## Phase 2: Install (repeat for each host)

Boot from the USB stick and choose **Install Proxmox VE (Graphical)**. The
terminal UI variant asks the same questions.

### 2.1 EULA, then target disk

- **Target Harddisk:** pick the **boot disk** from 0.3, using its model,
  size and serial to identify it. Never pick a Ceph disk.
- **Options → Filesystem:** the choice from 0.4.
  - *ext4:* under Advanced, the defaults are fine. Optionally set `swapsize`
    to 4–8 GB and leave `maxvz` empty so the rest goes to `local-lvm`.
  - *ZFS RAID1:* select both boot disks and set the rest to `-- do not use --`.
    Defaults (`ashift=12`, `compress=on`) are fine. New installs cap the ARC
    at about 10% of RAM, which is fine here.

### 2.2 Location and time zone

Country, time zone (`Europe/Belgrade` or yours), and keyboard layout. The
time zone matters for logs. Cluster sync uses chrony, which the installer
enables.

### 2.3 Password and email

- **root password:** use a strong one and store it in Bitwarden. Stage 02
  logs in as `root@pam` with this password, so **use the same password on
  all three hosts**. The tfvars file only has one `proxmox_password`.
- **Email:** where notifications go (failed backups, disk SMART errors).
  Use a real address.

### 2.4 Management network (where your current problem likely is)

| Field | pve-1 | pve-2 | pve-3 |
|---|---|---|---|
| Management interface | **the 1G port** (check the MAC) | same | same |
| Hostname (FQDN) | `pve-1.home.arpa` | `pve-2.home.arpa` | `pve-3.home.arpa` |
| IP address (CIDR) | `192.168.0.5/24` | `192.168.0.6/24` | `192.168.0.7/24` |
| Gateway | `192.168.0.1` | `192.168.0.1` | `192.168.0.1` |
| DNS server | `192.168.0.1` | `192.168.0.1` | `192.168.0.1` |

- The **Management Interface** dropdown lists every NIC with its MAC and
  link state. Pick the one whose MAC matches the 1G port **and** that shows
  link up (a green or filled dot, depending on the UI). The installer fills
  in the IP fields from whatever DHCP lease that NIC got. **Overwrite them**
  with the static values above.
- If the installer offers **"Pin network interface names"**, enable it.
  It gives NICs stable names (`nic0`, `nic1`, ...) that survive kernel and
  firmware updates. Without it, a kernel upgrade can rename a NIC and leave
  `vmbr0` bound to a name that no longer exists, so the host goes offline
  after a reboot. If you pin, the NIC names in the README's mesh snippet will
  be `nicN` instead of `enp...`. Use whatever `ip link` shows.
- The CIDR suffix matters. `192.168.0.5/24` is correct. `192.168.0.5/32` or
  a typo'd `192.168.1.5` gives you a host nobody can reach.

### 2.5 Summary, then install

Check every line of the summary, especially the **disk** and the
**management interface**. Untick *automatically reboot* if you want to pull
the USB stick first, then install. It takes a few minutes. Remove the stick
when it reboots.

When it boots, the console shows something like:

```
Welcome to the Proxmox Virtual Environment. Please use your web browser to
configure this server - connect to:

  https://192.168.0.5:8006/
```

That banner shows the *configured* address. It doesn't prove the network
works. Phase 3.1 does.

---

## Phase 3: First boot (each host)

### 3.1 Prove the network from the host console

Log in at the console as `root`:

```bash
ip -br link          # the 1G port must show UP; vmbr0 must show UP
ip -br addr          # vmbr0 must show 192.168.0.5/24 (per host)
ping -c 3 192.168.0.1        # gateway reachable
ping -c 3 1.1.1.1            # internet reachable
ping -c 3 download.proxmox.com   # DNS works
systemctl status pveproxy    # active (running) — this is the :8006 web server
```

Then from your workstation:

```bash
ping 192.168.0.5
curl -k https://192.168.0.5:8006   # returns HTML
```

Then open **`https://192.168.0.5:8006`** in the browser. It must be
**https**. Plain http on 8006 doesn't answer. Accept the self-signed
certificate warning. Log in as `root` with the realm **Linux PAM standard
authentication**.

If any of this fails, go to the [troubleshooting appendix](#appendix-troubleshooting)
before going further.

### 3.2 Package repositories

A fresh install points at the **enterprise** repository, which needs a paid
subscription. Without one, `apt update` returns 401 errors. Switch to
**no-subscription**.

**GUI:** *Node → Updates → Repositories*

1. Select the `pve-enterprise` entry and click **Disable**.
2. Select the Ceph enterprise entry and click **Disable**. We don't use
   Proxmox's Ceph, but the entry is there and fails `apt update`.
3. **Add** and choose **No-Subscription**, then OK.
4. The page should show no errors. A warning that no-subscription isn't
   recommended for production is expected.

**CLI equivalent.** PVE 9 uses deb822 `.sources` files in
`/etc/apt/sources.list.d/`:

```bash
ls /etc/apt/sources.list.d/
# expect: debian.sources  pve-enterprise.sources  ceph.sources

# disable enterprise + ceph enterprise
for f in pve-enterprise ceph; do
  grep -q '^Enabled:' /etc/apt/sources.list.d/$f.sources \
    || echo 'Enabled: false' >> /etc/apt/sources.list.d/$f.sources
done

cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
```

### 3.3 Update fully, then reboot

```bash
apt update
apt full-upgrade        # ALWAYS full-upgrade (dist-upgrade) on Proxmox, never plain `apt upgrade`
reboot
```

Plain `apt upgrade` holds back packages whose dependencies change, and on
Proxmox that can leave a broken mix of versions.

After the reboot:

```bash
pveversion -v | head -5     # pve-manager 9.2.x, kernel 7.0.x
```

**All three hosts must be on the same Proxmox version before you cluster
them.**

### 3.4 CPU microcode

```bash
apt install intel-microcode      # Intel
# or
apt install amd64-microcode      # AMD
reboot
```

This needs the `non-free-firmware` component in `debian.sources`. Debian 13
installs include it by default. Check with
`grep Components /etc/apt/sources.list.d/debian.sources`.

### 3.5 SSH: key-only root login

The Talos pipeline needs `ssh root@<host>` to work with your key and the
agent (`ssh.agent = true` in `shared/providers.tf`).

From your workstation:

```bash
ssh-copy-id root@192.168.0.5     # repeat for .6 and .7
ssh root@192.168.0.5 hostname    # prints pve-1 with no password prompt
```

Then on each host, turn off password logins over SSH. GUI and API
logins still use the password:

```bash
cat > /etc/ssh/sshd_config.d/10-keys-only.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
systemctl reload ssh
```

**Test a new SSH session before closing the current one.** If you lock
yourself out, the physical console still works.

Add the hosts to your workstation's `~/.ssh/config` to make life easier:

```
Host pve-1
    HostName 192.168.0.5
    User root
Host pve-2
    HostName 192.168.0.6
    User root
Host pve-3
    HostName 192.168.0.7
    User root
```

### 3.6 Optional but recommended

- **Two-factor auth for the GUI:** *Datacenter → Permissions → Two Factor →
  Add → TOTP* for `root@pam`. **Don't** do this before the Talos bootstrap.
  The OpenTofu provider logs in with username and password and can't
  answer a TOTP prompt. Add it afterwards, or create a separate admin user
  for daily GUI use and keep root for automation.
- **Notifications:** *Datacenter → Notifications*. Check that the email
  target works ("Test"). The default sendmail target uses the email from
  the installer.
- **Subscription nag popup:** cosmetic. Leave it alone. Scripts that patch
  it break on updates.

---

## Phase 4: Networking

### 4.1 Check what the installer wrote

```bash
cat /etc/network/interfaces
```

Expect something like this (NIC names vary; `nic0` if pinned):

```
auto lo
iface lo inet loopback

iface enp5s0 inet manual

auto vmbr0
iface vmbr0 inet static
    address 192.168.0.5/24
    gateway 192.168.0.1
    bridge-ports enp5s0
    bridge-stp off
    bridge-fd 0

iface enp1s0f0np0 inet manual
iface enp1s0f1np1 inet manual
```

- `bridge-ports` must name the **1G port with the cable in it**. Check
  with `ip -br link`: that port should be `UP`.
- Also check that `/etc/hosts` maps the hostname to the **LAN IP**, not to
  `127.0.1.1`. Cluster join depends on this:

  ```
  192.168.0.5 pve-1.home.arpa pve-1
  ```

Leave `vmbr0` as a plain Linux bridge, not VLAN-aware. The Talos VMs'
uplink NICs (`ens18`) attach here and get their LAN IPs by DHCP reservation.

### 4.2 Build the 25G mesh (`vmbr1`)

The full config and the reasons for it are in
[`README.md` → *The mesh*](README.md#the-mesh-configured-on-the-hosts-by-hand).
In short, on every host:

```bash
apt install openvswitch-switch
ip -br link        # find the two 25G port names (and with them cabled, both show UP)
```

1. Add the `OVSPort` × 2 and `OVSBridge vmbr1` stanzas from the README to
   `/etc/network/interfaces`, replacing the NIC names with yours and
   `address 10.10.0.1/24` with `.2` / `.3` per host.
2. Apply: `ifreload -a`.
3. Check:

   ```bash
   ovs-vsctl show                 # vmbr1 with both 25G ports
   ovs-appctl rstp/show           # exactly ONE port on ONE host "Discarding", rest "Forwarding"
   ip -br addr show vmbr1         # 10.10.0.N/24, UP
   ping -c 3 10.10.0.2            # and .3, from each host
   ping -M do -s 8972 -c 3 10.10.0.2   # jumbo frames: MUST succeed with no fragmentation error
   ```

   If the 8972-byte ping fails while a normal ping works, an MTU is missing
   somewhere. Every `OVSPort` **and** the bridge need `ovs_mtu 9000`.

Notes:

- You can't build the RSTP options in the GUI. *System → Network* shows
  `vmbr1` once it exists. Don't edit it there, because the GUI rewrites
  the file and may drop the `ovs_options`/`up` lines.
- Don't put a gateway on `vmbr1`. The mesh is a closed L2 segment, and the
  only default route is on `vmbr0`.
- Optional failover test: unplug one DAC and watch `ovs-appctl rstp/show`.
  The blocked port should start forwarding within seconds, and a running
  `ping 10.10.0.x` should lose at most a few packets.

### 4.3 Name resolution between hosts

So every host can reach the others by name, add them to `/etc/hosts` on
**each** host (the installer only adds the host itself):

```
192.168.0.5 pve-1.home.arpa pve-1
192.168.0.6 pve-2.home.arpa pve-2
192.168.0.7 pve-3.home.arpa pve-3
```

---

## Phase 5: Storage

### 5.1 The VM datastore

*Datacenter → Storage* (or `pvesm status`) on each host, before clustering:

| Datastore | Content | Exists on |
|---|---|---|
| `local` | ISO images, container templates, backups | all hosts. Stage 01 uploads the Talos ISO here. |
| `local-lvm` **or** `local-zfs` | VM disks | all hosts, **same name** (0.4) |

```bash
pvesm status
```

`local` must list **ISO image** as a content type (it does by default).

### 5.2 Prepare the Ceph disks

On each host, find the disks reserved for Ceph:

```bash
lsblk -d -o NAME,SIZE,ROTA,MODEL,SERIAL     # ROTA 0 = SSD/NVMe
ls -l /dev/disk/by-id/ | grep -v -e part -e wwn-
```

- Write the `/dev/disk/by-id/...` paths (not `/dev/sdX`, which can change
  between boots) into each worker's `ceph_disks` in `secrets.auto.tfvars`.
  Split each host's disks between its two workers.
- Wipe them. **Triple-check the ID: this destroys the disk's data.**

  ```bash
  wipefs -a /dev/disk/by-id/<id>
  sgdisk --zap-all /dev/disk/by-id/<id>
  ```

  Or in the GUI: *Node → Disks → select disk → Wipe Disk*.
- **Don't** create LVM, ZFS, a directory or Proxmox Ceph OSDs on them. Leave
  them empty, or Rook will skip them.

### 5.3 Proxmox Ceph: don't install it

The GUI's *Ceph* panel offers to install Ceph Tentacle. **Don't.** Storage
for this cluster is Rook-Ceph inside the Talos workers. Running two Ceph
clusters on the same disks or network just makes trouble.

---

## Phase 6: Create the Proxmox cluster

### 6.1 Pre-flight, on all three hosts

- [ ] Same `pveversion` on all three hosts (3.3).
- [ ] Times agree: `chronyc tracking` shows a small offset, and `date`
      matches on all three.
- [ ] Each host can ping the others on **both** networks (`192.168.0.x`
      and `10.10.0.x`).
- [ ] `/etc/hosts` resolves each host's own name to its LAN IP (4.1).
- [ ] **No VMs or containers on pve-2 and pve-3.** A node with guests
      can't join, because VM IDs could collide. pve-1 may have some, but it
      shouldn't yet either.
- [ ] Same datastore names on all three (5.1).

### 6.2 Corosync link plan

Corosync is the cluster heartbeat. It needs **low latency**, not bandwidth.
Give it two links so quorum survives losing either network:

| Link | Network | Role |
|---|---|---|
| `link0` | mesh `10.10.0.x` | preferred: lowest latency, separate from LAN traffic |
| `link1` | LAN `192.168.0.x` | fallback if the mesh fails |

By default, the lower-numbered link is preferred, so link0 (mesh) carries
the heartbeat and link1 only takes over if it fails.

One caveat: Ceph replication also runs on the mesh. Under very heavy Ceph
load, corosync latency on link0 can rise. With 25G links that's unlikely,
and link1 is the safety net. If you ever see `[KNET] link down` flapping in
`journalctl -u corosync` during heavy I/O, give link1 a higher priority
(see 8.4).

### 6.3 Create the cluster on pve-1

**GUI:** *Datacenter → Cluster → Create Cluster*

- Cluster name: `ykube`
- Cluster network → Link 0: `10.10.0.1`
- Add → Link 1: `192.168.0.5`
- Create. The task log should end with `TASK OK`.

**CLI equivalent:**

```bash
pvecm create ykube --link0 10.10.0.1 --link1 192.168.0.5
pvecm status
```

### 6.4 Join pve-2, then pve-3

**GUI route:**

1. On **pve-1**: *Datacenter → Cluster → Join Information → Copy
   Information*.
2. On **pve-2**: *Datacenter → Cluster → Join Cluster*. Paste the
   information, enter pve-1's **root password**, then set its links:
   - Link 0: `10.10.0.2`
   - Link 1: `192.168.0.6`
3. Join. The GUI session on pve-2 drops, because its certificates are
   replaced by cluster ones. Reload the page and log in again.
4. Repeat on **pve-3** with `10.10.0.3` / `192.168.0.7`.

**CLI equivalent** (on the *joining* node, pointing at an existing member):

```bash
# on pve-2
pvecm add 192.168.0.5 --link0 10.10.0.2 --link1 192.168.0.6
# on pve-3
pvecm add 192.168.0.5 --link0 10.10.0.3 --link1 192.168.0.7
```

It asks for pve-1's root password and asks you to confirm its certificate
fingerprint.

**Join one node at a time.** Wait until `pvecm status` on pve-1 shows the
new member before starting the next join.

### 6.5 What the join changed

- `/etc/pve` is now a cluster filesystem (pmxcfs), replicated to all nodes.
  Anything written there, such as VM configs or `storage.cfg`, appears on
  every node instantly.
- The web GUI on **any** host shows and manages all three. Use
  `https://192.168.0.5:8006` as your main entry point. That's also
  `proxmox_endpoint` in tfvars.
- Each node's TLS certificate was re-issued by the cluster CA.
- Quorum: 3 votes, 2 needed. One host can be down and the cluster stays
  fully writable. With two down, `/etc/pve` goes read-only on the
  survivor, so nothing can be started or changed until quorum returns.
  No QDevice is needed with three nodes.

---

## Phase 7: Verify, the gate before the Talos bootstrap

Run on any node:

```bash
pvecm status
```

Expect:

```
Cluster information
-------------------
Name:             ykube
Config Version:   3
Transport:        knet
Secure auth:      on

Quorum information
------------------
Nodes:            3
Quorate:          Yes

Votequorum information
----------------------
Expected votes:   3
Highest expected: 3
Total votes:      3
Quorum:           2
```

```bash
pvecm nodes                    # pve-1, pve-2, pve-3
corosync-cfgtool -n            # each peer: link 0 and link 1 both "connected"
ha-manager status              # quorum OK; no resources (and keep it that way)
pvesm status                   # local + local-lvm/local-zfs "active" on every node
```

Final checklist against the README's *Prerequisites*:

- [ ] 3 Proxmox VE 9.2 hosts in **one** cluster, quorate.
- [ ] `ssh root@pve-1` / `pve-2` / `pve-3` work with your key and no password.
- [ ] Same OS-disk datastore name everywhere, matching `proxmox_disk_datastore`.
- [ ] `vmbr0` (LAN) and `vmbr1` (mesh, MTU 9000, RSTP) exist on all three,
      **with the same names**. Stage 02 attaches VM NICs by bridge name.
- [ ] Jumbo-frame ping passes between all host pairs.
- [ ] Ceph disks are wiped and listed by `/dev/disk/by-id` in tfvars.
- [ ] Node names in tfvars (`pve_node`) match `pvecm nodes` exactly.
- [ ] 9 Talos MACs reserved on the router; the VIP and LB pool are outside DHCP.
- [ ] Root password is in Bitwarden. No 2FA on `root@pam` yet (3.6).

Then:

```bash
cp shared/secrets.auto.tfvars.example shared/secrets.auto.tfvars   # fill in
task -d seed/talos cluster:bootstrap
```

---

## Phase 8: Day-2 operations

### 8.1 Updating the hosts

One host at a time, never all at once:

```bash
# on the host
apt update && apt full-upgrade
# if a new kernel arrived, drain workloads first (see 8.2), then:
reboot
# after it's back:
pvecm status    # Quorate: Yes, 3 nodes, before touching the next host
```

Before rebooting a host, check the Ceph and Kubernetes side (8.2). A host
reboot takes down **three** Kubernetes nodes and one copy of every Ceph
object.

### 8.2 Rebooting a host safely, with Talos on it

```bash
# from the workstation
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status      # HEALTH_OK first
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set noout
kubectl drain wk-1a --ignore-daemonsets --delete-emptydir-data
kubectl drain wk-1b --ignore-daemonsets --delete-emptydir-data
# reboot pve-1. Guests are shut down cleanly if the qemu-guest-agent is running
# (it is — stage 00 adds the extension)
# afterwards:
kubectl uncordon wk-1a wk-1b
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset noout
task -d seed/talos vault:status   # Vault reseals on restart
task -d seed/talos vault:unseal
```

Stage 02 sets every VM to start on boot (`on_boot = true`), so they come
back by themselves after the host reboots. Check with
`qm config <vmid> | grep onboot`.

### 8.3 Don't turn these on

| Feature | Why not |
|---|---|
| **HA** (and 9.2's HA arm/disarm, dynamic load balancer) | Kubernetes is the HA layer. A migrated VM keeps its old zone label, and workers can't move because their Ceph disks are physically in one box. See the README. |
| **Proxmox Ceph** | Rook-Ceph inside the VMs owns the disks. |
| **SDN / fabrics** (incl. 9.2's WireGuard fabric) | The OVS RSTP mesh already gives the VMs a shared L2. The README explains why the routed/EVPN options aren't worth it. |
| **Live migration of Talos VMs** | Same zone-label problem as HA. Workers with passthrough disks can't migrate at all. |
| **Proxmox firewall** (for now) | Off by default. If you enable it later, check that corosync (UDP 5405–5412), SSH, 8006 and the mesh still pass before rebooting anything. |

### 8.4 Corosync tweaks, if needed

To make the LAN link preferred, for example if the mesh link flaps under
Ceph load: edit `/etc/pve/corosync.conf` **carefully**. Bump `config_version`,
then in the `totem → interface` section for `linknumber: 1` add
`knet_link_priority: 10`, and give `linknumber: 0` a lower value. Save. The
change propagates and reloads automatically. Read the Proxmox *Cluster
Manager → Corosync Redundancy* docs first, because a broken corosync.conf
breaks quorum on every node.

### 8.5 What to back up from the hosts

The Talos VMs don't need Proxmox backups. They're rebuilt from the repo,
and their data lives in Ceph (which needs its own off-cluster backup; see
the README). For the hosts themselves, keep copies of:

- `/etc/network/interfaces` from each host (the mesh config especially)
- `/etc/pve/corosync.conf` and `/etc/pve/storage.cfg`
- `/etc/hosts`, `/etc/ssh/sshd_config.d/`

```bash
for h in pve-1 pve-2 pve-3; do
  mkdir -p host-backup/$h
  scp root@$h:'/etc/network/interfaces /etc/hosts' host-backup/$h/
done
scp root@pve-1:'/etc/pve/corosync.conf /etc/pve/storage.cfg' host-backup/
```

### 8.6 Removing or replacing a host

Removing a node is **permanent**. A removed node must never rejoin with
the same name and identity without being reinstalled. Procedure: move or
delete its guests, shut it down, then on a remaining node run
`pvecm delnode pve-N`. Reinstall it from Phase 2 before joining it again.
Follow the official *Remove a Cluster Node* docs step by step when you get
there.

---

## Appendix: Troubleshooting

### "I can't reach https://IP:8006"

Work from the bottom of the network stack up, and stop at the first check
that fails.

**From the workstation:**

```bash
ping -c 3 192.168.0.5
ip neigh show 192.168.0.5
curl -vk https://192.168.0.5:8006
```

| Result | Meaning |
|---|---|
| `ip neigh` shows `INCOMPLETE` / `FAILED` | **No device on the LAN answers for that IP.** The host isn't on the network at that address. Go to the console checks below. A firewall doesn't cause this. |
| Ping works, curl gets `Connection refused` | The network is fine, but `pveproxy` isn't running. Run `systemctl status pveproxy pvedaemon` and `journalctl -u pveproxy -b` on the host. |
| Ping works, curl hangs | Something is filtering 8006, either the host firewall or an AP/VLAN between you. |
| Curl works, browser doesn't | You typed `http://` (use `https://`), or the browser is blocking the self-signed certificate. |

**At the host console:**

```bash
ip -br link
ip -br addr
cat /etc/network/interfaces
ping -c 3 192.168.0.1
```

| Symptom | Cause | Fix |
|---|---|---|
| `vmbr0` has the right IP, but the port in `bridge-ports` shows `DOWN` / `NO-CARRIER` | Bridge is on the wrong NIC (the installer picked a 25G port or a different onboard port), or the cable is in a different port | Edit `bridge-ports` in `/etc/network/interfaces` to the NIC that shows `UP` with the LAN cable, then `ifreload -a` |
| Every port is `DOWN` | Cable, switch port, or no link light | Swap the cable or port and check the link LEDs |
| `vmbr0` has a different IP or subnet (e.g. `192.168.1.5`) | Installer prefilled from DHCP or a typo | Fix `address` and `gateway` in `/etc/network/interfaces`, fix `/etc/hosts`, then `ifreload -a` |
| NIC name in `bridge-ports` doesn't exist in `ip link` | NIC was renamed (kernel update, new hardware, BIOS change) | Point `bridge-ports` at the current name, then run `pve-network-interface-pinning generate` (or re-pin) so it stays stable |
| Gateway ping works but your workstation still can't reach it | Workstation on Wi-Fi with client/AP isolation, or a different VLAN or subnet | Test from a wired machine, and check the router's AP isolation and guest network settings |

If you change the management IP after install, update **both**
`/etc/network/interfaces` and `/etc/hosts`. Do it **before** clustering.
Changing a clustered node's IP also means editing `corosync.conf`.

### `apt update` fails with 401 Unauthorized

The enterprise repo is still enabled. See 3.2.

### Join fails: "this host already contains virtual guests"

The joining node has VMs or CTs. Back them up and delete them (or move them
to pve-1 by backup and restore), then join.

### Join fails or hangs at "waiting for quorum"

- Clocks out of sync: run `chronyc tracking` on both nodes.
- The link addresses you gave aren't reachable between the nodes (mesh not
  up yet?). Test with `ping` on both link networks.
- Leftover state from a failed attempt. On the *joining* node only:
  `systemctl stop pve-cluster corosync; pmxcfs -l; rm -rf /etc/corosync/*
  /etc/pve/corosync.conf; killall pmxcfs; systemctl start pve-cluster`.
  If that doesn't clear it, reinstalling the joining node is often faster.

### Lost quorum (two nodes down), `/etc/pve` read-only

Bring a second node back. As a last resort on the sole survivor, run
`pvecm expected 1` to regain write access temporarily. **Only** do this
if you're sure the other nodes are really off, because it allows
split-brain otherwise.

### Jumbo ping fails on the mesh

`ip link show vmbr1` and each 25G port must say `mtu 9000`. Make sure
`ovs_mtu 9000` is on every `OVSPort` *and* on the `OVSBridge`, then
`ifreload -a`. DAC cables and NICs that support 25G all support jumbo frames.

### Useful logs

```bash
journalctl -u pve-cluster -u corosync -b    # cluster / quorum
journalctl -u pveproxy -u pvedaemon -b      # web UI / API
journalctl -u networking -b                 # ifupdown2 / interfaces
dmesg | grep -i -e link -e eth -e mlx -e bnxt -e ice   # NIC driver / link events
```
