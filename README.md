# ykube

GitOps source of truth for the `firelink` Talos cluster. ArgoCD reconciles
everything in this repo into the cluster; nothing is applied imperatively
after the initial bootstrap.

Bootstrap walkthrough lives in [`rework/guide.md`](rework/guide.md). See
the **Bootstrap procedure** section there.

```
            ┌──────────────────────────────────────────────────────────┐
            │                bootstrap/root-app.yaml                   │
            │             (one-shot kubectl apply, default proj)       │
            └─────────────────────────┬────────────────────────────────┘
                                      │ creates
            ┌─────────────────────────┼────────────────────────────────┐
            │  AppProjects (6)        │  ApplicationSets (10)          │
            │  system                 │  5 system-<domain> +           │
            │  homelab                │  5 tenant AppSets              │
            │  morel · eko-servis ·   │                                │
            │  ofnir · raf            │  → one Application per         │
            │                         │    subdirectory                │
            └─────────────────────────┴────────────────────────────────┘
                                      │
            ┌─────────────────────────▼────────────────────────────────┐
            │   Generated Applications, namespaced + isolated by       │
            │   AppProject. Each pulls a kustomization that wraps a    │
            │   Helm chart (helmCharts:) plus per-app resources.       │
            └──────────────────────────────────────────────────────────┘
```

## Layout

```
ykube/
├── bootstrap/                # root Application + aggregator (one-time apply)
├── projects/                 # 6 AppProjects
├── appsets/                  # 10 ApplicationSets
├── apps/
│   ├── system/               # cluster plumbing + shared services (one AppProject, 5 AppSets)
│   │   ├── networking/       # cilium, gateway-api, gateway, cert-manager, external-dns, cloudflared
│   │   ├── security/         # vault, external-secrets, kyverno
│   │   ├── storage/          # longhorn, cloudnative-pg, harbor
│   │   ├── observability/    # kube-prometheus-stack, loki, alloy
│   │   └── ci-cd/            # argocd, argo-workflows, argo-events, forgejo
│   ├── homelab/              # personal apps on urosevicvuk.dev
│   ├── morel/                # morel.rs tenant
│   ├── eko-servis/           # eko-servis tenant (no domain yet)
│   ├── ofnir/                # ofnir.dev tenant
│   └── raf/                  # raf-project.com tenant (school)
├── rework/                   # bootstrap guide (delete after first cluster is stable)
├── flake.nix                 # dev shell: kubectl, helm, kustomize, argocd, talosctl, opentofu
└── renovate.json             # PR-only, no automerge
```

## Conventions

- **AppProject = trust boundary.** `system` allows cluster-scoped resources (CRDs).
  Tenant projects (`homelab`, `morel`, `eko-servis`, `ofnir`, `raf`) have
  `clusterResourceWhitelist: []` — workloads can't install CRDs.
- **AppSet = sync-wave bucket.** Each AppSet stamps a wave on every Application it
  generates. The split into per-domain AppSets (instead of one per project) is what
  makes ordering meaningful:

  | AppSet                 | Wave  | Apps                                                |
  |------------------------|-------|-----------------------------------------------------|
  | system-networking      | -100  | cilium, gateway-api, cert-manager, external-dns, … |
  | system-security        | 0     | vault, external-secrets, kyverno                    |
  | system-storage         | 10    | longhorn, cloudnative-pg, harbor                    |
  | system-observability   | 20    | kube-prometheus-stack, loki, alloy                  |
  | system-ci-cd           | 30    | argocd (self-takeover), argo-workflows, …, forgejo  |
  | homelab + tenant AppSets | 40+ | application workloads                               |

  Intra-app ordering (CRDs before custom resources) uses
  `argocd.argoproj.io/sync-wave` on individual manifests.
- **Helm via Kustomize.** Charts are wrapped with `helmCharts:` in
  `kustomization.yaml`. This requires
  `kustomize.buildOptions: --enable-helm --load-restrictor=LoadRestrictionsNone`
  in `argocd-cm` — set in `apps/system/ci-cd/argocd/values.yaml`.
  `LoadRestrictionsNone` is needed because `bootstrap/kustomization.yaml`
  references `../projects/*` and `../appsets/*` outside its own directory.
- **Secrets.** No secrets in Git. Vault + External Secrets Operator. Every secret
  is an `ExternalSecret` referencing `kv/<path>` in Vault. Bootstrap-time
  Vault unseal + seed happen via OpenTofu (deferred work).
- **Naming.** Soulslike convention. Cluster node `firelink`, LAN DNS `newlondo`.
  Application names: `<domain>-<dirname>` for system apps (e.g. `networking-cilium`),
  `<project>-<dirname>` for tenants (e.g. `morel-morel`).

## Adding an app

1. Pick the right place: `apps/system/<domain>/<name>/` for plumbing,
   `apps/<tenant>/<name>/` for workloads.
2. Drop in `kustomization.yaml` (with `helmCharts:` if it's a chart).
   Add a `namespace.yaml` only if you need to label/annotate the namespace
   (PSS, ESO selectors, etc.) — otherwise the AppSet's `CreateNamespace=true`
   handles it.
3. Commit and push. The matching ApplicationSet picks it up on next sync.

No new Application file, no AppSet to edit.

## Bootstrap, in one sentence

After OpenTofu brings up Talos + seeds Cilium + ArgoCD + Vault:
`kubectl apply -f bootstrap/root-app.yaml` — ArgoCD takes everything else.
