# Stage 03: configure Talos nodes, bootstrap etcd, retrieve credentials.
#
# Generates cluster PKI once (talos_machine_secrets), produces per-node
# machine config, applies it, bootstraps etcd on the first node, and writes
# talosconfig.yaml + kubeconfig.yaml to secrets/ for use by later stages and
# the operator.
#
# WARNING: state file contains the cluster PKI. Treat it like a private key —
# back up alongside vault-init.json (see seed/talos/README.md).

# ------------------------------------------------------------
# Wait for nodes to be reachable on the Talos API port (50000)
# ------------------------------------------------------------
# stage 02 returns once Proxmox has *created* the VM; the VM still needs to
# boot the ISO and start the Talos APId before we can apply config. nc the
# port until it answers.

resource "terraform_data" "wait_for_nodes" {
  for_each = var.nodes

  provisioner "local-exec" {
    command = "for i in {1..60}; do if nc -z ${each.value.ip_address} 50000; then exit 0; fi; sleep 10; done; exit 1"
  }
}

# ------------------------------------------------------------
# Cluster PKI
# ------------------------------------------------------------
resource "talos_machine_secrets" "this" {}

# ------------------------------------------------------------
# Per-node machine configuration
# ------------------------------------------------------------
# 3 controlplanes (one per Proxmox host) + 6 workers. Controlplanes keep the
# default NoSchedule taint — they run etcd + the control plane only, so a
# workload burst can't starve the apiserver.
#
# Networking (see shared/variables.tf):
#   ens18 — LAN uplink, DHCP. Carries the default route and, on controlplanes,
#           the VIP that the workstation reaches the API through.
#   ens19 — 25G mesh, static mesh_ip. The kubelet node IP and etcd advertise
#           on it, so node-to-node, pod-to-pod and Ceph traffic stay off the
#           1G link.
#
# Config format: Talos 1.14 moved almost everything out of the old monolithic
# `v1alpha1` document into dedicated documents (LinkConfig, KubeNodeConfig,
# UnattendedInstallConfig, ...), and REJECTS a config that sets the same thing
# both ways. So every patch below is its own new-style document, and the only
# thing still patched into v1alpha1 is etcd (which has no document of its own
# yet). Check a rendered config with `talosctl validate --mode metal --strict`.

