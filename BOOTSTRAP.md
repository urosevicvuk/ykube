# Bootstrap

Steps to bring up a fresh ykube cluster. No IaC yet — everything below is manual.

> **Status**: This file is a skeleton. Items marked **TBD** need to be filled in from the operator's actual procedure before relying on this doc.

## 1. K3s install

On the server:

```bash
# TBD: capture exact flags currently used (e.g. --disable=traefik, --write-kubeconfig-mode, etc.)
curl -sfL https://get.k3s.io | sh -
```

Copy `/etc/rancher/k3s/k3s.yaml` to the laptop, edit the server URL to the LAN IP, and use it as `KUBECONFIG`.

## 2. ArgoCD bootstrap

ArgoCD is installed out-of-band (not via this repo's app-of-apps, since the Application manifests *are* the repo).

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
# TBD: confirm version pin used in production
```

Then apply the root Application to start the app-of-apps reconciliation:

```bash
kubectl apply -f root/root.yaml
```

ArgoCD will sync everything under `root/` recursively from there.

## 3. Cloudflare tunnel

The cluster is exposed via Cloudflare Tunnel; the tunnel daemon runs as a Deployment in `system-ingress` (manifests under `manifests/networking/cloudflared/`).

- Tunnel credentials are mounted from a SealedSecret at `manifests/networking/cloudflared/secrets.yaml`.
- DNS routing rules live in `manifests/networking/cloudflared/config.yaml`.
- TBD: capture the `cloudflared tunnel create` + `cloudflared tunnel route dns ...` commands originally run.

## 4. Vault init + unseal

Vault deploys as a single-replica StatefulSet with file storage on Longhorn (chart `0.32.0`, values at `manifests/security/vault/environments/prod/values.yaml`).

After ArgoCD syncs Vault for the first time:

```bash
# Initialize (one time only — keep the unseal keys and root token safe)
kubectl exec -n system-security vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 > vault-init.txt

# Unseal (repeat for 3 of the 5 keys, or until Sealed=false)
kubectl exec -n system-security vault-0 -- vault operator unseal <key>

# After every pod restart you have to unseal again — this Vault is not auto-unsealed.
```

Configure Kubernetes auth (so ESO can talk to Vault):

```bash
# TBD: paste actual commands the operator used. Roughly:
# vault auth enable kubernetes
# vault write auth/kubernetes/config kubernetes_host=...
# vault write auth/kubernetes/role/external-secrets ...
```

The `ClusterSecretStore` referencing this auth role lives at `manifests/security/external-secrets/clustersecretstore.yaml`.

## 5. SealedSecrets controller

The controller is installed by ArgoCD (`manifests/security/sealed-secrets/`). Generate a sealed secret on the laptop:

```bash
kubectl create secret generic <name> --dry-run=client -o yaml --from-literal=key=value \
  | kubeseal --controller-name sealed-secrets --controller-namespace system-security \
  > sealed.yaml
```

## 6. GitLab runner registration

The only repo-side manual step after bootstrap. After GitLab finishes installing:

1. Log in, retrieve the runner registration token.
2. Register a runner on the cluster (or external host):
   ```bash
   # TBD: actual runner registration command and target host
   ```

## Recovery / rebuild

To rebuild from scratch: wipe the K3s install (`/usr/local/bin/k3s-uninstall.sh`), rerun steps 1–6. State on Longhorn volumes is lost unless backed up separately. **TBD: backup procedure.**
