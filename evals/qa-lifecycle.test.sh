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
# A ticket in QA already has a merged PR by definition (that is how it got
# here). MOCK_MERGED_PR_TITLE simulates that for the AGTE-179-style cases
# below; every other case leaves it unset and gets the old empty-PR-list
# behavior.
if [ -n "${MOCK_MERGED_PR_TITLE:-}" ] && [ "${1:-}" = api ] \
   && [[ "${2:-}" == repos/example/repo/pulls\?state=* ]]; then
  case "${2:-}" in
    *state=open*) printf '[]\n' ;;
    *)
      now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '[{"number":999,"title":"%s","html_url":"https://github.com/example/repo/pull/999","head":{"ref":"human/change"},"base":{"ref":"main"},"user":{"login":"human"},"draft":false,"created_at":"%s","updated_at":"%s","merged_at":"%s"}]\n' \
        "$MOCK_MERGED_PR_TITLE" "$now" "$now" "$now"
      ;;
  esac
  exit 0
fi
printf '[]\n'
EOF
cat > "$TMP/bin/model" <<'EOF'
#!/usr/bin/env bash
prompt="${!#}"
printf 'model ran\n' >> "$MOCK_MODEL_LOG"
printf '%s\n' "$prompt" >> "${MOCK_PROMPT_LOG:-/dev/null}"
verdict="$MOCK_VERDICT"
model_exit="${MOCK_MODEL_EXIT:-0}"
if [[ "$prompt" == *'QA VERDICT RETRY:'* ]]; then
  verdict="${MOCK_RETRY_VERDICT:-$MOCK_VERDICT}"
  model_exit="${MOCK_RETRY_EXIT:-0}"
fi
case "$verdict" in
  Done) text='<p><strong>Done: QA passed every acceptance step on live.</strong></p><p>AC 1, checkout completes. Live evidence: checkout completed at https://live.example.test/checkout.</p><p>Next: no action.</p>' ;;
  DoneWithPr) text='<p><strong>Done: QA passed every acceptance step on live.</strong></p><p>AC 1, checkout completes. Live evidence: checkout completed at https://live.example.test/checkout. PR <a href="https://github.com/example/repo/pull/1">https://github.com/example/repo/pull/1</a>.</p><p>Next: no action.</p>' ;;
  WeakDone) text='<p><strong>Done: QA passed every acceptance step.</strong></p><p>Next: Release the verified change.</p>' ;;
  Handoff) text='<p><strong>Handoff: Dev must fix the failing payment step.</strong></p><p>Next: Fix the payment step.</p>' ;;
  Question) text='<p><strong>Question: QA needs test credentials.</strong></p><p>Can the manager provide them?</p>' ;;
  Unmarked) text='<p><strong>QA passed every acceptance step.</strong></p><p>Ready to release.</p>' ;;
  Silent) exit "$model_exit" ;;
esac
"$AGENT_BOARD_CLI" comment add TEST-1 --text "$text" >/dev/null
exit "$model_exit"
EOF
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
args=" $* "
case "$args" in
  *' project show '*)
    printf '%s\n' '{"project":{"id":15,"ownerId":6,"sections":[{"name":"Bugs","isIntake":true},{"name":"In Progress"},{"name":"QA"},{"name":"Done"},{"name":"Agent Blocked (Infra)"}]}}'
    ;;
  *' task get BOARD-HEALTH'*) printf '%s\n' '{"tasks":[{"ticketNumber":"BOARD-HEALTH","projectId":15,"assignees":[],"labels":[]}]}' ;;
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
    if [ "${MOCK_MOVE_FAIL:-no}" != "yes" ] || [ "$section" != "Done" ]; then
      SECTION="$section" python3 - "$MOCK_TASKS" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
for task in doc["tasks"]:
    if task["ticketNumber"] == "TEST-1":
        task["section"] = os.environ["SECTION"]
