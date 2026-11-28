# Stage 02: provision Talos VMs on Proxmox.
#
# One VM per entry in var.nodes: per Proxmox host, 1 controlplane + 2 workers.
# Stage 03 decides the role; to Proxmox they differ only in sizing and in the
# workers' passed-through Ceph disks.
#
# Do NOT put these VMs under Proxmox HA. Kubernetes is the HA layer, and each
# VM's topology.kubernetes.io/zone label (stage 03) asserts which host it runs
# on — a Proxmox HA failover would move it without updating the label and
# could stack two etcd members or two Ceph replicas on one host. (Workers
# can't migrate anyway: their passthrough disks are physically in one host.)
#
# Hardware notes:
#   - OVMF (UEFI) bios + EFI disk are required by Talos.
#   - CPU type `host`: all three machines are the same hardware, so expose the
#     real CPU (AES-NI, AVX2, ... for etcd, Ceph checksums and crypto). The
#     cost is that live migration to a different CPU model wouldn't work —
#     irrelevant here, these VMs never migrate.
#   - The OS disk is virtio0 (/dev/vda in Talos — stage 03 installs there).
#   - Ceph disks are whole physical disks passed through on the SCSI bus
#     (scsi1, scsi2, ... -> /dev/sdX in Talos), one virtio-scsi controller per
#     disk (virtio-scsi-single) so each gets its own iothread. Rook turns every
#     empty /dev/sdX into an OSD and never touches /dev/vda. `ssd` sets the
#     rotation rate the guest sees, which is how Ceph tells SSD from HDD.
#     backup/replicate are off: vzdump must never try to back up a Ceph OSD.
#   - Two NICs: net0 on var.lan_bridge (ens18, 1G uplink) and net1 on
#     var.mesh_bridge (ens19, 25G mesh, jumbo frames). Order matters — Talos
#     names them by PCI slot, and stage 03 + the Cilium L2 policy assume it.
#
# Lifecycle:
#   - cdrom is ignored so future stage-01 re-runs (new Talos version) don't
#     stomp the existing VM's ISO reference (that ISO file may have been
#     replaced — see stage 01 comment about the upgrade footgun).
#   - boot_order is ignored for the same reason.
#   - disk is ignored after creation. Disk passthrough is marked experimental
#     in the bpg provider, and Proxmox reports a passed-through disk's size
#     back differently from what TF sent, which would show as a perpetual
#     diff (or a resize attempt) on every apply. Consequence: changing disks
#     later is a manual step — add an OSD disk with
#       qm set <vmid> -scsi<N> /dev/disk/by-id/<id>,backup=0,replicate=0,ssd=1,iothread=1,aio=native
#     (and add it to secrets.auto.tfvars so a rebuild gets it too).

resource "proxmox_virtual_environment_vm" "nodes" {
  for_each = var.nodes

  name        = each.key
  description = "Talos ${each.value.role} — managed by seed/talos/02-proxmox-provision."
  tags        = ["terraform", "talos", "kubernetes", each.value.role]

  node_name = each.value.pve_node
  vm_id     = each.value.vm_id

  stop_on_destroy = true
  on_boot         = true

  agent {
    enabled = true
    trim    = true
    type    = "virtio"
  }

  cpu {
    cores = each.value.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  scsi_hardware = "virtio-scsi-single"

  # OS disk.
  disk {
    datastore_id = var.proxmox_disk_datastore
    interface    = "virtio0"
    size         = each.value.disk_gb
    file_format  = "raw"
    discard      = "on"
    ssd          = true
    iothread     = true
  }

  # Ceph OSD disks: physical disks of this Proxmox host, passed through whole.
  dynamic "disk" {
    for_each = { for i, d in each.value.ceph_disks : i => d }
    content {
      datastore_id      = ""
      path_in_datastore = disk.value.path
      interface         = "scsi${disk.key + 1}"
      file_format       = "raw"
      ssd               = disk.value.ssd
      discard           = "on"
      iothread          = true
      aio               = "native"
      cache             = "none"
      backup            = false
      replicate         = false
    }
  }

  cdrom {
    interface = "ide2"
    file_id   = data.terraform_remote_state.proxmox_iso.outputs.proxmox_talos_iso_ids[each.value.pve_node]
  }

  boot_order = ["virtio0", "ide2"]

  # net0 -> ens18: 1G uplink. MAC is reserved on the router for a stable LAN IP.
  network_device {
    bridge      = var.lan_bridge
    model       = "virtio"
    firewall    = false
    mac_address = each.value.mac_address
  }

  # net1 -> ens19: 25G mesh. Static IP (stage 03), so the MAC can be generated.
  # mtu = 1 means "inherit the bridge's MTU" (9000 on vmbr1).
  network_device {
    bridge   = var.mesh_bridge
    model    = "virtio"
    firewall = false
    mtu      = 1
    queues   = each.value.cpu_cores
  }

  serial_device {}

  bios = "ovmf"

  efi_disk {
    datastore_id = var.proxmox_disk_datastore
    file_format  = "raw"
    type         = "4m"
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    ignore_changes = [
      cdrom,
      boot_order,
      disk,
    ]
  }
}
