#!/usr/bin/env python3
# Generate per-package manifest files under a directory, sharded by
# the first two hex chars of sha256(name):
#
#   manifest/<ab>/<name>.json = { "<version>": { "rev", "sha256", "attr" }, ... }
#   manifest/index.json       = [ "<name>", ... ]
#
# Hash-based sharding keeps the distribution uniform (~1100 files per
# shard at 290k packages). A prefix-based scheme fails here because
# language ecosystems have extreme skew — "python" and "perl"
# derivations alone would dump tens of thousands of files into one
# shard.
#
# The flake-side resolver mirrors the shard computation with
# `builtins.substring 0 2 (builtins.hashString "sha256" name)`, which
# produces byte-identical output to hashlib.sha256 on UTF-8 bytes.
#
# Output is deterministic (sorted keys, UTF-8, trailing newlines,
# consistent indent) so git delta compression packs successive
# regenerations tightly.
import hashlib
import json
import os
import shutil
import sqlite3
import sys
from collections import defaultdict

QUERY = """
WITH ranked AS (
  SELECT
    p.NAME AS name, p.VERSION AS version, p.KEY_NAME AS attr,
    p.COMMIT_HASH AS rev, c.SHA256 AS sha256,
    ROW_NUMBER() OVER (
      PARTITION BY p.NAME, p.VERSION
      ORDER BY cov.COMMIT_DATE DESC, length(p.KEY_NAME) ASC, p.KEY_NAME ASC
    ) AS rn
  FROM package_details p
  JOIN commit_states c ON c.COMMIT_HASH = p.COMMIT_HASH
  JOIN coverage cov    ON cov.COMMIT_HASH = p.COMMIT_HASH
  WHERE c.INDEXING_STATE = 'Success' AND c.SHA256 IS NOT NULL
)
SELECT name, version, rev, sha256, attr FROM ranked WHERE rn = 1
"""

SHARD_WIDTH = 2  # hex chars → 256 shards, ~1100 files each at 290k total


def shard_for(name: str) -> str:
    # First SHARD_WIDTH hex chars of sha256 over UTF-8-encoded name.
    # Nix's `builtins.hashString "sha256"` produces the same bytes,
    # so the flake-side resolver computes the same shard.
    return hashlib.sha256(name.encode("utf-8")).hexdigest()[:SHARD_WIDTH]


def write_json(path: str, obj) -> None:
    # sort_keys + explicit separators + trailing newline = byte-for-byte
    # identical output for identical input. indent=2 is a readability
    # concession that costs a little size but keeps `git diff` sane.
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, sort_keys=True, indent=2, separators=(",", ": "))
        f.write("\n")


def main() -> int:
    db_path = sys.argv[1] if len(sys.argv) > 1 else "database/DATABASE.db"
    out_dir = sys.argv[2] if len(sys.argv) > 2 else "manifest"

    # Wipe and recreate so removed packages don't linger as stale files.
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir)

    conn = sqlite3.connect(db_path)
    try:
        cur = conn.execute(QUERY)
        by_name: dict[str, dict] = defaultdict(dict)
        for name, version, rev, sha256, attr in cur:
            # A slash would escape the shard directory; control chars
            # would make filesystem behaviour undefined. The DB has
            # never contained such names, but guard anyway.
            if not name or "/" in name or any(c in name for c in "\t\n\r"):
                print(f"skipping suspicious name: {name!r}", file=sys.stderr)
                continue
            if name.startswith("."):
                print(f"skipping dotfile-like name: {name!r}", file=sys.stderr)
                continue
            by_name[name][version] = {"rev": rev, "sha256": sha256, "attr": attr}
    finally:
        conn.close()

    # Group by shard prefix so we can create each subdir once.
    by_shard: dict[str, list[str]] = defaultdict(list)
    for name in by_name:
        by_shard[shard_for(name)].append(name)

    for shard, names in by_shard.items():
        shard_dir = os.path.join(out_dir, shard)
        os.makedirs(shard_dir, exist_ok=True)
        for name in names:
            write_json(os.path.join(shard_dir, f"{name}.json"), by_name[name])

    # Flat sorted name list. Flake consumers drive `genAttrs` off this
    # without having to walk shard subdirectories themselves.
    write_json(os.path.join(out_dir, "index.json"), sorted(by_name.keys()))

    print(
        f"wrote {len(by_name)} packages across {len(by_shard)} shards "
        f"to {out_dir}/"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
