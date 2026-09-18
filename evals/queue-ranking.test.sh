#!/usr/bin/env bash
# Queue-ranking checks use local command stubs and never call a board or model.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
runner_pid=""
cleanup() {
  if [ -n "$runner_pid" ] && kill -0 "$runner_pid" 2>/dev/null; then
    kill "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/home/.config/agents" "$TMP/company" "$TMP/repo" \
  "$TMP/bin" "$TMP/state/agent-board-poll"
printf '# company pack\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"
mkfifo "$TMP/run-ready" "$TMP/run-release"

python3 - "$TMP/tasks.json" <<'PYEOF'
from datetime import datetime, timedelta, timezone
import json, sys

now = datetime.now(timezone.utc)
def stamp(hours):
    return (now + timedelta(hours=hours)).isoformat().replace("+00:00", "Z")

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"tasks": [
        {"id": "task-1", "ticketNumber": "AGTE-1", "section": "Queued",
         "title": "Ordinary first on board", "description": "ordinary",
         "priority": "Normal", "dueDate": stamp(96), "assignees": [],
         "labels": [], "commentCount": 0},
        {"id": "task-2", "ticketNumber": "AGTE-2", "section": "Queued",
         "title": "Urgent due today", "description": "urgent",
         "priority": {"name": "Urgent"}, "dueDate": stamp(1), "assignees": [],
         "labels": [], "commentCount": 0},
        {"id": "task-3", "ticketNumber": "AGTE-3", "section": "Queued",
         "title": "Normal due tomorrow", "description": "due soon",
         "priority": "Normal", "dueDate": stamp(24), "assignees": [],
         "labels": [], "commentCount": 0},
    ]}, handle)
PYEOF

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *'/mcp/tasks?'*) cat "$TASKS_JSON"; printf '\n200' ;;
  *'/mcp/comments?'*) printf '%s\n200' '{"comments":[]}' ;;
  *) printf '%s\n404' '{}' ;;
esac
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *' --json project show '*) printf '{"project":{"ownerId":6}}\n' ;;
  *' --json comment list '*) printf '{"comments":[]}\n' ;;
  *) printf '{}\n' ;;
esac
EOF
cat > "$TMP/bin/provider" <<'EOF'
#!/usr/bin/env bash
prompt="${!#}"
ref="$(printf '%s\n' "$prompt" | sed -n 's/^You are .* one ticket, \([^,]*\),.*$/\1/p' | head -1)"
printf '%s\n' "$ref" >> "$CLAIMS"
printf 'ready\n' > "$RUN_READY"
cat "$RUN_RELEASE" >/dev/null
EOF
chmod +x "$TMP/bin/"*

cat > "$TMP/home/.config/agents/dev.conf" <<EOF
AGENT_ID="agent-1"
AGENT_NAME="Dev Bot"
AGENT_KIND="dev"
AGENT_REPO="$TMP/repo"
AGENT_SLUG="dev"
BOARD_ADAPTER="hypertask"
BOARD_ID="5500"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/board"
WATCH_SECTIONS="Queued"
SKILLS_INDEX=""
MODEL_CLI="provider"
PR_REPO="example/repo"
TRIAGE="no"
CLAIM_UNASSIGNED="yes"
MAX_CONCURRENT_RUNS="1"
GRAFT="off"
FLEET_PROGRESS_SUPERVISOR="off"
EOF

run_tick() {
  HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
    XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
    TASKS_JSON="$TMP/tasks.json" CLAIMS="$TMP/claims" \
    RUN_READY="$TMP/run-ready" RUN_RELEASE="$TMP/run-release" \
    PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" "$@" dev
}

output="$(run_tick --once --dry-run --explain)"
order="$(printf '%s\n' "$output" | sed -n 's/^would pick up \([^ ]*\).*/\1/p' | paste -sd ' ' -)"
if [ "$order" = 'AGTE-2 AGTE-3 AGTE-1' ]; then
  ok urgent-due-queue-order 'urgent due today is first, then due-soon, then ordinary board work'
else
  bad urgent-due-queue-order "order=$order output=$output"
fi

: > "$TMP/claims"
run_tick --once >"$TMP/first.out" 2>"$TMP/first.err" &
runner_pid=$!
ready="$(timeout 20 cat "$TMP/run-ready")"
second="$(run_tick --once 2>&1)"
lock_ticket="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ticket"])' "$TMP/state/agent-board-poll/dev.lock")"
claims="$(paste -sd ' ' "$TMP/claims")"
if [ "$ready" = 'ready' ] && kill -0 "$runner_pid" 2>/dev/null \
   && [ "$claims" = 'AGTE-2' ] && [ "$lock_ticket" = 'AGTE-2' ] \
   && grep -qF 'tick skipped: another tick for dev is still running' "$TMP/state/agent-board-poll/dev.log"; then
  ok active-run-not-interrupted 'the next tick leaves the running urgent claim alive and starts no replacement'
else
  bad active-run-not-interrupted "ready=$ready alive=$(kill -0 "$runner_pid" 2>/dev/null && echo yes || echo no) claims=$claims lock=$lock_ticket second=$second"
fi

printf 'release\n' > "$TMP/run-release"
wait "$runner_pid"
runner_pid=""

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
