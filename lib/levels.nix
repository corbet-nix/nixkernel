# SPDX-License-Identifier: MIT OR Apache-2.0
# The CPU levels a kernel can be built for: what each one needs from the CPU, which levels a host
# can run, and which one it gets. Plain data and functions, no `pkgs`; modules/nixkernel.nix applies
# them, checks/ tests them directly.
#
# A level is named the way the kernel source suffixes its package sets
# (`linuxPackages-cachyos-<line>[-lto]<suffix>`). `generic` is not a CachyOS build at all: it leaves
# `boot.kernelPackages` and the ZFS package as the configuration has them (nixpkgs' default kernel).
#
# Flags are /proc/cpuinfo names (`pni` is SSE3, `abm` is LZCNT), because two readers use them: the
# evaluation, against the flags a host declares in `nixcpu.features`, and the post-boot unit, against
# the live /proc/cpuinfo. One list serves both, so they cannot disagree.
{ lib }:
let
  v2 = [
    "cx16"
    "lahf_lm"
    "popcnt"
    "pni"
    "sse4_1"
    "sse4_2"
    "ssse3"
  ];
  v3 = v2 ++ [
    "avx"
    "avx2"
    "bmi1"
    "bmi2"
    "f16c"
    "fma"
    "abm"
    "movbe"
    "xsave"
  ];
  v4 = v3 ++ [
    "avx512f"
    "avx512bw"
    "avx512cd"
    "avx512dq"
    "avx512vl"
  ];
  # What -march=znver4 adds to v4, and what -march=znver5 adds to that.
  znver4 = v4 ++ [
    "avx512ifma"
    "avx512vbmi"
    "avx512_vbmi2"
    "avx512_vnni"
    "avx512_bitalg"
    "avx512_vpopcntdq"
    "avx512_bf16"
    "gfni"
    "vaes"
    "vpclmulqdq"
    "clwb"
    "rdpid"
    "wbnoinvd"
  ];
  znver5 = znver4 ++ [
    "avx_vnni"
    "movdiri"
    "movdir64b"
    "avx512_vp2intersect"
  ];

  # name -> {
  #   suffix  the package-set suffix of the kernel source (null: not a source package, see `generic`)
  #   psabi   the x86-64 psABI level the build needs, compared with `nixcpu.microarch`
  #   flags   the /proc/cpuinfo flags every processor needs
  #   tuned   true when `flags` go beyond the psABI level, so the declared level alone cannot prove them
  #   vendor  (tuned levels) the nixcpu vendor the build is tuned for
  # }
  levels = {
    generic = {
      suffix = null;
      psabi = 0;
      flags = [ ];
      tuned = false;
    };
    x86_64-v1 = {
      suffix = "";
      psabi = 1;
      flags = [ ];
      tuned = false;
    };
    x86_64-v2 = {
      suffix = "-x86_64-v2";
      psabi = 2;
      flags = v2;
      tuned = false;
    };
    x86_64-v3 = {
      suffix = "-x86_64-v3";
      psabi = 3;
      flags = v3;
      tuned = false;
    };
    x86_64-v4 = {
      suffix = "-x86_64-v4";
      psabi = 4;
      flags = v4;
      tuned = false;
    };
    zen4 = {
      suffix = "-zen4";
      psabi = 4;
      flags = znver4;
      tuned = true;
      vendor = "amd";
    };
    znver5 = {
      suffix = "-znver5";
      psabi = 4;
      flags = znver5;
      tuned = true;
      vendor = "amd";
    };
  };

  # nixcpu's vendor facts as /proc/cpuinfo spells them.
  cpuinfoVendor = {
    amd = "AuthenticAMD";
    intel = "GenuineIntel";
  };

  psabiRank =
    microarch: if microarch == null then 0 else lib.toInt (lib.removePrefix "x86_64-v" microarch);

  # What a host lacks for a level, as messages; [ ] means it can run it. `facts` is null (nothing
  # declared) or { arch, vendor, microarch, features } as nixcpu declares them.
  #
  # `generic` and `x86_64-v1` need nothing: every x86-64 CPU runs the baseline, and the kernel source
  # offers only x86-64 builds. Every higher level needs declared facts. The tuned levels need the
  # recorded flags as well, because their flags go beyond what `nixcpu.microarch` can state; at the
  # psABI levels recorded flags are checked when present.
  missing =
    facts: name:
    let
      l = levels.${name};
      declared = v: if v == null then "null" else toString v;
    in
    if !(levels ? ${name}) then
      [ "a level nixkernel knows (${lib.concatStringsSep ", " (lib.attrNames levels)})" ]
    else if l.psabi <= 1 then
      [ ]
    else if facts == null then
      [ "declared CPU facts (compose nixcpu and set nixcpu.enable, nixcpu.microarch)" ]
    else
      lib.optional (facts.arch != "x86_64") "nixcpu.arch = \"x86_64\" (declared: ${declared facts.arch})"
      ++ lib.optional (
        psabiRank facts.microarch < l.psabi
      ) "nixcpu.microarch x86_64-v${toString l.psabi} or higher (declared: ${declared facts.microarch})"
      ++ lib.optional (
        l ? vendor && facts.vendor != l.vendor
      ) "nixcpu.vendor = \"${l.vendor}\" (declared: ${declared facts.vendor})"
      ++ (
        if facts.features == null then
          lib.optional l.tuned "the recorded CPU flags (nixcpu.features)"
        else
          map (f: "flag ${f}") (lib.filter (f: !(lib.elem f facts.features)) l.flags)
      );

  # The first level of `preference` that the host can run and the source offers (`offered`: name ->
  # bool); `generic` when there is none. A level the source does not offer yet is skipped, so the lock
  # bump that brings it adopts it.
  select =
    {
      facts,
      preference,
      offered,
    }:
    let
      ok = lib.filter (n: (n == "generic" || offered n) && missing facts n == [ ]) preference;
    in
    if ok == [ ] then "generic" else lib.head ok;

  # The attribute of the source's package sets for a level (`linuxPackages-cachyos-latest-lto-zen4`).
  kernelAttr =
    {
      line,
      lto,
      level,
    }:
    "linuxPackages-cachyos-${line}${lib.optionalString lto "-lto"}${levels.${level}.suffix}";

  # A /proc/cpuinfo of the processors [ { vendor, features } ] (cpuinfo vendor strings), for testing the
  # post-boot unit against look-alikes.
  cpuinfoOf = lib.concatImapStrings (
    i: c:
    "processor\t: ${toString (i - 1)}\nvendor_id\t: ${c.vendor}\nflags\t\t: ${lib.concatStringsSep " " c.features}\n\n"
  );
in
{
  inherit
    levels
    cpuinfoVendor
    missing
    select
    kernelAttr
    cpuinfoOf
    ;
}
