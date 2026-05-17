output "proxmox_talos_iso_ids" {
  description = "Per-Proxmox-node Talos ISO file IDs, consumed by stage 02 to attach as cdrom."
  value       = { for node, iso in proxmox_download_file.talos_iso : node => iso.id }
}
