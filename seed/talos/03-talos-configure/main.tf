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
#   ens19 — 20G mesh, static mesh_ip. kubelet.nodeIP and etcd advertise on it,
#           so node-to-node, pod-to-pod and Ceph traffic stay off the 1G link.

locals {
  install_image = "factory.talos.dev/installer/${data.terraform_remote_state.talos_factory.outputs.schematic_id}:${var.talos_version}"
}

data "talos_machine_configuration" "nodes" {
  for_each = var.nodes

  cluster_name       = var.talos_cluster_name
  machine_type       = each.value.role
  cluster_endpoint   = "https://${var.talos_cluster_vip}:6443"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = null # follow the version baked into talos_version

  config_patches = concat([
    # Per-node hostname.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = each.key
      auto       = "off"
    }),

    # Install image (the factory installer with our extensions baked in) and
    # the two NICs. The VIP only exists on controlplanes.
    yamlencode({
      machine = {
        install = {
          disk  = "/dev/vda"
          wipe  = true
          image = local.install_image
        }
        network = {
          nameservers = ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"]
          interfaces = [
            merge(
              {
                interface = "ens18"
                dhcp      = true
              },
              each.value.role == "controlplane" ? { vip = { ip = var.talos_cluster_vip } } : {},
            ),
            {
              interface = "ens19"
              dhcp      = false
              mtu       = var.mesh_mtu
              addresses = ["${each.value.mesh_ip}/${local.mesh_prefix}"]
            },
          ]
        }
      }
    }),

    # KubePrism (in-cluster API endpoint at localhost:7445 — referenced by
    # apps/system/networking/cilium/values.yaml as k8sServiceHost), the node IP
    # pinned to the mesh, and the failure-domain label. The zone label is one of
    # the few kubernetes.io labels a kubelet may set on its own Node.
    yamlencode({
      machine = {
        features = {
          kubePrism = {
            enabled = true
            port    = 7445
          }
        }
        kubelet = {
          nodeIP = {
            validSubnets = [var.mesh_cidr]
          }
        }
        nodeLabels = {
          "topology.kubernetes.io/zone" = each.value.pve_node
        }
      }
    }),

    # Cluster-level: Cilium replaces both flannel and kube-proxy, so we
    # disable the default CNI and proxy. The pod/service subnets are Talos's
    # defaults, spelled out because Cilium's ipv4NativeRoutingCIDR must match.
    yamlencode({
      cluster = {
        network = {
          cni = {
            name = "none"
          }
          podSubnets     = ["10.244.0.0/16"]
          serviceSubnets = ["10.96.0.0/12"]
        }
        proxy = {
          disabled = true
        }
        coreDNS = {
          disabled = false
        }
        controlPlane = {
          endpoint = "https://${var.talos_cluster_vip}:6443"
        }
      }
    }),
    ],

    each.value.role == "controlplane" ? [
      # etcd peers talk over the mesh, and the control plane exposes metrics
      # beyond localhost so kube-prometheus-stack can scrape them
      # (kubeControllerManager / kubeScheduler / kubeEtcd in its values).
      yamlencode({
        cluster = {
          etcd = {
            advertisedSubnets = [var.mesh_cidr]
            extraArgs = {
              "listen-metrics-urls" = "http://0.0.0.0:2381"
            }
          }
          controllerManager = {
            extraArgs = {
              "bind-address" = "0.0.0.0"
            }
          }
          scheduler = {
            extraArgs = {
              "bind-address" = "0.0.0.0"
            }
          }
        }
      }),
    ] : [],
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
