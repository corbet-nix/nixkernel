# Open questions

Defaults that are reasoned but not measured, and what would settle each.

## 001 — the tuned levels against `x86_64-v4`

The default preference puts `zen4` before `x86_64-v4` on the reasoning that `-march=znver4` builds
use instructions and scheduling a generic `x86-64-v4` build does not. No comparison has been run
here. Worth measuring on one Zen 4 or Zen 5 host: a kernel-heavy workload (network forwarding with
encryption, ZFS compression, PostgreSQL commits) on both builds of the same line and release, THP and
command line equal.

## 002 — `znver5`

The level is in the catalogue and the default preference so that the lock bump which publishes it
adopts it. The source does not publish it yet, and the suffix `-znver5` is the expected name, not an
observed one. When the source publishes a Zen 5 build, check its suffix against `lib/levels.nix`.

## 003 — `aesni_intel` in the initrd

Observed on the 7.2 line: the initrd does not pull `aesni_intel` in through `aes`, so a LUKS root is
opened with the generic AES code. Worth re-checking on each new line: `cryptsetup benchmark` and
`/proc/crypto` in the initrd with and without the module; drop the default once the kernel pulls it in
by itself.

## 004 — THP `madvise`

The default follows the generic kernel and PostgreSQL's guidance rather than CachyOS's `always`. No
measurement of `always` against `madvise` on these kernels has been made.
