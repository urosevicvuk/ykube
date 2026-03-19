# Stage 04: Generate and provision all Vault secrets
# Providers, variables, and locals are symlinked from shared/

variable "vault_keys_file" {
  description = "Path to vault-keys.json from 03-vault-init"
  type        = string
  default     = "../03-vault-init/vault-keys.json"
}

# Manual inputs (can't be generated)
variable "cloudflared_tunnel_token" {
  description = "Cloudflare tunnel token"
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token for DNS-01 challenges"
  type        = string
  sensitive   = true
}

variable "authelia_users_database" {
  description = "Authelia users database YAML content (file-based auth backend)"
  type        = string
  sensitive   = true
  default     = <<-EOT
    users:
      admin:
        displayname: Admin
        password: "$argon2id$v=19$m=65536,t=3,p=4$CHANGE_ME"
        email: admin@urosevicvuk.dev
        groups:
          - admins
  EOT
}

locals {
  root_token = jsondecode(file(var.vault_keys_file)).root_token
}

# --- Generated secrets ---

resource "random_password" "gitlab_db" {
  length  = 32
  special = true
}

resource "random_password" "harbor_db" {
  length  = 32
  special = true
}

resource "random_password" "authelia_db" {
  length  = 32
  special = true
}

resource "random_password" "authelia_session_encryption" {
  length  = 64
  special = true
}

resource "random_password" "authelia_storage_encryption" {
  length  = 64
  special = true
}

resource "random_password" "authelia_hmac_secret" {
  length  = 64
  special = true
}

resource "random_password" "authelia_oidc_argocd_secret" {
  length  = 64
  special = false
}

resource "random_password" "authelia_oidc_grafana_secret" {
  length  = 64
  special = false
}

resource "tls_private_key" "authelia_oidc" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "random_password" "harbor_secret_key" {
  length  = 16
  special = false
}

resource "random_password" "harbor_admin_password" {
  length  = 32
  special = true
}

resource "random_password" "harbor_dagger_robot_password" {
  length  = 32
  special = true
}

resource "random_password" "pocket_id_encryption_key" {
  length  = 32
  special = false
}

resource "random_password" "searxng_secret_key" {
  length  = 32
  special = false
}

resource "random_password" "cosign_password" {
  length  = 32
  special = false
}

resource "tls_private_key" "cosign" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

# --- Vault login ---

resource "null_resource" "vault_login" {
  provisioner "local-exec" {
    command = "${local.vault_exec} vault login ${local.root_token} > /dev/null"
  }

  triggers = {
    always = timestamp()
  }
}

# --- Provision secrets ---

resource "null_resource" "secret_cloudflared" {
  provisioner "local-exec" {
    command = "${local.vault_exec} vault kv put secret/cloudflared token='${var.cloudflared_tunnel_token}'"
  }
  triggers = {
    token = md5(var.cloudflared_tunnel_token)
  }
  depends_on = [null_resource.vault_login]
}

resource "null_resource" "secret_cloudflare" {
  provisioner "local-exec" {
    command = "${local.vault_exec} vault kv put secret/cloudflare api-token='${var.cloudflare_api_token}'"
  }
  triggers = {
    token = md5(var.cloudflare_api_token)
  }
  depends_on = [null_resource.vault_login]
}

resource "null_resource" "secret_cnpg_gitlab" {
  provisioner "local-exec" {
    command = "${local.vault_exec} vault kv put secret/cloudnative-pg/gitlab username=gitlab password='${random_password.gitlab_db.result}'"
  }
  triggers = {
    password = random_password.gitlab_db.id
  }
  depends_on = [null_resource.vault_login]
}

resource "null_resource" "secret_cnpg_harbor" {
  provisioner "local-exec" {
    command = "${local.vault_exec} vault kv put secret/cloudnative-pg/harbor username=harbor password='${random_password.harbor_db.result}'"
  }
  triggers = {
    password = random_password.harbor_db.id
  }
  depends_on = [null_resource.vault_login]
}

resource "null_resource" "secret_cnpg_authelia" {
  provisioner "local-exec" {
    command = "${local.vault_exec} vault kv put secret/cloudnative-pg/authelia username=authelia password='${random_password.authelia_db.result}'"
  }
  triggers = {
    password = random_password.authelia_db.id
  }
  depends_on = [null_resource.vault_login]
}

