#!/usr/bin/env bash
# A 200-ticket fixture verifies that an ordinary delta tick stays O(pages + changes).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.config/agents" "$TMP/company" "$TMP/repo" "$TMP/bin" "$TMP/state/agent-board-poll"
printf '# company pack\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"

python3 - "$TMP/tasks.json" <<'PYEOF'
import json, sys
rows = []
for number in range(1, 201):
    rows.append({
        "id": number, "ticketNumber": "FAST-%d" % number, "section": "Queued",
        "title": "Fixture ticket %d" % number, "description": "fixture",
        "updatedAt": "2026-01-01T00:00:02Z" if number == 200 else "2026-01-01T00:00:00Z",
        "priority": "Normal", "dueDate": None, "assignees": [], "labels": [],
        "commentCount": 0,
    })
json.dump({"tasks": rows}, open(sys.argv[1], "w", encoding="utf-8"))
PYEOF

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$API_CALLS"
url="${!#}"
case "$url" in
  *'/mcp/tasks?'*'status=Archive'*) printf '%s\n200' '{"tasks":[],"total":0}' ;;
  *'/mcp/tasks?'*)
    offset="$(printf '%s' "$url" | sed -n 's/.*[?&]offset=\([0-9][0-9]*\).*/\1/p')"
    OFFSET="${offset:-0}" TASKS_JSON="$TASKS_JSON" python3 - <<'PY'
import json, os
rows = json.load(open(os.environ["TASKS_JSON"]))["tasks"]
print(json.dumps({"tasks": rows[int(os.environ["OFFSET"]):int(os.environ["OFFSET"])+100], "total": len(rows)}))
PY
    printf '\n200'
    ;;
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
chmod +x "$TMP/bin/"*

cat > "$TMP/home/.config/agents/fast.conf" <<EOF
AGENT_ID="agent-1"
AGENT_NAME="Fast Bot"
AGENT_KIND="worker"
AGENT_REPO="$TMP/repo"
AGENT_SLUG="fast"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/board"
WATCH_SECTIONS="Queued"
SKILLS_INDEX=""
MODEL_CLI="true"
PR_REPO="example/repo"
TRIAGE="no"
CLAIM_UNASSIGNED="yes"
MAX_CONCURRENT_RUNS="1"
GRAFT="off"
FLEET_PROGRESS_SUPERVISOR="off"
EOF

printf '2026-01-01T00:00:01Z\n' > "$TMP/state/agent-board-poll/fast.updated-cursor.15"
date +%s > "$TMP/state/agent-board-poll/fast.full-rescan.15"
printf '0\n' > "$TMP/state/agent-board-poll/fast.comment-cursor.15"
: > "$TMP/api.calls"
start="$(python3 -c 'import time; print(time.monotonic())')"
HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
  XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
  TASKS_JSON="$TMP/tasks.json" API_CALLS="$TMP/api.calls" \
  PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once --dry-run fast >/dev/null
end="$(python3 -c 'import time; print(time.monotonic())')"
calls="$(grep -cF 'https://' "$TMP/api.calls")"
elapsed="$(START="$start" END="$end" python3 -c 'import os; print("%.3f" % (float(os.environ["END"])-float(os.environ["START"])))')"
legacy_calls=204
if [ "$calls" -le 8 ]; then
  printf 'PASS %-36s 200 tickets use %s API calls (legacy fixture: %s), %ss\n' fast-tick-api-budget "$calls" "$legacy_calls" "$elapsed"
else
  printf 'FAIL %-36s used %s API calls, expected at most 8\n' fast-tick-api-budget "$calls"
  sed 's/.*https:/https:/' "$TMP/api.calls"
  exit 1
fi

: > "$TMP/api.calls"
RANKING_PASS_SECONDS=0 HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
  XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
  TASKS_JSON="$TMP/tasks.json" API_CALLS="$TMP/api.calls" \
  PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once fast >/dev/null
pending="$(HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
  XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
  TASKS_JSON="$TMP/tasks.json" API_CALLS="$TMP/api.calls" \
  PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once --dry-run fast)"
if printf '%s\n' "$pending" | grep -qF 'would pick up FAST-200'; then
  printf 'PASS %-36s %s\n' fast-tick-ranking-tail 'the 60-second boundary retains unranked changed tickets for the next tick'
else
  printf 'FAIL %-36s changed ticket disappeared after the ranking boundary\n' fast-tick-ranking-tail
  exit 1
fi
