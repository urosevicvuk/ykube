{
  description = "ykube — homelab GitOps repo. Dev shell with the k8s/argo/talos toolchain.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg:
          builtins.elem (nixpkgs.lib.getName pkg) ["vault"];
      };
    in {
      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          # Core k8s
          kubectl
          kubernetes-helm
          kustomize
          k9s

          # ArgoCD
          argocd

          # Talos + Proxmox bootstrap
          talosctl
          opentofu # OpenTofu (Terraform fork) — used for the bootstrap pipeline
          go-task # Taskfile runner — orchestrates seed/ stages

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
          netcat-gnu # nc — used by stage 03 to wait for Talos APId
        ];

        shellHook = ''
          export INFRA_ROOT="$PWD/seed-talos"
          export KUBECONFIG=~/.kube/firelink.yaml
        '';
      };
    });
}
