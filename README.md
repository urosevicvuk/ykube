# ykube

GitOps source of truth for the `firelink` Talos cluster. ArgoCD reconciles
everything in this repo into the cluster; nothing is applied imperatively
after the initial bootstrap.

Bootstrap walkthrough lives in [`rework/guide.md`](rework/guide.md).

```
            ┌──────────────────────────────────────────────────────────┐
            │                bootstrap/root-app.yaml                   │
            │              (one-shot kubectl apply, default proj)      │
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
            │   Generated Applications, isolated by AppProject. Each   │
            │   pulls a kustomization that wraps a Helm chart          │
            │   (helmCharts:) plus per-app resources.                  │
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
│   │   ├── foundation/       # external-secrets, longhorn, vault, kyverno
│   │   ├── networking/       # cilium, gateway-api, cert-manager, external-dns, cloudflared, gateway
│   │   ├── platform/         # cloudnative-pg, harbor, forgejo, argo-workflows, argo-events
│   │   ├── observability/    # kube-prometheus-stack, loki, alloy
│   │   └── argocd/           # argocd self-takeover (last to sync)
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

### AppProjects = trust boundaries

`system` allows cluster-scoped resources (CRDs). Tenant projects (`homelab`,
`morel`, `eko-servis`, `ofnir`, `raf`) have `clusterResourceWhitelist: []` —
workloads cannot install CRDs.

### AppSets = sync-wave buckets

| AppSet                 | Wave  | Apps                                                              |
|------------------------|-------|-------------------------------------------------------------------|
| system-foundation      | -100  | external-secrets, longhorn, vault, kyverno                        |
| system-networking      | -80   | cilium, gateway-api, cert-manager, external-dns, cloudflared, gateway |
| system-platform        | -40   | cloudnative-pg, harbor, forgejo, argo-workflows, argo-events      |
| system-observability   | -20   | kube-prometheus-stack, loki, alloy                                |
| homelab + tenants      | 0     | application workloads                                              |
| system-argocd          | +100  | argocd self-takeover (last)                                        |

Note: ArgoCD removed cross-Application health gating in 1.8 (see
[#24212](https://github.com/argoproj/argo-cd/issues/24212)). Application-level
sync waves give a creation-order *head start* but don't strictly serialize.
Within an Application, sync waves on individual resources still gate on
Healthy — that's where the real ordering happens (CRDs at wave 0,
ClusterIssuers at wave 5, HTTPRoutes at wave 10, etc.).

### Helm via Kustomize

Charts wrapped with `helmCharts:` in `kustomization.yaml`. This requires
`kustomize.buildOptions: --enable-helm --load-restrictor=LoadRestrictionsNone`
in `argocd-cm` — set in `apps/system/argocd/values.yaml`.
`LoadRestrictionsNone` is needed because `bootstrap/kustomization.yaml`
references `../projects/*` and `../appsets/*` outside its own directory.

### Secrets

No secrets in Git. Vault + External Secrets Operator. Every secret is an
`ExternalSecret` referencing `kv/<path>` in Vault. Vault is *chart-deployed*
by Argo (not seed-installed by Terraform); TF only does the imperative
init+unseal once Vault's pods are running.

### Naming

Soulslike convention. Cluster node `firelink`, LAN DNS `newlondo`.
Application names: `<domain>-<dirname>` for system apps (e.g.
`foundation-vault`, `networking-cilium`, `platform-cloudnative-pg`),
`<project>-<dirname>` for tenants (e.g. `morel-morel`), and just `argocd`
for the self-takeover.

## Adding an app

1. Pick the right place: `apps/system/<domain>/<name>/` for plumbing,
   `apps/<tenant>/<name>/` for workloads.
2. Drop in `kustomization.yaml` (with `helmCharts:` if it's a chart).
   Add a `namespace.yaml` only if you need to label/annotate the namespace
   (PSS, ESO selectors, etc.) — otherwise the AppSet's `CreateNamespace=true`
   handles it.
3. Commit and push. The matching ApplicationSet picks it up on next sync.

No new Application file, no AppSet to edit.

## Bootstrap

The full procedure is in [`rework/guide.md`](rework/guide.md). Summary:

1. **TF stages 00–04**: provision Talos cluster + seed Cilium.
2. **TF stage 05**: seed ArgoCD + `kubectl apply -f bootstrap/root-app.yaml`.
   Argo creates AppProjects + AppSets, AppSets generate Applications, and
   the cluster starts converging. Vault chart deploys but pods come up sealed.
3. **TF stage 06**: imperative `vault operator init/unseal` + enable kubernetes auth.
4. **TF stage 07**: write seed secrets to `kv/*` paths.
5. ESO ClusterSecretStore now resolves; ExternalSecrets across the cluster
   materialize their target Secrets; ClusterIssuers go Ready; certificates
   issue. Cluster is converged.

### Expected first-sync transients

These resolve themselves via Argo's reconcile retry; **no manual
intervention needed**.

- ServiceMonitor manifests in cert-manager / external-secrets fail at first
  apply because their CRD comes from kube-prometheus-stack (which syncs
  later). Resolves on next reconcile (~3 min).
- ExternalSecrets in cert-manager remain Pending until TF stages 06+07 finish.
- ClusterIssuers stay `False/Pending` until their cloudflare-api-token
  Secret materializes from ESO.
