#!/usr/bin/env bash
# WATCH_SECTIONS is a priority order. An earlier column beats a later one.
set -euo pipefail
unset AGENT_ORIGINAL_PATH AGENT_IDENTITY_PATH

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/home/.config/agents" "$TMP/company" "$TMP/repo" \
  "$TMP/bin" "$TMP/state/agent-board-poll"
printf '# company pack\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"

python3 - "$TMP/tasks.json" <<'PYEOF'
from datetime import datetime, timedelta, timezone
import json, sys

now = datetime.now(timezone.utc)
def stamp(hours):
    return (now + timedelta(hours=hours)).isoformat().replace("+00:00", "Z")

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"tasks": [
        {"id": "task-1", "ticketNumber": "AGTE-1", "section": "Bugs",
         "title": "Ordinary bug listed first", "description": "ordinary",
         "priority": "Normal", "dueDate": stamp(96), "assignees": [],
         "labels": [], "commentCount": 0},
        {"id": "task-2", "ticketNumber": "AGTE-2", "section": "Agent Blocked (Infra)",
         "title": "Infra blockage listed second", "description": "infra",
         "priority": "Normal", "dueDate": stamp(96), "assignees": [],
         "labels": [{"name": "infra"}], "commentCount": 0},
        {"id": "task-3", "ticketNumber": "AGTE-3", "section": "Bugs",
         "title": "Urgent bug listed third", "description": "urgent",
         "priority": {"name": "Urgent"}, "dueDate": stamp(1), "assignees": [],
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
printf '{}\n'
EOF
chmod +x "$TMP/bin/"*

write_conf() {
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
WATCH_SECTIONS="$1"
SKILLS_INDEX=""
MODEL_CLI="provider"
PR_REPO="example/repo"
TRIAGE="no"
CLAIM_UNASSIGNED="yes"
MAX_CONCURRENT_RUNS="1"
GRAFT="off"
FLEET_PROGRESS_SUPERVISOR="off"
EXCLUDE_LABELS=""
EOF
}

run_tick() {
  HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
    XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
    TASKS_JSON="$TMP/tasks.json" \
    PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once --dry-run --explain dev
}

write_conf "Agent Blocked (Infra),Bugs"
order="$(run_tick | sed -n 's/^would pick up \([^ ]*\).*/\1/p' | paste -sd ' ' -)"
if [ "$order" != "AGTE-2 AGTE-3 AGTE-1" ]; then
  printf 'infra-first order=%s\n' "$order" >&2
  exit 1
fi

write_conf "Bugs,Agent Blocked (Infra)"
order="$(run_tick | sed -n 's/^would pick up \([^ ]*\).*/\1/p' | paste -sd ' ' -)"
if [ "$order" != "AGTE-3 AGTE-1 AGTE-2" ]; then
  printf 'bugs-first order=%s\n' "$order" >&2
  exit 1
fi

echo "section order verification passed"
