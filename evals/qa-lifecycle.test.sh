#!/usr/bin/env bash
# QA lifecycle checks use isolated board and model stubs; no board is contacted.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/home" "$TMP/config" "$TMP/bin" "$TMP/repo" "$TMP/company" "$TMP/state" \
  "$TMP/runtime" "$TMP/identity-shims"
export XDG_RUNTIME_DIR="$TMP/runtime"
export AGENT_IDENTITY_SHIM_DIR="$TMP/identity-shims"
printf '# company skills\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *'/mcp/tasks?'*) cat "$MOCK_TASKS"; printf '\n200' ;;
  *'/mcp/comments?'*) cat "$MOCK_COMMENTS"; printf '\n200' ;;
  *) printf '{}\n404' ;;
esac
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
cat > "$TMP/bin/model" <<'EOF'
#!/usr/bin/env bash
prompt="${!#}"
printf 'model ran\n' >> "$MOCK_MODEL_LOG"
printf '%s\n' "$prompt" >> "${MOCK_PROMPT_LOG:-/dev/null}"
verdict="$MOCK_VERDICT"
if [[ "$prompt" == *'QA VERDICT RETRY:'* ]]; then
  verdict="${MOCK_RETRY_VERDICT:-$MOCK_VERDICT}"
fi
case "$verdict" in
  Done) text='<p><strong>Done: QA passed every acceptance step.</strong></p><p>Next: Release the verified change.</p>' ;;
  Handoff) text='<p><strong>Handoff: Dev must fix the failing payment step.</strong></p><p>Next: Fix the payment step.</p>' ;;
  Question) text='<p><strong>Question: QA needs test credentials.</strong></p><p>Can the manager provide them?</p>' ;;
  Unmarked) text='<p><strong>QA passed every acceptance step.</strong></p><p>Ready to release.</p>' ;;
