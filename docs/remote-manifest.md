# Manifest distribution

## Motivation

The consumer-facing `packages.<system>.<name>.<version>` API relies on
per-package manifest files (`manifest/<name>.json`) that carry the
`{ rev, sha256, attr }` needed to reconstruct a specific package at a
specific version. Early assumptions put the manifest set in the
"hundreds of MB, grows with every run" bucket, which ruled out
shipping it inside the flake source. Actual measurement against the
first full 2014-present index proves that assumption wrong.

Measured sizes at 367 indexed commits / ~1.12M unique
`(name, version)` pairs:

| artifact                                 | size    |
|------------------------------------------|---------|
| 290,438 per-package JSON files           | 204 MB  |
| tar of the tree (with headers)           | 663 MB  |
| **gzipped tarball (what GitHub serves)** | **36 MB** |

A `nix flake update` pulling this repo downloads ~36 MB — smaller
than a typical nixpkgs pin (~50 MB). That is cheap enough that the
whole catalogue can live directly in this repository, and the
complexity of a remote manifest host goes away entirely.

## Chosen approach: bundle all manifests in the repo

The repo contains:

```
├── flake.nix
├── manifest/
│   ├── index.json          # sorted array of package names
│   ├── 00/                 # shard: first 2 hex chars of sha256(name)
│   │   └── …
│   ├── c1/
│   │   ├── python3.json    # { "3.14.3": { rev, sha256, attr }, ... }
│   │   └── …
│   └── …                   # 256 shard dirs × ~1100 files each
└── scripts/export-manifest.py
```

Each successful indexing run regenerates `manifest/` from the SQLite
DB and commits the result. Downstream flakes pick up the new
catalogue via ordinary `nix flake update` on the npv input. A
consumer pinned to an older npv commit reads the manifest tree at
that commit; no external resource can go stale.

### Why sharding (and why hash-based)

A flat 290k-file directory renders unusable in GitHub's web browser
and slows local tooling. Splitting files across subdirectories
solves both. But **prefix-based** sharding fails badly here: Python
and Perl packages alone (pnames like `python2.7-*`, `python3-*`,
`perl5.XX-*`) would pile ~75k files into a single shard. The name
distribution is too skewed for any short prefix to balance.

**Hash-based** sharding — first two hex chars of `sha256(name)` —
makes the distribution uniform: 256 shards × ~1100 files each, with
no shard ever more than a few percent above average regardless of
name patterns. Nix's `builtins.hashString "sha256"` produces the
same bytes as Python's `hashlib.sha256`, so the export script and
the flake-side resolver land on the same shard for any given name.

### Flake-side resolution

```nix
# Pseudocode
let
  index = fromJSON (readFile ./manifest/index.json);

  shardFor = name:
    builtins.substring 0 2 (builtins.hashString "sha256" name);

  readPackage = name:
    fromJSON (readFile (./manifest + "/${shardFor name}/${name}.json"));

  mkVersions = system: name:
    mapAttrs (_: e: buildFromEntry system e) (readPackage name);
in
  { packages.${system} = genAttrs index (mkVersions system); }
```

Integrity chain:

- The whole `manifest/` tree is trusted because it is part of the
  flake source, pinned transitively by the consumer's `flake.lock`
  entry for npv.
- Each entry inside a package manifest carries the SRI sha256 of its
  nixpkgs tarball, which is fed into `fetchTarball`.

No hash is ever taken on trust. A consumer's `flake.lock` entry for
npv alone is enough to reproduce every derivation path it transitively
builds. No eval-time network I/O, no IFD, no external object store.

### Why this works once you see the numbers

- Git object storage is blob-level, not file-level. The 290k small
  blobs pack tightly and delta-compress well across revisions.
- Per-publish churn is small: most packages don't change between
  indexing runs, so most blobs are reused and the new pack grows by
  only a few MB.
- The GitHub tarball endpoint streams a gzipped tar of the commit
  tree. The repeated tar-header pattern compresses extremely
  efficiently (~30× ratio observed), which is what keeps the
  consumer-side download at ~36 MB despite ~660 MB of raw tar.
- Consumers fetch tarballs, not git clones, so history growth is
  invisible to them — only maintainers care about packed history
  size, and shallow clone handles that.

### Attribute layout: nested, not flat

The user-facing installable syntax is
`npv#packages.<system>.<name>.<version>` (nested), not
`npv#packages.<system>."<name>@<version>"` (flat). Both are valid Nix
attribute paths when the version segment is quoted, but their
evaluation costs differ drastically.

- **Flat** requires every `(name, version)` pair to be materialised as
  a top-level key. Since attrset keys must be enumerated at eval time,
  the flake would have to read every per-package manifest up-front —
  ~234k remote fetches or file reads just to list attributes.
- **Nested** only enumerates the `name` layer from `index.json`; the
  version layer is a lazy attrset that materialises when a specific
  name is accessed. Flake eval cost stays "nixpkgs-shaped": one big
  attrset of names with lazy values.

