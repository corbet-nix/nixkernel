# nixkernel

**The kernel a NixOS host boots, chosen at the CPU level the host can run: the CachyOS kernel and
its matching ZFS from [xddxdd/nix-cachyos-kernel](https://github.com/xddxdd/nix-cachyos-kernel),
refused at evaluation when the declared CPU cannot run it, with a fallback boot entry in every
generation and a post-boot check of the live CPU.**

## Why this exists

A kernel built with `-march=x86-64-v3` or `-march=znver4` does not run slower on a CPU that lacks
the instructions: it faults in early boot, before any handler exists, and the machine does not come
back. That requirement lives in the tail of a package name (`linuxPackages-cachyos-latest-lto-zen4`),
which nothing checks against the CPU it is about to run on. A virtual machine adds a second failure:
the provider can move it to an older host after it was deployed.

nixkernel closes both with three guards:

| Guard | When | What |
|---|---|---|
| 1. Refusal | evaluation | A level the declared CPU cannot run is an assertion failure that names the missing flags, however the level was chosen. |
| 2. Fallback entry | every boot | A specialisation `generic-kernel` (the same system on nixpkgs' kernel and its stock ZFS) stays in every generation's boot menu. |
| 3. `nixkernel-verify` | after boot | A oneshot unit reads `/proc/cpuinfo` and **fails**, naming the missing flags, when any processor lacks what the level needs. A deploy health gate requires it to be active. |

## Where the facts come from

nixkernel couples to its neighbours by option value, never by flake input:

| Fact | Owner | Read as |
|---|---|---|
| CPU architecture, vendor, psABI level, recorded flags | [nixcpu](https://git.corbet.ch/corbet-nix/nixcpu-corbet-ch) | `config.nixcpu.{arch,vendor,microarch,features}`; without nixcpu only `generic` and `x86_64-v1` are allowed |
| Boot loader, its entries, how many generations stay on the boot partition | [nixboot](https://git.corbet.ch/corbet-nix/nixboot-corbet-ch) | nothing is written there: the fallback is a specialisation the loader lists by itself, and it doubles the kernels per generation, so size `nixboot.generations.keep` for two |
| Minimum kernel versions (a filesystem feature, a driver) | the domain that needs them, e.g. nixfs's f2fs floor | `nixkernel.floors.<name> = { version; reason; }`, enforced here |
| The kernel source and its pin | the consumer's flake input | `nixkernel.source`, or the source's overlay (`pkgs.cachyosKernels`) |

## Levels

| Level | Package-set suffix | Needs |
|---|---|---|
| `generic` | none: nixpkgs' kernel, stock ZFS | nothing |
| `x86_64-v1` | (none) | an x86-64 CPU |
| `x86_64-v2` .. `x86_64-v4` | `-x86_64-vN` | `nixcpu.microarch` at that level; recorded flags, when present, must have it too |
| `zen4` | `-zen4` | AMD, `x86_64-v4`, and the recorded `-march=znver4` flags (AVX-512 VBMI2/BF16, GFNI, VAES, ...) |
| `znver5` | `-znver5` | as `zen4` plus the Zen 5 flags; the source does not publish it yet |

`nixkernel.level` defaults to the first entry of `nixkernel.preference`
(`znver5`, `zen4`, `x86_64-v4`, `x86_64-v3`) that the declared CPU runs and the source offers, and to
`generic` when none does (with a warning that says why). A level the source does not offer yet is
skipped, so the lock bump that brings it adopts it. Forcing a level is allowed; the refusal still
applies. The flag lists are `/proc/cpuinfo` names in [`lib/levels.nix`](lib/levels.nix), shared by
the evaluation and the post-boot unit so the two cannot disagree.

## Usage

```nix
{
  inputs = {
    nixkernel.url = "git+https://git.corbet.ch/corbet-nix/nixkernel.git?allRefs=1";
    nixkernel.inputs.nixpkgs.follows = "nixpkgs";
    nixcpu.url = "git+https://git.corbet.ch/corbet-nix/nixcpu-corbet-ch.git?allRefs=1";
    # The kernel source. Its nixpkgs must NOT follow yours: the binary cache holds the kernels
    # only for the source's own pin.
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";
  };

  outputs = { nixpkgs, nixkernel, nixcpu, nix-cachyos-kernel, ... }: {
    nixosConfigurations.example = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixcpu.nixosModules.nixcpu
        nixkernel.nixosModules.nixkernel
        ({ pkgs, ... }: {
          nixcpu = {
            enable = true;
            arch = "x86_64";
            vendor = "amd";
            microarch = "x86_64-v3"; # a Zen 3 CPU
            cores = 8;
            threads = 16;
          };
          nixkernel = {
            enable = true;
            source = nix-cachyos-kernel.legacyPackages.${pkgs.stdenv.hostPlatform.system};
          };
        })
      ];
    };
  };
}
```

This host gets `linuxPackages-cachyos-latest-lto-x86_64-v3` with `zfs_cachyos`, the fallback entry,
`nixkernel-verify`, `aesni_intel` in the initrd and the source's cache.
Forcing `nixkernel.level = "zen4"` on it fails evaluation, naming what the declared CPU lacks.

## Options

| Option | Default | |
|---|---|---|
| `enable` | `false` | |
| `source` | `pkgs.cachyosKernels or { }` | the source's package sets |
| `line` | `"latest"` | the CachyOS line (`latest`, `lts`, `bore`, ...) |
| `lto` | `true` | the `-lto` builds |
| `preference` | `znver5 zen4 x86_64-v4 x86_64-v3` | see Levels |
| `level` | from `preference` | force one; refused if the CPU cannot run it |
| `fallback.{enable,name}` | `true`, `"generic-kernel"` | guard 2 |
| `verify.enable` | `true` | guard 3 |
| `cache.{enable,substituter,publicKey}` | `true`, the source's cache | `extra-substituters`/`extra-trusted-public-keys` |
| `zfs.cachyos` | `true` | `zfs_cachyos` at CachyOS levels; `false` keeps nixpkgs' ZFS (needs a line under the OpenZFS cap) |
| `floors` | `{ }` | kernel versions other domains require |
| `transparentHugepage` | `null` | THP belongs to nixram (`nixram.thp`); set only on a host without nixram |
| `initrdAesni` | `true` | `aesni_intel` in the initrd at CachyOS levels |

Every option is documented in [`modules/nixkernel.nix`](modules/nixkernel.nix); the design and the
reasoning behind each default are in [`docs/index.md`](docs/index.md).

## Non-goals

- No kernel is built here, and a combination the source does not publish is refused rather than
  compiled: a from-source kernel on the build host takes hours.
- No CPU facts are probed at evaluation. nixcpu states them; nixkernel only compares.
- No scheduler, preemption or power tuning. The CachyOS kernel is `PREEMPT_DYNAMIC`, so
  `preempt=` on the command line changes the model without another kernel; nixkernel does not set it.
- No memory (nixram), network (nixnet) or filesystem (nixfs) parameters, even on the kernel command
  line: each belongs to its domain.

## Status

Experimental. Measured: `nix flake check` passes on `x86_64-linux` (eval tests of the level choice
and of the module in both directions, the post-boot script against cpuinfo look-alikes, formatting);
moving two production configurations onto it left one system store path identical and changed only
the post-boot unit's name and messages in the other. Not measured here: the
performance difference between levels, and whether the 7.x initrd still lacks `aesni_intel`. Open
questions are in [`experiments/README.md`](experiments/README.md).

## Licence

Outbound licence is `MIT OR Apache-2.0`. See `LICENSE-MIT` and `LICENSE-APACHE`; every source file
carries `SPDX-License-Identifier: MIT OR Apache-2.0`.
