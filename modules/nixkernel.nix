# SPDX-License-Identifier: MIT OR Apache-2.0
# nixkernel: the kernel a NixOS host boots, at the CPU level the host can run.
#
# The CachyOS kernel from xddxdd/nix-cachyos-kernel with its matching ZFS, selected per host from
# the CPU facts nixcpu declares. Three guards, because a kernel built for a CPU level the processor
# lacks does not fail one program: it faults in early boot, before any handler exists.
#   1. Evaluation: a level the declared CPU cannot run is refused (assertion), whoever chose it.
#   2. A permanent fallback boot entry (a specialisation) on the generic kernel with its stock ZFS,
#      listed by the boot loader in every kept generation.
#   3. After boot: the unit nixkernel-verify FAILS, with the missing flags in the journal, when the
#      live CPU lacks what the level needs (a virtual machine moved to an older host).
#
# Ownership. The CPU facts belong to nixcpu and are read by option value (`config.nixcpu.*`), never
# through a flake input; without nixcpu only the levels every x86-64 CPU runs are allowed. The boot
# loader, its entries and how many generations stay on the boot partition belong to nixboot. Minimum
# kernel versions are supplied by the domains that need them (`floors`); this module enforces them.
# The kernel source itself is a flake input of the consumer, handed over as `source` or applied as
# the source's overlay (`pkgs.cachyosKernels`): its nixpkgs must not follow the consumer's, because
# the binary cache holds the kernels only for the source's own pin.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    literalExpression
    ;

  cfg = config.nixkernel;
  k = import ../lib/levels.nix { inherit lib; };
  levelNames = lib.attrNames k.levels;

  # The declared CPU, or null when nixcpu is not composed or not enabled. `features` is read
  # defensively: a nixcpu that predates it simply records no flags.
  facts =
    if options ? nixcpu && config.nixcpu.enable then
      {
        inherit (config.nixcpu) arch vendor microarch;
        features = config.nixcpu.features or null;
      }
    else
      null;

  attrOf =
    level:
    k.kernelAttr {
      inherit (cfg) line lto;
      inherit level;
    };
  offered = level: level != "generic" && cfg.source ? ${attrOf level};
  selected = k.select {
    inherit facts offered;
    inherit (cfg) preference;
  };

  level = cfg.level;
  cachyos = level != "generic";
  # A CachyOS level whose package set exists; the assertions refuse every other CachyOS level.
  active = cachyos && offered level;
  need = k.levels.${level};
  lacking = k.missing facts level;
  offeredLines = lib.filter (lib.hasPrefix "linuxPackages-cachyos-${cfg.line}") (
    lib.attrNames cfg.source
  );

  # The check the unit runs. It takes the path of a cpuinfo file as its argument (default
  # /proc/cpuinfo), so the flake checks run the very same script against fixtures. Every processor
  # must satisfy the level.
  cpuCheck = pkgs.writeShellApplication {
    name = "nixkernel-verify";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
    ];
    text = ''
      cpuinfo=''${1:-/proc/cpuinfo}
      level=${lib.escapeShellArg level}
      need_vendor=${lib.escapeShellArg (if need ? vendor then k.cpuinfoVendor.${need.vendor} else "")}
      need_flags=${lib.escapeShellArg (lib.concatStringsSep " " need.flags)}

      lacking=$(awk -v need_vendor="$need_vendor" -v need_flags="$need_flags" '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        function value() { return trim(substr($0, index($0, ":") + 1)) }
        function finish(   out, i) {
          if (cpu == "") return
          out = ""
          if (need_vendor != "" && vendor != need_vendor) out = out " vendor=" vendor "(need " need_vendor ")"
          n = split(need_flags, want, " ")
          for (i = 1; i <= n; i++) if (!(want[i] in have)) out = out " " want[i]
          if (out != "") { if (!(out in count)) order[++kinds] = out; if (!(out in first)) first[out] = cpu; count[out]++ }
          cpu = ""
        }
        /^processor[ \t]*:/ { finish(); cpu = value(); seen++; vendor = ""; delete have; next }
        /^vendor_id[ \t]*:/ { vendor = value(); next }
        /^flags[ \t]*:/ { m = split(value(), fl, " "); for (i = 1; i <= m; i++) have[fl[i]] = 1; next }
        END {
          finish()
          if (seen == 0) print "no processor in the cpuinfo"
          for (i = 1; i <= kinds; i++) print count[order[i]] " of " seen " processors (first: " first[order[i]] ") lack:" order[i]
        }
      ' "$cpuinfo")

      if [ -n "$lacking" ]; then
        {
          echo "nixkernel-verify: FAIL: the CPU cannot run the kernel level $level of this system:"
          echo "$lacking"
          echo "nixkernel-verify: the host may have been moved to an older CPU. Boot the entry '${cfg.fallback.name}' of the boot menu, then correct the CPU facts (nixcpu) and the level."
        } >&2
        exit 1
      fi
      echo "nixkernel-verify: PASS: every processor satisfies the kernel level $level (running $(uname -r), configured ${config.boot.kernelPackages.kernel.version})"
    '';
  };
