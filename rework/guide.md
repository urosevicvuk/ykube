# ykube bootstrap guide

This is a handoff document for an AI coding assistant (Claude Code) to take an empty repo and produce a working ArgoCD GitOps setup matching the architecture decided in design discussions. Read the whole thing before starting. Don't over-engineer; the goal is a clean, minimal, working baseline that we extend over time.

## Context you need

We are setting up a homelab Kubernetes cluster managed via GitOps with ArgoCD. The cluster runs on Talos Linux on Proxmox (multi-node, eventually). This repo (`ykube`) is the single source of truth for everything the cluster runs.

There will eventually be a second, structurally-identical repo for business workloads (Eko Servis, Morel) on a separate cluster. Keep that in mind: anything specific to the homelab goes in homelab-specific paths, anything general (patterns, conventions) should be reusable.

The owner is comfortable with Kubernetes, Argo, NixOS, and Go. Don't explain basics. Do explain non-obvious decisions inline as comments.

## Architectural decisions (do not relitigate)

1. **Single ArgoCD instance per cluster.** No hub-and-spoke, no multi-cluster from this ArgoCD.
2. **Three AppProjects:** `platform`, `infrastructure`, `workloads`. A fourth (`friends-paas`) may be added later — leave room for it but don't create it now.
3. **App-of-apps bootstrap.** One root Application is applied by hand. It points at `bootstrap/` and creates everything else.
4. **One ApplicationSet per AppProject**, using the git directory generator over `apps/<project>/*`.
5. **Sync waves** enforce ordering: platform = wave 0–10, infrastructure = wave 20–29, workloads = wave 30+.
6. **Kustomize over Helm where practical**, Helm where the upstream chart is the obvious choice (cert-manager, kube-prometheus-stack, vault, harbor, forgejo). When using Helm, wrap it in a Kustomization that uses `helmCharts:` so everything is uniform.
7. **No secrets in Git, ever.** Vault + External Secrets Operator. The Git repo only contains `ExternalSecret` resources. SOPS is acceptable as a transitional measure for the very first bootstrap of Vault itself, but plan to migrate.
8. **Cluster naming follows Soulslike convention.** Current node: `firelink`. DNS server: `newlondo`. Don't invent new names; ask the user.
9. **No matrix ApplicationSet generators** unless there is a concrete reason. Three boring git-directory ApplicationSets is correct.
10. **ArgoCD manages itself.** The initial install is bootstrapped imperatively (via `kubectl apply` of the upstream manifest, or a Nix/Talos module) but is treated as throwaway. ArgoCD lives at `apps/platform/argocd/` and is reconciled by its own Application. Version bumps happen by editing the Helm chart version in Git, not by re-running the bootstrap install.

## Target directory layout

```
ykube/
├── README.md
├── BOOTSTRAP.md                # this file
├── bootstrap/
│   └── root-app.yaml           # the one Application applied by hand
├── projects/
│   ├── platform.yaml
│   ├── infrastructure.yaml
│   └── workloads.yaml
├── appsets/
│   ├── platform.yaml
│   ├── infrastructure.yaml
│   └── workloads.yaml
├── apps/
│   ├── platform/
│   │   ├── argocd/             # ArgoCD manages itself; see "ArgoCD self-management" below
│   │   ├── cert-manager/
│   │   │   ├── kustomization.yaml
│   │   │   └── (helm values, namespace, etc.)
│   │   ├── external-secrets/
│   │   ├── external-dns/
│   │   ├── ingress-nginx/      # or whatever ingress; confirm with user
│   │   └── kube-prometheus-stack/
│   ├── infrastructure/
│   │   ├── vault/
│   │   ├── harbor/
│   │   ├── forgejo/
│   │   ├── argo-workflows/
│   │   └── argo-events/
│   └── workloads/
│       └── (empty for now; placeholder .gitkeep)
└── clusters/
    └── firelink/
        └── (cluster-specific overlays / values; empty for now)
```

