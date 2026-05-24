# ykube

GitOps source of truth for a small professional Kubernetes platform — built
to host workloads and services for multiple companies under one cluster,
with tenant isolation, observability, and a clean public surface.

Currently runs on **k3s** on the NixOS host `firelink` (see
[`seed-k3s/`](seed-k3s/README.md)). The Talos+Proxmox target is preserved
in [`seed-talos/`](seed-talos/README.md) and will land as a separate task.

ArgoCD reconciles everything in this repo into the cluster; nothing is
applied imperatively after the initial bootstrap.

```
            ┌──────────────────────────────────────────────────────────┐
            │                root/app-of-apps.yaml                     │
            │       (one-shot kubectl apply, default proj; also        │
            │        renders the argo-cd chart — self-managed)         │
            └─────────────────────────┬────────────────────────────────┘
                                      │ creates
            ┌─────────────────────────┼────────────────────────────────┐
            │  AppProjects (6)        │  ApplicationSets (6)           │
            │  system                 │  system + 5 tenant AppSets     │
            │  homelab                │                                │
            │  morel · eko-servis ·   │  → one Application per         │
            │  ofnir · raf            │    subdirectory                │
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
├── root/                     # app-of-apps source: argo-cd chart + aggregator + argocd HTTPRoute
├── projects/                 # 6 AppProjects
├── appsets/                  # 6 ApplicationSets
├── apps/
│   ├── system/               # cluster plumbing + shared services (one AppProject, one AppSet)
│   │   ├── security/         # vault, external-secrets, kyverno (+ policies)
│   │   ├── storage/          # longhorn, cloudnative-pg
│   │   ├── networking/       # cilium (+ cluster-policies), cert-manager, external-dns, cloudflared, envoy (+ gateway-external, gateway-internal), tailscale-operator
│   │   ├── platform/         # harbor, forgejo (argo-workflows, argo-events deferred)
│   │   └── observability/    # kube-prometheus-stack, loki, alloy
│   ├── homelab/              # personal apps on urosevicvuk.dev (excalidraw, opencloud, stirling-pdf)
│   ├── morel/                # morel.rs tenant
│   ├── eko-servis/           # eko-servis tenant (no domain yet)
│   ├── ofnir/                # ofnir.dev tenant (placeholder)
│   └── raf/                  # raf-project.com tenant (school)
├── seed-k3s/                 # k3s/firelink bootstrap (current cluster)
├── seed-talos/               # Talos+Proxmox bootstrap (deferred future target)
├── flake.nix                 # dev shell: kubectl, helm, kustomize, argocd, talosctl, opentofu, cilium, hubble, vault
└── renovate.json             # PR-only, no automerge
```

## Public surface

Every UI has an HTTPRoute on a domain — no port-forwards. Public DNS is
fronted by Cloudflare Tunnel (HTTP/HTTPS only for now; a VPS+WireGuard L4
frontend will replace it when TCP/UDP support is needed).

| Hostname                          | Service                          |
|-----------------------------------|----------------------------------|
| `argocd.urosevicvuk.dev`          | Argo CD UI                       |
| `vault.urosevicvuk.dev`           | Vault UI                         |
| `dashboard.urosevicvuk.dev`       | Grafana                          |
| `prometheus.urosevicvuk.dev`      | Prometheus                       |
| `alertmanager.urosevicvuk.dev`    | Alertmanager                     |
| `hubble.urosevicvuk.dev`          | Cilium Hubble UI                 |
| `git.urosevicvuk.dev`             | Forgejo                          |
| `registry.urosevicvuk.dev`        | Harbor                           |
| `cloud.urosevicvuk.dev`           | OpenCloud                        |
| `draw.urosevicvuk.dev`            | Excalidraw                       |
| `pdf.urosevicvuk.dev`             | Stirling PDF                     |
| `morel.rs` / `www.morel.rs`       | Morel website (tenant)           |

## Conventions

### AppProjects = trust boundaries

`system` allows cluster-scoped resources (CRDs). Tenant projects (`homelab`,
`morel`, `eko-servis`, `ofnir`, `raf`) have `clusterResourceWhitelist: []` —
workloads cannot install CRDs.

### Tenant isolation

Each tenant app declares its own isolation manifests in its own dir,
alongside the Deployment / HTTPRoute / ExternalSecret. Specifically:

- `namespace.yaml` — Pod Security Standards labels (`enforce: restricted`
  for tenants, `baseline` for system; `privileged` only for `alloy` which
  needs `/var/log/pods` hostPath access)
- `resource-quota.yaml` — CPU/memory/storage/PVC/pod caps for that namespace
- `limit-range.yaml` — default container request + limit when a Pod spec
  doesn't declare its own
- `network-policy.yaml` — namespaced `CiliumNetworkPolicy`, default-deny
  + explicit allow to DNS, Gateway, kube-prometheus-stack, and selectively
  Vault / ESO / open internet where the app needs it

The cluster-wide allow rules those default-denies depend on (kube-dns +
host-network) live in `apps/system/networking/cilium/cluster-policies.yaml`
because they're `CiliumClusterwideNetworkPolicy` resources and tenants
can't ship cluster-scoped objects (their AppProject has
`clusterResourceWhitelist: []`).

When you onboard untrusted third-party committers later, move the
tenant-side manifests back into a system-owned Application so a tenant
can't relax its own quota.

### AppSets

| AppSet                 | Scope                                                                |
|------------------------|----------------------------------------------------------------------|
| system                 | scans `apps/system/*/*` (security, storage, networking, platform, observability) |
| homelab, morel, ofnir, eko-servis, raf | tenants (one AppSet per AppProject)                  |

ArgoCD itself is not generated by an AppSet — it's rendered directly by the
root Application from `root/kustomization.yaml`. The argocd HTTPRoute
(`root/argocd-route.yaml`) ships in the same Application.

