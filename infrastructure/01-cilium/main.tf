# Stage 01: Install Gateway API CRDs and Cilium CNI
# Providers, variables, and locals are symlinked from shared/

# Read chart version from ArgoCD Application YAML (single source of truth)
locals {
  cilium_app = yamldecode(file("${var.project_root}/ci-cd/argocd/environments/prod/apps/cilium.yaml"))
  cilium_version = [
    for s in local.cilium_app.spec.sources : s.targetRevision
    if try(s.chart, "") == "cilium"
  ][0]
}

# Wait for K8s API to be reachable
resource "null_resource" "wait_for_api" {
  provisioner "local-exec" {
    command = "${local.scripts}/wait-for-k8s-api.sh"
    environment = {
      KUBECONFIG = var.kubeconfig_path
    }
  }
}

# Install Gateway API CRDs (required before Cilium)
resource "null_resource" "gateway_api_crds" {
  provisioner "local-exec" {
    command = "${local.kubectl} apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml"
  }

  depends_on = [null_resource.wait_for_api]
}

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = local.cilium_version
  namespace  = "kube-system"
  timeout    = 600

  values = [
    file("${var.project_root}/networking/cilium/environments/prod/values.yaml")
  ]

  depends_on = [null_resource.gateway_api_crds]
}

output "cilium_version" {
  value = local.cilium_version
}
