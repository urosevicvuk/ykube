locals {
  controlplanes = { for name, node in var.nodes : name => node if node.role == "controlplane" }

  # First controlplane by sorted hostname — the bootstrap target for etcd init
  # and the endpoint Cilium / ArgoCD providers connect to before the VIP is up.
  first_node_name = tolist(sort(keys(local.controlplanes)))[0]
  first_node_ip   = local.controlplanes[local.first_node_name].ip_address

  # Prefix length of the mesh network, for the static address on ens19.
  mesh_prefix = split("/", var.mesh_cidr)[1]

  # Proxmox host name -> its management IP, one entry per host. Feeds the
  # provider's ssh.node blocks so it never has to guess a host's address (its
  # API-based lookup could pick the mesh IP, which the workstation can't reach).
  pve_hosts = { for node in values(var.nodes) : node.pve_node => node.proxmox_ip... }
}
