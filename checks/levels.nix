# SPDX-License-Identifier: MIT OR Apache-2.0
# checks/levels.nix -- the choice of a level, as plain functions (lib/levels.nix), no NixOS eval.
# Each check names the mutation it catches.
{ lib, fixtures }:
let
  inherit (fixtures) k check;
  facts = c: c.nixcpu;
  pick =
    {
      offered ? (n: n != "znver5" && n != "x86_64-v2"),
      preference ? [
        "znver5"
        "zen4"
        "x86_64-v4"
        "x86_64-v3"
      ],
    }:
    c:
    k.select {
      facts = if c == null then null else facts c;
      inherit offered preference;
    };
  has = text: lib.any (lib.hasInfix text);
in
[
  # Catches: offered-filter dropped (znver5 chosen though the source lacks it), or a tuned level
  # never chosen.
  (check "levels/zen5-gets-zen4-until-the-source-offers-znver5" (
    pick { } fixtures.zen5 == "zen4" && pick { offered = _: true; } fixtures.zen5 == "znver5"
  ) "a Zen 5 host must get zen4 while the source lacks znver5, and znver5 once it offers it")

  # Catches: the psABI cap ignored (a v3 host given v4), or no fallback to generic.
  (check "levels/zen3-gets-x86_64-v3-and-a-v2-host-the-generic-kernel" (
    pick { } fixtures.zen3 == "x86_64-v3"
    && pick { } (fixtures.cpu { microarch = "x86_64-v2"; }) == "generic"
  ) "a v3 host must get x86_64-v3; a v2 host, with x86_64-v2 not offered, the generic kernel")

  # Catches: the vendor guard dropped (an Intel CPU with every znver4 flag tuned for Zen).
  (check "levels/the-zen-levels-need-amd" (
    pick { } fixtures.intelV4 == "x86_64-v4"
  ) "an Intel host with AVX-512 must get x86_64-v4, never the AMD-tuned zen4")

  # Catches: a tuned level allowed on the declared psABI level alone, without recorded flags.
  (check "levels/tuned-levels-need-recorded-flags" (
    pick { } (fixtures.cpu { microarch = "x86_64-v4"; }) == "x86_64-v4"
    && has "nixcpu.features" (k.missing (facts (fixtures.cpu { microarch = "x86_64-v4"; })) "zen4")
  ) "zen4 must be refused when only nixcpu.microarch is declared")

  # Catches: recorded flags trusted over the declared level (the declaration caps the choice).
  (check "levels/the-declared-microarch-caps-the-flags" (
    pick { } (
      fixtures.cpu {
        microarch = "x86_64-v3";
        features = k.levels.zen4.flags;
      }
    ) == "x86_64-v3"
  ) "a host declaring x86_64-v3 must get x86_64-v3 even when its flags would allow more")

  # Catches: a recorded flag list not checked at a psABI level (one missing AVX-512 flag).
  (check "levels/recorded-flags-are-checked-at-psabi-levels" (
    let
      partial = fixtures.cpu {
        microarch = "x86_64-v4";
        features = lib.remove "avx512vl" k.levels.x86_64-v4.flags;
      };
    in
    pick { } partial == "x86_64-v3" && has "flag avx512vl" (k.missing (facts partial) "x86_64-v4")
  ) "a host whose recorded flags lack avx512vl must get x86_64-v3, with the flag named")

  # Catches: facts demanded where none are needed, or none demanded where they are.
  (check "levels/without-facts-only-generic-and-x86_64-v1" (
    pick { } null == "generic"
    && k.missing null "generic" == [ ]
    && k.missing null "x86_64-v1" == [ ]
    && has "declared CPU facts" (k.missing null "x86_64-v3")
  ) "no facts: generic and x86_64-v1 allowed, x86_64-v3 refused naming nixcpu")

  # Catches: a non-x86 host allowed a psABI level.
  (check "levels/an-aarch64-host-gets-no-x86-level" (has "nixcpu.arch" (
    k.missing (
      facts (fixtures.cpu { microarch = "x86_64-v3"; })
      // {
        arch = "aarch64";
      }
    ) "x86_64-v3"
  )) "an aarch64 declaration must not run an x86-64 level")

  # Catches: preference order ignored, or an empty preference not falling back.
  (check "levels/the-preference-order-rules" (
    pick {
      preference = [
        "x86_64-v3"
        "zen4"
      ];
    } fixtures.zen5 == "x86_64-v3"
    && pick { preference = [ ]; } fixtures.zen5 == "generic"
  ) "the first runnable, offered level of the list wins; an empty list gives generic")

  # Catches: a suffix or lto mix-up in the package-set name.
  (check "levels/package-set-names" (
    k.kernelAttr {
      line = "latest";
      lto = true;
      level = "zen4";
    } == "linuxPackages-cachyos-latest-lto-zen4"
    &&
      k.kernelAttr {
        line = "lts";
        lto = false;
        level = "x86_64-v3";
      } == "linuxPackages-cachyos-lts-x86_64-v3"
    &&
      k.kernelAttr {
        line = "latest";
        lto = true;
        level = "x86_64-v1";
      } == "linuxPackages-cachyos-latest-lto"
  ) "linuxPackages-cachyos-<line>[-lto][-<level>], x86_64-v1 without a suffix")

  # Catches: the flag lists drifting from cumulative (a level not including the one below it).
  (check "levels/flag-lists-are-cumulative" (
    lib.all (f: lib.elem f k.levels.x86_64-v3.flags) k.levels.x86_64-v2.flags
    && lib.all (f: lib.elem f k.levels.x86_64-v4.flags) k.levels.x86_64-v3.flags
    && lib.all (f: lib.elem f k.levels.zen4.flags) k.levels.x86_64-v4.flags
    && lib.all (f: lib.elem f k.levels.znver5.flags) k.levels.zen4.flags
  ) "each level's flags must include the flags of the level below it")
]
