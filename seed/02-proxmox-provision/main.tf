# Stage 02: provision Talos VMs on Proxmox.
#
# One VM per entry in var.nodes. All-controlplane topology — there are no
# separate worker VMs; stage 03 sets allowSchedulingOnControlPlanes=true so
# every node runs both control plane components and workloads.
#
# Hardware notes:
#   - OVMF (UEFI) bios + EFI disk are required by Talos.
#   - x86-64-v2-AES is the broadest CPU type that includes AES-NI (needed for
#     etcd at decent speed). Bump to host or x86-64-v3 if all your boxes share
#     a more recent µarch.
#   - Disk is virtio0, raw + discard + ssd. virtio is fastest with the Talos
#     kernel modules; raw + discard lets Proxmox pass TRIM through to the SSD.
#
# Lifecycle:
#   - cdrom is ignored so future stage-01 re-runs (new Talos version) don't
#     stomp the existing VM's ISO reference (that ISO file may have been
#     replaced — see stage 01 comment about the upgrade footgun).
#   - boot_order is ignored for the same reason.

resource "proxmox_virtual_environment_vm" "nodes" {
  for_each = var.nodes

  name        = each.key
  description = "Talos node — managed by seed/02-proxmox-provision."
  tags        = ["terraform", "talos", "kubernetes"]

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

  cdrom {
    interface = "ide2"
    file_id   = data.terraform_remote_state.proxmox_iso.outputs.proxmox_talos_iso_ids[each.value.pve_node]
  }

  boot_order = ["virtio0", "ide2"]

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    firewall    = false
    mac_address = each.value.mac_address
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
