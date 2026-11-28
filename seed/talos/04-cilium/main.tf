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
  # path.module is this stage's directory (seed/talos/<stage>); ../../.. is the repo root.
  repo_root = "${path.module}/../../.."

  cilium_dir           = "${local.repo_root}/apps/system/networking/cilium"
  cilium_kustomization = yamldecode(file("${local.cilium_dir}/kustomization.yaml"))
  cilium_chart_version = local.cilium_kustomization.helmCharts[0].version
  cilium_values        = file("${local.cilium_dir}/values.yaml")

  # Envoy Gateway's CRD chart is versioned in lockstep with the controller
  # chart that apps/system/networking/envoy deploys — read it from there.
  envoy_kustomization = yamldecode(file("${local.repo_root}/apps/system/networking/envoy/kustomization.yaml"))
  envoy_chart_version = [for c in local.envoy_kustomization.helmCharts : c.version if c.name == "gateway-helm"][0]
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

# Gateway API + Envoy Gateway CRDs (Gateway, HTTPRoute, ListenerSet, TCPRoute,
# EnvoyProxy, ClientTrafficPolicy, ...). Nothing else installs them: the
# envoy app's gateway-helm chart no longer bundles CRDs (they moved to the
# separate gateway-crds-helm chart), and every Gateway/HTTPRoute in the repo
# — including root/argocd-route.yaml in the very first Argo sync — needs them.
# Experimental channel because the repo uses ListenerSet and TCPRoute.
# Server-side apply because HTTPRoute's schema is too large for client-side
# apply's last-applied annotation; the bootstrap owns these CRDs, not Argo
# (see apps/system/networking/envoy/kustomization.yaml). To update them later,
# bump the envoy chart and re-run the same pipeline by hand.
resource "null_resource" "gateway_crds" {
  triggers = {
    version    = local.envoy_chart_version
    infra_root = "${path.module}/.."
  }

  provisioner "local-exec" {
    command = <<-EOT
      source ${self.triggers.infra_root}/scripts/common.sh
      load_tf_kube_env
      create_cert_dir
      helm template gateway-crds oci://docker.io/envoyproxy/gateway-crds-helm \
        --version ${self.triggers.version} \
        --set crds.gatewayAPI.enabled=true \
        --set crds.gatewayAPI.channel=experimental \
        --set crds.envoyGateway.enabled=true \
        | kubectl_wrapper apply --server-side -f -
    EOT
    environment = {
      INFRA_ROOT = self.triggers.infra_root
      TF_DIR     = "${self.triggers.infra_root}/03-talos-configure"
    }
  }

  depends_on = [helm_release.cilium]

  lifecycle {
    ignore_changes = all
  }
}

# Prometheus Operator CRDs (ServiceMonitor, PodMonitor, PrometheusRule, ...).
# Most system charts render ServiceMonitors and would SyncFail until
# kube-prometheus-stack itself lands. Pre-installing the CRDs decouples the
# order; kube-prometheus-stack adopts them via server-side apply. The version
# must match the Prometheus Operator that kube-prometheus-stack ships (its
# chart appVersion) — bump both together.
resource "null_resource" "prometheus_operator_crds" {
  triggers = {
    version    = "v0.95.2" # = kube-prometheus-stack 93.10.0 appVersion; bump together
    infra_root = "${path.module}/.."
  }

  provisioner "local-exec" {
    command = <<-EOT
      source ${self.triggers.infra_root}/scripts/common.sh
      load_tf_kube_env
      create_cert_dir
      kubectl_wrapper apply --server-side -f https://github.com/prometheus-operator/prometheus-operator/releases/download/${self.triggers.version}/stripped-down-crds.yaml
    EOT
    environment = {
      INFRA_ROOT = self.triggers.infra_root
      TF_DIR     = "${self.triggers.infra_root}/03-talos-configure"
    }
  }

  depends_on = [helm_release.cilium]

  lifecycle {
    ignore_changes = all
  }
}
