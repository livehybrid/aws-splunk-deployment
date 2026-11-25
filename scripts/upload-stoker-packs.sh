#!/usr/bin/env bash
# Register eventgen packs with a running Stoker instance.
#
#   STOKER_URL=https://stoker.example.com ./scripts/upload-stoker-packs.sh [packs-dir]
#
# Neither the Stoker image nor its worker image ships the packs, so a fresh
# deployment needs them registered once. Each pack is a directory containing a
# pack.json manifest; this POSTs every manifest found under packs-dir
# (default: ./packs).
set -euo pipefail

: "${STOKER_URL:?set STOKER_URL to the Stoker base URL, e.g. https://stoker.example.com}"
PACKS_DIR="${1:-./packs}"

[ -d "$PACKS_DIR" ] || { echo "packs directory not found: $PACKS_DIR" >&2; exit 1; }

shopt -s nullglob
manifests=("$PACKS_DIR"/*/pack.json)
[ ${#manifests[@]} -gt 0 ] || { echo "no */pack.json under $PACKS_DIR" >&2; exit 1; }

for m in "${manifests[@]}"; do
  printf 'registering %s ... ' "$(basename "$(dirname "$m")")"
  curl -fsS -X POST "${STOKER_URL%/}/api/packs" \
    -H 'Content-Type: application/json' \
    --data-binary "@$m" >/dev/null
  echo ok
done
