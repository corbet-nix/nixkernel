# SPDX-License-Identifier: MIT OR Apache-2.0
# checks/fixtures.nix -- shared fixtures for the eval tests and the unit test.
#
# The kernel source is a stand-in: every level's package set is nixpkgs' own `linuxPackages` with a
# marker attribute naming the level and a marker `zfs_cachyos`, so a test can tell which set the
# module selected without building or downloading a kernel. `x86_64-v2` and `znver5` are absent on
# purpose: they prove that a level the source does not offer is skipped by the preference and refused
# when forced.
#
# nixcpu is a stand-in too: a module declaring the option shape nixkernel reads
# (`nixcpu.{enable,arch,vendor,microarch,features}`). nixkernel couples to nixcpu by option value,
# never by flake input, so the shape is the whole contract under test.
{
  pkgs,
  lib,
  nixpkgs,
  system,
  nixkernelModule,
}:
let
  k = import ../lib/levels.nix { inherit lib; };

  stubSet =
    level:
    pkgs.linuxPackages.extend (
      _: _: {
        nixkernelTestLevel = level;
        zfs_cachyos = pkgs.writeText "zfs-cachyos-${level}" "";
      }
    );
  source = {
    "linuxPackages-cachyos-latest-lto" = stubSet "x86_64-v1";
    "linuxPackages-cachyos-latest-lto-x86_64-v3" = stubSet "x86_64-v3";
    "linuxPackages-cachyos-latest-lto-x86_64-v4" = stubSet "x86_64-v4";
    "linuxPackages-cachyos-latest-lto-zen4" = stubSet "zen4";
  };

  nixcpuShape =
    { lib, ... }:
    {
      options.nixcpu = {
        enable = lib.mkEnableOption "the nixcpu stand-in";
        arch = lib.mkOption { type = lib.types.str; };
        vendor = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        microarch = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        features = lib.mkOption {
          type = lib.types.nullOr (lib.types.listOf lib.types.str);
          default = null;
        };
      };
    };

  base = {
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "none";
      fsType = "tmpfs";
    };
    system.stateVersion = "25.05";
    nixkernel = {
      enable = true;
      inherit source;
    };
  };

  # withNixcpu: compose the nixcpu stand-in (false = a host without nixcpu at all).
  evalWith =
    withNixcpu: extra:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [
        nixkernelModule
        base
        extra
      ]
      ++ lib.optional withNixcpu nixcpuShape;
    }).config;
  eval = evalWith true;

  # CPU facts as nixcpu declares them.
  cpu =
    {
      vendor ? "amd",
      microarch,
      features ? null,
    }:
    {
      nixcpu = {
        enable = true;
        arch = "x86_64";
        inherit vendor microarch features;
      };
    };
  zen5 = cpu {
    microarch = "x86_64-v4";
    features = [ "fpu" ] ++ k.levels.znver5.flags;
  };
  zen3 = cpu {
    microarch = "x86_64-v3";
    features = [ "fpu" ] ++ k.levels.x86_64-v3.flags;
  };
  # An Intel CPU with every flag -march=znver4 uses: the vendor alone keeps it off the AMD tuning.
  intelV4 = cpu {
    vendor = "intel";
    microarch = "x86_64-v4";
    features = k.levels.zen4.flags;
  };

  # The messages of nixkernel's failing assertions; [ ] means the configuration is accepted.
  refusals =
    config:
    map (a: a.message) (
      lib.filter (a: !a.assertion && lib.hasPrefix "nixkernel:" a.message) config.assertions
    );
  refusedWith = config: text: lib.any (lib.hasInfix text) (refusals config);

  check = name: ok: detail: { inherit name ok detail; };
in
{
  inherit
    k
    source
    eval
    evalWith
    cpu
    zen5
    zen3
    intelV4
    refusals
    refusedWith
    check
    ;
}
