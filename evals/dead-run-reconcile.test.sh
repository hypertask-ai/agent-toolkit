#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
wrong_pid=""
cleanup() {
  [ -z "$wrong_pid" ] || kill "$wrong_pid" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/home" "$TMP/config" "$TMP/bin" "$TMP/repo" "$TMP/company" "$TMP/state" "$TMP/worktrees"
printf '# skills\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *'/mcp/tasks?'*) cat "$MOCK_TASKS"; printf '\n200' ;;
  *'/mcp/comments?'*) printf '%s\n200' '{"comments":[]}' ;;
  *'/mcp/chat/rooms/pending') printf '{"messages":[{"projectId":5500,"roomId":"toolkit-room"}]}' ;;
  *'/mcp/chat/rooms/toolkit-room/messages') printf '{"success":true}' ;;
  *) printf '{}\n404' ;;
esac
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${GITHUB_RATE_LIMIT:-no}" = yes ] && [ "${1:-}" = api ]; then
  printf 'HTTP/2 403\nX-RateLimit-Reset: %s\n\n{"message":"API rate limit exceeded"}\n' \
    "${RATE_LIMIT_RESET:-1790000000}"
  printf 'API rate limit exceeded (HTTP 403)\n' >&2
  exit 1
fi
printf '[]\n'
EOF
cat > "$TMP/bin/model" <<'EOF'
#!/usr/bin/env bash
touch "$MOCK_MODEL_MARKER"
EOF
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
args=" $* "
argv=("$@")
value_after() {
  local wanted="$1" i
  for ((i=0;i<${#argv[@]}-1;i++)); do
    [ "${argv[$i]}" != "$wanted" ] || { printf '%s' "${argv[$((i+1))]}"; return; }
  done
}
case "$args" in
  *' project show '*)
    printf '%s\n' '{"project":{"ownerId":6,"sections":[{"title":"Backlog","isIntake":true},{"title":"In Progress"},{"title":"Review"}]}}'
    ;;
  *' task get '*) cat "$MOCK_TASKS" ;;
  *' comment list '*) printf '{"comments":[]}\n' ;;
  *' task unassign '*)
    ref="$(value_after unassign)"
    printf 'unassign\t%s\n' "$ref" >> "$MOCK_BOARD_LOG"
    REF="$ref" python3 - "$MOCK_TASKS" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
for task in doc["tasks"]:
    if task["ticketNumber"] == os.environ["REF"]:
        task["assignees"] = []
json.dump(doc, open(path, "w", encoding="utf-8"))
PYEOF
    ;;
  *' task move '*)
    ref="$(value_after move)"; section="$(value_after --section)"
    printf 'move\t%s\t%s\n' "$ref" "$section" >> "$MOCK_BOARD_LOG"
    REF="$ref" SECTION="$section" python3 - "$MOCK_TASKS" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
for task in doc["tasks"]:
    if task["ticketNumber"] == os.environ["REF"]:
        task["section"] = os.environ["SECTION"]
json.dump(doc, open(path, "w", encoding="utf-8"))
PYEOF
    ;;
  *' comment add '*)
    ref="$(value_after add)"; text="$(value_after --text)"; file="$(value_after --file)"
    [ -z "$file" ] || text="$(cat "$file")"
    printf 'comment\t%s\t%s\n' "$ref" "$text" >> "$MOCK_BOARD_LOG"
    printf '{"comment":{"id":1}}\n'
    ;;
  *' task create '*)
    printf 'create\t%s\n' "$*" >> "$MOCK_BOARD_LOG"
    printf '{"task":{"ticketNumber":"AGTE-999"}}\n'
    ;;
  *) printf '{}\n' ;;
esac
EOF
chmod +x "$TMP/bin/"*

cat > "$TMP/config/dev.conf" <<EOF
AGENT_ID="agent-dev"
AGENT_NAME="Dev"
AGENT_KIND="dev"
AGENT_REPO="$TMP/repo"
AGENT_SLUG="dev"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/board"
WATCH_SECTIONS="Backlog"
MODEL_CLI="$TMP/bin/model"
PR_REPO="example/repo"
PR_BRANCH_PREFIX="agent/dev-"
TRIAGE="no"
CLAIM_UNASSIGNED="yes"
WORKDIR_MODE="per-run"
WORKDIR_ROOT="$TMP/worktrees"
FLEET_PROGRESS_SUPERVISOR="off"
EOF

