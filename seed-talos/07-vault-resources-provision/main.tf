# Stage 07: write the bootstrap secrets that the cluster needs to actually
# converge. Right now this is just one — the Cloudflare API token used by
# cert-manager DNS-01. Add more entries as new ExternalSecrets land in the repo.
#
# Pattern: each secret is a null_resource that exec's into vault-0 and runs
# `vault kv put kv/<path> <key>=<value>`. Triggers re-run only when the value
# changes. Random passwords (e.g. for Postgres app-user creds) can be added
# with a sibling random_password resource — see h8s for the full menagerie.

# ------------------------------------------------------------
# Cloudflare API token — unblocks cert-manager ClusterIssuers
# ------------------------------------------------------------
# Path matches apps/system/networking/cert-manager/external-secret.yaml:
#   remoteRef.key:      cert-manager/cloudflare-api-token
#   remoteRef.property: api-token
# Vault kv-v2 stores it at kv/data/cert-manager/cloudflare-api-token.

resource "null_resource" "vault_secret_cloudflare_api_token" {
  triggers = {
    secret_hash     = sha256(var.cloudflare_api_token)
    init_token_path = data.terraform_remote_state.vault_init.outputs.vault_init_file
  }

  provisioner "local-exec" {
    command = <<-EOT
      source ${path.module}/../scripts/common.sh
      load_tf_kube_env
      create_cert_dir

      VAULT_TOKEN=$(jq -r '.root_token' ${self.triggers.init_token_path})
      kubectl_wrapper exec vault-0 -n vault -- /bin/sh -c "
        export VAULT_TOKEN='$VAULT_TOKEN'
        vault login -no-store \"\$VAULT_TOKEN\" >/dev/null
        vault kv put kv/cert-manager/cloudflare-api-token \\
          api-token='${var.cloudflare_api_token}'
      "
    EOT
    environment = {
      INFRA_ROOT = "${path.module}/.."
      TF_DIR     = "${path.module}/../03-talos-configure"
    }
  }
}
