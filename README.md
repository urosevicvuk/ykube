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
            │  AppProjects (7)        │  ApplicationSets (7)           │
            │  platform               │  git-directory generators      │
            │  infrastructure         │  over apps/<project>/*         │
            │  homelab                │                                │
            │  morel · eko-servis ·   │  → one Application per         │
            │  ofnir · raf            │    subdirectory                │
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
├── bootstrap/      # root Application + Kustomization aggregator (one-time apply)
├── projects/       # 7 AppProjects
├── appsets/        # 7 ApplicationSets, one per AppProject
├── apps/
│   ├── platform/         # cluster plumbing (argocd, cilium, cert-manager, ESO, observability)
│   ├── infrastructure/   # shared services (vault, harbor, forgejo, argo-workflows, argo-events)
│   ├── homelab/          # personal apps on urosevicvuk.dev
│   ├── morel/            # morel.rs tenant
│   ├── eko-servis/       # eko-servis tenant (no domain yet)
│   ├── ofnir/            # ofnir.dev tenant
│   └── raf/              # raf-project.com tenant (school)
├── rework/         # bootstrap guide + design notes (drop after first cluster is stable)
├── flake.nix       # dev shell — kubectl, helm, kustomize, argocd, talosctl, opentofu, vault
└── renovate.json   # PR-only, no automerge
```

## Conventions

- **AppProject ownership.** Every Application belongs to exactly one project.
  `clusterResourceWhitelist: []` on tenant + homelab projects (no CRDs from workloads).
- **Sync waves.** Coarse, per-AppSet:
  | Project        | Default wave |
  |----------------|--------------|
  | platform       | 0            |
  | infrastructure | 20           |
  | homelab        | 30           |
  | morel/eko-servis/ofnir/raf | 30 |
  Per-Application overrides are *not* used (the directory generator can't set them).
  Intra-app ordering (CRDs before instances) uses resource-level
  `argocd.argoproj.io/sync-wave` annotations.
- **Helm via Kustomize.** Charts wrapped with `helmCharts:` in `kustomization.yaml`.
  This requires `kustomize.buildOptions: --enable-helm` in `argocd-cm` — set
  in `apps/platform/argocd/values.yaml`.
- **Secrets.** No secrets in Git. Vault + External Secrets Operator. Every secret
  is an `ExternalSecret` referencing `kv/<path>` in Vault. The bootstrap Vault
  unseal + initial credential seed happen via OpenTofu stages (TBD; see `rework/guide.md`).
- **Naming.** Soulslike convention. Cluster node `firelink`, LAN DNS `newlondo`.
  Application names follow `<project>-<dirname>`, e.g. `platform-cilium`.

## Adding an app

1. `mkdir apps/<project>/<name>/`
2. Drop in `namespace.yaml` and `kustomization.yaml` (with `helmCharts:` for charts).
3. Commit and push. The `<project>` ApplicationSet picks it up on next sync.

That's it. No new Application file to write, no AppSet to edit.

## Bootstrap, in one sentence

After OpenTofu brings up Talos + seeds Cilium + ArgoCD + Vault:
`kubectl apply -f bootstrap/root-app.yaml` — and ArgoCD takes everything else from there.
