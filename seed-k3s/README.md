# seed-k3s/

Bootstrap pipeline for the **k3s/firelink** cluster. Takes the cluster from
"k3s flags swapped to disable Flannel + kube-proxy + servicelb" to "ArgoCD
reconciling the GitOps repo".

The Talos+Proxmox pipeline lives at [`seed-talos/`](../seed-talos/README.md)
— that's the future target and is currently deferred.

## What this assumes

The `firelink` NixOS host has already been rebuilt with the k3s flags from
`ynix/modules/features/cluster/k3s.nix`:

- `--flannel-backend=none`
- `--disable-kube-proxy`
- `--disable-network-policy`
- `--disable=servicelb`
- `--disable=traefik`

After that rebuild, k3s nodes have **no pod networking** until Cilium is
installed. Step 00 below installs Cilium and gets the cluster healthy again.
Don't run this if Cilium is already healthy — it's idempotent but `helm
install` will refuse to re-run.

## Prerequisites

From the repo's dev shell (`nix develop`):

- `kubectl` pointed at the firelink k3s cluster (kubeconfig at
  `/etc/rancher/k3s/k3s.yaml` on the host, copy to `~/.kube/config` if
  running off-host)
- `helm`, `cilium`, `vault`, `jq`, `yq`, `task`

You'll need three things in your hand before running:

1. **A Cloudflare API token** with `Zone:Read` + `DNS:Edit` on the four
   domains (urosevicvuk.dev, morel.rs, raf-project.com, ofnir.dev).
   Used by cert-manager (DNS-01) + external-dns.
2. **A Cloudflare Tunnel credentials JSON** (the file `cloudflared tunnel
   create ykube` writes to `~/.cloudflared/<tunnel-id>.json`). Used by the
   in-cluster cloudflared.
3. **An age/SSH identity** that can decrypt the existing `sops` secrets on
   the NixOS host, if you want to import the same Cloudflare tokens that
   ynix's sops-nix already has.

## Bootstrap

```bash
nix develop
export KUBECONFIG=/path/to/k3s.yaml   # or merge into ~/.kube/config
task -d seed-k3s cluster:bootstrap
```

This runs stages 00 → 03 in order:

| Stage | What it does |
|-------|--------------|
| `00-cilium-install` | Install Cilium 1.19.3 onto k3s with the values from `apps/system/networking/cilium/values.yaml`. CNI + kube-proxy replacement + Gateway API + L2 announcements + Hubble. |
| `01-argocd-install` | Install ArgoCD 9.5.13 + `kubectl apply -f root/app-of-apps.yaml`. GitOps takes over from this point. |
| `02-vault-init` | Wait for vault pods to be `Running` (sealed), `vault operator init` (5 keys, threshold 3), save unseal keys + root token to `secrets/vault-init.json`, unseal Vault, mount kv-v2 at `kv/`, enable Kubernetes auth, create the ESO policy + role. |
| `03-vault-secrets-provision` | Prompt for each bootstrap secret (Cloudflare API token, tunnel credentials JSON, admin passwords for Grafana / ArgoCD / Forgejo / Harbor / etc.) and write to `kv/`. ExternalSecrets materialize into the cluster. |

After bootstrap, Argo's first sync settles in 5-10 minutes. Expected
first-sync transients (auto-resolve):

- ServiceMonitors in cert-manager / external-secrets fail until kube-prom-stack
  syncs (CRDs land out of order).
- ExternalSecrets stay Pending until step 02 + 03 finish.
- ClusterIssuers stay `False/Pending` until the cloudflare-api-token Secret
  materializes from ESO.
- CNPG Cluster manifests show `Setting up primary` briefly while Postgres initializes.

## Re-running after node reboot

Vault's file storage requires unseal after every restart:

```bash
task -d seed-k3s vault:unseal
```

This reads `secrets/vault-init.json` and replays three of the five unseal keys.

## Manual post-bootstrap steps

A few things need a human in the loop after the stack is healthy:

1. **Harbor**: log in at `https://registry.urosevicvuk.dev` as admin (password
   from `kv/harbor/admin`), create project `morel`, push the morel image:
   ```bash
   docker login registry.urosevicvuk.dev
   docker pull <wherever-the-old-morel-image-is>
   docker tag <old> registry.urosevicvuk.dev/morel/website:v1.1.1
   docker push registry.urosevicvuk.dev/morel/website:v1.1.1
   ```
   Then create a robot account scoped to `morel/*` pull-only, dump its docker
   config, and write to Vault:
   ```bash
   vault kv put kv/morel/registry-creds .dockerconfigjson=@/tmp/dockerconfig.json
   ```
2. **Forgejo**: log in at `https://git.urosevicvuk.dev` (admin from
   `kv/forgejo/admin`), create personal user(s), set up first repo.
3. **Cloudflared DNS records**: cloudflared auto-publishes `*.cfargotunnel.com`
   CNAMEs as it picks up the ingress config from the ConfigMap. external-dns
   creates the matching public CNAMEs. Verify with:
   ```bash
   dig +short argocd.urosevicvuk.dev   # → <tunnel-id>.cfargotunnel.com
   ```

## Backup checklist

Single-node cluster + file-storage Vault means a hard storage failure on
firelink wipes the cluster. Before you put anything you care about on here,
**at minimum** copy these off-box:

- [ ] `seed-k3s/secrets/vault-init.json` (Vault unseal keys + root token)
- [ ] `~/.cloudflared/*.json` (tunnel credentials, also stored in Vault)
- [ ] CNPG Postgres data — periodically `pg_dump` from each Cluster

A real backup story (Velero, CNPG `Backup` to S3-compatible object store,
Longhorn recurring snapshots) is the next pass after this one.
