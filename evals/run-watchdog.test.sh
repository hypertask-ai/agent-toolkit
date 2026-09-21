#!/usr/bin/env bash
# Watchdog and last-moment claim checks use local command stubs only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/config" "$TMP/bin" "$TMP/repo" "$TMP/company" "$TMP/state"
printf '# skills\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *'/mcp/tasks?ticket_number='*)
    if [ "${MOCK_CLAIM_GET_ERROR:-no}" = yes ]; then
      printf '{}\n500'
    elif [ "${MOCK_CLAIM_AT_GET:-no}" = yes ]; then
      python3 - "$MOCK_TASKS" <<'PYEOF'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
task = doc["tasks"][0]
task["section"] = "In Progress"
task["assignees"] = [{"agent": {"id": "agent-other", "displayName": "Dev 1"}}]
print(json.dumps(doc))
PYEOF
      printf '\n200'
    else
      cat "$MOCK_TASKS"
      printf '\n200'
    fi
    ;;
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
case "${MOCK_MODEL_MODE:-stall}" in
  stall)
    trap 'touch "$MOCK_MODEL_TERM"; exit 143' TERM
    while :; do sleep 10; done
    ;;
  waiting)
    : > "$MOCK_MODEL_DONE"
    exec sleep 10
    ;;
  done)
    touch "$MOCK_MODEL_DONE"
    ;;
  max)
    trap 'touch "$MOCK_MODEL_TERM"; exit 143' TERM
    while :; do printf 'working\n'; sleep 0.2; done
    ;;
  stderr)
    for _ in $(seq 1 15); do printf 'progress\r' >&2; sleep 0.2; done
    touch "$MOCK_MODEL_DONE"
    ;;
  cpu)
    python3 - <<'PYEOF'
import time
end = time.monotonic() + 3
while time.monotonic() < end:
    pass
PYEOF
    touch "$MOCK_MODEL_DONE"
    ;;
  worktree)
    for _ in $(seq 1 15); do touch "$MOCK_WORKTREE_FILE"; sleep 0.2; done
    touch "$MOCK_MODEL_DONE"
    ;;
esac
EOF
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
args=" $* "
case "$args" in
  *' task get '*)
    if [ "${MOCK_CLAIM_AT_GET:-no}" = yes ]; then
      python3 - "$MOCK_TASKS" <<'PYEOF'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
task = doc["tasks"][0]
task["section"] = "In Progress"
task["assignees"] = [{"agent": {"id": "agent-other", "displayName": "Dev 1"}}]
print(json.dumps(doc))
PYEOF
    else
      cat "$MOCK_TASKS"
    fi
    ;;
  *' comment list '*) printf '{"comments":[]}\n' ;;
  *' task assign '*)
    printf 'assign TEST-1 agent-dev\n' >> "$MOCK_BOARD_LOG"
    python3 - "$MOCK_TASKS" <<'PYEOF'
import json, sys
path=sys.argv[1]; doc=json.load(open(path)); doc["tasks"][0]["assignees"]=[{"agent":{"id":"agent-dev","displayName":"Dev 2"}}]; json.dump(doc,open(path,"w"))
PYEOF
    ;;
  *' task unassign '*)
    printf 'unassign TEST-1 agent-dev\n' >> "$MOCK_BOARD_LOG"
    python3 - "$MOCK_TASKS" <<'PYEOF'
import json, sys
path=sys.argv[1]; doc=json.load(open(path)); doc["tasks"][0]["assignees"]=[]; json.dump(doc,open(path,"w"))
PYEOF
    ;;
  *' task move '*)
    argv=("$@"); section=""
    for ((i=0;i<${#argv[@]};i++)); do [ "${argv[$i]}" != --section ] || section="${argv[$((i+1))]}"; done
    printf 'move TEST-1 %s\n' "$section" >> "$MOCK_BOARD_LOG"
    SECTION="$section" python3 - "$MOCK_TASKS" <<'PYEOF'
import json, os, sys
path=sys.argv[1]; doc=json.load(open(path)); doc["tasks"][0]["section"]=os.environ["SECTION"]; json.dump(doc,open(path,"w"))
PYEOF
    ;;
  *' comment add '*) printf 'comment %s\n' "$*" >> "$MOCK_BOARD_LOG" ;;
  *' project show '*) printf '{"project":{"ownerId":6}}\n' ;;
  *) printf '{}\n' ;;
esac
EOF
chmod +x "$TMP/bin/"*

cat > "$TMP/config/dev.conf" <<EOF
AGENT_ID="agent-dev"
AGENT_NAME="Dev 2"
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
RUN_STALL_SECONDS="1"
RUN_MAX_SECONDS="30"
FLEET_PROGRESS_SUPERVISOR="off"
EOF

