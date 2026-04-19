# Remote manifest distribution

## Motivation

The consumer-facing `packages.<system>.<name>.<version>` API relies on
per-package manifest files (`manifest/<name>.json`) that carry the
`{ rev, sha256, attr }` needed to reconstruct a specific package at a
specific version. The generated manifest set is large (hundreds of
thousands of files, ~1 GB) and grows with every indexing run, so
shipping it inside the flake source itself is not viable:

- A flake input is fetched in full at lock time. Users subscribing to
  a few packages would pay the cost of the entire catalogue.
- Manifest updates would require frequent flake-lock churn in every
  downstream project.

Instead, manifests live on a static host (S3, GitHub Pages, a CDN) and
consumers fetch only the per-package files they need, at eval time,
via `builtins.fetchurl`. Pure evaluation requires each fetch to be
pinned by hash, which is what this document is about.

## Chosen approach: central pinned index (Option A)

Publish two layers on the remote host:

1. A small `index.json` that maps package name → `{ url, sha256 }`.
2. Many per-package `<name>.json` files, each listing that package's
   versions with their `{ rev, sha256, attr }`.

```
s3://example.com/manifest/
├── index.json          # { "python3": { "url": ".../python3.json", "sha256": "sha256-..." }, ... }
├── python3.json
├── nodejs.json
└── …
```

The flake itself carries (or pins via its own flake input) only
`index.json` plus the hash of that index. Everything else is fetched
on demand.

### Flake-side resolution

```nix
# Pseudocode
let
  index = fromJSON (readFile (fetchurl {
    url = "https://example.com/manifest/index.json";
    sha256 = indexHash;          # pinned in-repo or in flake.lock
  }));

  readPackage = name:
    let entry = index.${name} or (throw "unknown package ${name}"); in
    fromJSON (readFile (fetchurl {
      url = entry.url;
      sha256 = entry.sha256;     # from the pinned index
    }));

  mkVersions = system: name:
    mapAttrs (_: e: buildFromEntry system e) (readPackage name);
in
  { packages.${system} = genAttrs (attrNames index) (mkVersions system); }
```

No hash is ever taken on trust — the `index.json` hash pins everything
transitively.

### Update cadence

Regenerating `index.json` requires rehashing every affected
`<name>.json` and recomputing the overall `indexHash`. Downstream
flakes pick up new indexed versions by updating their flake input (or
the hash constant they pin).

Index size scales with the number of packages, not versions. At the
current sample (~232k packages) the raw numbers are roughly:

- per-entry `{ name, url, sha256 }` ≈ 130 B
- `index.json` ≈ 30 MB uncompressed, ~5 MB gzipped

Per-package manifests stay small (`python3.json` is ~12 KB).

## Prior art

The two-layer "small pinned root + lazy per-entry fetches" shape is well
established outside Nix. Nothing in upstream Nix or Nixpkgs solves the
exact problem (per-attribute, hash-pinned, on-demand metadata fetch),
but several adjacent systems inform the design.

- **Guix Data Service** (`data.guix.gnu.org`) is the closest functional
  precedent: a JSON-over-HTTP API that exposes per-package, per-revision
  metadata including derivation paths and NAR sha256s — e.g.
  `GET /revision/<commit>/package/<name>/<version>.json`. It deliberately
  trusts TLS rather than pinning hashes, so its output cannot be used as
  a pure build input. The URL layout convention is worth borrowing; the
  hash-pinning layer is what this design adds on top.

- **Guix `guix pull` / `guix time-machine` / channels** all distribute
  package recipes via full git checkout, not via a remote index. Guix
  avoids the "(package, version) tuple explosion" problem because each
  package is one recipe regardless of upstream version history. That is
  the same shape as Nixpkgs' flake-input model and the reason this
  project needs a different distribution strategy.

- **Debian APT** is the structural template: an `InRelease` file
  (GPG-signed root) lists SHA-256s of every per-component `Packages`
  index, which in turn lists per-`.deb` hashes. The chain of trust
  collapses to one signed root, exactly as Option A's `index.json` does.
  APT's `acquire-by-hash` mode additionally serves indexes at
  `/by-hash/sha256/<hex>` URLs so old roots keep resolving cleanly
  during a publish race — directly relevant to the Option B variant
  below.

