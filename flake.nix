{
  inputs = {
    systems.url = "github:nix-systems/default";

    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-25.11-darwin";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    just = {
      url = "github:casey/just";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { inputs, ... }:
      {
        imports = [ flake-parts.flakeModules.modules ];

        systems = import inputs.systems;

        perSystem =
          { inputs', pkgs, ... }:
          {
            devShells.default = pkgs.mkShell {
              packages = [
                inputs'.just.packages.default

                pkgs.fzf
                pkgs.gum

                pkgs.act
                pkgs.skopeo
              ];
            };

            formatter = pkgs.nixfmt-rfc-style;
          };
      }
    );
}
