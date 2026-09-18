#!/usr/bin/env bash
# AGTE-31: manager ticks and their top-level failure logging stay offline here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/home/.config/agents" "$TMP/company" "$TMP/repo" "$TMP/bin" "$TMP/state"
printf '# company pack\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"

cat > "$TMP/home/.config/agents/product-bot.conf" <<EOF
AGENT_SLUG="product-bot"
AGENT_ID="agent-product"
AGENT_NAME="Product Bot"
AGENT_KIND="manager"
AGENT_REPO="$TMP/repo"
BOARD_ADAPTER="hypertask"
BOARD_ID="5500"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/bin/hypertask"
WATCH_SECTIONS="*"
MODEL_CLI="provider"
PR_REPO="example/repo"
SKILLS_INDEX=""
TRIAGE="no"
CLAIM_UNASSIGNED="no"
MANAGER="on"
MAINTAINER="on"
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *'/mcp/tasks?'*) printf '{"tasks":[]}\n200' ;;
  *) printf '{}\n200' ;;
esac
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
# The dry run checks `command -v hypertask` before doing anything else,
# regardless of BOARD_CLI, so a fake CLI must be on PATH here or this eval
# only passes on a host that happens to have the real one installed.
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/"*

set +e
output="$(HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
  XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
  PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" \
  --once --dry-run product-bot 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] || printf '%s\n' "$output" | grep -qF 'command not found'; then
  printf 'FAIL manager-maintainer-dry-run rc=%s output=%s\n' "$rc" "$output"
  exit 1
fi
printf 'PASS manager-maintainer-dry-run      exits zero without command-not-found\n'

cat > "$TMP/bin/failing-poll" <<'EOF'
#!/usr/bin/env bash
printf 'synthetic poll failure\n' >&2
exit 27
EOF
chmod +x "$TMP/bin/failing-poll"
set +e
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" AGENT_BOARD_POLL_BIN="$TMP/bin/failing-poll" \
  "$ROOT/scripts/agent-board-poll-tick" product-bot >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 27 ] \
   || ! grep -qF 'run FAILED tick exit=27' "$TMP/state/agent-board-poll/product-bot.log"; then
  printf 'FAIL failed-tick-logged rc=%s log=%s\n' "$rc" \
    "$(cat "$TMP/state/agent-board-poll/product-bot.log" 2>/dev/null || true)"
  exit 1
fi
printf 'PASS failed-tick-logged              preserves exit and writes the failure marker\n'

# shellcheck disable=SC1091
. "$ROOT/scripts/lib/core.sh"
core_write_poll_units "$TMP/units" "$TMP/bin"
if ! grep -qF 'ExecStart='"$TMP/bin"'/agent-board-poll-tick %i' \
  "$TMP/units/agent-board-poll@.service"; then
  printf 'FAIL poll-unit-uses-tick-wrapper\n'
  exit 1
fi
printf 'PASS poll-unit-uses-tick-wrapper     systemd runs the failure-logging entrypoint\n'