in
{
  options.nixkernel = {
    enable = mkEnableOption "the CachyOS kernel at the CPU level the host can run";

    source = mkOption {
      type = types.attrs;
      default = pkgs.cachyosKernels or { };
      defaultText = literalExpression "pkgs.cachyosKernels or { }";
      example = literalExpression "inputs.nix-cachyos-kernel.legacyPackages.\${pkgs.stdenv.hostPlatform.system}";
      description = ''
        The kernel package sets of the source (xddxdd/nix-cachyos-kernel, `release` branch):
        attributes `linuxPackages-cachyos-<line>[-lto][-<level>]`. The default reads them from
        `pkgs.cachyosKernels`, which the source's `overlays.pinned` adds; a consumer that does not
        apply the overlay passes the source's `legacyPackages.<system>` here. Do not make the
        source's nixpkgs follow yours: the binary cache holds the kernels only for its own pin.
      '';
    };

    line = mkOption {
      type = types.nonEmptyStr;
      default = "latest";
      example = "lts";
      description = ''
        The CachyOS kernel line (`latest`, `lts`, `bore`, `server`, `hardened`, ... as the source
        names them). A line/level combination the source does not offer is refused at evaluation:
        it would compile the kernel on the build host for hours.
      '';
    };

    lto = mkOption {
      type = types.bool;
      default = true;
      description = "The ThinLTO build of the kernel (the `-lto` package sets).";
    };

    preference = mkOption {
      type = types.listOf (types.enum levelNames);
      default = [
        "znver5"
        "zen4"
        "x86_64-v4"
        "x86_64-v3"
      ];
      description = ''
        Levels in order of preference. The first one that the declared CPU can run and that the
        source offers wins; `generic` (no CachyOS kernel) when none does. A level the source does not
        offer yet is skipped, so the lock bump that brings it adopts it. `x86_64-v2` is not in the
        default because the source publishes it without a binary cache.
      '';
    };

    level = mkOption {
      type = types.enum levelNames;
      default = selected;
      defaultText = lib.literalMD "the first level of `preference` that the CPU can run and the source offers";
      example = "x86_64-v3";
      description = ''
        The level this system runs: `generic` (the configuration's own kernel, nixpkgs' default),
        `x86_64-v1` to `x86_64-v4` (the CachyOS builds for the x86-64 psABI levels; `x86_64-v1` is
        the untuned build every x86-64 CPU runs), or the tuned `zen4`/`znver5`. Set it only to force
        one: the evaluation refuses a level the declared CPU cannot run.
      '';
    };

    fallback = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Keep a boot entry on the generic kernel and its stock ZFS in every generation (a
          specialisation of the same system). It costs one more kernel and initrd per generation on
          the boot partition; how many generations stay there is the boot loader's setting
          (nixboot's `generations.keep`).
        '';
      };
      name = mkOption {
        type = types.strMatching "[A-Za-z0-9_-]+";
        default = "generic-kernel";
        description = "The name of the fallback specialisation, which is also its label in the boot menu.";
      };
    };

    verify.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        The oneshot unit `nixkernel-verify`: after boot it reads /proc/cpuinfo and fails when any
        processor lacks what the level needs. A deploy health gate should require it to be active.
      '';
    };

    cache = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Declare the source's binary cache (`extra-substituters`, `extra-trusted-public-keys`), so
          the host fetches the kernel instead of compiling it. The source's own `nixConfig` is not
          applied to a flake input, hence this.
        '';
      };
      substituter = mkOption {
        type = types.str;
        default = "https://attic.xuyh0120.win/lantian";
        description = "The binary cache of the kernel source.";
      };
      publicKey = mkOption {
        type = types.str;
        default = "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc=";
        description = "The signing key of that cache.";
      };
    };

    zfs.cachyos = mkOption {
      type = types.bool;
      default = true;
      description = ''
        At CachyOS levels, use the source's matching ZFS (`zfs_cachyos`, which follows kernels newer
        than upstream OpenZFS supports). With `false` the ZFS package stays nixpkgs' own, which then
        requires a kernel line under the OpenZFS kernel cap (for example `lts`).
      '';
    };

    floors = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            version = mkOption {
              type = types.str;
              example = "6.12";
              description = "The lowest kernel version that satisfies the requirement.";
            };
            reason = mkOption {
              type = types.str;
              description = "Who needs the floor and why, for the assertion message.";
            };
          };
        }
      );
      default = { };
      example = literalExpression ''
        {
          f2fs-compression = {
            version = "6.12";
            reason = "f2fs compression release/reserve accounting (nixfs catalogue)";
          };
        }
      '';
      description = ''
        Minimum kernel versions supplied by other domains (a filesystem feature, a driver). The
        kernel the system boots, including the one of the fallback entry, must satisfy every floor.
      '';
    };

    transparentHugepage = mkOption {
      type = types.nullOr (
        types.enum [
          "always"
          "madvise"
          "never"
        ]
      );
      default = "madvise";
      description = ''
        `transparent_hugepage=` on the kernel command line at CachyOS levels. CachyOS builds with
        `always`; the generic kernel's default, and PostgreSQL's guidance, is `madvise`, and one value
        on every level keeps THP out of a comparison between kernels. `null` keeps the build's default.
      '';
    };

    initrdAesni = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Add `aesni_intel` to the initrd at CachyOS levels. The 7.x kernels' initrd does not pull it in
        through `aes` (the 6.18 one does); without it a LUKS root is opened with the generic AES code.
      '';
    };

    cpuCheck = mkOption {
      type = types.package;
      readOnly = true;
      internal = true;
      default = cpuCheck;
      description = "The script of the unit nixkernel-verify, exposed for the flake checks.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lacking == [ ];
        message = ''
          nixkernel: the level `${level}` cannot run on this host: its declared CPU lacks ${lib.concatStringsSep ", " lacking}.
          A kernel built for a level the CPU does not have does not boot. Take a lower level (nixkernel.preference
          does it by itself when nixkernel.level is not forced), or declare the CPU again in nixcpu if the host changed.
        '';
      }
      {
        assertion = !cachyos || offered level;
        message = ''
          nixkernel: the kernel source does not offer `${attrOf level}`; a package missing from its binary cache would
          compile on the build host for hours. It offers for line `${cfg.line}`: ${
            if offeredLines == [ ] then "nothing" else lib.concatStringsSep ", " offeredLines
          }. Change nixkernel.line, nixkernel.lto or nixkernel.level.
        '';
      }
    ]
    ++ lib.mapAttrsToList (name: floor: {
      assertion = lib.versionAtLeast config.boot.kernelPackages.kernel.version floor.version;
      message = ''
        nixkernel: the kernel ${config.boot.kernelPackages.kernel.version} (level ${level}, line ${cfg.line}) is below the
        floor `${name}` = ${floor.version}: ${floor.reason}. Pick a newer nixkernel.line or level, or drop the requirement.
      '';
    }) cfg.floors;

    # Selecting the generic kernel by default is never an error, but it is never silent either: a
    # missing nixcpu, or a line the source does not offer (a typo), would otherwise go unnoticed.
    warnings =
      lib.optional
        (level == "generic" && !(options.nixkernel.level.highestPrio < 1500) && cfg.preference != [ ])
        (
          if facts == null then
            ''
              nixkernel: no CPU facts are declared (nixcpu), so this host gets the generic kernel. Compose nixcpu and declare
              nixcpu.microarch (and nixcpu.features for the tuned levels), or force nixkernel.level = "x86_64-v1".
            ''
          else
            ''
              nixkernel: no level of nixkernel.preference is both runnable on the declared CPU and offered by the source for
              line `${cfg.line}`, so this host gets the generic kernel. The source offers: ${
                if offeredLines == [ ] then "nothing for this line" else lib.concatStringsSep ", " offeredLines
              }.
            ''
        );

    # A level the source does not offer leaves the kernel alone; the assertion above refuses it with
    # the list of what the source does offer (a throw here would pre-empt that message).
    boot.kernelPackages = mkIf active cfg.source.${attrOf level};
    # The matching CachyOS ZFS; at `generic` the kernel and ZFS stay as nixpkgs has them.
    boot.zfs.package = mkIf (active && cfg.zfs.cachyos) config.boot.kernelPackages.zfs_cachyos;

    # The kernel is PREEMPT_DYNAMIC (full by default, HZ=1000): `preempt=none|voluntary|full|lazy` on
    # the command line, or /sys/kernel/debug/sched/preempt at run time, changes the preemption model
    # without another kernel. Only THP is set here.
    boot.kernelParams = mkIf (cachyos && cfg.transparentHugepage != null) [
      "transparent_hugepage=${cfg.transparentHugepage}"
    ];
    boot.initrd.availableKernelModules = mkIf (cachyos && cfg.initrdAesni) [ "aesni_intel" ];

    # Builds happen on the deploying host, which needs the key anyway; the host needs it to accept the
    # paths and to fetch them itself if it ever has to.
    nix.settings = mkIf cfg.cache.enable {
      extra-substituters = [ cfg.cache.substituter ];
      extra-trusted-public-keys = [ cfg.cache.publicKey ];
    };

    # Guard 3, in the shape of nixboot-verify: a oneshot after boot whose failure is the signal.
    systemd.services.nixkernel-verify = mkIf cfg.verify.enable {
      description = "nixkernel: the CPU can run the selected kernel level (${level})";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe cpuCheck;
      };
    };

    # Guard 2: the entry stays in every generation. It is the same system on the generic kernel.
    specialisation = mkIf cfg.fallback.enable {
      ${cfg.fallback.name}.configuration.nixkernel.level = lib.mkForce "generic";
    };
  };
}
