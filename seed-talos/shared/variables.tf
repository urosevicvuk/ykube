# ============================================================
# Proxmox
# ============================================================

variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint, e.g. https://pve.example.com:8006"
  type        = string
}

variable "proxmox_insecure" {
  description = "Skip TLS verification for the Proxmox API"
  type        = bool
  default     = true
}

variable "proxmox_username" {
  description = "Proxmox username with realm, e.g. root@pam"
  type        = string
  sensitive   = true
}

variable "proxmox_password" {
  description = "Proxmox password (or API token value)"
  type        = string
  sensitive   = true
}

variable "proxmox_iso_datastore" {
  description = "Proxmox datastore to upload Talos ISOs into (must support iso content)"
  type        = string
  default     = "local"
}

variable "proxmox_disk_datastore" {
  description = "Proxmox datastore for VM disks, e.g. local-lvm or local-zfs"
  type        = string
  default     = "local-lvm"
}

variable "proxmox_node_name" {
  description = "Proxmox node used by the bpg provider for SSH (must match a pve_node in the nodes map)"
  type        = string
}

# ============================================================
# Talos
# ============================================================

variable "talos_version" {
  description = "Talos Linux version. Pin to the latest stable release."
  type        = string
  default     = "v1.12.4"
}

variable "talos_cluster_name" {
  description = "Kubernetes cluster name (used in kubeconfig context and TLS SANs)"
  type        = string
  default     = "firelink"
}

variable "talos_cluster_vip" {
  description = "Virtual IP shared across all controlplane nodes. Same L2 segment as the nodes, outside DHCP scope."
  type        = string
}

# ============================================================
# Nodes
# ============================================================

variable "nodes" {
  description = <<-EOT
    Cluster nodes. Map key is the Kubernetes hostname; keep keys stable across
    rebuilds — renaming triggers a Longhorn diskUUID mismatch on existing data.

    All nodes are controlplane with allowSchedulingOnControlPlanes=true (3-node
    hyperconverged HA). Add new nodes by adding new keys.
  EOT

  type = map(object({
    vm_id       = number
    pve_node    = string
    proxmox_ip  = string
    cpu_cores   = number
    memory_mb   = number
    disk_gb     = number
    ip_address  = string
    mac_address = string
  }))
}

# ============================================================
# Bootstrap-time external secrets
# ============================================================
# Provided via TF_VAR_* env vars or ~/.envrc.local. Never committed.

variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS edit + zone read on the cert-manager-managed zones. Stored at kv/cert-manager/cloudflare-api-token by stage 07."
  type        = string
  sensitive   = true
}
