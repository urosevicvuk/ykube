#!/usr/bin/env bash
# 00-kubeconfig.sh — fetch the RKE2 admin kubeconfig from a node and point it
# at the API VIP.
#
# RKE2 writes /etc/rancher/rke2/rke2.yaml root-only (mode 0600, server
# https://127.0.0.1:6443). This copies it to seed/rke2/secrets/kubeconfig.yaml
# (gitignored), rewrites the server to the VIP and names the context `ykube`.
#
#   API_VIP=192.168.1.10 task -d seed/rke2 kubeconfig
#   NODE=kiln2 SSH_USER=vyke API_VIP=... task -d seed/rke2 kubeconfig
#
# API_VIP must match ykube.cluster.lan.apiVip in ynix modules/sites/office.nix.

source "$(dirname "$0")/common.sh"
require_cmd ssh scp yq kubectl

NODE="${NODE:-kiln1}"
SSH_USER="${SSH_USER:-${USER}}"
API_VIP="${API_VIP:?Set API_VIP to the cluster API VIP (ynix modules/sites/office.nix)}"
OUT="${SECRETS_DIR}/kubeconfig.yaml"
REMOTE_TMP="/tmp/rke2-kubeconfig.$$"

mkdir -p "${SECRETS_DIR}"
umask 077

log "Copying /etc/rancher/rke2/rke2.yaml from ${SSH_USER}@${NODE} (sudo will ask for your password)"
ssh -t "${SSH_USER}@${NODE}" "sudo install -m 0600 -o ${SSH_USER} /etc/rancher/rke2/rke2.yaml ${REMOTE_TMP}"
scp -q "${SSH_USER}@${NODE}:${REMOTE_TMP}" "${OUT}"
# shellcheck disable=SC2029  # REMOTE_TMP is meant to expand locally
ssh "${SSH_USER}@${NODE}" "rm -f ${REMOTE_TMP}"

log "Pointing it at https://${API_VIP}:6443 (context: ykube)"
yq -i "
  .clusters[0].cluster.server = \"https://${API_VIP}:6443\" |
  .clusters[0].name = \"ykube\" |
  .users[0].name = \"ykube-admin\" |
  .contexts[0].name = \"ykube\" |
  .contexts[0].context.cluster = \"ykube\" |
  .contexts[0].context.user = \"ykube-admin\" |
  .current-context = \"ykube\"
" "${OUT}"
chmod 600 "${OUT}"

log "Wrote ${OUT}"
KUBECONFIG="${OUT}" kubectl get nodes -o wide
log "Nodes stay NotReady until Cilium is installed (next: task -d seed/rke2 cilium)."
