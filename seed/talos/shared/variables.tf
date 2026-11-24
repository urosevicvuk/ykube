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
  description = "Virtual IP shared across the controlplane nodes on the LAN (uplink) NIC. Same subnet as the nodes' LAN IPs, outside DHCP scope — it is what kubectl/talosctl on the workstation talk to."
  type        = string
}

# ============================================================
# Networking
# ============================================================
# Each Talos VM has two NICs:
#   - net0 -> var.lan_bridge  (ens18): 1G uplink. DHCP, default route, internet
#     egress, the Talos VIP and Cilium L2-announced LoadBalancer IPs.
#   - net1 -> var.mesh_bridge (ens19): the 20G full mesh between the Proxmox
#     hosts (an OVS bridge running RSTP across the two mesh NICs — no switch).
#     Static IPs from var.mesh_cidr. Kubelet node IPs, etcd peer traffic,
#     pod-to-pod (Cilium native routing) and all Ceph traffic live here.

variable "lan_bridge" {
  description = "Proxmox bridge on the 1G uplink"
  type        = string
  default     = "vmbr0"
}

variable "mesh_bridge" {
  description = "Proxmox bridge on the 20G mesh (OVS bridge with RSTP across the two mesh NICs)"
  type        = string
  default     = "vmbr1"
}

variable "mesh_cidr" {
  description = "Cluster network on the mesh. Must not overlap the LAN, the pod CIDR (10.244.0.0/16) or the service CIDR (10.96.0.0/12)."
  type        = string
  default     = "10.10.0.0/24"
}

variable "mesh_mtu" {
  description = "MTU on the mesh NIC. Must match the Proxmox mesh bridge and the physical mesh NICs."
  type        = number
  default     = 9000
}

# ============================================================
# Nodes
# ============================================================

variable "nodes" {
  description = <<-EOT
    Cluster nodes. Map key is the Kubernetes hostname; keep keys stable across
    rebuilds — Ceph OSDs and CRUSH map entries are keyed by hostname.

    Topology: per Proxmox host, 1 controlplane VM + 2 worker VMs. Controlplanes
    keep their NoSchedule taint (no workloads). Every node is labelled
    topology.kubernetes.io/zone=<pve_node>, which is the failure domain
    everything spreads across (Ceph CRUSH, Vault raft, CNPG, app replicas) —
    two VMs on the same Proxmox host are NOT independent.

    ip_address is the LAN (uplink) address, reserved by MAC on the router;
    mesh_ip is the static cluster-network address inside var.mesh_cidr.
    ceph_disk_gb > 0 attaches a second virtual disk (virtio1 -> /dev/vdb) that
    Rook consumes as an OSD; leave it 0 on controlplanes.
  EOT

  type = map(object({
    role         = string # "controlplane" | "worker"
    vm_id        = number
    pve_node     = string
    proxmox_ip   = string
    cpu_cores    = number
    memory_mb    = number
    disk_gb      = number
    ceph_disk_gb = optional(number, 0)
    ip_address   = string
    mac_address  = string
    mesh_ip      = string
  }))

  validation {
    condition     = alltrue([for n in values(var.nodes) : contains(["controlplane", "worker"], n.role)])
    error_message = "Each node's role must be \"controlplane\" or \"worker\"."
  }

  validation {
    condition     = length([for n in values(var.nodes) : n if n.role == "controlplane"]) % 2 == 1
    error_message = "Use an odd number of controlplane nodes (etcd quorum)."
  }
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
