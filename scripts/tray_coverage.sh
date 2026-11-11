#!/usr/bin/env bash
set -euo pipefail

dir="${1:-.starlight-dev/battle_debug}"

for suite in "$dir"/*_chain_tray.suite; do
  id=$(basename "$suite" .suite)
  truth="$dir/$id.truth.json"
  [ -f "$truth" ] || truth="$dir/$id.json"
  jq -c --arg hour "${id:0:13}" '(.slots // .detected.slots)[] | (.top, .bottom) | {sin, tier, hour: $hour}' "$truth"
done | jq -rs '
  group_by(.sin) | map(. as $rows | {
    sin: $rows[0].sin,
    cells: ["skill1", "skill2", "skill3"] | map(. as $t | [$rows[] | select(.tier == $t)] | "\(length)/\(map(.hour) | unique | length)")
  })
  | (["sin", "skill1", "skill2", "skill3"] | @tsv), (.[] | [.sin] + .cells | @tsv)
' | column -t
