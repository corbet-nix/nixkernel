# SPDX-License-Identifier: MIT OR Apache-2.0
{
  description = "The kernel domain: the CachyOS kernel and its ZFS at the CPU level a NixOS host can run, refused at evaluation when the declared CPU cannot run it, with a fallback boot entry and a post-boot CPU check.";

  inputs = {
    # checks-only: the module uses the `pkgs`/`lib` the consumer's evaluation passes in, so a
    # consumer that follows this input (or ignores it) pays no second nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      # The kernel source publishes x86_64 builds only, and every check is a real derivation an
      # x86_64 runner can build, so this is the one system the checks claim.
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      nixosModules.nixkernel = ./modules/nixkernel.nix;
      nixosModules.default = self.nixosModules.nixkernel;

      # The level catalogue and the selection functions, for consumers that want to inspect or test
      # them without evaluating a system.
      lib.levels = import ./lib/levels.nix { inherit lib; };

      checks = forAllSystems (
        system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit lib nixpkgs system;
          nixkernelModule = self.nixosModules.nixkernel;
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
