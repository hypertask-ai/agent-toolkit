#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
export AGENT_CONFIG_DIR="$TMP/conf" XDG_STATE_HOME="$TMP/state"
mkdir -p "$AGENT_CONFIG_DIR/Product Board"
conf="$AGENT_CONFIG_DIR/Product Board/test-agent.conf"
printf 'BOARD_ID="15"\nCUSTOM="unchanged"\n' > "$conf"
chmod 600 "$conf"
# The flat legacy file must not win over the board folder.
printf 'BOARD_ID="old"\n' > "$AGENT_CONFIG_DIR/test-agent.conf"
reason="owner's \$(touch $TMP/injected) maintenance"
"$ROOT/scripts/agent-pause" test-agent --reason "$reason"
if grep -q '^PAUSED="yes"$' "$conf" && grep -q '^PAUSED_AT=' "$conf" \
   && [ "$(stat -c %a "$conf")" = 600 ] \
   && [ ! -e "$TMP/injected" ] \
   && [ "$(bash -c '. "$1"; printf "%s" "$PAUSED_REASON"' _ "$conf")" = "$reason" ] \
   && ! grep -q '^PAUSED=' "$AGENT_CONFIG_DIR/test-agent.conf"; then
  ok pause-board-folder-reason
else bad pause-board-folder-reason; fi
for flags in '--once' '--once --ticket AGTE-38 --board 15' ''; do
  # shellcheck disable=SC2086
  if "$ROOT/scripts/agent-board-poll" $flags test-agent; then ok "poll-paused-${flags:-timer}"; else bad "poll-paused-${flags:-timer}"; fi
done
if [ "$(wc -l < "$XDG_STATE_HOME/agent-board-poll/test-agent.log")" -eq 3 ] \
   && [ "$(grep -c ' paused$' "$XDG_STATE_HOME/agent-board-poll/test-agent.log")" -eq 3 ]; then
  ok paused-logs
else bad paused-logs; fi
"$ROOT/scripts/agent-pause" test-agent
if [ "$(grep -c '^PAUSED=' "$conf")" -eq 1 ] \
   && grep -q '^PAUSED_REASON=' "$conf"; then ok pause-idempotent; else bad pause-idempotent; fi
if "$ROOT/scripts/agent-pause" test-agent --reason $'bad\nline' > "$TMP/out" 2>&1; then
  bad multiline-reason
elif [ "$(grep -c '^PAUSED=' "$conf")" -eq 1 ]; then
  ok multiline-reason
else bad multiline-reason; fi
"$ROOT/scripts/agent-resume" test-agent
if ! grep -qE '^PAUSED(_REASON|_AT)?=' "$conf" \
   && grep -q '^CUSTOM="unchanged"$' "$conf" \
   && [ "$(stat -c %a "$conf")" = 600 ]; then ok resume-removes-keys; else bad resume-removes-keys; fi
if PAUSED=yes "$ROOT/scripts/agent-board-poll" --once test-agent > "$TMP/out" 2>&1; then
  bad unpaused-default
elif grep -q 'has no AGENT_ID' "$TMP/out"; then
  ok unpaused-default
else bad unpaused-default; fi
printf 'PAUSED="no"\n' >> "$conf"
if "$ROOT/scripts/agent-board-poll" --ticket AGTE-38 test-agent > "$TMP/out" 2>&1; then
  bad non-yes-default
elif grep -q 'has no AGENT_ID' "$TMP/out"; then
  ok non-yes-default
else bad non-yes-default; fi
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
