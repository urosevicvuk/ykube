# Stage 02: Install ArgoCD and apply app-of-apps
# Providers, variables, and locals are symlinked from shared/

# Read chart version from ArgoCD Application YAML (single source of truth)
locals {
  argocd_app = yamldecode(file("${var.project_root}/ci-cd/argocd/environments/prod/apps/argocd.yaml"))
  argocd_version = [
    for s in local.argocd_app.spec.sources : s.targetRevision
    if try(s.chart, "") == "argo-cd"
  ][0]
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = local.argocd_version
  namespace  = "argocd"
  timeout    = 600

  values = [
    file("${var.project_root}/ci-cd/argocd/environments/prod/values.yaml")
  ]

  depends_on = [kubernetes_namespace.argocd]
}

# Wait for ArgoCD server to be ready
resource "null_resource" "wait_argocd" {
  provisioner "local-exec" {
    command = "${local.kubectl} -n argocd rollout status deployment/argocd-server --timeout=300s"
  }

  depends_on = [helm_release.argocd]
}

# Apply the app-of-apps using kubectl (ArgoCD CRDs don't exist during plan)
resource "null_resource" "app_of_apps" {
  provisioner "local-exec" {
    command = "${local.kubectl} apply -f ${var.project_root}/ci-cd/argocd/environments/prod/app-of-apps.yaml"
  }

  depends_on = [null_resource.wait_argocd]
}

output "argocd_version" {
  value = local.argocd_version
}

output "argocd_password_cmd" {
  value = "${local.kubectl} -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
