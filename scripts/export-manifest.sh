#!/usr/bin/env bash
# Generate per-package manifest files under a directory, one JSON file
# per package name:
#
#   manifest/<name>.json = { "<version>": { "rev", "sha256", "attr" }, ... }
#   manifest/index.json  = [ "<name>", ... ]
#
# This layout lets a consumer fetch only the packages it needs (e.g.
# publish each file behind a static URL and fetch via builtins.fetchurl),
# instead of shipping one monolithic manifest.
set -euo pipefail

db="${1:-database/DATABASE.db}"
outDir="${2:-manifest}"

mkdir -p "$outDir"
rm -f "$outDir"/*.json

# One-pass dump: for every (name, version) keep the newest successful
# commit; prefer the shortest KEY_NAME as a tiebreaker (more canonical).
sqlite3 "$db" <<'SQL' |
.mode json
WITH ranked AS (
  SELECT
    p.NAME AS name,
    p.VERSION AS version,
    p.KEY_NAME AS attr,
    p.COMMIT_HASH AS rev,
    c.SHA256 AS sha256,
    ROW_NUMBER() OVER (
      PARTITION BY p.NAME, p.VERSION
      ORDER BY cov.COMMIT_DATE DESC, length(p.KEY_NAME) ASC, p.KEY_NAME ASC
    ) AS rn
  FROM package_details p
  JOIN commit_states c ON c.COMMIT_HASH = p.COMMIT_HASH
  JOIN coverage cov ON cov.COMMIT_HASH = p.COMMIT_HASH
  WHERE c.INDEXING_STATE = 'Success'
    AND c.SHA256 IS NOT NULL
)
SELECT name, version, rev, sha256, attr FROM ranked WHERE rn = 1
ORDER BY name;
SQL
jq -c '
  group_by(.name)
  | map({ name: .[0].name,
          entries: (map({ (.version): { rev, sha256, attr } }) | add) })
' | jq -r '.[] | @base64' | while read -r row; do
    decoded=$(echo "$row" | base64 -d)
    name=$(echo "$decoded" | jq -r '.name')
    # Slashes in package names would escape the manifest dir, so reject.
    case "$name" in */*|*$'\n'*|*$'\t'*) echo "skipping suspicious name: $name" >&2; continue ;; esac
    echo "$decoded" | jq '.entries' > "$outDir/${name}.json"
done

# Index of available package names so clients can enumerate without
# directory listings (static hosting often disables those).
ls "$outDir" | grep -E '\.json$' | grep -v '^index\.json$' | sed 's/\.json$//' \
  | jq -R -s 'split("\n") | map(select(length > 0))' > "$outDir/index.json"

echo "wrote $(jq 'length' "$outDir/index.json") packages to $outDir/"