esac
"$AGENT_BOARD_CLI" comment add TEST-1 --text "$text" >/dev/null
EOF
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
args=" $* "
case "$args" in
  *' project show '*)
    printf '%s\n' '{"project":{"id":15,"ownerId":6,"sections":[{"name":"Bugs","isIntake":true},{"name":"In Progress"},{"name":"QA"},{"name":"Done"},{"name":"Agent Blocked (Infra)"}]}}'
    ;;
  *' task get '*) cat "$MOCK_TASKS" ;;
  *' comment list '*) cat "$MOCK_COMMENTS" ;;
  *' comment add '*)
    text=""
    ref=""
    argv=("$@")
    for ((i = 0; i < ${#argv[@]}; i++)); do
      [ "${argv[$i]}" = "add" ] && ref="${argv[$((i + 1))]:-}"
      [ "${argv[$i]}" = "--text" ] && text="${argv[$((i + 1))]:-}"
    done
    if [ "$ref" = "BOARD-HEALTH" ]; then
      printf 'health %s\n' "$text" >> "$MOCK_BOARD_LOG"
    else
      TEXT="$text" python3 - "$MOCK_COMMENTS" <<'PYEOF'
import datetime, json, os, sys
path = sys.argv[1]
try:
    doc = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    doc = {"comments": []}
rows = doc.get("comments") or []
rows.append({"id": 100 + len(rows), "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
             "agent": {"id": "agent-qa", "displayName": "QA Runner"}, "text": os.environ["TEXT"]})
with open(path, "w", encoding="utf-8") as handle:
    json.dump({"comments": rows}, handle)
PYEOF
    fi
    printf 'comment added\n'
    ;;
  *' task move '*)
    section=""
    argv=("$@")
    for ((i = 0; i < ${#argv[@]}; i++)); do
      [ "${argv[$i]}" = "--section" ] && section="${argv[$((i + 1))]:-}"
    done
    printf 'move TEST-1 %s\n' "$section" >> "$MOCK_BOARD_LOG"
    [ "${MOCK_MOVE_FAIL:-no}" != "yes" ] || [ "$section" != "Done" ]
    ;;
  *' task unassign '*)
    assignee=""
    argv=("$@")
    for ((i = 0; i < ${#argv[@]}; i++)); do
      [ "${argv[$i]}" = "--assignee" ] && assignee="${argv[$((i + 1))]:-}"
    done
    printf 'unassign TEST-1 %s\n' "$assignee" >> "$MOCK_BOARD_LOG"
    ;;
  *) printf '{}\n' ;;
esac
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/gh" "$TMP/bin/model" "$TMP/bin/hypertask"

cat > "$TMP/config/qa-runner.conf" <<EOF
AGENT_ID="agent-qa"
AGENT_NAME="QA Runner"
AGENT_KIND="qa"
AGENT_REPO="$TMP/repo"
AGENT_SLUG="qa-runner"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/board"
WATCH_SECTIONS="QA"
SKILLS_INDEX=""
MODEL_CLI="$TMP/bin/model"
PR_REPO="example/repo"
TRIAGE="no"
CLAIM_UNASSIGNED="no"
FLEET_PROGRESS_SUPERVISOR="off"
EOF

run_case() {
  local verdict="$1" labels="$2" comments="$3" assignees move_fail="${5:-no}" retry_verdict="${6:-}"
  if [ "$#" -ge 4 ]; then
    assignees="$4"
  else
    assignees='[{"id":40,"agent":{"id":"agent-dev","displayName":"Dev"}},{"id":41,"agent":{"id":"agent-qa","displayName":"QA Runner"}}]'
  fi
  rm -rf "$TMP/state"; mkdir -p "$TMP/state/agent-board-poll"
  if [ "$move_fail" = "yes" ]; then
    printf '%s\n' '{"boards":{"15":{"ref":"BOARD-HEALTH"}}}' > "$TMP/state/agent-board-poll/board-health.json"
  fi
  : > "$TMP/board.log"; : > "$TMP/model.log"; : > "$TMP/prompt.log"
  cat > "$TMP/tasks.json" <<EOF
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","projectId":15,"section":"QA","title":"Verify checkout","description":"Test every acceptance step","assignees":$assignees,"labels":$labels,"commentCount":1}]}
EOF
  printf '%s\n' "$comments" > "$TMP/comments.json"
  set +e
  env -u AGENT_ORIGINAL_PATH -u AGENT_IDENTITY_PATH \
    HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state" \
    COMPANY_SKILLS_DIR="$TMP/company" PATH="$TMP/bin:$PATH" MOCK_VERDICT="$verdict" \
    MOCK_RETRY_VERDICT="$retry_verdict" MOCK_MOVE_FAIL="$move_fail" \
    MOCK_TASKS="$TMP/tasks.json" MOCK_COMMENTS="$TMP/comments.json" \
    MOCK_BOARD_LOG="$TMP/board.log" MOCK_MODEL_LOG="$TMP/model.log" MOCK_PROMPT_LOG="$TMP/prompt.log" \
    "$ROOT/scripts/agent-board-poll" --once qa-runner > "$TMP/out" 2>&1
  printf '%s\n' "$?" > "$TMP/exit"
  set -e
}

run_case Done '[]' '{"comments":[]}'
if grep -qxF 'move TEST-1 Done' "$TMP/board.log" \
   && grep -qF 'QA run fallback moved TEST-1 to Done from verdict Done' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok qa-pass-fallback-move 'a Done verdict without a model move is moved to Done'
else
  bad qa-pass-fallback-move "board=$(cat "$TMP/board.log") output=$(cat "$TMP/out")"
fi
if grep -qF "MANDATORY: your final verdict comment's plain text must start with exactly one of" "$TMP/prompt.log"; then
  ok qa-prompt-requires-marker 'the QA prompt makes a verdict marker mandatory'
else
  bad qa-prompt-requires-marker "prompt=$(cat "$TMP/prompt.log")"
fi
if [ -x "$AGENT_IDENTITY_SHIM_DIR/qa-runner/hypertask" ] \
   && [ ! -e "$XDG_RUNTIME_DIR/agent-identity-shims/qa-runner/hypertask" ]; then
  ok qa-identity-shim-isolated 'the QA runner cannot collide with host identity shims'
else
  bad qa-identity-shim-isolated 'the QA eval wrote its identity shim outside the private directory'
fi

run_case Unmarked '[]' '{"comments":[]}' \
  '[{"id":40,"agent":{"id":"agent-dev","displayName":"Dev"}},{"id":41,"agent":{"id":"agent-qa","displayName":"QA Runner"}}]' no Done
if [ "$(grep -cFx 'model ran' "$TMP/model.log")" -eq 2 ] \
   && grep -qxF 'move TEST-1 Done' "$TMP/board.log" \
   && ! grep -qF 'Agent Blocked (Infra)' "$TMP/board.log" \
   && ! grep -qF 'exited 65' "$TMP/out" \
   && grep -qF 'QA verdict retry for TEST-1 returned a marked verdict' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok qa-unmarked-retry-pass 'an unmarked response gets one retry and its marked verdict completes'
else
  bad qa-unmarked-retry-pass "exit=$(cat "$TMP/exit") board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
fi

run_case Unmarked '[]' '{"comments":[]}' \
  '[{"id":40,"agent":{"id":"agent-dev","displayName":"Dev"}},{"id":41,"agent":{"id":"agent-qa","displayName":"QA Runner"}}]' no Unmarked
if [ "$(grep -cFx 'model ran' "$TMP/model.log")" -eq 2 ] \
   && grep -qxF 'move TEST-1 QA' "$TMP/board.log" \
   && ! grep -qF 'Agent Blocked (Infra)' "$TMP/board.log" \
   && grep -qF 'exited 65' "$TMP/out" \
   && grep -qF 'no verdict marker after one retry' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok qa-unmarked-retry-fails-in-qa 'two unmarked responses fail once without entering a human lane'
else
  bad qa-unmarked-retry-fails-in-qa "exit=$(cat "$TMP/exit") board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
fi

run_case Handoff '[]' '{"comments":[]}'
if grep -qxF 'move TEST-1 Bugs' "$TMP/board.log" \
   && grep -qxF 'unassign TEST-1 agent-dev' "$TMP/board.log" \
   && grep -qxF 'unassign TEST-1 agent-qa' "$TMP/board.log"; then
  ok qa-fail-intake-unassigned 'a Handoff verdict returns to first intake with no assignees'
else
  bad qa-fail-intake-unassigned "board=$(cat "$TMP/board.log") output=$(cat "$TMP/out")"
fi

run_case Question '[]' '{"comments":[]}'
if grep -qxF 'move TEST-1 Agent Blocked (Infra)' "$TMP/board.log" \
   && ! grep -q '^unassign ' "$TMP/board.log"; then
  ok qa-blocked-manager-review 'a Question verdict moves to the blocked column'
else
  bad qa-blocked-manager-review "board=$(cat "$TMP/board.log") output=$(cat "$TMP/out")"
fi

run_case Done '[{"name":"valentin"}]' '{"comments":[]}'
if [ ! -s "$TMP/board.log" ] && [ ! -s "$TMP/model.log" ] \
   && grep -qF 'pickup skipped for TEST-1: label valentin' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok qa-valentin-label-skip 'a valentin-labelled ticket is not run or moved'
else
  bad qa-valentin-label-skip "board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
fi
env -u AGENT_ORIGINAL_PATH -u AGENT_IDENTITY_PATH \
  HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state" \
  COMPANY_SKILLS_DIR="$TMP/company" PATH="$TMP/bin:$PATH" MOCK_VERDICT=Done \
  MOCK_MOVE_FAIL=no MOCK_TASKS="$TMP/tasks.json" MOCK_COMMENTS="$TMP/comments.json" \
  MOCK_BOARD_LOG="$TMP/board.log" MOCK_MODEL_LOG="$TMP/model.log" \
  "$ROOT/scripts/agent-board-poll" --once qa-runner >/dev/null 2>&1 || true
if [ "$(grep -cF 'pickup skipped for TEST-1: label valentin' "$TMP/state/agent-board-poll/qa-runner.log")" -eq 1 ]; then
  ok qa-protection-log-daily 'a protected QA ticket logs its skip only once per UTC day'
else
  bad qa-protection-log-daily "log=$(cat "$TMP/state/agent-board-poll/qa-runner.log")"
fi

run_case Done '[{"name":"manager-only"}]' '{"comments":[]}'
if [ ! -s "$TMP/board.log" ] && [ ! -s "$TMP/model.log" ] \
   && grep -qF 'pickup skipped for TEST-1: label manager-only' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok qa-manager-only-label-skip 'QA never claims a manager-only alarm ticket'
else
  bad qa-manager-only-label-skip "board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
fi
sed -i 's/AGENT_KIND="qa"/AGENT_KIND="dev"/' "$TMP/config/qa-runner.conf"
rm -rf "$TMP/state"; mkdir -p "$TMP/state/agent-board-poll"
: > "$TMP/board.log"; : > "$TMP/model.log"
env -u AGENT_ORIGINAL_PATH -u AGENT_IDENTITY_PATH \
  HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state" \
  COMPANY_SKILLS_DIR="$TMP/company" PATH="$TMP/bin:$PATH" MOCK_VERDICT=Done \
  MOCK_MOVE_FAIL=no MOCK_TASKS="$TMP/tasks.json" MOCK_COMMENTS="$TMP/comments.json" \
  MOCK_BOARD_LOG="$TMP/board.log" MOCK_MODEL_LOG="$TMP/model.log" \
  "$ROOT/scripts/agent-board-poll" --once qa-runner > "$TMP/out" 2>&1 || true
sed -i 's/AGENT_KIND="dev"/AGENT_KIND="qa"/' "$TMP/config/qa-runner.conf"
if [ ! -s "$TMP/board.log" ] && [ ! -s "$TMP/model.log" ] \
   && grep -qF 'pickup skipped for TEST-1: label manager-only' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok dev-manager-only-label-skip 'dev never claims a manager-only alarm ticket'
else
  bad dev-manager-only-label-skip "board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
fi

run_case Done '[]' '{"comments":[]}' '[{"id":6},{"id":41,"agent":{"id":"agent-qa","displayName":"QA Runner"}}]'
if [ ! -s "$TMP/board.log" ] && [ ! -s "$TMP/model.log" ] \
   && grep -qF 'pickup skipped for TEST-1: board owner assignment' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok qa-board-owner-skip 'a board-owner-assigned ticket is not run or moved'
else
  bad qa-board-owner-skip "board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
fi

run_case Done '[{"name":"valentin"}]' '{"comments":[]}'
sed -i 's/AGENT_KIND="qa"/AGENT_KIND="dev"/' "$TMP/config/qa-runner.conf"
rm -rf "$TMP/state"; mkdir -p "$TMP/state/agent-board-poll"
: > "$TMP/board.log"; : > "$TMP/model.log"
env -u AGENT_ORIGINAL_PATH -u AGENT_IDENTITY_PATH \
  HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state" \
  COMPANY_SKILLS_DIR="$TMP/company" PATH="$TMP/bin:$PATH" MOCK_VERDICT=Done \
  MOCK_MOVE_FAIL=no MOCK_TASKS="$TMP/tasks.json" MOCK_COMMENTS="$TMP/comments.json" \
  MOCK_BOARD_LOG="$TMP/board.log" MOCK_MODEL_LOG="$TMP/model.log" \
  "$ROOT/scripts/agent-board-poll" --once qa-runner > "$TMP/out" 2>&1 || true
sed -i 's/AGENT_KIND="dev"/AGENT_KIND="qa"/' "$TMP/config/qa-runner.conf"
if [ ! -s "$TMP/board.log" ] && [ ! -s "$TMP/model.log" ] \
   && grep -qF 'pickup skipped for TEST-1: label valentin' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok dev-valentin-label-skip 'a valentin-labelled ticket is held from a non-QA lane too'
else
  bad dev-valentin-label-skip "board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
fi

old="$(date -u -d '11 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
run_case Done '[]' "{\"comments\":[{\"id\":90,\"createdAt\":\"$old\",\"agent\":{\"id\":\"agent-qa\",\"displayName\":\"QA Runner\"},\"text\":\"<p><strong>Done: QA passed.</strong></p><p>Next: Release.</p>\"}]}"
if grep -qxF 'move TEST-1 Done' "$TMP/board.log" && [ ! -s "$TMP/model.log" ] \
   && grep -qF 'QA backfill comment 90 moved TEST-1 to Done from verdict Done' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok qa-verdict-backfill 'an own verdict older than ten minutes is moved without another run'
else
  bad qa-verdict-backfill "board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
fi

run_case Done '[]' '{"comments":[]}' \
  '[{"id":40,"agent":{"id":"agent-dev","displayName":"Dev"}},{"id":41,"agent":{"id":"agent-qa","displayName":"QA Runner"}}]' yes
if [ "$(grep -cFx 'move TEST-1 Done' "$TMP/board.log")" -eq 2 ] \
   && grep -qF 'health <p><strong>Decision: QA lifecycle could not move <a href="https://app.hypertask.ai/detail/project-15/1">TEST-1 Verify checkout</a> to Done after two attempts.</strong></p><p>Next: Check the run log and restore the board move.</p>' "$TMP/board.log"; then
  ok qa-move-retry-health 'a failed QA move retries once and reports Board health with a linked ticket'
else
  bad qa-move-retry-health "board=$(cat "$TMP/board.log") output=$(cat "$TMP/out")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
