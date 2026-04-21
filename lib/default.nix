{ manifestDir }:

let
  splitAttrPath = path:
    let m = builtins.match "([^.]+)\\.(.*)" path;
    in if m == null
       then [ path ]
       else [ (builtins.elemAt m 0) ] ++ splitAttrPath (builtins.elemAt m 1);

  lookupAttr = set: path:
    builtins.foldl'
      (acc: p: if acc == null then null else acc.${p} or null)
      set
      (splitAttrPath path);

  importNixpkgs = system: { rev, sha256, ... }:
    import (builtins.fetchTarball {
      url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
      inherit sha256;
    }) { inherit system; config = {}; overlays = []; };

  # Mirrors scripts/export-manifest.py: first two hex chars of
  # sha256(name) as a uniform-distribution shard key. Nix's
  # hashString over UTF-8 bytes matches hashlib.sha256, so the same
  # name always resolves to the same shard on both sides.
  shardFor = name: builtins.substring 0 2 (builtins.hashString "sha256" name);

  readPackageManifest = name:
    let path = manifestDir + "/${shardFor name}/${name}.json";
    in if builtins.pathExists path
       then builtins.fromJSON (builtins.readFile path)
       else throw "nix-package-versions: no manifest for package '${name}'";

  packageNames = builtins.fromJSON (builtins.readFile (manifestDir + "/index.json"));

  # For a given (system, name) return an attrset keyed by version whose
  # values are the actual derivations. Each version entry only triggers
  # its nixpkgs fetch when accessed (Nix evaluates attrset values lazily).
  mkVersions = system: name:
    builtins.mapAttrs
      (_version: entry: lookupAttr (importNixpkgs system entry) entry.attr)
      (readPackageManifest name);

  # Top-level name set. Enumerating `attrNames` here forces the index
  # but not any per-package manifest, so listing available packages is
  # cheap relative to actually resolving a version.
  mkPackageSet = system:
    builtins.listToAttrs (map
      (name: { inherit name; value = mkVersions system name; })
      packageNames);

  systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

  # Merge per-version derivations onto matching top-level attrs in `prev`
  # so consumers can write `pkgs.<name>."<version>"`. We skip names that
  # are absent from nixpkgs: several manifest entries (e.g. `static`,
  # `stdenv`) collide with callPackage default-argument names, and adding
  # them at the top level breaks auto-argument resolution for unrelated
  # packages. Values stay lazy — mapAttrs does not force versions, and
  # mkVersions only reads a package manifest when its attr is accessed.
  overlay = final: prev:
    let
      systemPkgs = mkPackageSet prev.stdenv.hostPlatform.system;
      # Force-checking each candidate eagerly triggers nixpkgs alias
      # evaluation (aliases.nix uses `with self; ...`) and blows up with
      # an infinite recursion. The cheap `?` check keeps the filter lazy;
      # the isAttrs guard inside the merge handles non-attrset values
      # (null, false, functions) if they are ever actually accessed.
      # Only merge when the existing attr is a derivation. Non-derivation
      # attrsets (lib, stdenv, pythonPackages, …), functions (runCommand,
      # fetchurl, …), and null aliases are returned unchanged so that
      # stdenv bootstrap and callPackage auto-arguments keep working.
      merge = name: versions:
        let base = prev.${name};
        in if builtins.isAttrs base && (base.type or null) == "derivation"
           then base // versions
           else base;
    in
    builtins.mapAttrs merge
      (prev.lib.filterAttrs (name: _: prev ? ${name}) systemPkgs);
in
{
  packages = builtins.listToAttrs (map
    (system: { name = system; value = mkPackageSet system; })
    systems);

  overlays.default = overlay;

  inherit lookupAttr importNixpkgs readPackageManifest;
}
