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
    testCache
    compromisedCache
    optionsOf
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
  (check "module/cachyos-level-adjustments"
    (
      !(lib.any (lib.hasPrefix "transparent_hugepage=") onZen5.boot.kernelParams)
      && lib.elem "aesni_intel" onZen5.boot.initrd.availableKernelModules
      && lib.elem testCache.substituter onZen5.nix.settings.extra-substituters
      && onZen5.systemd.services ? nixkernel-verify
    )
    "aesni_intel, the cache and nixkernel-verify must be present at a CachyOS level, and no THP parameter (nixram owns THP)"
  )

  # Catches: the declared pair not reaching nix.settings, or reaching it half (URL without key).
  (check "module/cache-pair-renders-as-declared" (
    lib.elem testCache.substituter onZen5.nix.settings.extra-substituters
    && lib.elem testCache.publicKey onZen5.nix.settings.extra-trusted-public-keys
    && refusals onZen5 == [ ]
  ) "the declared substituter and key must both be in extra-substituters/extra-trusted-public-keys")

  # Catches: a default pair coming back in the option declarations (the module would again hand every host a trust root
  # nobody chose; the other cache checks pass a pair explicitly and would not notice).
  (check "module/cache-url-and-key-have-no-default"
    (optionsOf.cache.substituter.default == null && optionsOf.cache.publicKey.default == null)
    "nixkernel.cache.substituter and nixkernel.cache.publicKey must default to null: the pair is the host's decision"
  )

  # Catches: a default pair coming back. A host that never declared a cache must not get a trust root nobody chose;
  # the incident of 2026-10-15 was exactly a default naming a compromised cache.
  (check "module/cache-without-a-pair-is-refused"
    (
      let
        noPair = eval (
          zen5
          // {
            nixkernel.cache = {
              substituter = lib.mkForce null;
              publicKey = lib.mkForce null;
            };
          }
        );
        onlyUrl = eval (zen5 // { nixkernel.cache.publicKey = lib.mkForce null; });
        off = eval (
          zen5
          // {
            nixkernel.cache = {
              enable = false;
              substituter = lib.mkForce null;
              publicKey = lib.mkForce null;
            };
          }
        );
      in
      refusedWith noPair "is true, but nixkernel.cache.substituter"
      && refusedWith onlyUrl "is true, but nixkernel.cache.substituter"
      && !(
        noPair.nix.settings ? extra-trusted-public-keys
        && noPair.nix.settings.extra-trusted-public-keys != [ ]
      )
      && refusals off == [ ]
    )
    "an enabled cache without both URL and key must be refused and render nothing; a disabled cache needs neither"
  )

  # Catches: the compromised pair accepted when a host names it explicitly (by URL or by key), or refused while disabled.
  (check "module/the-compromised-pair-is-refused-even-when-set"
    (
      let
        oldUrl = eval (zen5 // { nixkernel.cache.substituter = lib.mkForce compromisedCache.substituter; });
        oldKey = eval (zen5 // { nixkernel.cache.publicKey = lib.mkForce compromisedCache.publicKey; });
        off = eval (
          zen5
          // {
            nixkernel.cache = {
              enable = false;
              substituter = lib.mkForce compromisedCache.substituter;
              publicKey = lib.mkForce compromisedCache.publicKey;
            };
          }
        );
      in
      refusedWith oldUrl "names the cache pair that was compromised"
      && refusedWith oldKey "names the cache pair that was compromised"
      && refusals off == [ ]
      && !(lib.elem compromisedCache.publicKey (off.nix.settings.extra-trusted-public-keys or [ ]))
    )
    "the pair of 2026-10-15 must be refused by URL and by key while the cache is enabled, and never rendered"
  )

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
    && !(lib.elem testCache.substituter (bare.nix.settings.extra-substituters or [ ]))
    && bare.boot.zfs.package.name != "zfs-cachyos-x86_64-v3"
  ) "with fallback, verify, cache, THP, aesni and zfs.cachyos off only the kernel may change")

  # Catches: an unknown level accepted by the option type.
  (check "module/an-unknown-level-fails-by-type" (
    !(builtins.tryEval (builtins.seq (forced "znver9" zen5).nixkernel.level true)).success
  ) "a level outside lib/levels.nix must be a type error")
]
