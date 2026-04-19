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

  readPackageManifest = name:
    let path = manifestDir + "/${name}.json";
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
in
{
  packages = builtins.listToAttrs (map
    (system: { name = system; value = mkPackageSet system; })
    systems);

  inherit lookupAttr importNixpkgs readPackageManifest;
}
