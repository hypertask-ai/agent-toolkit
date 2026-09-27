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
# Every paused spelling must stop the poll before required-key validation.
for value in YES TrUe 1 ON unexpected '   '; do
  printf 'PAUSED=%q\n' "$value" > "$conf"
  if "$ROOT/scripts/agent-board-poll" --once test-agent > "$TMP/out" 2>&1 \
     && grep -q ' paused$' "$XDG_STATE_HOME/agent-board-poll/test-agent.log"; then
    ok "pause-value-${value// /space}"
  else bad "pause-value-${value// /space}"; fi
  if [ "$value" = unexpected ] && grep -q 'WARNING:.*unrecognized PAUSED' "$TMP/out"; then
    ok pause-unknown-warns
  elif [ "$value" = unexpected ]; then bad pause-unknown-warns; fi
done
for value in NO FaLsE 0 OFF ''; do
  printf 'PAUSED=%q\n' "$value" > "$conf"
  if "$ROOT/scripts/agent-board-poll" --once test-agent > "$TMP/out" 2>&1; then
    bad "running-value-${value:-empty}"
  elif grep -q 'has no AGENT_ID' "$TMP/out"; then
    ok "running-value-${value:-empty}"
  else bad "running-value-${value:-empty}"; fi
done
printf 'BOARD_ADAPTER=hypertask\nPAUSED=on\n' > "$conf"
if "$ROOT/scripts/agent-board-reconcile" --config-dir "$AGENT_CONFIG_DIR" \
    --state-dir "$TMP/reconcile" > "$TMP/out" 2>&1; then
  ok paused-reconcile-skips-conf
else bad paused-reconcile-skips-conf; fi
if [ "$(stat -c %a "$conf.lock")" = 600 ]; then ok pause-lock-private; else bad pause-lock-private; fi
if python3 - "$conf" "$ROOT/scripts/agent-resume" <<'PYEOF'
import fcntl
import subprocess
import sys

with open(sys.argv[1]) as conf:
    fcntl.flock(conf, fcntl.LOCK_EX)
    process = subprocess.Popen([sys.argv[2], "test-agent"])
    try:
        process.wait(timeout=0.2)
        raise AssertionError("resume did not wait for conf lock")
    except subprocess.TimeoutExpired:
        pass
    fcntl.flock(conf, fcntl.LOCK_UN)
    assert process.wait(timeout=5) == 0
PYEOF
then ok pause-conf-flock; else bad pause-conf-flock; fi
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
