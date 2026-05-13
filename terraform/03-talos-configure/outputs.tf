# Outputs consumed by stages 04+ (cilium / argocd / vault) and by the helper
# scripts in scripts/ which read them via `tofu output`.

output "kubernetes_client_configuration" {
  description = "Raw client config (host + base64 PKI) from talosctl kubeconfig"
  value       = talos_cluster_kubeconfig.this.kubernetes_client_configuration
  sensitive   = true
}

output "first_node_ip" {
  description = "IP of the first controlplane node — used as the API endpoint by stages 04/05/06."
  value       = local.first_node_ip
}

output "ca_cert" {
  description = "Kubernetes CA cert (decoded). Used by scripts/common.sh."
  value       = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
  sensitive   = true
}

output "client_cert" {
  description = "Kubernetes client cert (decoded). Used by scripts/common.sh."
  value       = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
  sensitive   = true
}

output "client_key" {
  description = "Kubernetes client key (decoded). Used by scripts/common.sh."
  value       = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  sensitive   = true
}
