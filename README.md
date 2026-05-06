# ykube

Single-cluster K3s homelab managed via GitOps with ArgoCD.

## Layout

```
ykube/
├── root/                     # ArgoCD Applications (app-of-apps)
│   ├── root.yaml             # entrypoint; recurses root/
│   ├── apps/                 # user workloads
│   ├── ci-cd/                # argocd resources, gitlab
│   ├── networking/           # traefik, cert-manager, cloudflared
│   ├── security/             # vault, eso, sealed-secrets, kyverno
│   ├── storage/              # longhorn
│   └── observability/        # prometheus stack, loki, promtail
├── manifests/
│   ├── apps/                 # workload manifests + helm values
│   ├── ci-cd/
│   ├── networking/
│   ├── security/
│   ├── storage/
│   └── observability/
├── BOOTSTRAP.md              # cluster bootstrap procedure
└── renovate.json
```

Helm-backed components store values at `manifests/<domain>/<component>/environments/prod/values.yaml`. Raw-manifest workloads sit flat under `manifests/<domain>/<component>/`.

## Stack

- **Ingress**: Traefik (Gateway API) behind a Cloudflare tunnel.
- **Secrets**: SealedSecrets in active use; Vault + ExternalSecrets installed for ongoing migration.
- **Storage**: Longhorn (single-replica, single-node).
- **Observability**: kube-prometheus-stack, Loki, Promtail.
- **Policy**: Kyverno + a small policy set under `manifests/security/kyverno/policies/`.
- **CI/CD**: ArgoCD; GitLab self-hosted.

## Working with this repo

- Add a new component: create `manifests/<domain>/<name>/` (with `environments/prod/values.yaml` if Helm-backed) and a matching `root/<domain>/<name>.yaml` Application.
- Change a Helm chart version: edit `targetRevision` in the Application under `root/`.
- Override Helm values: edit the file under `manifests/<domain>/<name>/environments/prod/values.yaml`.

## Bootstrap

See `BOOTSTRAP.md` for cluster-from-scratch steps.
