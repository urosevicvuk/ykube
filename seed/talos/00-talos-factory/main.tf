# Stage 00: Talos image factory schematic.
#
# Registers the customisation (system extensions) with factory.talos.dev and
# captures the schematic ID + ISO/installer URLs in state. Stage 01 uses the
# ISO URL to download the image to Proxmox; stage 03 uses the installer URL
# in each node's machine config so Talos installs the *factory* image (with
# extensions) to disk, not the upstream stock image.
#
# Extensions:
#   - siderolabs/qemu-guest-agent  (Proxmox shutdown / IP reporting / snapshots)
#
# Rook-Ceph needs nothing extra: the rbd/ceph kernel modules ship in the stock
# Talos kernel. (The iscsi-tools / util-linux-tools pair this used to carry was
# a Longhorn requirement.)
#
# Adding extensions later is a re-apply away — but doing so changes the
# schematic ID, which means a new ISO and a `talosctl upgrade` of every node.

resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = [
          "siderolabs/qemu-guest-agent",
        ]
      }
    }
  })
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "metal"
  architecture  = "amd64"
}