resource "null_resource" "secret_authelia" {
  provisioner "local-exec" {
    command = <<-EOT
      ${local.vault_exec} vault kv put secret/authelia \
        session-encryption-key='${random_password.authelia_session_encryption.result}' \
        storage-encryption-key='${random_password.authelia_storage_encryption.result}' \
        hmac-secret='${random_password.authelia_hmac_secret.result}' \
        users-database='${replace(var.authelia_users_database, "'", "'\\''")}'
    EOT
  }
  triggers = {
    session = random_password.authelia_session_encryption.id
    storage = random_password.authelia_storage_encryption.id
    hmac    = random_password.authelia_hmac_secret.id
  }
  depends_on = [null_resource.vault_login]
}

resource "null_resource" "secret_authelia_oidc" {
  provisioner "local-exec" {
    command = <<-EOT
      ${local.vault_exec} sh -c 'vault kv put secret/authelia/oidc private-key="'"$(echo '${base64encode(tls_private_key.authelia_oidc.private_key_pem)}' | base64 -d)"'"'
    EOT
  }
  triggers = {
    key = tls_private_key.authelia_oidc.id
  }
  depends_on = [null_resource.vault_login]
}

resource "null_resource" "secret_authelia_oidc_clients" {
  provisioner "local-exec" {
    command = <<-EOT
      ${local.vault_exec} vault kv put secret/authelia/oidc/clients \
        argocd-secret='${random_password.authelia_oidc_argocd_secret.result}' \
        grafana-secret='${random_password.authelia_oidc_grafana_secret.result}'
    EOT
  }
  triggers = {
    argocd  = random_password.authelia_oidc_argocd_secret.id
    grafana = random_password.authelia_oidc_grafana_secret.id
  }
  depends_on = [null_resource.vault_login]
}

resource "null_resource" "secret_harbor" {
  provisioner "local-exec" {
    command = <<-EOT
      ${local.vault_exec} vault kv put secret/harbor \
        secret-key='${random_password.harbor_secret_key.result}' \
        admin-password='${random_password.harbor_admin_password.result}'
    EOT
  }
  triggers = {
    secret_key = random_password.harbor_secret_key.id
    admin_pw   = random_password.harbor_admin_password.id
  }
  depends_on = [null_resource.vault_login]
}

resource "null_resource" "secret_harbor_dagger_robot" {
  provisioner "local-exec" {
    command = "${local.vault_exec} vault kv put secret/harbor/dagger-robot-secret password='${random_password.harbor_dagger_robot_password.result}'"
  }
  triggers = {
    password = random_password.harbor_dagger_robot_password.id
  }
  depends_on = [null_resource.vault_login]
}

resource "null_resource" "secret_pocket_id" {
  provisioner "local-exec" {
    command = "${local.vault_exec} vault kv put secret/pocket-id encryption-key='${random_password.pocket_id_encryption_key.result}'"
  }
  triggers = {
    key = random_password.pocket_id_encryption_key.id
  }
  depends_on = [null_resource.vault_login]
}

resource "null_resource" "secret_searxng" {
  provisioner "local-exec" {
    command = "${local.vault_exec} vault kv put secret/searxng secret-key='${random_password.searxng_secret_key.result}'"
  }
  triggers = {
    key = random_password.searxng_secret_key.id
  }
  depends_on = [null_resource.vault_login]
}

resource "null_resource" "secret_cosign" {
  provisioner "local-exec" {
    command = <<-EOT
      ${local.vault_exec} vault kv put secret/cosign \
        password='${random_password.cosign_password.result}' \
        private-key='${base64encode(tls_private_key.cosign.private_key_pem)}' \
        public-key='${base64encode(tls_private_key.cosign.public_key_pem)}'
    EOT
  }
  triggers = {
    key = tls_private_key.cosign.id
  }
  depends_on = [null_resource.vault_login]
}

# --- Outputs ---

output "harbor_admin_password" {
  value     = random_password.harbor_admin_password.result
  sensitive = true
}

output "summary" {
  value = "All ${length([
    "cloudflared", "cloudflare",
    "cnpg/gitlab", "cnpg/harbor", "cnpg/authelia",
    "authelia", "authelia/oidc", "authelia/oidc/clients",
    "harbor", "harbor/dagger-robot-secret",
    "pocket-id", "searxng", "cosign",
  ])} secrets provisioned to Vault."
}