`apps/workloads/` and `clusters/firelink/` are intentionally empty at bootstrap. Don't fabricate workloads. The user will add them as needed.

## What to build, in order

### Step 0: repo skeleton

Create the directory tree above. Add a `README.md` with a one-paragraph description, a pointer to this file, and the architecture diagram (text-only is fine). Add `.gitkeep` files where directories are empty.

### Step 1: the three AppProjects

Each AppProject lives in `projects/<name>.yaml` as a single `AppProject` manifest in namespace `argocd`.

**`platform`:**
- `sourceRepos`: the ykube repo URL (parameterize via a placeholder `REPO_URL` and tell the user to substitute)
- `destinations`: `*` namespaces on `https://kubernetes.default.svc` (platform components install into many namespaces)
- `clusterResourceWhitelist`: `'*'/'*'` (these need to install CRDs)
- `namespaceResourceWhitelist`: `'*'/'*'`
- Add finalizer `resources-finalizer.argocd.argoproj.io`

**`infrastructure`:**
- `sourceRepos`: same repo
- `destinations`: namespaces matching `vault`, `harbor`, `forgejo`, `argo-workflows`, `argo-events`, `ofnir-*` on the in-cluster server
- `clusterResourceWhitelist`: limited — allow CRDs only for things we know need them (Vault and Argo Workflows install CRDs). Start permissive and tighten later; leave a TODO comment.
- `namespaceResourceWhitelist`: `'*'/'*'`

**`workloads`:**
- `sourceRepos`: same repo
- `destinations`: any namespace except those reserved for platform/infrastructure (use a namespace blacklist via the AppProject `destinations` + an explicit list of allowed prefixes if the user wants stricter; for now allow `*` and add a TODO)
- `clusterResourceWhitelist`: empty array `[]` — workloads cannot install cluster-scoped resources
- `namespaceResourceWhitelist`: `'*'/'*'`

All three should have `description` fields explaining their purpose and the sync-wave range they own.

### Step 2: the three ApplicationSets

Each lives in `appsets/<name>.yaml`. All use the git directory generator.

