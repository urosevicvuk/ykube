#!/usr/bin/env bash
# 03-vault-secrets-provision.sh — interactive prompt for each bootstrap secret,
# write to kv/*. Idempotent: skips kv paths that already exist.

set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd vault
require_cmd jq

VAULT_INIT_FILE="${SECRETS_DIR}/vault-init.json"
if [[ ! -f "${VAULT_INIT_FILE}" ]]; then
  die "Run 02-vault-init.sh first — ${VAULT_INIT_FILE} is missing."
fi

log "Starting port-forward to vault svc"
pf_pid="$(vault_port_forward_start vault vault 8200)"
trap 'vault_port_forward_stop "${pf_pid}"' EXIT
sleep 3

export VAULT_TOKEN=$(jq -r .root_token "${VAULT_INIT_FILE}")

prompt_secret() {
  local prompt="$1"
  local value
  read -r -s -p "${prompt}: " value
  echo
  printf '%s' "${value}"
}

prompt_value() {
  local prompt="$1"
  local value
  read -r -p "${prompt}: " value
  printf '%s' "${value}"
}

kv_exists() {
  local path="$1"
  vault kv get -format=json "${path}" >/dev/null 2>&1
}

log "Provisioning kv/cert-manager/cloudflare-api-token"
if kv_exists kv/cert-manager/cloudflare-api-token; then
  warn "  already set — skipping"
else
  token=$(prompt_secret "  Cloudflare API token (Zone:Read + DNS:Edit)")
  vault kv put kv/cert-manager/cloudflare-api-token api-token="${token}"
fi

log "Provisioning kv/external-dns/cloudflare-api-token"
if kv_exists kv/external-dns/cloudflare-api-token; then
  warn "  already set — skipping"
else
  warn "  (re-enter the same token as above, or a different token if you want scope separation)"
  token=$(prompt_secret "  Cloudflare API token for external-dns")
  vault kv put kv/external-dns/cloudflare-api-token api-token="${token}"
fi

log "Provisioning kv/cloudflared/credentials"
if kv_exists kv/cloudflared/credentials; then
  warn "  already set — skipping"
else
  path=$(prompt_value "  Path to cloudflared tunnel credentials JSON file")
  [[ -f "${path}" ]] || die "File not found: ${path}"
  vault kv put kv/cloudflared/credentials credentials.json="@${path}"
fi

log "Provisioning kv/argocd/admin"
if kv_exists kv/argocd/admin; then
  warn "  already set — skipping"
else
  pw=$(prompt_secret "  ArgoCD admin password (leave empty to skip)")
  if [[ -n "${pw}" ]]; then
    vault kv put kv/argocd/admin password="${pw}"
  fi
fi

log "Provisioning kv/grafana/admin"
if kv_exists kv/grafana/admin; then
  warn "  already set — skipping"
else
  pw=$(prompt_secret "  Grafana admin password")
  vault kv put kv/grafana/admin admin-user=admin admin-password="${pw}"
fi

log "Provisioning kv/forgejo/admin"
if kv_exists kv/forgejo/admin; then
  warn "  already set — skipping"
else
  user=$(prompt_value "  Forgejo admin username (e.g. vuk)")
  email=$(prompt_value "  Forgejo admin email")
  pw=$(prompt_secret "  Forgejo admin password")
  vault kv put kv/forgejo/admin username="${user}" password="${pw}" email="${email}"
fi

log "Provisioning kv/harbor/admin"
if kv_exists kv/harbor/admin; then
  warn "  already set — skipping"
else
  pw=$(prompt_secret "  Harbor admin password")
  vault kv put kv/harbor/admin password="${pw}"
fi

log "Provisioning kv/harbor/registry-secret (auto-generated)"
if kv_exists kv/harbor/registry-secret; then
  warn "  already set — skipping"
else
  vault kv put kv/harbor/registry-secret \
    secret="$(openssl rand -hex 32)" \
    core="$(openssl rand -hex 32)" \
    jobservice="$(openssl rand -hex 32)"
fi

log "Provisioning kv/morel/smtp-creds (optional — skip if morel is not deployed)"
if kv_exists kv/morel/smtp-creds; then
  warn "  already set — skipping"
else
  user=$(prompt_value "  Morel SMTP username (leave empty to skip morel SMTP)")
  if [[ -n "${user}" ]]; then
    pw=$(prompt_secret "  Morel SMTP password")
    vault kv put kv/morel/smtp-creds smtp-user="${user}" smtp-pass="${pw}"
  fi
fi

log "Skipping kv/morel/registry-creds — provision manually after Harbor is up:"
log "  vault kv put kv/morel/registry-creds .dockerconfigjson=@/tmp/dockerconfig.json"

log "Done. ExternalSecrets should converge within 1 minute."
