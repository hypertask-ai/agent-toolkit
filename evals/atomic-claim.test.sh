#!/usr/bin/env bash
# Two real runner entry paths race against one local fake board.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/config" "$TMP/bin" "$TMP/repo" "$TMP/company" "$TMP/state"
printf '# skills\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token-a\n' > "$TMP/token-a"
printf 'token-b\n' > "$TMP/token-b"
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","projectId":15,"section":"Backlog","title":"Race it","description":"Exactly one agent should start","assignees":[],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
: > "$TMP/board.log"

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *'/mcp/tasks?'*) cat "$MOCK_TASKS"; printf '\n200' ;;
  *'/mcp/comments?'*) printf '%s\n200' '{"comments":[]}' ;;
  *) printf '{}\n404' ;;
esac
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
cat > "$TMP/bin/model" <<'EOF'
#!/usr/bin/env bash
printf 'model %s\n' "$AGENT_ID" >> "$MOCK_BOARD_LOG"
EOF
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
argv=("$@")
value_after() {
  local wanted="$1" i
  for ((i=0;i<${#argv[@]}-1;i++)); do
    [ "${argv[$i]}" != "$wanted" ] || { printf '%s' "${argv[$((i+1))]}"; return; }
  done
}
token="$(value_after --token || true)"
caller="agent-${token#token-}"
case " $* " in
  *' task get '*) cat "$MOCK_TASKS" ;;
  *' comment list '*) printf '{"comments":[]}\n' ;;
  *' project show '*) printf '{"project":{"ownerId":6}}\n' ;;
  *' task assign '*)
    assignee="$(value_after --assignee)"
    printf 'assign %s\n' "$assignee" >> "$MOCK_BOARD_LOG"
    (
      flock 9
      grep -qxF "$assignee" "$MOCK_ASSIGNMENTS" 2>/dev/null || printf '%s\n' "$assignee" >> "$MOCK_ASSIGNMENTS"
      if [ "$(wc -l < "$MOCK_ASSIGNMENTS")" -eq 2 ]; then
        python3 - "$MOCK_TASKS" <<'PYEOF'
import json, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
doc["tasks"][0]["assignees"] = [
    {"agent": {"id": "agent-a", "displayName": "Agent A"}},
    {"agent": {"id": "agent-b", "displayName": "Agent B"}},
]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(doc, handle)
PYEOF
        : > "$MOCK_ASSIGN_READY"
      fi
    ) 9>"$MOCK_LOCK"
    for _ in $(seq 1 500); do
      [ ! -f "$MOCK_ASSIGN_READY" ] || exit 0
      /bin/sleep 0.01
    done
    exit 1
    ;;
  *' task unassign '*)
    assignee="$(value_after --assignee)"
    printf 'unassign %s\n' "$assignee" >> "$MOCK_BOARD_LOG"
    (
      flock 9
      ASSIGNEE="$assignee" python3 - "$MOCK_TASKS" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
doc["tasks"][0]["assignees"] = [
    row for row in doc["tasks"][0]["assignees"]
    if str((row.get("agent") or {}).get("id") or "") != os.environ["ASSIGNEE"]
]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(doc, handle)
PYEOF
    ) 9>"$MOCK_LOCK"
    ;;
  *' comment add '*)
    printf 'comment %s %s\n' "$caller" "$(value_after --text)" >> "$MOCK_BOARD_LOG"
    printf 'comment added\n'
    ;;
  *' task move '*)
    section="$(value_after --section)"
    printf 'move %s %s\n' "$caller" "$section" >> "$MOCK_BOARD_LOG"
    ;;
  *) printf '{}\n' ;;
esac
EOF
chmod +x "$TMP/bin/"*

for suffix in a b; do
  name="Agent ${suffix^^}"
  cat > "$TMP/config/dev-$suffix.conf" <<EOF
AGENT_ID="agent-$suffix"
AGENT_NAME="$name"
AGENT_KIND="dev"
AGENT_REPO="$TMP/repo"
AGENT_SLUG="dev-$suffix"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$TMP/token-$suffix"
BOARD_CLI="$TMP/bin/board-$suffix"
WATCH_SECTIONS="Backlog"
MODEL_CLI="$TMP/bin/model"
PR_REPO="example/repo"
PR_BRANCH_PREFIX="agent/dev-$suffix-"
TRIAGE="no"
CLAIM_UNASSIGNED="yes"
FLEET_PROGRESS_SUPERVISOR="off"
EOF
done

export HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state"
export COMPANY_SKILLS_DIR="$TMP/company" PATH="$TMP/bin:$PATH"
export MOCK_TASKS="$TMP/tasks.json" MOCK_BOARD_LOG="$TMP/board.log"
export MOCK_ASSIGNMENTS="$TMP/assignments" MOCK_ASSIGN_READY="$TMP/assign-ready" MOCK_LOCK="$TMP/board.lock"
export ADAPTER_CLAIM_TEST_JITTER_SECONDS=0 ADAPTER_CLAIM_TEST_SETTLE_SECONDS=0
: > "$MOCK_ASSIGNMENTS"

"$ROOT/scripts/agent-board-poll" --once --explain dev-a > "$TMP/a.out" 2>&1 &
a_pid=$!
"$ROOT/scripts/agent-board-poll" --once --explain --ticket TEST-1 --board 15 dev-b > "$TMP/b.out" 2>&1 &
b_pid=$!
wait "$a_pid"
wait "$b_pid"

keeper="$(python3 - "$TMP/tasks.json" <<'PYEOF'
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8"))["tasks"][0]["assignees"]
print(" ".join(str((row.get("agent") or {}).get("id") or "") for row in rows))
PYEOF
)"
claim_comments="$(grep -c '^comment .*<p><strong>Claimed\.</strong>' "$TMP/board.log" || true)"
models="$(grep -c '^model ' "$TMP/board.log" || true)"
backoffs="$(cat "$TMP/a.out" "$TMP/b.out" | grep -cF 'claim TEST-1: backed off (lost deterministic tie-break to Agent A)' || true)"
if [ "$keeper" = agent-a ] \
   && [ "$(sort -u "$MOCK_ASSIGNMENTS" | paste -sd ' ' -)" = 'agent-a agent-b' ] \
   && grep -qxF 'unassign agent-b' "$TMP/board.log" \
   && [ "$claim_comments" -eq 1 ] \
   && [ "$models" -eq 1 ] \
   && [ "$backoffs" -eq 1 ]; then
  echo 'PASS atomic-claim-race                   poll and event runners both assign, lower id keeps the ticket, and only it comments and starts'
else
  echo "FAIL atomic-claim-race keeper=$keeper comments=$claim_comments models=$models backoffs=$backoffs log=$(cat "$TMP/board.log") a=$(cat "$TMP/a.out") b=$(cat "$TMP/b.out")"
  exit 1
fi
