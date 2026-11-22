#!/usr/bin/env bash
set -euo pipefail

ref="${1:-HEAD}"
root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for name in base user_seed; do
  path="priv/data/$name.db"
  echo "-- $path vs $ref"
  git -C "$root" show "$ref:$path" > "$tmp/$name.db"
  sqldiff "$tmp/$name.db" "$root/$path"
done