locals {
  # Factory installer for our schematic (qemu-guest-agent baked in), as
  # reported by stage 00 for the metal platform.
  install_image = data.terraform_remote_state.talos_factory.outputs.image_urls.urls.installer

  # Patches shared by every node. Each list element is one YAML document.
  common_patches = {
    for name, node in var.nodes : name => [
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "HostnameConfig"
        hostname   = name
        auto       = "off"
      }),

      # Install to the virtio OS disk with the factory image. /dev/vda is
      # Proxmox's virtio0; the passed-through Ceph disks are SCSI (/dev/sdX).
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "UnattendedInstallConfig"
        installer = {
          image = local.install_image
        }
        provisioning = {
          diskSelector = {
            match = "disk.dev_path == \"/dev/vda\""
          }
          wipe = true
        }
      }),

      # ens18: LAN uplink, DHCP (default route, internet, the VIP).
      # Configuring any link explicitly turns off Talos's "DHCP on every NIC"
      # default, so ens18 needs its own DHCP document.
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "LinkConfig"
        name       = "ens18"
        up         = true
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "DHCPv4Config"
        name       = "ens18"
      }),

      # ens19: the mesh. Static address, jumbo frames, no gateway.
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "LinkConfig"
        name       = "ens19"
        up         = true
        mtu        = var.mesh_mtu
        addresses = [
          { address = "${node.mesh_ip}/${local.mesh_prefix}" },
        ]
      }),

      # DNS. forwardKubeDNSToHost=false: Talos defaults CoreDNS to forwarding
      # through the host's DNS cache, and that path breaks when Cilium does
      # BPF masquerading (Talos "Deploying Cilium" guide, Known issues).
      # CoreDNS then forwards straight to the nameservers below instead.
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "ResolverConfig"
        nameservers = [
          { address = "1.1.1.1" },
          { address = "1.0.0.1" },
          { address = "8.8.8.8" },
          { address = "8.8.4.4" },
        ]
        hostDNS = {
          enabled              = true
          forwardKubeDNSToHost = false
        }
      }),

      # Node IP on the mesh + the failure-domain label (one of the few
      # kubernetes.io labels a kubelet may set on its own Node).
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeNodeConfig"
        nodeIP = {
          validSubnets = [var.mesh_cidr]
        }
        labels = {
          "topology.kubernetes.io/zone" = node.pve_node
        }
      }),

      # Pod/service CIDRs, spelled out because Cilium's ipv4NativeRoutingCIDR
      # (apps/system/networking/cilium/values.yaml) must match.
      yamlencode({
        apiVersion     = "v1alpha1"
        kind           = "KubeNetworkConfig"
        podSubnets     = ["10.244.0.0/16"]
        serviceSubnets = ["10.96.0.0/12"]
      }),

      # KubePrism: the in-node apiserver load balancer on localhost:7445 that
      # Cilium talks to (k8sServiceHost/Port in its values).
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubePrismConfig"
        port       = 7445
      }),
    ]
  }

  # Controlplane-only patches.
  controlplane_patches = [
    # Cilium is the CNI and replaces kube-proxy: no Flannel, no kube-proxy.
    # Both are deployed by the controlplane at bootstrap, so these documents
    # only exist (and are only accepted) on controlplanes.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeFlannelCNIConfig"
      "$patch"   = "delete"
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeProxyConfig"
      enabled    = false
    }),

    # The API VIP floats between the controlplanes on the LAN NIC.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "Layer2VIPConfig"
      name       = var.talos_cluster_vip
      link       = "ens18"
    }),

    # Expose controller-manager / scheduler metrics beyond localhost so
    # kube-prometheus-stack can scrape them.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeControllerManagerConfig"
      extraArgs = {
        "bind-address" = "0.0.0.0"
      }
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeSchedulerConfig"
      extraArgs = {
        "bind-address" = "0.0.0.0"
      }
    }),

    # etcd peers talk over the mesh; metrics on :2381 for Prometheus.
    # (etcd still lives in the v1alpha1 document in Talos 1.14.)
    yamlencode({
      cluster = {
        etcd = {
          advertisedSubnets = [var.mesh_cidr]
          extraArgs = {
            "listen-metrics-urls" = "http://0.0.0.0:2381"
          }
        }
      }
    }),
  ]
}

data "talos_machine_configuration" "nodes" {
  for_each = var.nodes

  cluster_name       = var.talos_cluster_name
  machine_type       = each.value.role
  cluster_endpoint   = "https://${var.talos_cluster_vip}:6443"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = concat(
    local.common_patches[each.key],
    each.value.role == "controlplane" ? local.controlplane_patches : [],
  )
}

# ------------------------------------------------------------
# Apply machine config
# ------------------------------------------------------------
# A fresh node is in maintenance mode and only answers on its own IP — we
# can't route through another node's API yet because no cluster exists. So
# both `node` and `endpoint` are the node's own IP. Once the cluster is up
# we'd point endpoint at the VIP, but TF re-applies are rare.

resource "talos_machine_configuration_apply" "nodes" {
  for_each = var.nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.nodes[each.key].machine_configuration

  node     = each.value.ip_address
  endpoint = each.value.ip_address

  on_destroy = {
    graceful = true
    reset    = true
    reboot   = true
  }

  depends_on = [terraform_data.wait_for_nodes]
}

# ------------------------------------------------------------
# Bootstrap etcd (idempotent — Talos detects an already-bootstrapped cluster)
# ------------------------------------------------------------
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.first_node_ip
  endpoint             = local.first_node_ip

  depends_on = [talos_machine_configuration_apply.nodes]
}

# ------------------------------------------------------------
# Retrieve kubeconfig
# ------------------------------------------------------------
resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.first_node_ip
  endpoint             = local.first_node_ip

  depends_on = [talos_machine_bootstrap.this]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.talos_cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  # talosctl endpoints must be controlplanes (they proxy to the target node).
  endpoints = [for name, node in local.controlplanes : node.ip_address]
  nodes     = [for name, node in var.nodes : node.ip_address]
}

# ------------------------------------------------------------
# Persist credentials to secrets/
# ------------------------------------------------------------
# Both files are gitignored. Back them up to Bitwarden alongside the tfstate.

resource "local_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/secrets/talosconfig.yaml"
  file_permission = "0600"
}

resource "local_file" "kubeconfig" {
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = "${path.module}/secrets/kubeconfig.yaml"
  file_permission = "0600"
}
