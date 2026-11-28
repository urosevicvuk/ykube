# seed/rke2/

Bootstrap for the RKE2 cluster on **kiln1-3** (bare-metal NixOS). Takes it
from "three RKE2 servers up, nodes NotReady" to "Argo CD reconciling this
repo, Vault unsealed". The why and the phases are in [`PLAN.md`](PLAN.md);
this file is the runbook. First install, from a NixOS USB stick to a running
cluster, step by step: [`INSTALL.md`](INSTALL.md).

The hosts themselves (OS, network, RKE2, keepalived, fans) are declared in
`ynix` (`modules/features/kiln/`, `modules/hosts/kilnN/`,
`modules/sites/office.nix`). Nothing here touches them.

## Prerequisites

- Dev shell: `nix develop` (kubectl, helm, yq, jq, vault, task, cilium, ...).
- SSH to the nodes as your user, with sudo (the kubeconfig is root-only).
- The API VIP from `ynix/modules/sites/office.nix` (`ykube.cluster.lan.apiVip`).

## 1. Hosts (in ynix, once per host)

Full procedure (ISO, facts, cable checks, host keys, install order, setting
the password): [`INSTALL.md`](INSTALL.md) steps 0–7. Short form:

```bash
cd ~/Projects/urosevicvuk/ynix

# Facts: NIC MACs/PCI paths and disk IDs, from any live Linux on the box
ssh root@<host> 'bash -s' < modules/features/kiln/_collect-facts.sh
# -> fill in modules/hosts/kilnN/configuration.nix, set ykube.node.factsVerified = true

# SSH host key, pre-generated so sops can encrypt the cluster token to it
# (full steps: secrets/kiln/README.md)

nix build .#checks.x86_64-linux.kiln-hosts      # all three evaluate
nixos-anywhere --flake .#kilnN --extra-files /tmp/kilnN root@<host>
```

Install kiln1 first: it's `bootstrapNode` and creates the cluster. kiln2 and
kiln3 join through the VIP as soon as they boot. Then set
`ykube.cluster.bootstrapNode = null` in `office.nix` and redeploy kiln1 (a
bootstrap node that lost its etcd would otherwise start a second, empty
cluster).

On a host (as root; `KUBECONFIG`, `CRI_CONFIG_FILE` and `ETCDCTL_*` are preset):

```bash
kubectl get nodes -o wide          # 3 nodes, NotReady until Cilium
crictl ps                          # etcd, kube-apiserver, -scheduler, -controller-manager
etcdctl member list                # 3 members on 10.10.0.x
bridge link show                   # mesh: one port blocking across the three hosts
journalctl -u kiln-fanctl -f       # M5 fans
```

## 2. Cluster bootstrap (from the workstation)

```bash
nix develop
API_VIP=192.168.1.10 task -d seed/rke2 kubeconfig   # -> seed/rke2/secrets/kubeconfig.yaml
task -d seed/rke2 cluster:bootstrap                 # stages 01 -> 05
task -d seed/rke2 check                             # exit checks
```

| Task | Stage | What it does |
|---|---|---|
| `kubeconfig` | 00 | Copies `/etc/rancher/rke2/rke2.yaml` off a node (sudo), points it at the VIP, context `ykube`. |
| `crds` | 01 | Gateway API + Envoy Gateway CRDs (version from the envoy kustomization) and Prometheus Operator CRDs (version = kube-prometheus-stack's appVersion). |
| `cilium` | 02 | Installs Cilium with the chart version and `values.yaml` Argo reconciles; waits for nodes Ready; applies the LB pool, L2 policy and kube-system policy. |
| `argocd` | 03 | Installs Argo CD from `root/` and applies `root/app-of-apps.yaml`. GitOps from here. |
| `vault:init` | 04 | Waits for Vault (Argo deploys it), `operator init` (5 keys, threshold 3) into `secrets/vault-init.json`, unseals all three replicas, enables kv-v2 + Kubernetes auth + the external-secrets role. |
| `vault:secrets` | 05 | Prompts for every bootstrap secret the repo's ExternalSecrets read. When migrating from firelink, paste the values it marks as must-copy. |

**Back up `seed/rke2/secrets/vault-init.json` to Bitwarden immediately.**
Without it a sealed Vault can't be opened again.

Each stage is idempotent; re-run any of them. Cilium and Argo CD are
installed once and then owned by Argo CD (upgrades go through Git).

## Day 2

```bash
task -d seed/rke2 vault:status     # after reboots
task -d seed/rke2 vault:unseal     # replicas come back sealed (no auto-unseal)
task -d seed/rke2 check
```

Rolling host updates, Kubernetes upgrades and backups: `PLAN.md` →
*Operations*.
