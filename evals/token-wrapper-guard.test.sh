#!/usr/bin/env bash
# AGTE-13: a hand-made board wrapper (the real ~/.local/bin/htbot) called the
# board API directly and let an unmarked, owner-mentioning comment through
# because it never passed through the identity shim's protected BOARD_CLI.
# core_guard_token_wrappers is the fix: find any other executable in the bin
# dir that embeds a managed agent's token file and is not that agent's own
# BOARD_CLI, and rewrite it to exec the BOARD_CLI instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-34s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-34s %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/bin" "$TMP/home/.config/agents"
printf 'agent-token\n' > "$TMP/token"

CORE_ROOT="$ROOT"
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/core.sh"
core_load_adapter hypertask
adapter_install_board_cli test "$TMP/token" "$TMP/bin/test-board" "Test Agent"
BOARD_CLI_CONTENT_BEFORE="$(cat "$TMP/bin/test-board")"

cat > "$TMP/home/.config/agents/test.conf" <<EOF
AGENT_SLUG="test"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/bin/test-board"
EOF

new_stray() {
  cat > "$TMP/bin/htbot" <<EOF
#!/usr/bin/env bash
TOKEN_FILE="$TMP/token"
TOKEN="\$(cat "\$TOKEN_FILE")"
exec hypertask --token "\$TOKEN" "\$@"
EOF
  chmod 755 "$TMP/bin/htbot"
}

run_guard() {
  env HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
    bash -c 'CORE_ROOT="$1"; . "$1/scripts/lib/core.sh"; core_guard_token_wrappers "$2" "$3"' \
    _ "$ROOT" "$TMP/bin" "$1"
}

# ---- a stray wrapper outside the shim gets rewritten, with a backup ----
new_stray
if run_guard 2> "$TMP/rewrite.err" no \
   && grep -qF "exec \"$TMP/bin/test-board\"" "$TMP/bin/htbot" \
   && [ -x "$TMP/bin/htbot" ] \
   && compgen -G "$TMP/bin/htbot.bak-*" > /dev/null \
   && grep -qF 'hypertask --token' "$TMP/bin"/htbot.bak-* \
   && grep -qF 'rewrote' "$TMP/rewrite.err"; then
  ok token-wrapper-rewritten "a stray board wrapper is rewritten to exec BOARD_CLI, with a backup"
else
  bad token-wrapper-rewritten "$(cat "$TMP/rewrite.err" 2>/dev/null)"
fi

# ---- the managed BOARD_CLI itself is never touched ----
if [ "$(cat "$TMP/bin/test-board")" = "$BOARD_CLI_CONTENT_BEFORE" ] \
   && ! compgen -G "$TMP/bin/test-board.bak-*" > /dev/null; then
  ok token-wrapper-board-cli-untouched "the agent's own BOARD_CLI is left alone"
else
  bad token-wrapper-board-cli-untouched "test-board was modified or backed up"
fi

# ---- dry-run reports the same finding and changes nothing ----
rm -f "$TMP/bin"/htbot.bak-*
new_stray
STRAY_BEFORE="$(cat "$TMP/bin/htbot")"
if run_guard 2> "$TMP/dry.err" yes \
   && [ "$(cat "$TMP/bin/htbot")" = "$STRAY_BEFORE" ] \
   && ! compgen -G "$TMP/bin/htbot.bak-*" > /dev/null \
   && grep -qF 'outside the identity shim' "$TMP/dry.err"; then
  ok token-wrapper-dry-run "dry-run warns without rewriting anything"
else
  bad token-wrapper-dry-run "$(cat "$TMP/dry.err" 2>/dev/null)"
fi

# ---- an unwritable stray wrapper is refused with a loud warning, not silently skipped ----
rm -f "$TMP/bin"/htbot.bak-*
new_stray
chmod 555 "$TMP/bin/htbot"
UNWRITABLE_BEFORE="$(cat "$TMP/bin/htbot")"
run_guard 2> "$TMP/refuse.err" no || true
chmod 755 "$TMP/bin/htbot"
if [ "$(cat "$TMP/bin/htbot")" = "$UNWRITABLE_BEFORE" ] \
   && ! compgen -G "$TMP/bin/htbot.bak-*" > /dev/null \
   && grep -qF 'could not be rewritten' "$TMP/refuse.err"; then
  ok token-wrapper-refuse-loud "an unwritable stray wrapper is left alone with a loud warning"
else
  bad token-wrapper-refuse-loud "$(cat "$TMP/refuse.err" 2>/dev/null)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
