# SPDX-License-Identifier: MIT OR Apache-2.0
# checks/module.nix -- the NixOS module evaluated through nixpkgs' eval-config: what it renders and
# what it refuses. Nothing is built. Each check names the mutation it catches.
{ lib, fixtures }:
let
  inherit (fixtures)
    eval
    evalWith
    zen5
    zen3
    refusals
    refusedWith
    check
    ;

  onZen5 = eval zen5;
  fallback = onZen5.specialisation.generic-kernel.configuration;
  stock = (evalWith false { nixkernel.enable = lib.mkForce false; }).boot.kernelPackages;

  forced = level: extra: eval (lib.recursiveUpdate extra { nixkernel.level = level; });

  # The nixnas shape: every guard and adjustment switched off, a forced level.
  bare = eval (
    lib.recursiveUpdate zen3 {
      nixkernel = {
        level = "x86_64-v3";
        fallback.enable = false;
        verify.enable = false;
        cache.enable = false;
        transparentHugepage = null;
        initrdAesni = false;
        zfs.cachyos = false;
      };
    }
  );
in
[
  # Catches: the selected level not reaching boot.kernelPackages / boot.zfs.package.
  (check "module/zen5-renders-the-zen4-kernel-and-its-zfs" (
    onZen5.nixkernel.level == "zen4"
    && onZen5.boot.kernelPackages.nixkernelTestLevel == "zen4"
    && onZen5.boot.zfs.package.name == "zfs-cachyos-zen4"
    && refusals onZen5 == [ ]
  ) "a Zen 5 host must get the zen4 set and its zfs_cachyos, with no refusal")

  # Catches: the CachyOS-level adjustments, the cache or the unit going missing.
  (check "module/cachyos-level-adjustments" (
    lib.elem "transparent_hugepage=madvise" onZen5.boot.kernelParams
    && lib.elem "aesni_intel" onZen5.boot.initrd.availableKernelModules
    && lib.elem "https://attic.xuyh0120.win/lantian" onZen5.nix.settings.extra-substituters
    && onZen5.systemd.services ? nixkernel-verify
  ) "THP madvise, aesni_intel, the cache and nixkernel-verify must be present at a CachyOS level")

  # Catches: the fallback entry missing, or running a CachyOS kernel or ZFS.
  (check "module/fallback-entry-runs-the-generic-kernel"
    (
      fallback.nixkernel.level == "generic"
      && !(fallback.boot.kernelPackages ? nixkernelTestLevel)
      && fallback.boot.kernelPackages.kernel.version == stock.kernel.version
      && fallback.boot.zfs.package.name != "zfs-cachyos-zen4"
      && !(lib.elem "transparent_hugepage=madvise" fallback.boot.kernelParams)
    )
    "the specialisation generic-kernel must boot nixpkgs' kernel with the stock ZFS and no THP override"
  )

  # Catches: guard 1 dropped -- a forced level the declared CPU cannot run is accepted.
  (check "module/forced-zen4-on-zen3-is-refused-with-the-flags-named" (
    refusedWith (forced "zen4" zen3) "cannot run on this host"
    && refusedWith (forced "zen4" zen3) "flag avx512f"
    && refusals (forced "x86_64-v3" zen3) == [ ]
  ) "zen4 forced on a Zen 3 declaration must be refused naming avx512f; x86_64-v3 must pass")

  # Catches: facts read from nowhere -- a host without nixcpu given a level above the baseline.
  (check "module/without-nixcpu-generic-with-a-warning-and-v3-refused" (
    let
      none = evalWith false { };
      v3 = evalWith false { nixkernel.level = "x86_64-v3"; };
      v1 = evalWith false { nixkernel.level = "x86_64-v1"; };
    in
    none.nixkernel.level == "generic"
    && lib.any (lib.hasInfix "no CPU facts are declared") none.warnings
    && refusedWith v3 "declared CPU facts"
    && refusals v1 == [ ]
    && v1.boot.kernelPackages.nixkernelTestLevel == "x86_64-v1"
  ) "no nixcpu: generic with a warning; x86_64-v3 refused; x86_64-v1 (no suffix) accepted")

  # Catches: guard against an uncached build dropped -- a level the source lacks is accepted.
  (check "module/a-level-the-source-does-not-offer-is-refused"
    (
      refusedWith (forced "x86_64-v2" (fixtures.cpu { microarch = "x86_64-v2"; })) "does not offer"
      && refusedWith (forced "zen4" (zen5 // { nixkernel.line = "lts"; })) "does not offer"
      && (eval (zen5 // { nixkernel.line = "lts"; })).nixkernel.level == "generic"
      &&
        lib.any (lib.hasInfix "no level of nixkernel.preference")
          (eval (zen5 // { nixkernel.line = "lts"; })).warnings
    )
    "a forced level the source lacks must be refused; an unoffered line selects generic with a warning"
  )

  # Catches: floors not enforced, or enforced when satisfied.
  (check "module/floors-are-enforced-both-ways" (
    let
      floor = version: {
        nixkernel.floors.test = {
          inherit version;
          reason = "the test";
        };
      };
    in
    refusedWith (eval (zen5 // floor "99.0")) "floor `test` = 99.0"
    &&
      refusedWith (eval (zen5 // floor "99.0")).specialisation.generic-kernel.configuration
        "floor `test` = 99.0"
    && refusals (eval (zen5 // floor "1.0")) == [ ]
  ) "a floor above the kernel must be refused, in the fallback entry too; one below it accepted")

  # Catches: a switched-off guard or adjustment still rendering (the shape nixnas depends on).
  (check "module/everything-switched-off-renders-only-the-kernel" (
    bare.boot.kernelPackages.nixkernelTestLevel == "x86_64-v3"
    && bare.specialisation == { }
    && !(bare.systemd.services ? nixkernel-verify)
    && !(lib.elem "aesni_intel" bare.boot.initrd.availableKernelModules)
    && !(lib.any (lib.hasPrefix "transparent_hugepage=") bare.boot.kernelParams)
    && !(lib.elem "https://attic.xuyh0120.win/lantian" (bare.nix.settings.extra-substituters or [ ]))
    && bare.boot.zfs.package.name != "zfs-cachyos-x86_64-v3"
  ) "with fallback, verify, cache, THP, aesni and zfs.cachyos off only the kernel may change")

  # Catches: an unknown level accepted by the option type.
  (check "module/an-unknown-level-fails-by-type" (
    !(builtins.tryEval (builtins.seq (forced "znver9" zen5).nixkernel.level true)).success
  ) "a level outside lib/levels.nix must be a type error")
]
