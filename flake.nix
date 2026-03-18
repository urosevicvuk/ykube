{
  description = "ykube - Kubernetes homelab development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          kubectl
          kubernetes-helm
          talosctl
          argocd
          cilium-cli
          go-task
          jq
          yq-go
          opentofu
          kubeseal
          sops
          age
        ];
      };
    });
}