reset_case() {
  rm -rf "$TMP/state" "$TMP/repo"; mkdir -p "$TMP/state" "$TMP/repo"
  : > "$TMP/board.log"
  rm -f "$TMP/model-term" "$TMP/model-done"
  cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","projectId":15,"section":"Backlog","title":"Change it","description":"Open a PR","assignees":[],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
}
RUNNER="$ROOT/scripts/agent-board-poll"
run_tick() {
  env HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state" \
    COMPANY_SKILLS_DIR="$TMP/company" PATH="$TMP/bin:$PATH" MOCK_TASKS="$TMP/tasks.json" \
    ADAPTER_CLAIM_TEST_JITTER_SECONDS=0 ADAPTER_CLAIM_TEST_SETTLE_SECONDS=0 \
    MOCK_BOARD_LOG="$TMP/board.log" MOCK_MODEL_TERM="$TMP/model-term" \
    MOCK_MODEL_DONE="$TMP/model-done" MOCK_WORKTREE_FILE="$TMP/repo/progress" \
    "$@" "$RUNNER" --once --explain dev
}

reset_case
run_tick MOCK_MODEL_MODE=stall >"$TMP/stall.out" 2>&1
record="$TMP/state/agent-board-poll/run-records/dev-TEST-1.json"
if [ -f "$TMP/model-term" ] \
   && [ "$(grep -c '^comment .*watchdog: no activity for 1 min' "$TMP/board.log")" -eq 1 ] \
   && grep -qxF 'unassign TEST-1 agent-dev' "$TMP/board.log" \
   && grep -qxF 'move TEST-1 Backlog' "$TMP/board.log" \
   && RECORD="$record" python3 -c 'import json,os,sys; r=json.load(open(os.environ["RECORD"])); sys.exit(0 if r["status"]=="FAILED" and r["reason"]=="watchdog: no activity for 1 min" and r.get("last_output_at") else 1)'; then
  printf 'PASS %-36s %s\n' stalled-run-watchdog 'inactive model is terminated, recorded, commented once, unassigned, and restored'
else
  echo "FAIL stalled-run-watchdog log=$(cat "$TMP/board.log") record=$(cat "$record" 2>/dev/null) output=$(cat "$TMP/stall.out")"; exit 1
fi

# Keep the dead-run case fast, but leave enough scheduling margin for the
# progress fixtures to run between watchdog samples on a busy host.
sed -i 's/RUN_STALL_SECONDS="1"/RUN_STALL_SECONDS="2"/' "$TMP/config/dev.conf"
run_liveness_case() {
  local mode="$1" label="$2" description="$3"
  reset_case
  run_tick MOCK_MODEL_MODE="$mode" >"$TMP/$mode.out" 2>&1
  if [ -f "$TMP/model-done" ] && [ ! -f "$TMP/model-term" ] \
      && ! grep -q 'watchdog: no activity' "$TMP/board.log"; then
    printf 'PASS %-36s %s\n' "$label" "$description"
  else
    echo "FAIL $label log=$(cat "$TMP/board.log") output=$(cat "$TMP/$mode.out")"; exit 1
  fi
}

run_liveness_case stderr stderr-progress-liveness 'stderr progress keeps a stdout-silent model alive'
run_liveness_case cpu cpu-time-liveness 'process-group CPU time keeps a silent model alive'
run_liveness_case worktree worktree-change-liveness 'worktree changes keep a silent model alive'

sed -i 's/RUN_STALL_SECONDS="2"/RUN_STALL_SECONDS="10"/; s/RUN_MAX_SECONDS="30"/RUN_MAX_SECONDS="2"/' "$TMP/config/dev.conf"
reset_case
run_tick MOCK_MODEL_MODE=max >"$TMP/max.out" 2>&1
record="$TMP/state/agent-board-poll/run-records/dev-TEST-1.json"
if [ -f "$TMP/model-term" ] \
   && [ "$(grep -c '^comment .*watchdog: over max run time' "$TMP/board.log")" -eq 1 ] \
   && RECORD="$record" python3 -c 'import json,os,sys; r=json.load(open(os.environ["RECORD"])); sys.exit(0 if r["status"]=="FAILED" and r["reason"]=="watchdog: over max run time" else 1)'; then
  printf 'PASS %-36s %s\n' maximum-run-watchdog 'output-producing model is terminated at the absolute run limit'
else
  echo "FAIL maximum-run-watchdog log=$(cat "$TMP/board.log") record=$(cat "$record" 2>/dev/null) output=$(cat "$TMP/max.out")"; exit 1
fi
sed -i 's/RUN_STALL_SECONDS="10"/RUN_STALL_SECONDS="2"/; s/RUN_MAX_SECONDS="2"/RUN_MAX_SECONDS="30"/' "$TMP/config/dev.conf"

reset_case
mkdir -p "$TMP/state/agent-board-poll"
printf '%s\n' '{"wait":{"state":"awaiting-merge","ticket":"TEST-1"}}' > "$TMP/state/agent-board-poll/dev.progress.json"
record="$TMP/state/agent-board-poll/run-records/dev-TEST-1.json"
waiting_record="$TMP/waiting-record.json"
run_tick MOCK_MODEL_MODE=waiting >"$TMP/waiting.out" 2>&1 &
waiting_tick_pid=$!
for _ in $(seq 1 200); do
  if RECORD="$record" python3 -c 'import json,os,sys; r=json.load(open(os.environ["RECORD"])); sys.exit(0 if r.get("waiting_on_pr") is True and r.get("wait_state")=="awaiting-merge" and r.get("last_output_at") else 1)' 2>/dev/null; then
    cp "$record" "$waiting_record"
    break
  fi
  kill -0 "$waiting_tick_pid" 2>/dev/null || break
  sleep 0.1
