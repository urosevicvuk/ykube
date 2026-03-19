variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "~/.kube/config"
}

variable "project_root" {
  description = "Root of the ykube repository"
  type        = string
  default     = "../.."
}

variable "infra_root" {
  description = "Root of the infrastructure directory"
  type        = string
  default     = ".."
}
