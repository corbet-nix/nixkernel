# nixkernel — design

How nixkernel chooses a kernel, why each default is what it is, and what it leaves to other domains.
The option surface is in [`../modules/nixkernel.nix`](../modules/nixkernel.nix), the level catalogue
in [`../lib/levels.nix`](../lib/levels.nix).

## 1. The kernel source

The CachyOS kernel, packaged for Nix by
[xddxdd/nix-cachyos-kernel](https://github.com/xddxdd/nix-cachyos-kernel). It is the maintained
CachyOS patchset and configuration, not a re-derivation, and the maintainer publishes pre-built
variants to a binary cache (its URL and signing key are the consumer's to declare, see below).

- Use the **`release` branch**: it carries the variants the maintainer's CI has built.
- Do **not** make the source's nixpkgs follow yours. The kernel derivation depends on it, and the
  cache holds the kernels only for the source's own pin; following would turn every kernel into a
  local build.
- Hand the package sets to nixkernel either as `nixkernel.source = <input>.legacyPackages.<system>`
  or by applying `<input>.overlays.pinned`, which adds `pkgs.cachyosKernels` (the default of
  `source`). Both name the same attributes, `linuxPackages-cachyos-<line>[-lto][-<level>]`.
- A kernel bump is a lock bump of that input, which lands the next cached revision.

The source's `nixConfig` declares its cache, but nothing applies a flake input's `nixConfig`, so
nixkernel declares it (`cache.*`) as `extra-substituters`/`extra-trusted-public-keys`: the
`extra-` form survives a host that sets its own substituter list with `mkForce`.

**The module has no default for the cache URL and key.** A signing key a host trusts is that host's
decision. The maintainer's cache was compromised on 2026-10-15
([xddxdd/nix-cachyos-kernel#110](https://github.com/xddxdd/nix-cachyos-kernel/issues/110)); a
module default naming it kept every host that never set the option trusting a key whose holder could
sign arbitrary store paths. The replacement pair, announced by the maintainer on 2026-10-24, is the
`nixConfig` of the source's `release` branch; a consumer copies it into one place of its own
configuration and checks it against that announcement before trusting it. With `cache.enable` true
(the default) and no pair, evaluation is refused with a message that says so, instead of silently
leaving the kernel to compile for hours. The compromised pair itself is refused by an assertion, even
when a host names it explicitly. `cache.enable = false` needs neither.

## 2. Binary cache versus a local compile

Only some combinations of line, LTO and level are published. Selecting one that is missing would
compile the kernel on the build host for hours, which defeats the reason for the source. nixkernel
therefore refuses a forced level the source does not offer (the assertion lists what it does offer
for the line) and skips it in the preference list. The `x86_64-v2` builds are published without a
binary cache upstream, which is why `x86_64-v2` is not in the default preference.

The tuned levels' ZFS modules (`zfs_cachyos` for `-zen4` and others) are not always in the
maintainer's cache: the build host builds them, which takes minutes, not hours.

If you deliberately want an unpublished combination, build it once on a capable machine and push it
to your own substituter, so a reinstall is not a fresh kernel compile.

## 3. Choosing the level

The levels and what each needs are in the README's table. The rules:

1. `generic` and `x86_64-v1` need no facts: every x86-64 CPU runs the baseline, and the source has
   only x86-64 builds.
2. Every higher level needs nixcpu: `nixcpu.arch = "x86_64"` and `nixcpu.microarch` at or above the
   level's psABI level. When `nixcpu.features` is recorded, the level's flags must all be in it.
3. The tuned levels (`zen4`, `znver5`) also need `nixcpu.vendor = "amd"` and the recorded flags,
   because their requirements go beyond what a psABI level can state: `-march=znver4` uses
   AVX-512 VBMI2, BF16, GFNI, VAES and more, which an `x86_64-v4` Intel part may lack. The vendor
   check keeps an Intel CPU that happens to have every flag off the AMD tuning.
4. The declared `microarch` caps the choice: flags recorded beyond it do not raise the level.
5. Flags are compared as the intersection over every processor: a kernel must run on all of them.

The flag lists are `/proc/cpuinfo` names (`pni` is SSE3, `abm` is LZCNT), the names nixos-facter
records, so one list serves the evaluation (against `nixcpu.features`) and the post-boot unit
(against the live `/proc/cpuinfo`).

Selection falls back to `generic` when nothing in `preference` is runnable and offered. That is
never an error and never silent: a warning says whether the CPU facts are missing or the line offers
nothing usable (a typo in `line` lands here).

## 4. The three guards

**Refusal at evaluation.** One assertion: the selected level's requirements against the declared
CPU, with every missing item named. It applies to a forced level as much as to a chosen one, which is
the point: a level copied from another host's configuration is caught before anything is built.

**The fallback entry.** `specialisation.<fallback.name>` is the same system with
`nixkernel.level = "generic"`: nixpkgs' kernel, its stock ZFS, none of the CachyOS-level
adjustments. The boot loader lists it under every generation, so it survives as long as the
generation does. It costs one more kernel and initrd per generation on the boot partition; the
number of generations kept there is the boot loader's setting (nixboot's `generations.keep`), sized
for two kernels each. With ZFS, do not run `zpool upgrade` while the fallback entry might still need
to import the pool with the stock ZFS.

**`nixkernel-verify`.** A oneshot unit after boot, in the shape of nixboot's `nixboot-verify`: it
reads `/proc/cpuinfo` and exits non-zero, printing `FAIL` and the missing flags per kind of
processor, when the CPU cannot run the level. A deploy's health gate should require it to be active.
It never reboots or changes anything. The script takes the cpuinfo path as its argument, so the
flake checks run the exact script the system ships against fixtures.

## 5. CachyOS-level adjustments

Applied only at CachyOS levels; the fallback entry has none of them.

| Option | Default | Why |
|---|---|---|
| `transparentHugepage` | `null` | Transparent hugepages belong to nixram (`nixram.thp`: every switch per RAM level, boot and run time), which refuses a THP parameter it did not render. Set only on a host without nixram. |
| `initrdAesni` | `true` | The 7.x kernels' initrd does not pull `aesni_intel` in through `aes` (the 6.18 one does); without it a LUKS root is opened with the generic AES code. Observed on the 7.2 line; not re-checked for every release. |
| `zfs.cachyos` | `true` | `zfs_cachyos` follows kernels newer than upstream OpenZFS supports; with `false` the line must stay under the OpenZFS kernel cap (`lts`). |

The kernel is `PREEMPT_DYNAMIC` (full preemption by default, `HZ=1000`): `preempt=none|voluntary|full|lazy`
on the command line, or `/sys/kernel/debug/sched/preempt` at run time, changes the preemption model
without another kernel. nixkernel sets no preemption or scheduler parameter.

## 6. Floors

Other domains know which kernel version their features need; nixkernel knows which kernel is
selected. `nixkernel.floors.<name> = { version; reason; }` joins the two: the selected kernel, and the
fallback entry's, must be at least `version`, or evaluation fails with `reason`. Example: the f2fs
compression release/reserve accounting needs a minimum kernel, a fact nixfs owns; a host that formats
f2fs with that recipe supplies it as a floor.

## 7. Boundaries

| Concern | Owner |
|---|---|
| Which kernel package, CPU level, LTO; its ZFS pairing; the source's cache; floors enforced | nixkernel |
| CPU facts (vendor, psABI level, recorded flags, topology) | nixcpu |
| Boot loader, entries, generations kept, Secure Boot, `nixboot-verify` | nixboot |
| zswap/zram parameters | nixram |
| Network sysctls | nixnet |
| Filesystem facts, including the kernel floors they need | nixfs |
| Provider-specific modules and command-line parameters of a guest (virtio drivers, haltpoll) | the host's provider layer |
