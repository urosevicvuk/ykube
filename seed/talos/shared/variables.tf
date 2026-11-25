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
  description = "Proxmox username with realm. Must be root@pam with a password (not an API token): passing host disks through to a VM is root-only in Proxmox."
  type        = string
  sensitive   = true
}

variable "proxmox_password" {
  description = "Password for proxmox_username"
  type        = string
  sensitive   = true
}

variable "proxmox_iso_datastore" {
  description = "Proxmox datastore to upload Talos ISOs into (must support iso content)"
  type        = string
  default     = "local"
}

variable "proxmox_disk_datastore" {
  description = "Proxmox datastore for the VMs' OS + EFI disks, e.g. local-lvm or local-zfs"
  type        = string
  default     = "local-lvm"
}

# ============================================================
# Versions
# ============================================================

variable "talos_version" {
  description = "Talos Linux version for the factory ISO and installer. After bootstrap, upgrade with `talosctl upgrade`, never by changing this (see README)."
  type        = string
  default     = "v1.14.7"
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes version baked into the machine configs at bootstrap. It has to
    sit inside what every layer supports. As of 2026-11:
      Talos 1.14  -> 1.33-1.37
      Cilium 1.20 -> 1.33-1.36   <- the binding constraint
      Rook 1.21   -> 1.32-1.37
      Argo CD 3.6 -> 1.34-1.37
    Leaving it unset does NOT follow talos_version: the Talos provider falls
    back to its own built-in default (1.37.0 for provider 0.12.0).
    After bootstrap, upgrade with `talosctl upgrade-k8s --to <version>`.
  EOT
  type        = string
  default     = "1.36.6"
}

# ============================================================
# Talos cluster
# ============================================================

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
#   - net1 -> var.mesh_bridge (ens19): the 25G full mesh between the Proxmox
#     hosts (an OVS bridge running RSTP across the two DAC ports — no switch).
#     Static IPs from var.mesh_cidr. Kubelet node IPs, etcd, pod-to-pod
#     (Cilium native routing) and all Ceph traffic (Ceph uses host
#     networking, bound to this subnet) live here.

variable "lan_bridge" {
  description = "Proxmox bridge on the 1G uplink"
  type        = string
  default     = "vmbr0"
}

variable "mesh_bridge" {
  description = "Proxmox bridge on the 25G mesh (OVS bridge with RSTP across the two DAC ports)"
  type        = string
  default     = "vmbr1"
}

variable "mesh_cidr" {
  description = "Cluster network on the mesh. Must not overlap the LAN, the pod CIDR (10.244.0.0/16) or the service CIDR (10.96.0.0/12). Also hardcoded in apps/system/storage/rook-ceph/cluster-values.yaml (Ceph addressRanges) — change both together."
  type        = string
  default     = "10.10.0.0/24"
}

variable "mesh_mtu" {
  description = "MTU on the mesh NIC (9000 = jumbo frames). Must match the Proxmox mesh bridge and the physical DAC ports."
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

    ceph_disks are physical disks of that VM's Proxmox host, passed straight
    through to the VM (scsi1, scsi2, ... -> /dev/sdX inside Talos). Each one
    becomes one Ceph OSD. `path` is the disk's /dev/disk/by-id/... path on the
    host; `ssd` must say whether the disk is solid-state (SATA SSD or NVMe),
    because that is how Ceph classifies the OSD. Workers only.
  EOT

  type = map(object({
    role        = string # "controlplane" | "worker"
    vm_id       = number
    pve_node    = string
    proxmox_ip  = string
    cpu_cores   = number
    memory_mb   = number
    disk_gb     = number
    ip_address  = string
    mac_address = string
    mesh_ip     = string
    ceph_disks = optional(list(object({
      path = string
      ssd  = bool
    })), [])
  }))

  validation {
    condition     = alltrue([for n in values(var.nodes) : contains(["controlplane", "worker"], n.role)])
    error_message = "Each node's role must be \"controlplane\" or \"worker\"."
  }

  validation {
    condition     = length([for n in values(var.nodes) : n if n.role == "controlplane"]) % 2 == 1
    error_message = "Use an odd number of controlplane nodes (etcd quorum)."
  }

  validation {
    condition     = alltrue([for n in values(var.nodes) : n.role == "worker" || length(n.ceph_disks) == 0])
    error_message = "ceph_disks belong on workers only — controlplanes are tainted and run no Ceph OSDs."
  }

  validation {
    condition     = alltrue(flatten([for n in values(var.nodes) : [for d in n.ceph_disks : startswith(d.path, "/dev/disk/by-id/")]]))
    error_message = "ceph_disks paths must be /dev/disk/by-id/... — /dev/sdX and /dev/nvmeXnY names can change between host reboots."
  }

  validation {
    condition = (
      length(flatten([for n in values(var.nodes) : [for d in n.ceph_disks : "${n.pve_node}:${d.path}"]])) ==
      length(distinct(flatten([for n in values(var.nodes) : [for d in n.ceph_disks : "${n.pve_node}:${d.path}"]])))
    )
    error_message = "The same physical disk is listed twice on one Proxmox host — handing one disk to two VMs corrupts it."
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
