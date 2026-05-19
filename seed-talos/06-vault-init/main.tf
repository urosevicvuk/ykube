# Stage 06: initialise + unseal Vault, enable k8s auth and the kv-v2 mount,
# create the policy + role that External Secrets Operator binds to.
#
# Runs after stage 05 has applied the GitOps root: Vault's chart is deployed
# by Argo (apps/system/foundation/vault/, raft HA, 3 replicas) and pods come
# up Running but sealed. This stage drives them to Initialised + Unsealed,
# then plumbs in the auth path that ESO uses to read kv/* secrets.
#
# The vault-bootstrap script handles raft auto-join: vault-0 inits the cluster,
# vault-1 / vault-2 join automatically and just need an unseal pass.
#
# IMPORTANT: secrets/vault-init.json contains the unseal keys + root token.
# Back it up to Bitwarden before tearing down the workstation.

resource "null_resource" "wait_for_kubernetes_api" {
  provisioner "local-exec" {
    command = "bash ${path.module}/../scripts/wait-for-k8s-api.sh"
    environment = {
      INFRA_ROOT = "${path.module}/.."
      TF_DIR     = "${path.module}/../03-talos-configure"
    }
  }
}

# ------------------------------------------------------------
# Init + unseal (idempotent, replays cleanly after any node reboot)
# ------------------------------------------------------------
resource "null_resource" "vault_bootstrap" {
  triggers = {
    # Re-run on every apply — the script is idempotent and gracefully skips
    # work that's already done. This is what you want, because pods that
    # restart come back sealed and need to be re-unsealed.
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/../scripts/vault-bootstrap.sh"
    environment = {
      INFRA_ROOT = "${path.module}/.."
      TF_DIR     = "${path.module}/../03-talos-configure"
      OUT_FILE   = "${path.module}/secrets/vault-init.json"
    }
  }

  depends_on = [null_resource.wait_for_kubernetes_api]
}

# ------------------------------------------------------------
# k8s auth method
# ------------------------------------------------------------
# Lets pods authenticate to Vault using their projected ServiceAccount token.
# ESO is the consumer — see resource null_resource.vault_role_external_secrets.

resource "null_resource" "vault_k8s_auth" {
  triggers = {
    init_token_path = "${path.module}/secrets/vault-init.json"
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
        vault auth list | grep -q '^kubernetes/' || vault auth enable kubernetes
        vault write auth/kubernetes/config \\
          kubernetes_host=\"https://\$KUBERNETES_PORT_443_TCP_ADDR:443\" \\
          kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      "
    EOT
    environment = {
      INFRA_ROOT = "${path.module}/.."
      TF_DIR     = "${path.module}/../03-talos-configure"
    }
  }

  depends_on = [null_resource.vault_bootstrap]
}

# ------------------------------------------------------------
# kv-v2 mount at path `kv` (matches our ClusterSecretStore.spec.provider.vault.path)
# ------------------------------------------------------------
resource "null_resource" "vault_enable_kv" {
  triggers = {
    init_token_path = "${path.module}/secrets/vault-init.json"
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
        vault secrets list | grep -q '^kv/' || vault secrets enable -path=kv -version=2 kv
      "
    EOT
    environment = {
      INFRA_ROOT = "${path.module}/.."
      TF_DIR     = "${path.module}/../03-talos-configure"
    }
  }

  depends_on = [null_resource.vault_bootstrap]
}

# ------------------------------------------------------------
# Policy: ESO can read everything under kv/
# ------------------------------------------------------------
resource "null_resource" "vault_policy_external_secrets" {
  triggers = {
    init_token_path = "${path.module}/secrets/vault-init.json"
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
        vault policy write external-secrets - <<'POLICY'
path \"kv/data/*\"     { capabilities = [\"read\"] }
path \"kv/metadata/*\" { capabilities = [\"read\", \"list\"] }
POLICY
      "
    EOT
    environment = {
      INFRA_ROOT = "${path.module}/.."
      TF_DIR     = "${path.module}/../03-talos-configure"
    }
  }

  depends_on = [null_resource.vault_enable_kv]
}

# ------------------------------------------------------------
# Role: bind the ESO ServiceAccount to the policy above
# ------------------------------------------------------------
# Matches apps/system/foundation/external-secrets/cluster-secret-store.yaml:
#   role:               external-secrets
#   serviceAccount:     external-secrets/external-secrets
resource "null_resource" "vault_role_external_secrets" {
  triggers = {
    init_token_path = "${path.module}/secrets/vault-init.json"
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
        vault write auth/kubernetes/role/external-secrets \\
          bound_service_account_names=external-secrets \\
          bound_service_account_namespaces=external-secrets \\
          policies=external-secrets \\
          ttl=1h
      "
    EOT
    environment = {
      INFRA_ROOT = "${path.module}/.."
      TF_DIR     = "${path.module}/../03-talos-configure"
    }
  }

  depends_on = [
    null_resource.vault_k8s_auth,
    null_resource.vault_policy_external_secrets,
  ]
}