json.dump(doc, open(path, "w", encoding="utf-8"))
PYEOF
    else
      exit 1
    fi
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
  local model_exit="${7:-0}" retry_exit="${8:-0}"
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
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","projectId":15,"section":"QA","title":"Verify checkout","description":"<h2>Acceptance criteria</h2><ul><li><p>Checkout completes.</p></li></ul>","assignees":$assignees,"labels":$labels,"commentCount":1}]}
EOF
  printf '%s\n' "$comments" > "$TMP/comments.json"
  set +e
  env -u AGENT_ORIGINAL_PATH -u AGENT_IDENTITY_PATH \
    HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state" \
    COMPANY_SKILLS_DIR="$TMP/company" PATH="$TMP/bin:$PATH" MOCK_VERDICT="$verdict" \
    MOCK_MODEL_EXIT="$model_exit" MOCK_RETRY_VERDICT="$retry_verdict" MOCK_RETRY_EXIT="$retry_exit" \
    MOCK_MOVE_FAIL="$move_fail" MOCK_MERGED_PR_TITLE="${MOCK_MERGED_PR_TITLE:-}" \
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
if grep -qF 'AC 1, <criterion name>. Live evidence:' "$TMP/prompt.log" \
   && grep -qF 'result, or developer report is not live evidence.' "$TMP/prompt.log"; then
  ok qa-prompt-requires-live-evidence 'the QA prompt requires criterion-by-criterion live evidence'
else
  bad qa-prompt-requires-live-evidence "prompt=$(cat "$TMP/prompt.log")"
fi

run_case DoneWithPr '[]' '{"comments":[]}'
if grep -qxF 'move TEST-1 Done' "$TMP/board.log" \
   && ! grep -qxF 'move TEST-1 AI Review' "$TMP/board.log" \
   && grep -qF 'QA move skipped for TEST-1: its live-evidence verdict already moved it to Done' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok qa-live-verdict-stays-done 'a linked PR cannot pull a qualifying live QA verdict back out of Done'
else
  bad qa-live-verdict-stays-done "board=$(cat "$TMP/board.log") output=$(cat "$TMP/out") log=$(cat "$TMP/state/agent-board-poll/qa-runner.log")"
fi

run_case WeakDone '[]' '{"comments":[]}'
if grep -qxF 'move TEST-1 QA' "$TMP/board.log" \
   && ! grep -qxF 'move TEST-1 Done' "$TMP/board.log" \
   && grep -qF 'Done move refused for TEST-1: QA must name every acceptance criterion with live evidence' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok qa-pass-needs-live-evidence 'a QA Done marker without per-criterion live evidence stays in QA'
else
  bad qa-pass-needs-live-evidence "board=$(cat "$TMP/board.log") output=$(cat "$TMP/out") log=$(cat "$TMP/state/agent-board-poll/qa-runner.log")"
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
   && [ "$(cat "$TMP/exit")" -eq 0 ] \
   && grep -qxF 'move TEST-1 Done' "$TMP/board.log" \
   && ! grep -Eq 'Agent Blocked \(Infra\)|HT Manager Review|Valentin Review' "$TMP/board.log" \
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
   && ! grep -Eq 'Agent Blocked \(Infra\)|HT Manager Review|Valentin Review' "$TMP/board.log" \
   && grep -qF 'exited 65' "$TMP/out" \
   && grep -qF 'no verdict marker after one retry' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok qa-unmarked-retry-fails-in-qa 'two unmarked responses fail once without entering a human lane'
else
  bad qa-unmarked-retry-fails-in-qa "exit=$(cat "$TMP/exit") board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
fi

run_case Silent '[]' '{"comments":[]}' \
  '[{"id":40,"agent":{"id":"agent-dev","displayName":"Dev"}},{"id":41,"agent":{"id":"agent-qa","displayName":"QA Runner"}}]' no '' 75
if [ "$(grep -cFx 'model ran' "$TMP/model.log")" -eq 1 ] \
   && grep -qxF 'move TEST-1 QA' "$TMP/board.log" \
   && ! grep -qxF 'move TEST-1 Agent Blocked (Infra)' "$TMP/board.log" \
   && ! grep -qxF 'move TEST-1 Done' "$TMP/board.log" \
   && grep -qF 'exited 75' "$TMP/out" \
   && ! grep -qF 'QA verdict marker missing for TEST-1' "$TMP/state/agent-board-poll/qa-runner.log" \
   && grep -qF 'model exited 75 before returning a verdict' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok qa-process-failure-no-retry 'a failed QA process keeps its exit, does not spend the marker retry, and stays in QA'
else
  bad qa-process-failure-no-retry "exit=$(cat "$TMP/exit") board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
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
if grep -qxF 'move TEST-1 Done' "$TMP/board.log"; then
  ok legacy-label-not-owner 'the old label alone no longer blocks agent work'
else
  bad legacy-label-not-owner "board=$(cat "$TMP/board.log") output=$(cat "$TMP/out")"
fi

