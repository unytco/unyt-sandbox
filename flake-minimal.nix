{
  description = "Minimal Flake for Tauri without AT-SPI conflicts";

  inputs = {
    tauri-plugin-holochain.url = "github:darksoil-studio/tauri-plugin-holochain/main-0.5";
    holonix.url = "github:holochain/holonix?ref=main-0.5";
    nixpkgs.follows = "holonix/nixpkgs";
    flake-parts.follows = "holonix/flake-parts";
    playground.url = "github:darksoil-studio/holochain-playground?ref=main-0.5";
  };

  outputs = inputs@{ flake-parts, ... }: flake-parts.lib.mkFlake { inherit inputs; } {
    systems = builtins.attrNames inputs.holonix.devShells;
    perSystem = { inputs', pkgs, ... }: {
      formatter = pkgs.nixpkgs-fmt;

      devShells.default = pkgs.mkShell {
        inputsFrom = [
              inputs'.tauri-plugin-holochain.devShells.holochainTauriDev inputs'.holonix.devShells.default ];

        packages = (with pkgs; [
          nodejs_20
          binaryen
          inputs'.playground.packages.hc-playground
          yarn
          # Minimal GTK dependencies - no AT-SPI related packages
          pkg-config
        ]);

        shellHook = ''
          export PS1='\[\033[1;34m\][holonix:\w]\$\[\033[0m\] '
          # Force Tauri to use system GTK (avoiding Nix GTK entirely)
          export PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig:$PKG_CONFIG_PATH"
          # Disable all accessibility
          export NO_AT_BRIDGE=1
          export GTK_A11Y=none
          export GDK_BACKEND=x11
        '';
      };
    };
  };
} 