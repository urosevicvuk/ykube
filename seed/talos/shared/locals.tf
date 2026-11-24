locals {
  controlplanes = { for name, node in var.nodes : name => node if node.role == "controlplane" }

  # First controlplane by sorted hostname — the bootstrap target for etcd init
  # and the endpoint Cilium / ArgoCD providers connect to before the VIP is up.
  first_node_name = tolist(sort(keys(local.controlplanes)))[0]
  first_node_ip   = local.controlplanes[local.first_node_name].ip_address

  # Prefix length of the mesh network, for the static address on ens19.
  mesh_prefix = split("/", var.mesh_cidr)[1]

  # Resolve the Proxmox node SSH address from the matching nodes-map entry.
  proxmox_ssh_node = [
    for name, node in var.nodes : node
    if node.pve_node == var.proxmox_node_name
  ][0]
  proxmox_ssh_address = local.proxmox_ssh_node.proxmox_ip
}