run_case Done '[{"name":"hold"}]' '{"comments":[]}'
if [ ! -s "$TMP/board.log" ] && [ ! -s "$TMP/model.log" ] \
   && grep -qF 'pickup skipped for TEST-1: label Hold' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok qa-hold-label-skip 'a Hold-labelled ticket is not run or moved'
else
  bad qa-hold-label-skip "board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
fi
env -u AGENT_ORIGINAL_PATH -u AGENT_IDENTITY_PATH \
  HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state" \
  COMPANY_SKILLS_DIR="$TMP/company" PATH="$TMP/bin:$PATH" MOCK_VERDICT=Done \
  MOCK_MOVE_FAIL=no MOCK_TASKS="$TMP/tasks.json" MOCK_COMMENTS="$TMP/comments.json" \
  MOCK_BOARD_LOG="$TMP/board.log" MOCK_MODEL_LOG="$TMP/model.log" \
  "$ROOT/scripts/agent-board-poll" --once qa-runner >/dev/null 2>&1 || true
if [ "$(grep -cF 'pickup skipped for TEST-1: label Hold' "$TMP/state/agent-board-poll/qa-runner.log")" -eq 1 ]; then
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

run_case Done '[]' '{"comments":[]}' '[{"id":88},{"id":41,"agent":{"id":"agent-qa","displayName":"QA Runner"}}]'
if [ ! -s "$TMP/board.log" ] && [ ! -s "$TMP/model.log" ] \
   && grep -qF 'pickup skipped for TEST-1: human owner' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok qa-human-owner-skip 'a human-assigned ticket is not run or moved'
else
  bad qa-human-owner-skip "board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
fi

# A human without a label wins even when the agent is assigned and addressed.
run_case Done '[]' '{"comments":[{"id":18,"createdAt":"2026-09-27T00:00:00Z","userId":6,"text":"<p>Hold this?</p>"}]}' \
  '[{"id":88},{"id":41,"agent":{"id":"agent-qa","displayName":"QA Runner"}}]'
if [ ! -s "$TMP/board.log" ] && [ ! -s "$TMP/model.log" ] \
   && grep -qF 'pickup skipped for TEST-1: human owner' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok qa-human-comment-skip 'a human owner with a comment receives no status, claim, move or verdict'
else
  bad qa-human-comment-skip "board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
fi
# The model cannot bypass pickup through its board wrapper.
: > "$TMP/board.log"
if ! env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
     MOCK_TASKS="$TMP/tasks.json" MOCK_BOARD_LOG="$TMP/board.log" \
     "$TMP/board" task assign TEST-1 --assignee agent-qa > "$TMP/wrapper.out" 2>&1 \
   && ! env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
     MOCK_TASKS="$TMP/tasks.json" MOCK_BOARD_LOG="$TMP/board.log" \
     "$TMP/board" task update TEST-1 --labels changed >> "$TMP/wrapper.out" 2>&1 \
   && ! env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
     MOCK_TASKS="$TMP/tasks.json" MOCK_BOARD_LOG="$TMP/board.log" \
     "$TMP/board" comment add TEST-1 --text '<p>Done: test.</p>' >> "$TMP/wrapper.out" 2>&1 \
   && ! env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
     MOCK_TASKS="$TMP/tasks.json" MOCK_BOARD_LOG="$TMP/board.log" \
     "$TMP/board" task move TEST-1 --section Done >> "$TMP/wrapper.out" 2>&1 \
   && [ ! -s "$TMP/board.log" ] \
   && [ "$(grep -cF 'human owner' "$TMP/wrapper.out")" -eq 4 ]; then
  ok wrapper-human-owner-skip 'the board wrapper blocks claim, label, comment, and move on a human ticket'
else
  bad wrapper-human-owner-skip "board=$(cat "$TMP/board.log") output=$(cat "$TMP/wrapper.out")"
fi

python3 - "$TMP/tasks.json" "$TMP/multiple-tasks.json" <<'PYEOF'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["tasks"].insert(0, {"id": "free-1", "ticketNumber": "TEST-2", "assignees": [], "labels": []})
json.dump(doc, open(sys.argv[2], "w"))
PYEOF
if ! env HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
     MOCK_TASKS="$TMP/multiple-tasks.json" MOCK_BOARD_LOG="$TMP/board.log" \
     "$TMP/board" task move TEST-1 --section Done > "$TMP/multiple.out" 2>&1 \
   && [ ! -s "$TMP/board.log" ] && grep -qF 'human owner' "$TMP/multiple.out"; then
  ok wrapper-multiple-tickets 'a safe first row cannot hide a human owner later in the response'