set_task() {
  local labels="${1:-[]}" human="${2:-[]}"
  LABELS="$labels" HUMAN="$human" python3 - "$TMP/tasks.json" <<'PYEOF'
import json, os, sys
labels = json.loads(os.environ["LABELS"])
humans = json.loads(os.environ["HUMAN"])
assignees = [{"agent": {"id": "agent-dev", "displayName": "Dev"}}]
assignees.extend({"id": value} for value in humans)
json.dump({"tasks": [{
    "id": "task-1", "ticketNumber": "TEST-1", "projectId": 15,
    "section": "In Progress", "title": "Change it", "description": "Open a PR",
    "assignees": assignees, "labels": [{"name": value} for value in labels],
    "commentCount": 0, "updatedAt": "2026-01-01T00:00:00Z"
}]}, open(sys.argv[1], "w", encoding="utf-8"))
PYEOF
}

write_record() {
  local started="$1" deaths="${2:-0}" kind="${3:-ticket}" pid="${4:-99999999}"
  mkdir -p "$TMP/state/agent-board-poll/run-records" "$TMP/worktrees/dev-TEST-1"
  touch -d '3 days ago' "$TMP/worktrees/dev-TEST-1"
  STARTED="$started" DEATHS="$deaths" KIND="$kind" PID_VALUE="$pid" python3 - "$TMP/state/agent-board-poll/run-records/dev-TEST-1.json" <<PYEOF
import json, os, sys
json.dump({
    "slug": "dev", "agent_id": "agent-dev", "pid": int(os.environ["PID_VALUE"]),
    "status": "running", "ref": "TEST-1", "task_id": "task-1", "board": "15",
    "origin_section": "Backlog", "started_at": os.environ["STARTED"],
    "workdir": "$TMP/worktrees/dev-TEST-1", "run_kind": os.environ["KIND"],
    "death_count": int(os.environ["DEATHS"])
}, open(sys.argv[1], "w", encoding="utf-8"))
PYEOF
}

reset_case() {
  rm -rf "$TMP/state" "$TMP/worktrees"
  mkdir -p "$TMP/state" "$TMP/worktrees"
  : > "$TMP/board.log"
  rm -f "$TMP/model-marker"
  set_task
}

run_tick() {
  env HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state" \
    COMPANY_SKILLS_DIR="$TMP/company" PATH="$TMP/bin:$PATH" MOCK_TASKS="$TMP/tasks.json" \
    MOCK_BOARD_LOG="$TMP/board.log" MOCK_MODEL_MARKER="$TMP/model-marker" CLEANUP_DOCKER=no \
    "$ROOT/scripts/agent-board-poll" --once --explain "$@" dev
}
run_reconciler() {
  env HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state" \
    COMPANY_SKILLS_DIR="$TMP/company" PATH="$TMP/bin:$PATH" MOCK_TASKS="$TMP/tasks.json" \
    MOCK_BOARD_LOG="$TMP/board.log" "$ROOT/scripts/agent-board-reconcile"
}
record="$TMP/state/agent-board-poll/run-records/dev-TEST-1.json"
pass() { printf 'PASS %-36s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %-36s %s\n' "$1" "$2"; exit 1; }

reset_case
write_record '2026-09-20T08:00:00+00:00'
run_tick > "$TMP/first.out" 2>&1
if grep -qx $'unassign\tTEST-1' "$TMP/board.log" \
   && grep -qx $'move\tTEST-1\tBacklog' "$TMP/board.log" \
   && [ "$(grep -c $'^comment\tTEST-1\t<p>Run 2026-09-20T08:00:00+00:00 died (pid is not running); requeued</p>$' "$TMP/board.log")" -eq 1 ] \
   && [ ! -e "$TMP/model-marker" ] && [ -d "$TMP/worktrees/dev-TEST-1" ] \
   && grep -qF 'This worktree is preserved for inspection.' "$TMP/worktrees/dev-TEST-1/.agent-run-preserved" \
   && RECORD="$record" python3 -c 'import json,os; r=json.load(open(os.environ["RECORD"])); assert r["status"] == "reconciled" and r["reason"] == "pid is not running" and r["death_count"] == 1 and r["reconciliation_action"] == "requeued" and r["keep_worktree"] is True' \
   && grep -qF "kept worktree $TMP/worktrees/dev-TEST-1" "$TMP/state/agent-board-poll/dev.log"; then
  pass dead-run-requeued 'a fake dead pid is marked, unassigned, requeued, commented once, and kept for inspection'
else
  fail dead-run-requeued "board=$(cat "$TMP/board.log") record=$(cat "$record") output=$(cat "$TMP/first.out")"
fi

