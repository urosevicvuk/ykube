# Stage 05: seed-install ArgoCD, then kubectl apply root/app-of-apps.yaml.
#
# Same pattern as stage 04: TF helm-installs once with values + version pulled
# from root/ (where the argo-cd chart + values now live as part of the
# app-of-apps kustomization), then ignore_changes = all so Argo can self-manage
# its own chart upgrades. The root Application IS the argocd self-manager.
#
# After this stage finishes, the root Application is created. From there:
# Argo creates AppProjects + AppSets, AppSets generate Applications, and the
# whole cluster starts converging. Stage 06/07 still need to run to unblock
# the ESO/cert-manager chain — see terraform/README.md.

locals {
  repo_root = "${path.module}/../.."

  argocd_dir           = "${local.repo_root}/root"
  argocd_kustomization = yamldecode(file("${local.argocd_dir}/kustomization.yaml"))
  argocd_chart_version = local.argocd_kustomization.helmCharts[0].version
  argocd_values        = file("${local.argocd_dir}/values.yaml")
  root_app_manifest    = file("${local.repo_root}/root/app-of-apps.yaml")
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = local.argocd_chart_version
  namespace  = "argocd"

  values = [local.argocd_values]

  wait             = true
  wait_for_jobs    = true
  timeout          = 600
  create_namespace = true

  # Probe ensures the API is healthy before we start the helm install.
  depends_on = [data.kubernetes_namespace_v1.probe]

  lifecycle {
    ignore_changes = all
  }
}

# ------------------------------------------------------------
# Apply app-of-apps.yaml — the GitOps pivot point
# ------------------------------------------------------------
# kubernetes_manifest validates against the live API at plan time, which fails
# before the Argo CRDs exist. null_resource + kubectl_wrapper sidesteps that.

resource "null_resource" "root_app" {
  triggers = {
    manifest   = local.root_app_manifest
    infra_root = "${path.module}/.."
  }

  provisioner "local-exec" {
    command = <<-EOT
      source ${self.triggers.infra_root}/scripts/common.sh
      load_tf_kube_env
      create_cert_dir
      kubectl_wrapper apply -f - <<'MANIFEST'
${self.triggers.manifest}
MANIFEST
    EOT
    environment = {
      INFRA_ROOT = self.triggers.infra_root
      TF_DIR     = "${self.triggers.infra_root}/03-talos-configure"
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      source ${self.triggers.infra_root}/scripts/common.sh
      load_tf_kube_env
      create_cert_dir
      kubectl_wrapper delete --ignore-not-found -f - <<'MANIFEST'
${self.triggers.manifest}
MANIFEST
    EOT
    environment = {
      INFRA_ROOT = self.triggers.infra_root
      TF_DIR     = "${self.triggers.infra_root}/03-talos-configure"
    }
  }

  depends_on = [helm_release.argocd]
}
