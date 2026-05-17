data "terraform_remote_state" "talos_configure" {
  backend = "local"
  config = {
    path = "../states/03-talos-configure.tfstate"
  }
}

# Probe the kube-system namespace to ensure the API is healthy before we
# helm-install ArgoCD. Cilium from stage 04 should already have kubelets
# Ready, but Argo CRDs come from the chart itself, so we don't need to wait
# on them.
data "kubernetes_namespace_v1" "probe" {
  metadata {
    name = "kube-system"
  }
}
