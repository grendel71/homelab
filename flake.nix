{
  description = "Talos + kubectl development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    sops-nix.url = "github:Mic92/sops-nix";
  };

  outputs = { self, nixpkgs, sops-nix }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in {
      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              talosctl
              kubectl
              sops
              age
              ssh-to-age
	      fluxcd
            ];

            shellHook = ''
              export KUBECONFIG="$PWD/.kubeconfig.dev"

	      export SOPS_AGE_KEY_FILE=./age.agekey
              # Talos config in-repo doesn't include nodes by default; talosctl then requires
              # specifying --nodes on every command. Keep the original as a source of truth,
              # but generate a dev config with nodes pre-set.
              export TALOSCONFIG="$PWD/.talosconfig.dev"

              # Edit these to match your cluster.
              export CONTROL_PLANE_IPS="192.168.1.100"
              export WORKER_IPS="192.168.1.158"

              # Used by some scripts/tools (Kubernetes API endpoint, not Talos API).
              export ENDPOINT="https://192.168.1.100:6443"

              if [ -f "$PWD/secrets/talosconfig.sops.yaml" ]; then
                umask 077
                sops -d "$PWD/secrets/talosconfig.sops.yaml" > "$TALOSCONFIG"

                # Use control plane nodes as Talos API endpoints.
                talosctl config endpoint $CONTROL_PLANE_IPS >/dev/null 2>&1 || true
                # Target all nodes by default.
                talosctl config node $CONTROL_PLANE_IPS $WORKER_IPS >/dev/null 2>&1 || true
              fi

              if [ -f "$PWD/secrets/kubeconfig.sops.yaml" ]; then
                umask 077
                sops -d "$PWD/secrets/kubeconfig.sops.yaml" > "$KUBECONFIG"
              fi
            '';
          };
        });
    };
}
