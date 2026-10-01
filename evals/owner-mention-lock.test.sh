#!/usr/bin/env bash
# A nested comment add must not wait forever on the owner-mention lock.
# Before the fix, the identity shim re-entered this wrapper while flock had
# no timeout, so the child waited until somebody killed it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/bin" "$TMP/identity-shims/locktest" "$TMP/state"
printf 'fixture-token\n' > "$TMP/token"
chmod 600 "$TMP/token"
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
printf 'call\n' >> "$CALL_LOG"
case " $* " in
  *' project show '*) printf '%s\n' '{"project":{"ownerId":6}}' ;;
  *' task get '*) printf '%s\n' '{"tasks":[{"id":1,"ticketNumber":"TEST-1","assignees":[],"labels":[]}]}' ;;
  *' comment list '*) printf '%s\n' '{"comments":[]}' ;;
  *' comment add '*) printf '%s\n' 'posted' ;;
  *) printf '%s\n' '{}' ;;
esac
EOF
chmod 755 "$TMP/bin/hypertask"
cat > "$TMP/identity-shims/locktest/hypertask" <<EOF
#!/usr/bin/env bash
printf 'shim\n' >> "\$SHIM_LOG"
export PATH="$TMP/bin:\$PATH"
exec "$TMP/bin/ht-lock" "\$@"
EOF
chmod 755 "$TMP/identity-shims/locktest/hypertask"

# shellcheck disable=SC1091
CORE_ROOT="$ROOT"
. "$ROOT/scripts/lib/core.sh"
core_load_adapter hypertask
PATH="$TMP/bin:$PATH" adapter_install_board_cli locktest "$TMP/token" "$TMP/bin/ht-lock" "Test Bot" agent-1 15 off

CALL_LOG="$TMP/calls"
SHIM_LOG="$TMP/shim-calls"
export CALL_LOG SHIM_LOG
: > "$CALL_LOG"
: > "$SHIM_LOG"
text='<p><strong>Claimed.</strong> A session is working this ticket now.</p>'
start=$(date +%s)
if PATH="$TMP/identity-shims/locktest:$TMP/bin:$PATH" \
   HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" BOARD_API_URL="http://127.0.0.1:9" \
   timeout 20 "$TMP/bin/ht-lock" comment add TEST-1 --raw --text "$text" >"$TMP/shim-run.out" 2>"$TMP/shim-run.err"; then
  elapsed=$(( $(date +%s) - start ))
  if [ "$elapsed" -lt 20 ] && ! grep -q '^shim$' "$SHIM_LOG" && grep -q '^call$' "$CALL_LOG"; then
    ok lock-skips-identity-shim "comment add finished in ${elapsed}s without re-entering the wrapper"
  else
    bad lock-skips-identity-shim "elapsed=$elapsed shim=$(wc -l < "$SHIM_LOG") calls=$(wc -l < "$CALL_LOG") err=$(cat "$TMP/shim-run.err")"
  fi
else
  bad lock-skips-identity-shim "comment add exited $? err=$(cat "$TMP/shim-run.err")"
fi

# Nested call while this process already holds the lock. The guard must skip
# a second flock. Without it, this waits until the holder exits.
lock="$TMP/state/agent-board-poll/locktest.owner-mentions.lock"
mkdir -p "$(dirname "$lock")"
bash -c 'exec 9>>"$1"; flock 9; sleep 45' _ "$lock" &
holder=$!
sleep 0.2
: > "$CALL_LOG"
start=$(date +%s)
set +e
PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" \
  BOARD_API_URL="http://127.0.0.1:9" HT_OWNER_MENTIONS_LOCKED=1 \
  timeout 20 "$TMP/bin/ht-lock" comment add TEST-1 --raw --text "$text" \
  >"$TMP/nested.out" 2>"$TMP/nested.err"
nested_rc=$?
set -e
elapsed=$(( $(date +%s) - start ))
if [ "$nested_rc" -eq 0 ] && [ "$elapsed" -lt 20 ] && grep -q '^posted$' "$TMP/nested.out"; then
  ok lock-reentrant-nested "nested comment add under the held lock finished in ${elapsed}s"
else
  bad lock-reentrant-nested "rc=$nested_rc elapsed=$elapsed err=$(cat "$TMP/nested.err")"
fi
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

# A different holder, and no guard, must fail the comment instead of waiting forever.
bash -c 'exec 9>>"$1"; flock 9; sleep 90' _ "$lock" &
holder=$!
sleep 0.2
start=$(date +%s)
set +e
env -u HT_OWNER_MENTIONS_LOCKED \
  PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" \
  BOARD_API_URL="http://127.0.0.1:9" \
  timeout 70 "$TMP/bin/ht-lock" comment add TEST-1 --raw --text "$text" \
  >"$TMP/wait.out" 2>"$TMP/wait.err"
wait_rc=$?
set -e
elapsed=$(( $(date +%s) - start ))
if [ "$wait_rc" -ne 0 ] && [ "$wait_rc" -ne 124 ] && [ "$elapsed" -lt 70 ] \
   && grep -q 'owner-mention lock timed out' "$TMP/wait.err"; then
  ok lock-timeout-fails-comment "contended lock failed the comment in ${elapsed}s"
else
  bad lock-timeout-fails-comment "rc=$wait_rc elapsed=$elapsed err=$(cat "$TMP/wait.err")"
fi
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