done
wait "$waiting_tick_pid"
if [ -f "$TMP/model-done" ] && [ ! -f "$TMP/model-term" ] && [ -f "$waiting_record" ]; then
  printf 'PASS %-36s %s\n' awaiting-merge-watchdog-exempt 'PR wait survives the silence threshold and publishes waiting state'
else
  echo "FAIL awaiting-merge-watchdog-exempt record=$(cat "$record" 2>/dev/null) output=$(cat "$TMP/waiting.out")"; exit 1
fi

reset_case
run_tick MOCK_CLAIM_AT_GET=yes MOCK_MODEL_MODE=waiting >"$TMP/claim.out" 2>&1
if [ "$(grep -cF 'claim-check TEST-1: claimant Dev 1' "$TMP/claim.out")" -eq 1 ] \
   && ! grep -Eq '^(assign|move|comment) ' "$TMP/board.log" \
   && [ ! -f "$TMP/model-done" ]; then
  printf 'PASS %-36s %s\n' claim-rechecked-at-start 'the real tick path sees a foreign API assignee and leaves the ticket untouched'
else
  echo "FAIL claim-rechecked-at-start log=$(cat "$TMP/board.log") output=$(cat "$TMP/claim.out")"; exit 1
fi

reset_case
run_tick MOCK_CLAIM_GET_ERROR=yes MOCK_MODEL_MODE=waiting >"$TMP/claim-error.out" 2>&1
if [ "$(grep -cF 'claim-check TEST-1: error (could not re-read ticket)' "$TMP/claim-error.out")" -eq 1 ] \
   && ! grep -Eq '^(assign|move|comment) ' "$TMP/board.log" \
   && [ ! -f "$TMP/model-done" ]; then
  printf 'PASS %-36s %s\n' claim-check-api-error 'a failed last-moment API read is explained and fails closed'
else
  echo "FAIL claim-check-api-error log=$(cat "$TMP/board.log") output=$(cat "$TMP/claim-error.out")"; exit 1
fi

mkdir -p "$TMP/core"
cp -a "$ROOT/scripts" "$ROOT/adapters" "$TMP/core/"
python3 - "$TMP/core/adapters/hypertask/adapter.sh" <<'PYEOF'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
start = text.index("# adapter_claimed_by_other <token-file>")
end = text.index("# adapter_assign_task <board-cli>", start)
path.write_text(text[:start] + text[end:], encoding="utf-8")
PYEOF
RUNNER="$TMP/core/scripts/agent-board-poll"
reset_case
run_tick MOCK_CLAIM_AT_GET=yes MOCK_MODEL_MODE=waiting >"$TMP/claim-adapter-missing.out" 2>&1
if [ "$(grep -cF 'claim-check TEST-1: error (adapter has no ownership re-read)' "$TMP/claim-adapter-missing.out")" -eq 1 ] \
   && ! grep -Eq '^(assign|move|comment) ' "$TMP/board.log" \
   && [ ! -f "$TMP/model-done" ]; then
  printf 'PASS %-36s %s\n' claim-check-adapter-missing 'a stale adapter cannot silently bypass the ownership re-read'
else
  echo "FAIL claim-check-adapter-missing log=$(cat "$TMP/board.log") output=$(cat "$TMP/claim-adapter-missing.out")"; exit 1
fi
RUNNER="$ROOT/scripts/agent-board-poll"

reset_case
run_tick MOCK_MODEL_MODE=done >"$TMP/no-claim.out" 2>&1
if [ "$(grep -cF 'claim-check TEST-1: no claimant' "$TMP/no-claim.out")" -eq 1 ] \
   && [ -f "$TMP/model-done" ]; then
  printf 'PASS %-36s %s\n' claim-check-no-claimant 'a clear last-moment API read is explained before the run starts'
else
  echo "FAIL claim-check-no-claimant log=$(cat "$TMP/board.log") output=$(cat "$TMP/no-claim.out")"; exit 1
fi

sed -i 's/AGENT_KIND="dev"/AGENT_KIND="worker"/' "$TMP/config/dev.conf"
reset_case
run_tick MOCK_MODEL_MODE=done >"$TMP/claim-gated.out" 2>&1
if [ "$(grep -cF 'claim-check TEST-1: skipped-because-gated (agent kind worker)' "$TMP/claim-gated.out")" -eq 1 ] \
   && [ -f "$TMP/model-done" ]; then
  printf 'PASS %-36s %s\n' claim-check-gated 'a non-development run explains why no ownership re-read was made'
else
  echo "FAIL claim-check-gated log=$(cat "$TMP/board.log") output=$(cat "$TMP/claim-gated.out")"; exit 1
fi
