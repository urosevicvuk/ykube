# ykube

GitOps source of truth for a small professional Kubernetes platform - built
to host workloads and services for multiple companies and domains under one cluster,
with tenant isolation, observability, and a clean public surface.

Runs on **RKE2** (CIS profile) on three bare-metal **NixOS** hosts, kiln1-3:
every host is a control plane, etcd member and worker. The hosts are joined
by a 25G full mesh (direct DAC cables, one L2 segment with spanning tree),
and **Rook-Ceph** provides block and S3 storage on their raw disks. The hosts
are declared in [`ynix`](https://github.com/urosevicvuk/ynix)
(`modules/features/kiln/`); the cluster bootstrap and the plan live in
[`seed/rke2/`](seed/rke2/README.md). The live cluster is still the
single-node k3s on the NixOS host `firelink` ([`seed/k3s/`](seed/k3s/README.md))
until the migration; the abandoned Proxmox + Talos design is in `seed/talos/`
until it is deleted.

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
│   │   ├── storage/          # rook-ceph (block + S3), cloudnative-pg, dragonfly-operator
│   │   ├── networking/       # cilium (+ cluster-policies), cert-manager, external-dns, cloudflared, envoy (+ gateway-external, gateway-internal), tailscale-operator
│   │   ├── platform/         # harbor, forgejo (argo-workflows, argo-events deferred)
│   │   └── observability/    # kube-prometheus-stack, loki, alloy
│   ├── homelab/              # personal apps on urosevicvuk.dev (excalidraw, opencloud, stirling-pdf, ...)
│   ├── morel/                # morel.rs tenant
│   ├── eko-servis/           # eko-servis tenant (no domain yet)
│   ├── ofnir/                # ofnir.dev tenant (placeholder)
│   └── raf/                  # raf-project.com tenant (school projects)
├── seed/rke2/                # RKE2 cluster bootstrap (Taskfile stages 00-05) + PLAN.md
├── seed/k3s/                 # current k3s/firelink (NixOS) bootstrap, until the migration
├── seed/talos/               # abandoned Talos+Proxmox design, to be deleted
├── flake.nix                 # dev shell: kubectl, helm, kustomize, argocd, cilium, hubble, vault, shellcheck
└── renovate.json             # PR-only, no automerge
```

