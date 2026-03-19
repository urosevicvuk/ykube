# Stage 03: Initialize Vault, unseal, configure K8s auth and ESO
# Providers, variables, and locals are symlinked from shared/

variable "vault_key_shares" {
  description = "Number of key shares for Vault init"
  type        = number
  default     = 5
}

variable "vault_key_threshold" {
  description = "Number of key shares required to unseal"
  type        = number
  default     = 3
}

locals {
  vault_keys_file = "${path.module}/vault-keys.json"
}

# Idempotent init + unseal
resource "null_resource" "vault_init" {
  provisioner "local-exec" {
    command = "${local.scripts}/vault-bootstrap.sh"
    environment = {
      KUBECONFIG      = var.kubeconfig_path
      KEY_SHARES      = var.vault_key_shares
      KEY_THRESHOLD   = var.vault_key_threshold
      VAULT_KEYS_FILE = local.vault_keys_file
    }
  }
}

# Configure Vault for ESO
resource "null_resource" "vault_enable_kv" {
  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      ROOT_TOKEN=$(jq -r '.root_token' "${local.vault_keys_file}")
      ${local.vault_exec} vault login "$ROOT_TOKEN" > /dev/null
      ${local.vault_exec} vault secrets enable -path=secret kv-v2 2>/dev/null || true
    EOT
  }

  depends_on = [null_resource.vault_init]
}

resource "null_resource" "vault_enable_k8s_auth" {
  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      ROOT_TOKEN=$(jq -r '.root_token' "${local.vault_keys_file}")
      ${local.vault_exec} vault login "$ROOT_TOKEN" > /dev/null
      ${local.vault_exec} vault auth enable kubernetes 2>/dev/null || true
      ${local.vault_exec} vault write auth/kubernetes/config \
        kubernetes_host="https://kubernetes.default.svc:443"
    EOT
  }

  depends_on = [null_resource.vault_init]
}

resource "null_resource" "vault_eso_policy" {
  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      ROOT_TOKEN=$(jq -r '.root_token' "${local.vault_keys_file}")
      ${local.vault_exec} vault login "$ROOT_TOKEN" > /dev/null
      ${local.vault_exec} sh -c 'cat <<POLICY | vault policy write external-secrets -
      path "secret/data/*" {
        capabilities = ["read", "list"]
      }
      path "secret/metadata/*" {
        capabilities = ["read", "list"]
      }
      POLICY'
    EOT
  }

  depends_on = [null_resource.vault_enable_kv]
}

resource "null_resource" "vault_eso_role" {
  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      ROOT_TOKEN=$(jq -r '.root_token' "${local.vault_keys_file}")
      ${local.vault_exec} vault login "$ROOT_TOKEN" > /dev/null
      ${local.vault_exec} vault write auth/kubernetes/role/external-secrets \
        bound_service_account_names=external-secrets-vault-auth \
        bound_service_account_namespaces=external-secrets \
        policies=external-secrets \
        ttl=24h
    EOT
  }

  depends_on = [null_resource.vault_enable_k8s_auth, null_resource.vault_eso_policy]
}

output "vault_keys_file" {
  value = local.vault_keys_file
}
