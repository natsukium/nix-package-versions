{ manifestDir ? ./manifest }:

let
  lib = import ./lib { inherit manifestDir; };
in
{
  inherit (lib) packages;
}
