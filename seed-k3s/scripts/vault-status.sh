#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_cmd vault

pf_pid="$(vault_port_forward_start vault vault 8200)"
trap 'vault_port_forward_stop "${pf_pid}"' EXIT
sleep 2

vault status || true