- **Cargo sparse index** (`sparse+https://index.crates.io/`) ships
  *no* global index file at all. Per-crate paths are derived from the
  name (`xx/yy/<name>`), and Cargo fetches only what dependency
  resolution touches. Integrity is TLS plus a per-tarball `cksum`
  embedded in the index file. The URL-derivation trick removes any
  "regenerate the whole index on every package update" cost; the
  trust model is not pure-eval-compatible but the layout is.

- **Homebrew 4.0** flipped to a single bundled `formula.jws.json`
  (~31 MB) fetched by every client. It is an active source of user
  complaints ([brew#21622](https://github.com/Homebrew/brew/issues/21622)),
  and a cautionary example: a ~30 MB `index.json` will hit the same
  pushback at scale.

- **npm registry** uses per-package metadata documents
  (`GET /<pkg>` returns all versions of one package, with SRI
  `integrity` per tarball). There is no global index — resolution is
  lazy, per-package. `package-lock.json` carries the SRI hash for
  reproducible installs without re-trusting the registry on relock.

- **PyPI PEP 691 simple index** is a per-project URL
  (`/simple/<name>/`) returning a JSON list of files with `hashes`.
  Same lazy, per-name pattern as npm and Cargo.

The recurring pattern across APT/Cargo/npm/PyPI is *lazy per-name
fetch with hashes verified by the client*. Option A matches this
pattern; the question is whether the global `index.json` is the right
shape for the "root" layer or whether a Cargo-style URL-derivation
removes the need for one.

## Why not the alternatives

- **Content-addressed URLs (`s3://.../sha256-<hash>/python3.json`)**
  removes one sha256 column from `index.json` at the cost of a more
  involved upload step (name-by-hash) and less friendly URLs. APT's
  `acquire-by-hash` mode is the same idea and exists for a concrete
  reason: serving immutable per-hash URLs lets an old pinned root
  keep resolving correctly even while a new publish is in flight, so
  there is no race window in which a downstream evaluation sees an
  index pointing at a per-package file that has already been
  overwritten. Worth revisiting once publish frequency exceeds CDN
  cache TTLs; not a day-one win.

- **Single tarball release on GitHub Releases** keeps the flake input
  model but forces every consumer to download the full catalogue
  (hundreds of MB compressed). Defeats the purpose of going remote.

- **Live API + `--impure`** avoids any hash management but breaks
  pure evaluation, so the resulting packages cannot appear in
  anyone's `flake.nix` outputs without global `--impure`.

## Open questions

- Where does hosting live? S3 bucket owned by the project vs. GitHub
  Pages vs. an existing lazamar-hosted endpoint. Pick one before
  shipping the publishing script.
- Retention: do we ever prune entries whose nixpkgs revision is no
  longer fetchable from GitHub? Probably yes eventually, but a
  read-only best-effort `fetch` is fine for the PoC.

## Decided (informed by prior art)

- **Regeneration cadence**: republish `index.json` on every successful
  indexing run; downstream flakes pick up the new catalogue by bumping
  `indexHash`. This is the APT model (`InRelease` regenerates per dak
  run) translated to a flake-input bump. PDiff-style delta indexes are
  not worth the complexity at this scale — `builtins.fetchurl` is the
  delivery primitive and it operates per-file.

## Future work: shrinking the root

At the current sample (~232k packages) `index.json` is ~30 MB
uncompressed (~5 MB gzipped). Homebrew's experience with a similarly
sized monolithic JSON suggests this will eventually be a complaint
vector. Two reductions are worth tracking, neither of which is
required for the PoC:

- **Derive per-package URL from name** (Cargo sparse-index style:
  `pa/python3.json`). Removes the `url` column from the root entirely;
  the root only has to carry `name -> sha256`. At ~60 B per entry that
  shaves the root roughly in half.
- **Three-layer split**: a tiny `names.json` (just attribute names,
  needed to drive `genAttrs (attrNames index) ...`) plus content-
  addressed per-package URLs (`by-hash/sha256/<hex>/<name>.json`).
  Eliminates the per-update root-rehash step entirely — only `names.json`
  changes when the package set's *membership* changes; per-package
  updates are pure adds in the by-hash space and never invalidate the
  root.

Both are post-PoC optimisations. The two-layer Option A above is the
shape that needs to land first.
