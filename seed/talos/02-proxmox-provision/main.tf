# Stage 02: provision Talos VMs on Proxmox.
#
# One VM per entry in var.nodes: per Proxmox host, 1 controlplane + 2 workers.
# Stage 03 decides the role; to Proxmox they differ only in sizing and in the
# workers' extra Ceph disk.
#
# Do NOT put these VMs under Proxmox HA. Kubernetes is the HA layer, and each
# VM's topology.kubernetes.io/zone label (stage 03) asserts which host it runs
# on — a Proxmox HA failover would move it without updating the label and
# could stack two etcd members or two Ceph replicas on one host.
#
# Hardware notes:
#   - OVMF (UEFI) bios + EFI disk are required by Talos.
#   - x86-64-v2-AES is the broadest CPU type that includes AES-NI (needed for
#     etcd at decent speed). Bump to host or x86-64-v3 if all your boxes share
#     a more recent µarch.
#   - Disk is virtio0, raw + discard + ssd. virtio is fastest with the Talos
#     kernel modules; raw + discard lets Proxmox pass TRIM through to the SSD.
#   - Workers get a second, empty disk on virtio1 (/dev/vdb in Talos) sized by
#     ceph_disk_gb. Rook's useAllDevices picks it up as an OSD; the install
#     disk is skipped because it carries partitions. If you'd rather hand a
#     whole physical disk to a worker, attach it by-id outside TF
#     (`qm set <vmid> -virtio1 /dev/disk/by-id/...`) and set ceph_disk_gb = 0.
#   - Two NICs: net0 on var.lan_bridge (ens18, 1G uplink) and net1 on
#     var.mesh_bridge (ens19, 20G mesh, jumbo frames). Order matters — Talos
#     names them by PCI slot, and stage 03 + the Cilium L2 policy assume it.
#
# Lifecycle:
#   - cdrom is ignored so future stage-01 re-runs (new Talos version) don't
#     stomp the existing VM's ISO reference (that ISO file may have been
#     replaced — see stage 01 comment about the upgrade footgun).
#   - boot_order is ignored for the same reason.

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
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    datastore_id = var.proxmox_disk_datastore
    interface    = "virtio0"
    size         = each.value.disk_gb
    file_format  = "raw"
    discard      = "on"
    ssd          = true
  }

  dynamic "disk" {
    for_each = each.value.ceph_disk_gb > 0 ? [each.value.ceph_disk_gb] : []
    content {
      datastore_id = var.proxmox_disk_datastore
      interface    = "virtio1"
      size         = disk.value
      file_format  = "raw"
      discard      = "on"
      ssd          = true
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

  # net1 -> ens19: 20G mesh. Static IP (stage 03), so the MAC can be generated.
  network_device {
    bridge   = var.mesh_bridge
    model    = "virtio"
    firewall = false
    mtu      = var.mesh_mtu
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
    ]
  }
}
