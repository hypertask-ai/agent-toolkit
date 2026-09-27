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
MODEL_CLI="$TMP/bin/provider"
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
  *'/mcp/tasks?'*) if [ -n "${MOCK_TASKS:-}" ]; then cat "$MOCK_TASKS"; printf '\n200'; else printf '{"tasks":[]}\n200'; fi ;;
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
case " $* " in
  *' project show '*) printf '{"project":{"id":5500,"ownerId":6,"sections":[{"name":"In Progress"}]}}\n' ;;
  *' task get '*) cat "$MOCK_TASKS" ;;
  *) printf '{}\n' ;;
esac
EOF
cat > "$TMP/bin/provider" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${!#}" > "$MOCK_PROMPT"
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

# A dry run with no tasks never builds the manager prompt that broke in AGTE-31.
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":181,"ticketNumber":"AGTE-181","projectId":5500,"section":"In Progress","title":"Exercise manager prompt","description":"Check quoted examples","assignees":[{"agent":{"id":"agent-product","displayName":"Product Bot"}}],"labels":[],"commentCount":0}]}
EOF
set +e
HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
  XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
  PATH="$TMP/bin:$PATH" MOCK_TASKS="$TMP/tasks.json" MOCK_PROMPT="$TMP/prompt" \
  "$ROOT/scripts/agent-board-poll" --once product-bot > "$TMP/work.out" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] || [ ! -s "$TMP/prompt" ] \
   || ! grep -qF 'saying "stop dev 1" runs' "$TMP/prompt" \
   || ! grep -qF 'Example: "give HTPR-6550 to dev 2" runs' "$TMP/prompt" \
   || ! grep -qF 'Example: "put dev 2 on grok fast" runs' "$TMP/prompt" \
   || ! grep -qF 'Example: "quiet off for qa-1" runs' "$TMP/prompt" \
   || ! grep -qF 'Example: "file a toolkit ticket: add a setup report" runs' "$TMP/prompt" \
   || grep -qF 'command not found' "$TMP/work.out"; then
  printf 'FAIL manager-prompt-quoted-example rc=%s output=%s log=%s\n' "$rc" "$(cat "$TMP/work.out")" "$(cat "$TMP/state/agent-board-poll/product-bot.log" 2>/dev/null)"
  exit 1
fi
printf 'PASS manager-prompt-quoted-example    work tick delivers the quoted command without executing it\n'

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

core_write_event_timer_dropin "$TMP/units" product-bot
event_timer="$TMP/units/agent-board-poll@product-bot.timer.d/events.conf"
if ! grep -qFx 'OnUnitActiveSec=5m' "$event_timer"; then
  printf 'FAIL event-poll-five-minute-safety-net\n'
  exit 1
fi
core_remove_event_timer_dropin "$TMP/units" product-bot
if [ -e "$event_timer" ]; then
  printf 'FAIL event-poll-dropin-removal\n'
  exit 1
fi
printf 'PASS event-poll-five-minute-safety-net events mode retains a five-minute fallback\n'
