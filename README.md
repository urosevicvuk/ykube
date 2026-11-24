# ykube

GitOps source of truth for a small professional Kubernetes platform - built
to host workloads and services for multiple companies and domains under one cluster,
with tenant isolation, observability, and a clean public surface.

Runs on **Talos** VMs on a three-host **Proxmox** cluster: per host, one
controlplane and two workers, with the hosts joined by a 20G full mesh and
**Rook-Ceph** providing block and S3 storage (see
[`seed/talos/`](seed/talos/README.md)). The previous single-node k3s
bootstrap for the NixOS host `firelink` is kept in [`seed/k3s/`](seed/k3s/README.md).

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
├── seed/talos/               # Talos+Proxmox bootstrap (OpenTofu stages 00-07)
├── seed/k3s/                 # previous k3s/firelink (NixOS) bootstrap
├── flake.nix                 # dev shell: kubectl, helm, kustomize, argocd, talosctl, opentofu, cilium, hubble, vault
└── renovate.json             # PR-only, no automerge
```

