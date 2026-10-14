# SPDX-License-Identifier: MIT OR Apache-2.0
# checks/unit.nix -- the post-boot unit's script, built exactly as the module builds it for a zen4
# host, run against /proc/cpuinfo look-alikes: the declared CPU passes; a CPU of which one processor
# lacks one flag fails with that flag named, and so do another vendor and an empty file. The generic
# level (the fallback entry) passes on any processor.
{
  pkgs,
  lib,
  fixtures,
}:
let
  inherit (fixtures) k eval zen5;
  onZen5 = eval zen5;
  script = lib.getExe onZen5.nixkernel.cpuCheck;
  generic = lib.getExe onZen5.specialisation.generic-kernel.configuration.nixkernel.cpuCheck;
  need = k.levels.zen4.flags;
  cpu = vendor: features: { inherit vendor features; };
  amd = cpu k.cpuinfoVendor.amd;
  file = name: cpus: pkgs.writeText "cpuinfo-${name}" (k.cpuinfoOf cpus);
  lacking = lib.last need;
  refuses = label: cpus: pattern: ''
    if ${script} ${file label cpus} 2> err; then echo "${label} was accepted" >&2; exit 1; fi
    grep -qF ${lib.escapeShellArg pattern} err || { echo "${label}: the message does not say '${pattern}':" >&2; cat err >&2; exit 1; }
  '';
in
pkgs.runCommand "nixkernel-verify-unit" { } ''
  ${script} ${file "recorded" (lib.replicate 4 (amd ([ "fpu" ] ++ need)))} > /dev/null
  ${refuses "second" [
    (amd need)
    (amd (lib.remove lacking need))
  ] "1 of 2 processors (first: 1) lack: ${lacking}"}
  ${refuses "empty" [ ] "no processor in the cpuinfo"}
  ${refuses "intel" [ (cpu k.cpuinfoVendor.intel need) ] "vendor=GenuineIntel(need AuthenticAMD)"}
  ${generic} ${file "old" [ (cpu k.cpuinfoVendor.intel [ "fpu" ]) ]} > /dev/null
  touch $out
''