Template for `appsets/platform.yaml` (adapt for the others):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: REPO_URL
        revision: main
        directories:
          - path: apps/platform/*
  template:
    metadata:
      name: 'platform-{{path.basename}}'
      annotations:
        argocd.argoproj.io/sync-wave: "0"   # platform waves: 0-10; tune per app
    spec:
      project: platform
      source:
        repoURL: REPO_URL
        targetRevision: main
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{path.basename}}'      # convention: namespace == app name; override per-app via kustomization if needed
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
```

For `infrastructure`: same shape, `path: apps/infrastructure/*`, `project: infrastructure`, sync-wave annotation `"20"`.

For `workloads`: same shape, `path: apps/workloads/*`, `project: workloads`, sync-wave annotation `"30"`.

Note: the sync-wave on the *generated Application* annotation governs ordering between Applications. Individual resources within an app can also carry sync-wave annotations for fine-grained ordering inside the app — leave that to the per-app kustomizations.

### Step 3: the root Application (app-of-apps)

`bootstrap/root-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default   # the only Application allowed in default
  source:
    repoURL: REPO_URL
    targetRevision: main
    path: bootstrap
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

The `bootstrap/` directory needs a `kustomization.yaml` that aggregates the AppProjects and ApplicationSets so the root app deploys all of them:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../projects/platform.yaml
  - ../projects/infrastructure.yaml
  - ../projects/workloads.yaml
  - ../appsets/platform.yaml
  - ../appsets/infrastructure.yaml
  - ../appsets/workloads.yaml
```

This is the only Application that lives in the `default` AppProject. Everything else is created via the ApplicationSets and belongs to one of the three real projects.

### Step 4: per-app scaffolding

For each platform/infrastructure app directory, create the minimum to make it a valid Kustomize source:

- `kustomization.yaml`
- `namespace.yaml` (creating the target namespace explicitly; even though `CreateNamespace=true` is set, having it in Git lets us label/annotate it — e.g. for ESO `ClusterSecretStore` selectors or PodSecurity standards)
- For Helm-based apps: a kustomization using `helmCharts:` with a `values.yaml` alongside

**Do not actually configure the apps yet.** Create the directory structure and a placeholder `kustomization.yaml` with a comment `# TODO: configure <app>`. The user wants to walk through each one with intent.

The exceptions: `argocd` itself, `cert-manager`, and `external-secrets` are foundational enough that working baselines are worth wiring up. Use the official Helm charts, install in their canonical namespaces, default values for now. For `argocd` specifically, see the "ArgoCD self-management" and "Bootstrap procedure" sections below — the values.yaml and the takeover flow have specific requirements.

### Step 5: documentation

Update `README.md` to include:

1. A short paragraph: what this repo is.
2. The architecture diagram (ASCII).
3. The bootstrap procedure: a brief summary, with a pointer to the full command-by-command runbook in this file (the "Bootstrap procedure (command-by-command)" section). Don't duplicate the runbook in README.md; link to BOOTSTRAP.md instead.
4. The directory layout, annotated.
5. Conventions: AppProjects, sync waves, naming.
6. A "how to add a new app" section: create directory under `apps/<project>/<name>/`, drop in kustomization, commit, done — the ApplicationSet picks it up.

Keep it concise. No marketing prose. The user is the audience and already knows what GitOps is.

## ArgoCD self-management

### Decision and rationale

ArgoCD manages itself after bootstrap. This is the official, documented pattern (see "Manage Argo CD using Argo CD" in the upstream docs), and is what `argocd-autopilot` (an Argo Labs tool) does by default. The community consensus is that this is the standard approach for any non-trivial deployment.

Why we do it:

- **Configuration changes go through Git like everything else.** RBAC tweaks, repo credentials, the `argocd-cm` configmap, SSO config, notifications, ingress — all PR'd, all auditable, all reviewable.
- **Version bumps are a one-line PR.** Edit the Helm chart version in `apps/platform/argocd/kustomization.yaml`, commit, ArgoCD self-applies. Renovate or similar can automate the PR.
- **Disaster recovery is symmetric with everything else.** Reapply the bootstrap install, apply the root app, ArgoCD takes over and reconverges to the Git state.
- **No special-case workflow.** "How is X deployed?" has the same answer for every X, including ArgoCD.

What we accept as the cost:

- **Self-upgrade restarts the controller mid-sync.** The application-controller pod terminates while it's in the middle of applying a new version of itself. The UI may show the sync stuck "in progress" for a minute or two; the new controller picks up reconciliation on startup. This is documented behavior, not a bug.
- **Spurious post-upgrade sync failures.** Sometimes after the controller restart, ArgoCD reports the self-sync as failed. The fix is to manually trigger a sync once and it goes green. Annoying but well-understood.
- **Recovery requires `kubectl` if the controller breaks itself.** If a bad chart upgrade leaves the controller crash-looping, you have to manually fix the deployment via `kubectl` — ArgoCD can't fix itself if it's not running. This is the worst-case scenario and the reason we pin chart versions and never auto-merge ArgoCD bumps without review.
- **CRD lifecycle is partially manual.** Helm doesn't update CRDs on upgrade by default. We mitigate this with `ServerSideApply=true` (in the ApplicationSet sync options) and with the chart's `crds.install: true, crds.keep: true` settings. If a CRD is *removed* across versions, manual cleanup is needed. In practice this is rare for ArgoCD.

### The flow

1. **Initial install (the seed).** Whatever provisions the cluster (Nix module today, Terraform on Talos later) installs ArgoCD via the official Helm chart at a pinned version. This step happens *outside* the GitOps repo, by design — it's the bootstrap that makes GitOps possible.

2. **The installer's lifecycle ignores subsequent changes.** If using Terraform, set `lifecycle { ignore_changes = all }` on the helm release. If using a Nix one-shot, just don't re-run it. The seed install is treated as immutable from the imperative layer's perspective; in-cluster state belongs to ArgoCD from this point on.

3. **Apply the root app.** `kubectl apply -f bootstrap/root-app.yaml`. This creates the AppProjects and ApplicationSets. The `platform` ApplicationSet then generates an Application for `apps/platform/argocd/`.

4. **ArgoCD reconciles itself.** That generated Application targets the `argocd` namespace and applies the Helm-rendered manifests from `apps/platform/argocd/`. The seed install gets replaced in place — same Deployment objects, just patched to match Git. There is *no* `helm uninstall` step. Don't ever uninstall the seed; let it be patched.

5. **From now on:** version bumps and config changes go through Git. The seed install sits there, ignored by Terraform/Nix, owned by ArgoCD.

### The circular dependency to avoid

The root app (`bootstrap/root-app.yaml`) is *not* the same as the ArgoCD self-management app (`apps/platform/argocd/`). They are two distinct Applications:

- **Root app** — points at `bootstrap/`, manages the AppProjects and ApplicationSets. Lives in the `default` AppProject. Applied by hand once.
- **ArgoCD self-management app** — generated by the platform ApplicationSet, points at `apps/platform/argocd/`, manages the ArgoCD Helm release.

The root app must NOT include itself in its own source path. Its `path` is `bootstrap/`, and `bootstrap/kustomization.yaml` aggregates the AppProjects and ApplicationSets — but NOT `root-app.yaml` itself. If the root app reconciled itself, you'd get an infinite reconciliation loop. The root app is applied imperatively once and is not meant to be in the reconciliation graph.

### Concrete `apps/platform/argocd/` contents

Use the official `argo-cd` Helm chart (chart name `argo-cd`, repo `https://argoproj.github.io/argo-helm`). Wrap it in a Kustomization with `helmCharts:`:

```yaml
# apps/platform/argocd/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd
helmCharts:
  - name: argo-cd
    repo: https://argoproj.github.io/argo-helm
    version: <PIN A SPECIFIC CHART VERSION>   # e.g. 7.x.x; check argoproj.github.io/argo-helm for current
    releaseName: argocd
    namespace: argocd
    valuesFile: values.yaml
```

The `values.yaml` should be minimal at first — just enough to get a working install. Things to consider including (ask the user, don't assume):

- `crds.install: true` and `crds.keep: true` so CRDs are managed by the chart but not deleted on uninstall.
- High-availability settings later (HA controller, redis-ha) — not for day one on a homelab.
- An Ingress with `cert-manager.io/cluster-issuer` once cert-manager is configured. Until then, `kubectl port-forward` is fine.
- The repo URL configured under `configs.repositories` so ArgoCD knows how to pull from itself. If the repo is private, this needs an `ExternalSecret` reference — but that's chicken-and-egg with ESO, so for the initial bootstrap either keep the repo public or pre-create the secret manually before applying the root app.

The ApplicationSet-generated Application for argocd needs:

- `argocd.argoproj.io/sync-wave: "-10"` — earlier than other platform components.
- `ServerSideApply=true` in syncOptions — already in the ApplicationSet template, but specifically critical for argocd because it handles CRD updates better than client-side apply.

### Renovate (optional, recommended later)

Once the system is stable, set up Renovate to open PRs for chart version bumps. Pattern:

```yaml
helmCharts:
  - name: argo-cd
    version: 7.6.12  # renovate: depName=argoproj/argo-helm extractVersion=^argo-cd-(?<version>.+)$
```

Renovate handles every chart in the repo this way. Don't auto-merge ArgoCD's own bumps — review those manually, since a bad bump is the worst-case scenario described above.

## Bootstrap procedure (command-by-command)

This is the runbook for taking an empty cluster to a working GitOps setup. Run these in order. Assumes you have `kubectl` configured to point at the target cluster, and `helm` installed locally.

### Prerequisites

- Cluster is up and reachable. `kubectl get nodes` returns nodes in `Ready` state.
- The GitOps repo (this repo) is pushed to its origin and accessible from the cluster. If private, see Step 4.
- You have a chart version pinned in `apps/platform/argocd/kustomization.yaml`. If not, set it before starting.

### Step 1: Install ArgoCD (the seed)

```bash
# Add the official Argo Helm repo.
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Create the namespace.
kubectl create namespace argocd

# Install ArgoCD at the pinned version. Use the SAME version that's pinned
# in apps/platform/argocd/kustomization.yaml so the takeover is a no-op
# rather than an immediate upgrade.
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version <SAME_VERSION_AS_IN_GIT> \
  --wait
```

Verify the install:

```bash
kubectl -n argocd get pods
# Expect: argocd-application-controller, argocd-server, argocd-repo-server,
# argocd-redis, argocd-applicationset-controller, argocd-notifications-controller,
# argocd-dex-server — all Running.
```

### Step 2: Get the admin password and access the UI (optional but useful)

```bash
# Initial admin password is auto-generated and stored in a secret.
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo

# Port-forward to access the UI.
kubectl -n argocd port-forward svc/argocd-server 8080:443
# Open https://localhost:8080, log in as user `admin` with the password above.
```

You don't *need* the UI to proceed — everything is declarative — but it's useful to watch syncs happen.

### Step 3: (If repo is private) Pre-create the repo credentials

If the GitOps repo is public, skip this step.

If private, ArgoCD needs a credential to pull from it. Create a secret it can read:

```bash
# For a token-based auth (e.g. Forgejo or GitHub PAT):
kubectl -n argocd create secret generic ykube-repo \
  --from-literal=type=git \
  --from-literal=url=<REPO_URL> \
  --from-literal=username=<GIT_USERNAME> \
  --from-literal=password=<GIT_TOKEN>

# Label it so ArgoCD picks it up as a repository:
kubectl -n argocd label secret ykube-repo argocd.argoproj.io/secret-type=repository
```

This is a one-time imperative action. Long-term the credential should come from Vault via ESO, but ESO isn't running yet — chicken-and-egg.

### Step 4: Apply the root Application

```bash
# This is the one and only manual `kubectl apply` of an Argo manifest.
kubectl apply -f bootstrap/root-app.yaml
```

What happens next, in order, automatically:

1. The root Application appears in ArgoCD and starts syncing.
2. It applies the AppProjects (`platform`, `infrastructure`, `workloads`) and the ApplicationSets.
3. Each ApplicationSet's git directory generator scans `apps/<project>/*` and creates one Application per subdirectory.
4. Sync waves kick in: `apps/platform/argocd/` (wave -10) syncs first, taking over the seed install. Then cert-manager, ESO, etc. (wave 0–10). Then infrastructure (wave 20+). Then workloads (wave 30+).

Watch progress:

```bash
# Watch all Applications across all namespaces.
kubectl get applications -A -w

# Or via the CLI:
argocd app list
```

Expect a few transient errors during the first few minutes as things come up out-of-order or wait for CRDs. Sync waves should resolve them; if anything is still red after 5–10 minutes, investigate.

### Step 5: Verify the takeover

After the first full reconciliation, the seed install has been replaced by the Git-managed install. Verify:

```bash
# The argocd Application should exist and be Synced + Healthy.
kubectl -n argocd get application platform-argocd
# Status should show:
#   SYNC STATUS: Synced
#   HEALTH STATUS: Healthy

# Helm still sees its release, but ArgoCD now owns the resources.
helm -n argocd list
# argocd release should still be listed; this is fine.
```

From this point on, **do not run `helm upgrade argocd`**. All changes go through Git.

### Step 6: (When using Terraform) Add lifecycle ignore_changes

If the seed was installed via Terraform's helm provider rather than `helm install` directly:

```hcl
resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "<PINNED_VERSION>"

  lifecycle {
    ignore_changes = all
  }
}
```

After this is applied once, Terraform will not touch the helm release again. Future `terraform apply` runs are no-ops for this resource. ArgoCD owns it.

### Step 7: First post-bootstrap upgrade (when you eventually do one)

When a new ArgoCD chart version comes out and you want to upgrade:

```bash
# 1. Edit apps/platform/argocd/kustomization.yaml — bump the chart version.
# 2. Commit and push.
git add apps/platform/argocd/kustomization.yaml
git commit -m "chore(argocd): bump chart to X.Y.Z"
git push

# 3. ArgoCD picks up the change on its next reconcile (default 3 minutes,
#    or trigger immediately):
argocd app sync platform-argocd

# 4. Watch the sync. Expect the controller pod to restart mid-sync and the
#    UI to briefly stall. Wait 1–2 minutes, refresh.
kubectl -n argocd get pods -w

# 5. If sync shows as Failed afterward, click sync again or:
argocd app sync platform-argocd
# It should go green on the second try. This is the documented spurious-failure
# behavior — not a real issue.
```

### Recovery: if a bad upgrade breaks the controller

If `apps/platform/argocd` syncs a broken values.yaml or a chart version with a regression and the application-controller is crash-looping:

```bash
# 1. Revert the bad commit in Git.
git revert <bad-commit>
git push

# But this won't help if the controller can't read Git anymore. So:

# 2. Manually patch the deployment back to a known-good image.
kubectl -n argocd set image deployment/argocd-application-controller \
  application-controller=quay.io/argoproj/argocd:<known-good-version>

# 3. Wait for it to come back up.
kubectl -n argocd rollout status deployment/argocd-application-controller

# 4. Once it's healthy, it will reconcile from Git (which now has the reverted state).
```

Keep the previous chart version and image tag in your notes for exactly this scenario.

## What NOT to do

- Don't put any actual secrets in any file. Use `ExternalSecret` references with placeholder Vault paths and a TODO.
- Don't create the friends-PaaS structure. It's intentionally deferred.
- Don't add Argo Rollouts, Image Updater, or other Argo subprojects. We may add Argo Workflows + Events under `infrastructure/` (the directories should exist as placeholders), but the actual setup is a separate piece of work.
- Don't use a matrix or merge ApplicationSet generator. Three plain git-directory generators.
- Don't invent application configurations. Empty placeholders are correct unless explicitly told otherwise.
- Don't add CI/CD pipeline configs for this repo (no GitHub Actions, no Forgejo Actions, no pre-commit). The user will decide on those separately.

## Open questions to ask the user before finalizing

1. **Repo URL.** What's the actual git URL — `https://github.com/urosevicvuk/ykube` or a Forgejo URL once Forgejo is up? (Bootstrap with GitHub probably; migrate to Forgejo later.)
2. **Ingress controller.** Ingress-nginx, Traefik (Talos default), or Cilium Gateway API? Affects what goes in `apps/platform/`.
3. **DNS / cert strategy.** ExternalDNS to Cloudflare + cert-manager with a Cloudflare DNS-01 issuer? Confirm.
4. **Initial cluster name.** `firelink` is the existing convention; confirm this is the homelab cluster's name.
5. **PodSecurity defaults.** Cluster-wide baseline / restricted enforcement, or per-namespace?

Ask these before generating the per-app stubs, since the answers affect concrete contents.

## How to work with the user

The user is opinionated and technical. He will push back if something feels over-engineered or wrong-shaped — listen to that, don't double down on defaults. He prefers Unix-philosophy composition over monolithic platforms. He likes Go, NixOS idioms, and clean separation of concerns. He dislikes excessive abstraction and YAML for YAML's sake.

When you finish, present the file tree, the bootstrap command (`kubectl apply -f bootstrap/root-app.yaml`), and a short summary of what's done vs what's deferred. Don't pad. Don't wrap up with a sales pitch.
