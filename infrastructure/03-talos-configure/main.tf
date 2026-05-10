# Stage 03: configure Talos nodes, bootstrap etcd, retrieve credentials.
#
# Generates cluster PKI once (talos_machine_secrets), produces per-node
# machine config, applies it, bootstraps etcd on the first node, and writes
# talosconfig.yaml + kubeconfig.yaml to secrets/ for use by later stages and
# the operator.
#
# WARNING: state file contains the cluster PKI. Treat it like a private key —
# back up alongside vault-init.json (see infrastructure/README.md).

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
# All nodes are controlplane. allowSchedulingOnControlPlanes=true means
# workloads land on every node — fine for a 3-box homelab where dedicating a
# node to control plane only would waste capacity.

data "talos_machine_configuration" "nodes" {
  for_each = var.nodes

  cluster_name       = var.talos_cluster_name
  machine_type       = "controlplane"
  cluster_endpoint   = "https://${var.talos_cluster_vip}:6443"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = null # follow the version baked into talos_version

  config_patches = [
    # Per-node hostname.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = each.key
      auto       = "off"
    }),

    # Install image (the factory installer with our extensions baked in),
    # plus per-node network — DHCP on ens18 with the cluster VIP shared
    # across all controlplanes.
    yamlencode({
      machine = {
        install = {
          disk  = "/dev/vda"
          wipe  = true
          image = "factory.talos.dev/installer/${data.terraform_remote_state.talos_factory.outputs.schematic_id}:${var.talos_version}"
        }
        network = {
          nameservers = ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"]
          interfaces = [
            {
              interface = "ens18"
              dhcp      = true
              vip = {
                ip = var.talos_cluster_vip
              }
            }
          ]
        }
      }
    }),

    # KubePrism (in-cluster API endpoint at localhost:7445 — referenced by
    # apps/system/networking/cilium/values.yaml as k8sServiceHost) plus the
    # Longhorn bind mount. Without the bind mount, Longhorn cannot create
    # PVs; the directory is created lazily by Talos when the kubelet starts.
    yamlencode({
      machine = {
        features = {
          kubePrism = {
            enabled = true
            port    = 7445
          }
        }
        kubelet = {
          extraMounts = [
            {
              destination = "/var/lib/longhorn"
              type        = "bind"
              source      = "/var/lib/longhorn"
              options     = ["bind", "rshared", "rw"]
            }
          ]
        }
      }
    }),

    # Cluster-level: Cilium replaces both flannel and kube-proxy, so we
    # disable the default CNI and proxy. allowSchedulingOnControlPlanes=true
    # is what makes our 3 controlplane nodes also act as workers.
    yamlencode({
      cluster = {
        allowSchedulingOnControlPlanes = true
        network = {
          cni = {
            name = "none"
          }
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
  ]
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
  endpoints            = [for name, node in var.nodes : node.ip_address]
  nodes                = [for name, node in var.nodes : node.ip_address]
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
