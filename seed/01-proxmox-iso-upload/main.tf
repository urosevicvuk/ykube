# Stage 01: upload the factory ISO to each Proxmox node's local storage.
#
# Local Proxmox storage isn't shared between hosts, so each pve_node referenced
# in var.nodes gets its own ISO copy. The ISO file name embeds both the Talos
# version and the schematic ID, so Talos upgrades or extension changes don't
# clash with the previous ISO.
#
# DO NOT change var.talos_version on a running cluster expecting an upgrade —
# stage 02's lifecycle ignores cdrom changes, so existing VMs would still
# point at the old ISO filename which now no longer exists, and they wouldn't
# boot. Use `talosctl upgrade` for in-place upgrades instead.

locals {
  pve_nodes = toset([for node in var.nodes : node.pve_node])
}

resource "proxmox_download_file" "talos_iso" {
  for_each = local.pve_nodes

  content_type = "iso"
  datastore_id = var.proxmox_iso_datastore
  node_name    = each.key

  url       = data.terraform_remote_state.talos_factory.outputs.image_urls.urls.iso
  file_name = "talos-${var.talos_version}-${data.terraform_remote_state.talos_factory.outputs.schematic_id}.iso"

  # Replace the file when version or schematic changes.
  overwrite = true
}
