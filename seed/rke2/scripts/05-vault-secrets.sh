#!/usr/bin/env bash
# 05-vault-secrets.sh — write the bootstrap secrets every ExternalSecret in the
# repo reads (kv/*). Interactive; skips paths that already exist.
#
# Covers every `remoteRef.key` / `dataFrom.extract.key` under apps/ and root/
# as of 2026-11-26. Add a block here when a new ExternalSecret lands.
#
# MIGRATING FROM firelink: some values must be COPIED, not regenerated, or the
# data they protect becomes unreadable. Read them from firelink's Vault first:
#   vault kv get -format=json kv/n8n/encryption            (n8n credentials)
#   vault kv get -format=json kv/opencloud/service-account (OpenCloud config)
#   vault kv get -format=json kv/vaultwarden/admin
#   vault kv get -format=json kv/harbor/registry-secret
# and paste them when prompted. Everything else can be fresh.

source "$(dirname "$0")/common.sh"
require_cmd kubectl vault jq openssl
require_cluster
[[ -f "${VAULT_INIT_FILE}" ]] || die "Run vault:init first — ${VAULT_INIT_FILE} is missing."

export VAULT_ADDR="http://127.0.0.1:8200"
VAULT_TOKEN="$(jq -r .root_token "${VAULT_INIT_FILE}")"
export VAULT_TOKEN

log "Port-forwarding to the active Vault replica"
kubectl -n vault port-forward svc/vault-active 8200:8200 >/dev/null 2>&1 &
pf_pid=$!
trap 'kill "${pf_pid}" 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do
  vault status >/dev/null 2>&1 && break
  sleep 1
done
vault status >/dev/null || die "Vault is not reachable/unsealed through the port-forward."

prompt_secret() {
  local value
  read -r -s -p "$1: " value
  echo >&2
  printf '%s' "${value}"
}
prompt_value() {
  local value
  read -r -p "$1: " value
  printf '%s' "${value}"
}
kv_exists() { vault kv get -format=json "$1" >/dev/null 2>&1; }
section() {
  log "kv/$1"
  if kv_exists "kv/$1"; then
    warn "  already set — skipping"
    return 1
  fi
}

# --- Networking ---------------------------------------------------------

if section cert-manager/cloudflare-api-token; then
  vault kv put kv/cert-manager/cloudflare-api-token \
    api-token="$(prompt_secret '  Cloudflare API token for cert-manager DNS-01 (Zone:Read + DNS:Edit)')"
fi

if section external-dns/cloudflare-api-token; then
  vault kv put kv/external-dns/cloudflare-api-token \
    api-token="$(prompt_secret '  Cloudflare API token for external-dns (same or a separate token)')"
fi

if section cloudflared/credentials; then
  path="$(prompt_value '  Path to the cloudflared tunnel credentials JSON (~/.cloudflared/<tunnel-id>.json)')"
  [[ -f "${path}" ]] || die "File not found: ${path}"
  vault kv put kv/cloudflared/credentials credentials.json="@${path}"
fi

if section tailscale/operator-oauth; then
  log "  Tailscale admin console -> Settings -> Trust credentials (OAuth client), scopes per"
  log "  apps/system/networking/tailscale-operator/secrets.yaml"
  vault kv put kv/tailscale/operator-oauth \
    client_id="$(prompt_value '  client_id')" \
    client_secret="$(prompt_secret '  client_secret')"
fi

# --- Platform -----------------------------------------------------------

if section argocd/webhook; then
  secret="$(prompt_secret '  GitHub webhook secret used by the repo webhooks (empty = generate)')"
  [[ -n "${secret}" ]] || secret="$(openssl rand -hex 32)"
  vault kv put kv/argocd/webhook github-secret="${secret}"
  log "  set the same value as the secret of each GitHub repo webhook (ykube, morelrs/infra)"
fi

if section morel/infra-repo; then
  vault kv put kv/morel/infra-repo \
    username="$(prompt_value '  Git username for morelrs/infra (e.g. morel-argocd)')" \
    password="$(prompt_secret '  Fine-grained PAT, Contents: read on morelrs/infra')"
fi

if section grafana/admin; then
  vault kv put kv/grafana/admin admin-user=admin \
    admin-password="$(prompt_secret '  Grafana admin password')"
fi

if section forgejo/admin; then
  vault kv put kv/forgejo/admin \
    username="$(prompt_value '  Forgejo admin username')" \
    email="$(prompt_value '  Forgejo admin email')" \
    password="$(prompt_secret '  Forgejo admin password')"
fi

if section harbor/admin; then
  vault kv put kv/harbor/admin password="$(prompt_secret '  Harbor admin password')"
fi

if section harbor/registry-secret; then
  if [[ "$(prompt_value '  Generate fresh Harbor internal secrets? [Y/n] (n = paste firelink values)')" =~ ^[Nn] ]]; then
    vault kv put kv/harbor/registry-secret \
      secret="$(prompt_secret '  secret')" core="$(prompt_secret '  core')" jobservice="$(prompt_secret '  jobservice')"
  else
    vault kv put kv/harbor/registry-secret \
      secret="$(openssl rand -hex 32)" core="$(openssl rand -hex 32)" jobservice="$(openssl rand -hex 32)"
  fi
fi

# --- Homelab ------------------------------------------------------------

if section n8n/encryption; then
  warn "  MIGRATING: paste firelink's key, or every stored n8n credential becomes unreadable."
  key="$(prompt_secret '  N8N encryption key (empty = generate, ONLY for a fresh n8n)')"
  [[ -n "${key}" ]] || key="$(openssl rand -hex 32)"
  vault kv put kv/n8n/encryption key="${key}"
fi

if section opencloud/service-account; then
  warn "  MIGRATING: paste firelink's id/secret (they're written into OpenCloud's config)."
  id="$(prompt_value '  Service account id (empty = generate, ONLY for a fresh OpenCloud)')"
  if [[ -z "${id}" ]]; then
    id="$(cat /proc/sys/kernel/random/uuid)"
    secret="$(openssl rand -hex 32)"
  else
    secret="$(prompt_secret '  Service account secret')"
  fi
  vault kv put kv/opencloud/service-account id="${id}" secret="${secret}"
fi

if section vaultwarden/admin; then
  log "  An argon2 hash: docker run --rm -it vaultwarden/server /vaultwarden hash"
  # shellcheck disable=SC2016  # literal $argon2id$ in the prompt
  vault kv put kv/vaultwarden/admin token="$(prompt_secret '  Vaultwarden admin token hash ($argon2id$...)')"
fi

log "Done. ExternalSecrets refresh within a minute:"
log "  kubectl get externalsecrets -A"
