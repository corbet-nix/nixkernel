# SPDX-License-Identifier: MIT OR Apache-2.0
# checks/default.nix
#
# Three checks, each proving its claims in both directions (a check that cannot fail is worthless):
#
#   eval-tests  lib/levels.nix as plain functions (levels.nix) and the module through nixpkgs'
#               eval-config (module.nix): what it selects, renders and refuses. Evaluation only.
#   verify-unit the post-boot script as the module builds it, run against cpuinfo look-alikes
#               (unit.nix). Builds one small shell script; no kernel is built or downloaded.
#   format      nixfmt leaves every .nix file unchanged.
{
  pkgs,
  lib,
  nixpkgs,
  system,
  nixkernelModule,
}:
let
  fixtures = import ./fixtures.nix {
    inherit
      pkgs
      lib
      nixpkgs
      system
      nixkernelModule
      ;
  };

  results =
    import ./levels.nix { inherit lib fixtures; } ++ import ./module.nix { inherit lib fixtures; };
  failed = lib.filter (r: !r.ok) results;
  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;
in
{
  eval-tests =
    if failed == [ ] then
      pkgs.runCommand "nixkernel-eval-tests" { } ''
        echo "${toString (lib.length results)} eval tests passed" > $out
      ''
    else
      throw "nixkernel eval tests failed:\n${report}";

  verify-unit = import ./unit.nix { inherit pkgs lib fixtures; };

  format = pkgs.runCommand "nixkernel-format" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
    cd ${../.}
    find . -name '*.nix' -print0 | xargs -0 nixfmt --check
    touch $out
  '';
}
