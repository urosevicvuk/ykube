{
  description = "ykube — homelab GitOps repo. Dev shell with the k8s/argo/talos toolchain.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs {
            inherit system;
            config.allowUnfreePredicate = pkg:
              builtins.elem (nixpkgs.lib.getName pkg) [ "vault" ];
          };
      in {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Core k8s
            kubectl
            kubernetes-helm
            kustomize

            # ArgoCD
            argocd

            # Talos + Proxmox bootstrap
            talosctl
            opentofu          # OpenTofu (Terraform fork) — used for the bootstrap pipeline
            go-task           # Taskfile runner — orchestrates infrastructure/ stages

            # Cilium
            cilium-cli
            hubble

            # Vault
            vault

            # YAML / JSON tooling
            yq-go
            jq

            # Misc useful
            git
            curl
            openssl
            netcat-gnu        # nc — used by stage 03 to wait for Talos APId
          ];

          shellHook = ''
            export INFRA_ROOT="$PWD/infrastructure"
            echo "ykube dev shell"
            echo "  kubectl    $(kubectl version --client 2>/dev/null | head -1)"
            echo "  helm       $(helm version --short 2>/dev/null)"
            echo "  argocd     $(argocd version --client --short 2>/dev/null | head -1)"
            echo "  talosctl   $(talosctl version --client --short 2>/dev/null | head -1)"
            echo "  tofu       $(tofu version 2>/dev/null | head -1)"
            echo "  task       $(task --version 2>/dev/null)"
            echo "  INFRA_ROOT=$INFRA_ROOT"
          '';
        };
      });
}
