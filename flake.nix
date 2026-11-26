{
  description = "ykube — homelab GitOps repo. Dev shell with the k8s/argo/rke2 bootstrap toolchain.";

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
          cloudflared

          # Bootstrap (seed/rke2) and host installs (ynix, nixos-anywhere)
          go-task # Taskfile runner — orchestrates seed/ stages
          nixos-anywhere
          shellcheck

          # Only for the abandoned seed/talos pipeline; drop together with it.
          talosctl
          opentofu

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
          export INFRA_ROOT="$PWD/seed/talos"
        '';
      };
    });
}
