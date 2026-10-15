# nix-hug v5 uses builtins.fetchurl for LFS payloads, buffering huge models in
# the evaluator. Keep its metadata/filtering logic but fetch payloads in builders.
{ pkgs, nix-hug }:
let
  source = builtins.readFile "${nix-hug}/lib/default.nix";
  needle = "drv = fetchurl {";
in
assert builtins.length (pkgs.lib.splitString needle source) == 3;
import
  (builtins.toFile "nix-hug-streaming.nix" (
    pkgs.lib.replaceStrings [ needle ] [ "drv = pkgs.fetchurl {" ] source
  ))
  { inherit pkgs; }