The top of `packages.<system>` is deliberately the same order of
magnitude as Nixpkgs' package set (~234k names). The version dimension
sits one level below it and is resolved only on access, so eval memory
does not scale with version-count.

A wrapper CLI can still offer `name@version` ergonomics (e.g.
`npv run python3@3.14.3`) by translating internally to the nested
attribute path.

### Update cadence

Each successful indexing run produces:

1. New per-package `<name>.json` files wherever content changed,
   uploaded to the object store at *new* CAS URLs (old URLs remain).
2. A refreshed `index.json` whose entries point at the new URLs +
   new sha256s for changed packages.
3. A git commit in this repo that replaces `index.json` in place.

Downstream flakes pick up the new catalogue by running
`nix flake update` on the npv input. Consumers still pinned to an
earlier npv commit keep their `index.json` → their URLs → their
per-package manifests, all of which remain resolvable because the
previous snapshots untouched.

Per-package manifests stay small: the average file is ~740 B; the
largest (language package sets with many tracked versions, e.g.
`python3.json`) is around 40 KB.

Repository growth over time: a re-publish rewrites the subset of
`manifest/<name>.json` files whose content changed and adjusts
`manifest/index.json` if the package set itself changed. Git's
blob-level delta compression handles this well — consecutive
publishes share the vast majority of blobs. Weekly updates are
expected to add on the order of tens of MB to the repo's packed
history per year. Consumers fetch tarballs of the commit tree, not
git history, so the growth is invisible to them.

### Stability of `(name, version) → commit` across indexing runs

`scripts/export-manifest.sh` picks the *newest* commit that contains
a given `(name, version)` pair:

```sql
PARTITION BY p.NAME, p.VERSION
ORDER BY cov.COMMIT_DATE DESC, length(p.KEY_NAME) ASC, p.KEY_NAME ASC
```

`DESC` is the right default for **buildability**. The newest commit
shipping a given version is the one most likely to:

- still have a populated binary cache on `cache.nixos.org`
- reference source URLs that are still live (old fetchurl URLs rot)
- use build infrastructure (bootstrap tools, `stdenv`) that is known
  to work with current Nix

Picking the *oldest* commit (`ASC`) would make the manifest
append-only at the SQL layer, but at the cost of resolving every
version to its earliest encounter — usually an ancient commit whose
builds are least likely to succeed today. That is a bad trade for
the user.

So this layer keeps the current ordering. The invariant the
distribution model needs is not "`(name, version)` always resolves
to the same commit forever", but **a published snapshot never
changes after it is published**. That invariant is satisfied
automatically by the chosen in-repo distribution: each git commit
is an immutable snapshot, and a re-indexing run that picks a
different commit for an existing version simply produces a new
git commit; consumers pinned to an older commit see the older
mapping unchanged.

## Long-term availability of pinned revisions

A downstream `flake.lock` that pins an older revision of the npv
flake must keep evaluating successfully years later. With the
in-repo bundle, this is trivially satisfied: every git commit
already is an immutable snapshot of the whole manifest tree, served
indefinitely by GitHub's tarball endpoint, with content hashed into
`flake.lock`.

The previous design iterations considered hosting manifests on a
remote store and linking to them from an in-repo index. Those
options are still worth documenting because they become attractive
for different operational reasons — not because of the pin-stability
requirement, which the in-repo bundle already covers.

Decision matrix:

| Scheme                     | Old pins survive | Repo size | Ops cost |
|----------------------------|------------------|-----------|----------|
| Mutable per-URL (baseline) | **no**           | small     | low      |
| CAS URLs + in-repo index   | yes              | small     | medium   |
| Release assets             | yes              | small     | low      |
| **In-repo bundle (chosen)**| **yes**          | medium    | **low**  |

The in-repo bundle is the chosen shape. The alternatives exist for
different reasons, described in the next section.

## Keeping the remote-storage option warm

The in-repo bundle is the right choice *for the flake consumer
channel*. There is still an operational reason to also publish
manifests to a remote object store (R2, S3, GitHub Pages, etc.):
**non-Nix consumers**.

Concretely, the following use cases benefit from remote hosting:

- A future **web UI or API** (nixhub.io-style) that lets users search
  and browse old versions. It wants per-package JSON over HTTPS with
  CDN caching, not a flake tarball.
- A **thin CLI** (`npv search`, `npv inspect`) that should not have
  to pull the whole catalogue just to answer a single query.
- External tools that need `curl`-able, cacheable URLs with stable
  semantics.

The natural shape for this is content-addressed per-package URLs:

```
https://manifests.example.com/python3/sha256-AAA.json   # immutable
https://manifests.example.com/python3/sha256-BBB.json   # later snapshot, both kept
https://manifests.example.com/index.json                # name -> { url, sha256 }
```

Properties:

- **Immutable per-version files**, so an API consumer or cached
  response never goes stale mid-session.
- **CDN-friendly**: per-file caches are trivial to reason about;
  invalidation is "upload new URL, update index", never "purge".
