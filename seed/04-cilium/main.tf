# Stage 04: seed-install Cilium CNI.
#
# Without a CNI, kubelets are NotReady and no pods can schedule — including
# ArgoCD itself. So Cilium MUST be installed imperatively before GitOps can
# take over. To prevent TF from later fighting Argo on chart bumps, the helm
# release uses lifecycle.ignore_changes = all: TF installs once, never updates.
#
# Drift-free guarantee: this stage reads BOTH the chart version and the values
# file from apps/system/networking/cilium/. Argo and TF deploy literally the
# same chart with literally the same values.

locals {
  # path.module is this stage's directory; ../.. is the repo root.
  repo_root = "${path.module}/../.."

  cilium_dir           = "${local.repo_root}/apps/system/networking/cilium"
  cilium_kustomization = yamldecode(file("${local.cilium_dir}/kustomization.yaml"))
  cilium_chart_version = local.cilium_kustomization.helmCharts[0].version
  cilium_values        = file("${local.cilium_dir}/values.yaml")
}

resource "null_resource" "wait_for_kubernetes_api" {
  provisioner "local-exec" {
    command = "bash ${path.module}/../scripts/wait-for-k8s-api.sh"
    environment = {
      INFRA_ROOT = "${path.module}/.."
      TF_DIR     = "${path.module}/../03-talos-configure"
    }
  }
}

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = local.cilium_chart_version
  namespace  = "kube-system"

  values = [local.cilium_values]

  wait             = true
  wait_for_jobs    = true
  timeout          = 600
  create_namespace = false # kube-system always exists

  depends_on = [null_resource.wait_for_kubernetes_api]

  # GitOps takes over after stage 05. From there, ArgoCD's `networking-cilium`
  # Application is the source of truth — TF must not stomp Argo's updates.
  lifecycle {
    ignore_changes = all
  }
}

# Once Cilium is up, apply the LB IP pool + L2 announcement policy that the
# Argo Application also manages. Same drift-free trick as the helm release.
# These are tiny CRD instances, so we apply with kubectl rather than pulling
# in the kubernetes provider's manifest resource (which evaluates schemas at
# plan time and would fail before Cilium installs the CRDs).

resource "null_resource" "cilium_resources" {
  triggers = {
    pool_yaml   = file("${local.cilium_dir}/lb-ip-pool.yaml")
    policy_yaml = file("${local.cilium_dir}/l2-announcement-policy.yaml")
    cilium_dir  = local.cilium_dir
  }

  provisioner "local-exec" {
    command = <<-EOT
      source ${path.module}/../scripts/common.sh
      load_tf_kube_env
      create_cert_dir
      kubectl_wrapper apply -f ${self.triggers.cilium_dir}/lb-ip-pool.yaml
      kubectl_wrapper apply -f ${self.triggers.cilium_dir}/l2-announcement-policy.yaml
    EOT
    environment = {
      INFRA_ROOT = "${path.module}/.."
      TF_DIR     = "${path.module}/../03-talos-configure"
    }
  }

  depends_on = [helm_release.cilium]

  lifecycle {
    ignore_changes = all
  }
}