reset_case
write_record '2026-09-20T08:30:00+00:00'
set +e
GITHUB_RATE_LIMIT=yes RATE_LIMIT_RESET=1790000123 run_tick > "$TMP/paused.out" 2>&1
paused_rc=$?
set -e
if [ "$paused_rc" -eq 75 ] \
   && grep -qx $'unassign\tTEST-1' "$TMP/board.log" \
   && grep -qx $'move\tTEST-1\tBacklog' "$TMP/board.log" \
   && grep -qF 'requeued' "$TMP/board.log" \
   && grep -qF "GitHub paused until $(date -d @1790000123 +%H:%M)" \
      "$TMP/state/agent-board-poll/dev.log"; then
  pass paused-dead-run-reconcile 'dead-run board reconciliation finishes before a paused tick exits 75'
else
  fail paused-dead-run-reconcile "rc=$paused_rc board=$(cat "$TMP/board.log") output=$(cat "$TMP/paused.out")"
fi
rm -f "$TMP/state/agent-board-poll/pr-cache/example__repo.json.rate-limit"

set_task
: > "$TMP/board.log"
write_record '2026-09-20T09:00:00+00:00' 1
run_tick > "$TMP/second.out" 2>&1
run_tick --ticket TEST-1 --board 15 > "$TMP/third.out" 2>&1
run_reconciler > "$TMP/second-reconciler.out" 2>&1
if [ "$(grep -c $'^create\t' "$TMP/board.log")" -eq 1 ] \
   && grep -q -- '--section Review --priority high' "$TMP/board.log" \
   && ! grep -Eq '^(unassign|move|comment)\tTEST-1' "$TMP/board.log" \
   && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = 'In Progress' ] \
   && [ ! -e "$TMP/model-marker" ] \
   && grep -qF 'two dead runs raised an alarm, so a third run needs intervention' "$TMP/third.out" \
   && RECORD="$record" python3 -c 'import json,os; r=json.load(open(os.environ["RECORD"])); assert r["status"] == "reconciled" and r["death_count"] == 2 and r["reconciliation_action"] == "alarm"'; then
  pass second-death-alarm 'the second death raises the AGTE-118 alarm instead of enabling a third run'
else
  fail second-death-alarm "board=$(cat "$TMP/board.log") record=$(cat "$record") output=$(cat "$TMP/second.out")"
fi

reset_case
sleep 60 &
wrong_pid=$!
write_record '2026-09-20T10:00:00+00:00' 0 ticket "$wrong_pid"
run_tick > "$TMP/wrong-command.out" 2>&1
kill "$wrong_pid" 2>/dev/null || true
wait "$wrong_pid" 2>/dev/null || true
wrong_pid=""
if RECORD="$record" python3 -c 'import json,os; r=json.load(open(os.environ["RECORD"])); assert r["reason"] == "pid belongs to a different command" and r["reconciliation_action"] == "requeued"'; then
  pass reused-pid-requeued 'a live pid owned by another command is treated as a dead run'
else
  fail reused-pid-requeued "record=$(cat "$record") output=$(cat "$TMP/wrong-command.out")"
fi

reset_case
set_task '["valentin"]'
write_record '2026-09-20T11:00:00+00:00'
run_tick > "$TMP/owner-hold.out" 2>&1
run_reconciler > "$TMP/owner-reconciler.out" 2>&1
if [ ! -s "$TMP/board.log" ] \
   && RECORD="$record" python3 -c 'import json,os; assert json.load(open(os.environ["RECORD"]))["reconciliation_action"] == "owner-hold"'; then
  pass dead-run-owner-hold 'a protected owner ticket is recorded without changing its assignment or column'
else
  fail dead-run-owner-hold "board=$(cat "$TMP/board.log") record=$(cat "$record")"
fi

reset_case
write_record '2026-09-20T12:00:00+00:00'
printf '%s\n' '{"ticket":"TEST-1","pr":9,"state":"red"}' > "$TMP/state/agent-board-poll/dev.blocked"
run_tick > "$TMP/pr-fix.out" 2>&1
run_reconciler > "$TMP/pr-fix-reconciler.out" 2>&1
if [ ! -s "$TMP/board.log" ] \
   && RECORD="$record" python3 -c 'import json,os; assert json.load(open(os.environ["RECORD"]))["reconciliation_action"] == "pr-binding"'; then
  pass dead-fix-keeps-binding 'a dead fix-round run does not unassign or move its PR-bound ticket'
else
  fail dead-fix-keeps-binding "board=$(cat "$TMP/board.log") record=$(cat "$record")"
fi