- **No pin-stability constraint**: external HTTP consumers don't
  have `flake.lock`, so the "old pins must keep working" problem
  that drove the in-repo decision doesn't apply. But reusing CAS
  URLs anyway costs nothing and yields cache-safety as a side
  benefit.

Implementation sketch for when we enable it:

1. After each successful indexing run, the publishing pipeline
   generates the same `manifest/` tree as today.
2. For each file whose content changed since the last run, upload
   it at `manifests/<name>/sha256-<hex>.json` on the bucket (only
   new blobs; existing hashes are never re-uploaded).
3. Regenerate `manifests/index.json` on the bucket: `{ name: { url,
   sha256 } }`.
4. In the git repo, the same `manifest/` tree is also committed
   (the in-repo channel).

Both channels stay in sync because they share the same source data.
The repo is the source of truth; the bucket is a cache/CDN
projection of it for non-Nix clients.

### Relationship to the chosen approach

None of this changes what the flake does. Flake consumers keep
using `readFile ./manifest/<name>.json` against the in-repo tree;
they never touch the remote bucket. The bucket is purely an
operational convenience to unlock the API/web-UI workstream
without interfering with the flake story.

### Also: the IFD-free eval profile

For the minority of consumers who need *zero* eval-time network I/O
(hermetic CI, air-gapped evaluators), the in-repo bundle already
delivers this — `readFile ./manifest/<name>.json` is pure
filesystem I/O, no fetch, no IFD. No separate Release asset is
needed.

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
fetch with hashes verified by the client*. The in-repo bundle is a
different trade-off — it pays an upfront cost (one tarball per
`flake update`, ~36 MB) in exchange for zero eval-time I/O and
trivial old-pin survivability. The prior art still informs the
shape of the parallel remote-storage channel (see "Keeping the
remote-storage option warm").

## Why not the alternatives

- **Mutable per-URL manifests (`s3://.../python3.json`, overwritten
  in place)** — simpler to publish, but breaks the moment a
  consumer pins an older npv revision and the remote file is
  overwritten. Sidestepped entirely by the in-repo bundle, which
  doesn't involve mutable URLs.

- **Single tarball release on GitHub Releases** as the distribution
  channel — functionally equivalent to the in-repo bundle but adds
  a publish step (upload the release asset) and a second place to
  manage. The in-repo bundle reuses the existing git/GitHub path
  and needs nothing beyond `git commit && git push`.

- **Per-package fetch from a remote index at eval time** — was the
  leading candidate before the actual tarball size was measured. At
  ~36 MB gzipped for the entire tree, the remote split is no longer
  necessary to keep `flake update` bandwidth reasonable. It remains
  useful for *non-Nix* consumers (see "Keeping the remote-storage
  option warm").

- **Live API + `--impure`** avoids any hash management but breaks
  pure evaluation, so the resulting packages cannot appear in
  anyone's `flake.nix` outputs without global `--impure`.

## Open questions

- **When do we enable the parallel remote channel?** The API/web-UI
  workstream isn't currently scheduled. The in-repo bundle alone is
  enough to ship the flake. Revisit when there's a concrete
  non-Nix consumer that needs HTTPS access.
- **Hosting choice for the parallel channel** when we do enable it:
  Cloudflare R2 is the leading candidate (egress-free, cheap CAS
  storage, HTTP+CDN out of the box), but GitHub Pages or an S3
  bucket could work equally well for the static content.
- Retention: do we ever prune entries whose nixpkgs revision is no
  longer fetchable from GitHub? Probably yes eventually, but a
  read-only best-effort `fetch` is fine for the PoC.

## Decided

- **Distribution shape**: the entire manifest tree is bundled in
  this repository under `manifest/` and versioned via ordinary git
  commits. Consumers `nix flake update` to pick up new snapshots;
  old pins keep resolving because git/GitHub retain the referenced
  commit indefinitely.
- **Regeneration cadence**: regenerate `manifest/` from the SQLite
  DB on every successful indexing run and commit the result.
- **Format stability**: `scripts/export-manifest.sh` emits files in
  a deterministic shape (sorted keys, consistent indentation,
  newest-commit tiebreaker) so git's delta compression can exploit
  the high blob-level overlap between publishes.
- **Parallel remote channel stays on the roadmap** — see "Keeping
  the remote-storage option warm". Not blocking for the flake
  launch; expected to be wired in when the API/web-UI work starts.

## Future work

- **Parallel publish to R2 / S3 / GitHub Pages** with
  content-addressed per-package URLs, as a non-Nix egress channel
  for APIs, search UIs, and light CLI tools. See "Keeping the
  remote-storage option warm" for the sketch.
- **Size reductions** if the in-repo bundle grows past the
  comfortable envelope (say, doubling from 36 MB to 70+ MB
  gzipped). Pruning entries whose nixpkgs revision is no longer
  fetchable is the most obvious lever; widening the shard key is
  another if the per-shard file count itself becomes unwieldy
  (neither is currently pressing).