Argo's cross-Application health gating was removed in 1.8
([#24212](https://github.com/argoproj/argo-cd/issues/24212)), so engineering
sync waves between Applications buys little. Argo's automated retry +
`selfHeal: true` + `ServerSideApply=true` converges first-sync transients
(CRDs racing resources, ServiceMonitor refs before kube-prom-stack lands).
Intra-Application sync waves still gate on Healthy — that's where ordering
inside a chart actually matters.

### Helm via Kustomize

Charts wrapped with `helmCharts:` in `kustomization.yaml`. This requires
`kustomize.buildOptions: --enable-helm --load-restrictor=LoadRestrictionsNone`
in `argocd-cm` — set in `root/values.yaml`.
`LoadRestrictionsNone` is needed because `root/kustomization.yaml`
references `../projects/*` and `../appsets/*` outside its own directory.

### Secrets

No secrets in Git. Vault + External Secrets Operator. Every secret is an
`ExternalSecret` referencing `kv/<path>` in Vault. Vault is *chart-deployed*
by Argo (not seed-installed by Terraform); the seed scripts only do the
imperative init + unseal + ESO-role setup once Vault's pods are running.

SealedSecrets is **not** used — the clean break to Vault+ESO is intentional
(the legacy GitLab/SealedSecrets stack on `main` is dropped).

### Naming

Soulslike convention. Cluster node `firelink`, LAN DNS `newlondo`.
Application names: `<domain>-<dirname>` for system apps (e.g.
`security-vault`, `networking-cilium`, `storage-cloudnative-pg`),
`<project>-<dirname>` for tenants (e.g. `morel-morel`). ArgoCD itself
isn't an Application — it's rendered directly by the root app.

## Adding an app

1. Pick the right place: `apps/system/<domain>/<name>/` for plumbing,
   `apps/<tenant>/<name>/` for workloads.
2. Drop in:
   - `namespace.yaml` declaring the target Namespace with PSS labels
     (`restricted` for tenants, `baseline` for system).
   - `kustomization.yaml` with the namespace listed in `resources:` and a
     top-level `namespace: <name>` directive so every rendered resource is
     pinned to that namespace. Add `helmCharts:` if it's a chart.
   - HTTPRoute (in the same namespace) if it has a UI.
   - Any ExternalSecret it needs (point at `kv/<app>/<key>`).
   - Exception: apps that target a pre-existing namespace (cilium →
     `kube-system`) skip `namespace.yaml`.
3. Commit and push. The matching ApplicationSet picks it up on next sync.

For a new tenant: add a `projects/<tenant>.yaml` (AppProject with
`clusterResourceWhitelist: []` and the tenant's namespace allow-list),
an `appsets/<tenant>.yaml` (ApplicationSet scanning `apps/<tenant>/*`),
add it to `root/kustomization.yaml`. The tenant's first app dir should
include its own `resource-quota.yaml`, `limit-range.yaml`, and
`network-policy.yaml` alongside the workload manifests.

## Bootstrap

### Current cluster (k3s/firelink)

```bash
# 1. Rebuild firelink with the Cilium k3s flags (in ynix):
sudo nixos-rebuild switch --flake .#firelink

# 2. From the ykube dev shell:
nix develop
export KUBECONFIG=/path/to/k3s.yaml
task -d seed-k3s cluster:bootstrap
```

End-to-end pipeline lives in [`seed-k3s/README.md`](seed-k3s/README.md).
Stages 00 → 03: Cilium install → ArgoCD install + root app-of-apps →
Vault init+unseal+ESO config → bootstrap kv/* secrets.

### Future cluster (Talos on Proxmox)

See [`seed-talos/README.md`](seed-talos/README.md). Not in use today.

### Expected first-sync transients

These resolve themselves via Argo's reconcile retry; **no manual
intervention needed**.

- ServiceMonitor manifests in cert-manager / external-secrets fail at first
  apply because their CRD comes from kube-prometheus-stack (which syncs
  later). Resolves on next reconcile (~3 min).
- ExternalSecrets remain Pending until the seed scripts populate `kv/*`.
- ClusterIssuers stay `False/Pending` until their cloudflare-api-token
  Secret materializes from ESO.
- CNPG `Cluster` resources show `Setting up primary` briefly while Postgres
  initializes; Forgejo and Harbor pods CrashLoopBackOff until their DBs are
  Ready.

## Known deferred items

- **Argo Workflows + Argo Events** — kustomization dirs left as TODO stubs.
- **VPS+WireGuard public frontend** — needed for TCP/UDP exposure (game
  servers, SSH, anything that isn't HTTP/HTTPS). Cloudflared covers HTTP
  for now.
- **CI** — no `kustomize build --enable-helm` render check, no kubeconform,
  no PR diff workflow. Renovate can merge a broken chart bump and Argo will
  catch it post-merge instead of pre-merge.
- **Backups** — no Velero, no CNPG `Backup`, no Longhorn recurring
  snapshots. Single-node cluster + file-storage Vault means a disk failure
  on firelink wipes the cluster; back up `seed-k3s/secrets/vault-init.json`
  and CNPG `pg_dump`s off-box manually until this lands.
- **SSO** — Forgejo as OIDC provider for Argo/Grafana/Harbor; deferred to
  the "full features" pass.
- **Talos+Proxmox cluster** — `seed-talos/` is intact but not wired up.

## Repository layout footnotes

- The `flake.nix` dev shell sets `INFRA_ROOT=$PWD/seed-talos` for legacy
  reasons; the k3s path doesn't use it.
- Helm chart caches under `apps/**/charts/` and `root/charts/` are
  gitignored — kustomize fetches them on `--enable-helm` build.
