{
  description = "Flake for Holochain app development";

  inputs = {
    tauri-plugin-holochain.url = "github:darksoil-studio/tauri-plugin-holochain/main-0.5";
    holonix.url = "github:holochain/holonix?ref=main-0.5";

    nixpkgs.follows = "holonix/nixpkgs";
    # Use a stable nixpkgs for GTK dependencies to avoid AT-SPI conflicts
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-23.11";
    flake-parts.follows = "holonix/flake-parts";
    playground.url = "github:darksoil-studio/holochain-playground?ref=main-0.5";
  };

  outputs = inputs@{ flake-parts, ... }: flake-parts.lib.mkFlake { inherit inputs; } {
    systems = builtins.attrNames inputs.holonix.devShells;
    perSystem = { inputs', pkgs, system, ... }: 
    let
      # Use stable nixpkgs for GTK dependencies to avoid AT-SPI conflicts
      stable-pkgs = import inputs.nixpkgs-stable { inherit system; };
    in {
      formatter = pkgs.nixpkgs-fmt;

      devShells.default = pkgs.mkShell {
        inputsFrom = [
              inputs'.tauri-plugin-holochain.devShells.holochainTauriDev inputs'.holonix.devShells.default ];

        packages = (with pkgs; [
          nodejs_20
          binaryen
          inputs'.playground.packages.hc-playground
          yarn
          pkg-config
        ]) ++ (with stable-pkgs; [
          # GTK and system dependencies for Tauri from stable nixpkgs
          gtk3
          webkitgtk
          cairo
          gdk-pixbuf
          pango
          atk
          glib
          wrapGAppsHook
        ]);

        buildInputs = with stable-pkgs; [
          gtk3
          webkitgtk
          glib
        ];

        nativeBuildInputs = with stable-pkgs; [
          pkg-config
          wrapGAppsHook
        ];

        shellHook = ''
          export PS1='\[\033[1;34m\][holonix:\w]\$\[\033[0m\] '
          # Completely disable AT-SPI to prevent symbol conflicts
          export NO_AT_BRIDGE=1
          export GTK_A11Y=none
          export ACCESSIBILITY_ENABLED=0
          export WEBKIT_DISABLE_COMPOSITING_MODE=1
          export WEBKIT_DISABLE_DMABUF_RENDERER=1
          export GDK_BACKEND=x11
          # Prevent AT-SPI from loading
          export DISABLE_ACCESSIBILITY=1
          export ATK_BRIDGE_DISABLE=1
        '';
      };
      devShells.androidDev = pkgs.mkShell {
        inputsFrom = [
              inputs'.tauri-plugin-holochain.devShells.holochainTauriAndroidDev inputs'.holonix.devShells.default ];

        packages = (with pkgs; [
          nodejs_20
          binaryen
          inputs'.playground.packages.hc-playground
          yarn
          pkg-config
        ]) ++ (with stable-pkgs; [
          # GTK and system dependencies for Tauri from stable nixpkgs
          gtk3
          webkitgtk
          cairo
          gdk-pixbuf
          pango
          atk
          glib
          wrapGAppsHook
        ]);

        buildInputs = with stable-pkgs; [
          gtk3
          webkitgtk
          glib
        ];

        nativeBuildInputs = with stable-pkgs; [
          pkg-config
          wrapGAppsHook
        ];

        shellHook = ''
          export PS1='\[\033[1;34m\][holonix:\w]\$\[\033[0m\] '
          # Completely disable AT-SPI to prevent symbol conflicts
          export NO_AT_BRIDGE=1
          export GTK_A11Y=none
          export ACCESSIBILITY_ENABLED=0
          export WEBKIT_DISABLE_COMPOSITING_MODE=1
          export WEBKIT_DISABLE_DMABUF_RENDERER=1
          export GDK_BACKEND=x11
          # Prevent AT-SPI from loading
          export DISABLE_ACCESSIBILITY=1
          export ATK_BRIDGE_DISABLE=1
        '';
      };
    };
  };
}