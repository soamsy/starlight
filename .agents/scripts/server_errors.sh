#!/usr/bin/env bash
# Injects recent Starlight server errors/warnings into Claude's context.
# Called by the UserPromptSubmit hook — outputs JSON with additionalContext.
LOG=/tmp/starlight.log
STAMP=/tmp/.starlight_log_stamp

[ -f "$LOG" ] || { echo '{}'; exit 0; }

TOTAL=$(wc -l < "$LOG")
SINCE=$(cat "$STAMP" 2>/dev/null || echo 0)
echo "$TOTAL" > "$STAMP"

# Handle log rotation / truncation
if [ "$TOTAL" -le "$SINCE" ]; then
  echo '{}'
  exit 0
fi

NEW=$(sed -n "$((SINCE + 1)),${TOTAL}p" "$LOG" \
  | awk '{ts=$1; $1=""; if (!seen[$0]++) order[++n]=$0; last[$0]=ts}
         END {for (i=1; i<=n; i++) {m=order[i]; printf "%s%s%s\n", last[m], m, (seen[m] > 1 ? " (x" seen[m] ")" : "")}}' \
  | tail -n 30 | cut -c1-300)
[ -z "$NEW" ] && { echo '{}'; exit 0; }

jq -n --arg ctx "=== Starlight server log (new since last turn) ===
$NEW" \
  '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":$ctx}}'
