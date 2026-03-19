locals {
  kubectl    = "kubectl --kubeconfig ${var.kubeconfig_path}"
  vault_exec = "${local.kubectl} exec -n vault vault-0 --"
  scripts    = "${var.infra_root}/scripts"
}