else
  bad wrapper-multiple-tickets "board=$(cat "$TMP/board.log") output=$(cat "$TMP/multiple.out")"
fi

sed -i 's/AGENT_KIND="qa"/AGENT_KIND="dev"/' "$TMP/config/qa-runner.conf"
run_case Done '[]' '{"comments":[]}' '[{"id":88},{"id":41,"agent":{"id":"agent-qa","displayName":"QA Runner"}}]'
sed -i 's/AGENT_KIND="dev"/AGENT_KIND="qa"/' "$TMP/config/qa-runner.conf"
if [ ! -s "$TMP/board.log" ] && [ ! -s "$TMP/model.log" ] \
   && grep -qF 'pickup skipped for TEST-1: human owner' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok dev-human-owner-skip 'a dev lane skips a human owner without a label'
else
  bad dev-human-owner-skip "board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
fi

run_case Done '[{"name":"hold"}]' '{"comments":[]}'
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
   && grep -qF 'pickup skipped for TEST-1: label Hold' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok dev-hold-label-skip 'a Hold-labelled ticket is held from a non-QA lane too'
else
  bad dev-hold-label-skip "board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
fi

old="$(date -u -d '11 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
run_case Done '[]' "{\"comments\":[{\"id\":90,\"createdAt\":\"$old\",\"agent\":{\"id\":\"agent-qa\",\"displayName\":\"QA Runner\"},\"text\":\"<p><strong>Done: QA passed on live.</strong></p><p>AC 1, checkout completes. Live evidence: checkout completed at https://live.example.test/checkout.</p><p>Next: no action.</p>\"}]}"
if grep -qxF 'move TEST-1 Done' "$TMP/board.log" && [ ! -s "$TMP/model.log" ] \
   && grep -qF 'QA backfill comment 90 moved TEST-1 to Done from verdict Done' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok qa-verdict-backfill 'an own verdict older than ten minutes is moved without another run'
else
  bad qa-verdict-backfill "board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
fi

# Regression for the QA/Bugs bounce loop: the reconciler posts this exact
# notice under the QA agent's own identity when it hands a merged PR to QA.
# It is not a verdict, so backfill must leave it alone and a real QA run
# must still happen (old tickets carry the notice under its original
# "Handoff:" wording, so that form is checked here).
old="$(date -u -d '11 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
run_case Done '[]' "{\"comments\":[{\"id\":95,\"createdAt\":\"$old\",\"agent\":{\"id\":\"agent-qa\",\"displayName\":\"QA Runner\"},\"text\":\"<p>Handoff: QA must verify https://github.com/example/repo/pull/9 on live against every acceptance criterion.</p>\"}]}"
if [ "$(grep -cFx 'move TEST-1 Bugs' "$TMP/board.log")" -eq 0 ] \
   && grep -qxF 'move TEST-1 Done' "$TMP/board.log" \
   && [ "$(grep -cFx 'model ran' "$TMP/model.log")" -eq 1 ] \
   && ! grep -qF 'QA backfill comment 95 moved' "$TMP/state/agent-board-poll/qa-runner.log"; then
  ok qa-backfill-ignores-handoff-notice 'the reconciler hand-off notice is not read as a FAIL verdict, so a real QA run still happens'
else
  bad qa-backfill-ignores-handoff-notice "board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
fi

run_case Done '[]' '{"comments":[]}' \
  '[{"id":40,"agent":{"id":"agent-dev","displayName":"Dev"}},{"id":41,"agent":{"id":"agent-qa","displayName":"QA Runner"}}]' yes
if [ "$(grep -cFx 'move TEST-1 Done' "$TMP/board.log")" -eq 2 ] \
   && grep -qF 'health <p><strong>Decision: QA lifecycle could not move <a href="https://app.hypertask.ai/detail/project-15/1">TEST-1 Verify checkout</a> to Done after two attempts.</strong></p><p>Next: Check the run log and restore the board move.</p>' "$TMP/board.log"; then
  ok qa-move-retry-health 'a failed QA move retries once and reports Board health with a linked ticket'
else
  bad qa-move-retry-health "board=$(cat "$TMP/board.log") output=$(cat "$TMP/out")"
fi

# HR-08 (2026-09-29): the QA model's runtime crashed on every run, and the
# runner's "merged PR outcome" fallback (meant for a developer whose own run
# crashed after its own PR merged) also fired for QA runs. Every ticket a QA
# agent picks up already has a merged PR by definition, so the fallback
# treated an unrelated pre-existing merged PR as this run's own success,
# forced the exit code to 0, and asked the board to move straight to Done
# with no parsed QA verdict. A separate board-CLI guard (hypertask-runner-cli,
# AGTE-179) caught every one of those requests on board 15, so no ticket
# actually reached Done from the crash path; instead each run was wrongly
# logged and recorded as "done", and burned an extra QA verdict-marker retry
# on a model that had already crashed.
#
# Worse, the same fallback ran unconditionally on every QA outcome, not only
# crashes: after a real "Done:" verdict with live evidence had already
# legitimately moved the ticket to Done, this fallback fired right after it,
# asked to move the same ticket to Done again without the flag that lets a
# move to Done through, and the CLI guard rewrote that second request back to
# QA. So a real, correct QA pass on a ticket with a merged PR (effectively
# every QA ticket) was being silently bounced back to QA every time. These
# cases pin the fix: a merged PR already on the ticket must never be read as
# this QA run's own outcome.
MOCK_MERGED_PR_TITLE='TEST-1: shipped'

run_case Silent '[]' '{"comments":[]}' \
  '[{"id":40,"agent":{"id":"agent-dev","displayName":"Dev"}},{"id":41,"agent":{"id":"agent-qa","displayName":"QA Runner"}}]' no '' 134 134
if [ "$(grep -cFx 'model ran' "$TMP/model.log")" -eq 1 ] \
   && grep -qxF 'move TEST-1 QA' "$TMP/board.log" \
   && ! grep -qxF 'move TEST-1 Done' "$TMP/board.log" \
   && grep -qF 'exited 134' "$TMP/out" \
   && [ "$(awk '$1 == "task-1" && $3 == "model" && $4 == "failed" { n++ } END { print n + 0 }' "$TMP/state/agent-board-poll/qa-runner.attempts")" -eq 1 ] \
   && ! grep -qF 'using the merged pull request as the run outcome' "$TMP/state/agent-board-poll/qa-runner.log" \
   && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$TMP/state/agent-board-poll/run-records/qa-runner-TEST-1.json")" = "qa-missing-verdict" ]; then
  ok qa-merged-pr-crash-stays-qa 'a crashed QA run never reads a pre-existing merged PR as its own outcome'
else
  bad qa-merged-pr-crash-stays-qa "exit=$(cat "$TMP/exit") board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") attempts=$(cat "$TMP/state/agent-board-poll/qa-runner.attempts" 2>/dev/null) output=$(cat "$TMP/out")"
fi

run_case Unmarked '[]' '{"comments":[]}' \
  '[{"id":40,"agent":{"id":"agent-dev","displayName":"Dev"}},{"id":41,"agent":{"id":"agent-qa","displayName":"QA Runner"}}]' no Unmarked
if grep -qxF 'move TEST-1 QA' "$TMP/board.log" \
   && ! grep -qxF 'move TEST-1 Done' "$TMP/board.log" \
   && grep -qF 'exited 65' "$TMP/out" \
   && ! grep -qF 'using the merged pull request as the run outcome' "$TMP/state/agent-board-poll/qa-runner.log" \
   && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$TMP/state/agent-board-poll/run-records/qa-runner-TEST-1.json")" = "qa-missing-verdict" ]; then
  ok qa-merged-pr-unmarked-stays-qa 'a merged PR present cannot turn an unmarked QA reply into a Done move'
else
  bad qa-merged-pr-unmarked-stays-qa "board=$(cat "$TMP/board.log") output=$(cat "$TMP/out")"
fi

run_case Done '[]' '{"comments":[]}'
if [ "$(tail -n1 "$TMP/board.log")" = "move TEST-1 Done" ] \
   && [ "$(grep -cFx 'move TEST-1 Done' "$TMP/board.log")" -eq 1 ] \
   && ! grep -qxF 'move TEST-1 QA' "$TMP/board.log"; then
  ok qa-merged-pr-real-pass-still-done 'a real QA Done verdict with live evidence completes and a merged PR cannot bounce it back to QA'
else
  bad qa-merged-pr-real-pass-still-done "board=$(cat "$TMP/board.log") output=$(cat "$TMP/out")"
fi
unset MOCK_MERGED_PR_TITLE

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
