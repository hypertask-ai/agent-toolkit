#!/usr/bin/env bash
set -euo pipefail
unset AGENT_ORIGINAL_PATH AGENT_IDENTITY_PATH
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
lock_holder=""
cleanup() {
  [ -z "$lock_holder" ] || kill "$lock_holder" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/home" "$TMP/config" "$TMP/bin" "$TMP/repo" "$TMP/company" "$TMP/state"
printf '# skills\n' > "$TMP/company/INDEX.md"
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
if [ "${1:-} ${2:-}" = "pr view" ]; then
  case "$3" in
    https://*) url="$3" ;;
    *) url="https://github.com/example/repo/pull/$3" ;;
  esac
  state="${MOCK_PR_STATE:-OPEN}"
  [ ! -s "$MOCK_PR_MERGED" ] || state=MERGED
  printf '{"state":"%s","url":"%s"}\n' "$state" "$url"
  exit 0
fi
if [ "${1:-}" = api ] && [[ "${2:-}" == repos/example/repo/pulls\?state=* ]]; then
  case "${2:-}" in
    *state=open*)
      if [ -s "$MOCK_PR_OPEN" ] && [ ! -s "$MOCK_PR_MERGED" ]; then
        printf '[{"number":9,"title":"%s","html_url":"https://github.com/example/repo/pull/9","head":{"ref":"dev/TEST-1"},"base":{"ref":"main"},"user":{"login":"bot"},"draft":false,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","merged_at":null}]\n' "${MOCK_PR_TITLE:-TEST-1: change}"
      else
        printf '[]\n'
      fi
      ;;
    *)
      now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      if [ "${MOCK_PR_STATE:-OPEN}" = MERGED ] || [ -s "$MOCK_PR_MERGED" ]; then
        printf '[{"number":9,"title":"%s","html_url":"https://github.com/example/repo/pull/9","head":{"ref":"human/change"},"base":{"ref":"main"},"user":{"login":"human"},"draft":false,"created_at":"%s","updated_at":"%s","merged_at":"%s"}]\n' "${MOCK_PR_TITLE:-TEST-1: change}" "$now" "$now" "$now"
      elif [ -n "${MOCK_MERGED_PR_TITLE:-}" ]; then
        printf '[{"number":999,"title":"%s","html_url":"https://github.com/example/repo/pull/999","head":{"ref":"human/change"},"base":{"ref":"main"},"user":{"login":"human"},"draft":false,"created_at":"%s","updated_at":"%s","merged_at":"%s"}]\n' "$MOCK_MERGED_PR_TITLE" "$now" "$now" "$now"
      else
        printf '[]\n'
      fi
      ;;
  esac
  exit 0
fi
if [ "${1:-} ${2:-}" = "pr list" ]; then
  case " $* " in
    *' --state merged '*)
      if [ -n "${MOCK_MERGED_PR_TITLE:-}" ]; then
        printf '[{"number":999,"url":"https://github.com/example/repo/pull/999","title":"%s"}]\n' "$MOCK_MERGED_PR_TITLE"
      else
        printf '[]\n'
      fi
      ;;
    *)
      if [ -s "$MOCK_PR_OPEN" ]; then
        printf '[{"number":9,"state":"OPEN","url":"https://github.com/example/repo/pull/9","title":"TEST-1: change","body":"","headRefName":"agent/dev-TEST-1","createdAt":"2026-01-01T00:00:00Z","author":{"login":"bot"}}]\n'
      else
        printf '[]\n'
      fi
      ;;
  esac
  exit 0
fi
printf '[]\n'
EOF
cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_GIT_LOG"
case " $* " in
  *' fetch '*) exit 0 ;;
  *' rev-parse '*) printf '%040d\n' 0 | tr 0 b; exit 0 ;;
  *' log '*)
    case "${!#}" in *..*) exit 0 ;; esac
    if [ "${MOCK_GIT_COMMIT:-no}" = yes ] \
       && [ "${!#}" = "refs/remotes/origin/${MOCK_GIT_BRANCH:-master}" ]; then
      printf '%040d\t%s\n' 0 "$MOCK_GIT_TITLE" | sed 's/^0000000000000000000000000000000000000000/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/'
    fi
    exit 0
    ;;
esac
exit 1
EOF
cat > "$TMP/bin/model" <<'EOF'
#!/usr/bin/env bash
printf 'model\n' >> "$MOCK_BOARD_LOG"
if [ "${MOCK_MODEL_MODE:-pr}" = sleep ]; then
  printf '%s\n' "$$" > "$MOCK_MODEL_PID"
  exec sleep 60
fi
touch "$MOCK_CHECK_READY"
if [ "${MOCK_MODEL_MODE:-pr}" = merged-comment-failure ]; then
  if [ -n "${MOCK_MODEL_MOVE:-}" ]; then
    "$AGENT_BOARD_CLI" task move AGTE-168 --section "$MOCK_MODEL_MOVE"
  fi
  printf 'yes\n' > "$MOCK_PR_MERGED"
  "$AGENT_BOARD_CLI" comment add AGTE-168 --text '<p><strong>Done: AGTE-168 now keeps merged runs successful.</strong></p><p>PR #9 merged.</p><p>Next: No action is needed.</p>'
  exit 74
fi
printf 'yes\n' > "$MOCK_PR_OPEN"
mkdir -p "$XDG_STATE_HOME/agent-board-poll"
printf 'TEST-1 opened-9\n' >> "$XDG_STATE_HOME/agent-board-poll/dev.posted-comments"
python3 - "$MOCK_COMMENTS" <<'PYEOF'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["comments"].append({
    "id": "opened-9",
    "createdAt": "2026-01-01T00:00:01Z",
    "agent": {"id": "agent-dev", "displayName": "Dev"},
    "text": '<p><strong>Handoff: The pull request is ready for review.</strong></p><p><a href="https://github.com/example/repo/pull/9">https://github.com/example/repo/pull/9</a></p><p>Next: Review the linked change.</p>',
})
json.dump(data, open(path, "w"))
PYEOF
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
  *' task get '*) cat "$MOCK_TASKS" ;;
  *' comment list '*) cat "$MOCK_COMMENTS" ;;
  *' task assign '*)
    ref="$(value_after assign)"
    printf 'assign %s agent-dev\n' "$ref" >> "$MOCK_BOARD_LOG"
    REF="$ref" python3 - "$MOCK_TASKS" <<'PYEOF'
import json, os, sys
p=sys.argv[1]; d=json.load(open(p))
for task in d["tasks"]:
    if task["ticketNumber"] == os.environ["REF"]:
        task["assignees"]=[{"agent":{"id":"agent-dev","displayName":"Dev"}}]
json.dump(d,open(p,"w"))
PYEOF
    ;;
  *' task unassign '*)
    ref="$(value_after unassign)"; assignee="$(value_after --assignee)"
    printf 'unassign %s %s\n' "$ref" "$assignee" >> "$MOCK_BOARD_LOG"
    REF="$ref" ASSIGNEE="$assignee" python3 - "$MOCK_TASKS" <<'PYEOF'
import json, os, sys
p=sys.argv[1]; d=json.load(open(p))
for task in d["tasks"]:
    if task["ticketNumber"] == os.environ["REF"]:
        task["assignees"]=[]
json.dump(d,open(p,"w"))
PYEOF
    ;;
  *' task move '*)
    ref="$(value_after move)"; section="$(value_after --section)"
    printf 'move %s %s\n' "$ref" "$section" >> "$MOCK_BOARD_LOG"
    REF="$ref" SECTION="$section" python3 - "$MOCK_TASKS" <<'PYEOF'
import json, os, sys
p=sys.argv[1]; d=json.load(open(p))
for task in d["tasks"]:
    if task["ticketNumber"] == os.environ["REF"]:
        task["section"]=os.environ["SECTION"]
json.dump(d,open(p,"w"))
PYEOF
    ;;
  *' comment add '*)
    ref="$(value_after add)"; text="$(value_after --text)"
    printf 'comment %s %s\n' "$ref" "$text" >> "$MOCK_BOARD_LOG"
    printf 'comment added\n'
    ;;
  *) printf '{}\n' ;;
esac
EOF
cat > "$TMP/bin/ticket-links" <<'EOF'
#!/usr/bin/env python3
import os
import sys

if os.environ.get("MOCK_LINK_REWRITE_FAIL") == "yes":
    raise SystemExit(1)
text = sys.stdin.read()
link = '<a href="https://app.hypertask.ai/detail/project-5500/168">AGTE-168 Keep merged PR runs successful when closing comments fail</a>'
sys.stdout.write(text.replace("AGTE-168", link))
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
FLEET_PROGRESS_SUPERVISOR="off"
EOF
printf 'app,%s,example/repo,master,,test=test -f %s/ready\n' "$TMP/repo" "$TMP/repo" > "$TMP/config/repos.allow"

reset_case() {
  rm -rf "$TMP/state"; mkdir -p "$TMP/state"
  rm -f "$TMP/repo/ready"
  : > "$TMP/board.log"; : > "$TMP/pr-open"; : > "$TMP/pr-merged"; : > "$TMP/git.log"
  printf '{"comments":[]}\n' > "$TMP/comments.json"
  cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","projectId":15,"section":"Backlog","title":"Change it","description":"Open a PR","assignees":[],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
}
run_env=(HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state" AGENT_PR_CACHE_DIR="$TMP/state/pr-cache" COMPANY_SKILLS_DIR="$TMP/company" PATH="$TMP/bin:$PATH" TICKET_LINK_FORMATTER="$TMP/bin/ticket-links" ADAPTER_CLAIM_TEST_JITTER_SECONDS=0 ADAPTER_CLAIM_TEST_SETTLE_SECONDS=0 MOCK_TASKS="$TMP/tasks.json" MOCK_COMMENTS="$TMP/comments.json" MOCK_BOARD_LOG="$TMP/board.log" MOCK_PR_OPEN="$TMP/pr-open" MOCK_PR_MERGED="$TMP/pr-merged" MOCK_MODEL_PID="$TMP/model.pid" MOCK_CHECK_READY="$TMP/repo/ready" MOCK_GIT_LOG="$TMP/git.log")

reset_case
env "${run_env[@]}" MOCK_MODEL_MODE=sleep "$ROOT/scripts/agent-board-poll" --once dev >"$TMP/run.out" 2>&1 &
runner_pid=$!
python3 - "$TMP/model.pid" <<'PYEOF'
import pathlib, sys, time
path = pathlib.Path(sys.argv[1])
for _ in range(400):
    if path.exists() and path.stat().st_size:
        break
    time.sleep(0.05)
PYEOF
if [ "$(sed -n '1p' "$TMP/board.log")" = 'assign TEST-1 agent-dev' ] \
   && [ "$(sed -n '2p' "$TMP/board.log")" = 'comment TEST-1 <p><strong>Claimed.</strong> A session is working this ticket now.</p>' ] \
   && [ "$(sed -n '3p' "$TMP/board.log")" = 'move TEST-1 In Progress' ] \
   && [ "$(sed -n '4p' "$TMP/board.log")" = model ]; then
  echo 'PASS run-start-state                    settled assignment, claim comment, and In Progress move precede model invocation'
else
  echo "FAIL run-start-state                    log=$(cat "$TMP/board.log")"; exit 1
fi
kill "$runner_pid" 2>/dev/null || true
wait "$runner_pid" 2>/dev/null || true
[ ! -s "$TMP/model.pid" ] || kill "$(cat "$TMP/model.pid")" 2>/dev/null || true
env "${run_env[@]}" "$ROOT/scripts/agent-board-reconcile"
if grep -qxF 'move TEST-1 Backlog' "$TMP/board.log"; then
  echo 'PASS killed-run-reconciled              one pass restores the recorded origin section'
else
  echo "FAIL killed-run-reconciled              log=$(cat "$TMP/board.log")"; exit 1
fi

reset_case
env "${run_env[@]}" MOCK_MODEL_MODE=pr "$ROOT/scripts/agent-board-poll" --once dev >"$TMP/pr.out" 2>&1
if tail -n1 "$TMP/board.log" | grep -qxF 'move TEST-1 AI Review' \
   && [ "$(grep -cF 'comment TEST-1 <p><strong>Handoff: The review team can review the opened pull request.</strong></p><p><a href="https://github.com/example/repo/pull/9">https://github.com/example/repo/pull/9</a></p><p>Next: Review the linked change.</p>' "$TMP/board.log")" -eq 1 ]; then
  echo 'PASS pr-outcome-review                  a newly opened PR is linked on the ticket and moves it to AI Review'
else
  echo "FAIL pr-outcome-review                  log=$(cat "$TMP/board.log") output=$(cat "$TMP/pr.out")"; exit 1
fi

reset_case
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-168","ticketNumber":"AGTE-168","projectId":15,"section":"Backlog","title":"Keep merged PR runs successful when closing comments fail","description":"Keep the merged run successful","assignees":[],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
env "${run_env[@]}" MOCK_MODEL_MODE=merged-comment-failure \
  MOCK_PR_TITLE='AGTE-168: keep merged runs successful' \
  "$ROOT/scripts/agent-board-poll" --once dev >"$TMP/merged-comment.out" 2>&1
merged_record="$TMP/state/agent-board-poll/run-records/dev-AGTE-168.json"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = QA ] \
   && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$merged_record")" = done ] \
   && grep -qF '<a href="https://app.hypertask.ai/detail/project-5500/168">AGTE-168 Keep merged PR runs successful when closing comments fail</a>' "$TMP/board.log" \
   && grep -qF '<a href="https://github.com/example/repo/pull/9">https://github.com/example/repo/pull/9</a>' "$TMP/board.log" \
   && grep -qF 'model exited 74 after https://github.com/example/repo/pull/9 merged; using the merged pull request as the run outcome' "$TMP/state/agent-board-poll/dev.log" \
   && grep -qF 'run done AGTE-168 exit=0' "$TMP/state/agent-board-poll/dev.log"; then
  echo 'PASS merged-pr-comment-rewrite          a refused closing comment is linked and the merged PR finishes the run'
else
  echo "FAIL merged-pr-comment-rewrite          task=$(cat "$TMP/tasks.json") record=$(cat "$merged_record" 2>/dev/null) board=$(cat "$TMP/board.log") output=$(cat "$TMP/merged-comment.out")"; exit 1
fi

reset_case
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-168","ticketNumber":"AGTE-168","projectId":15,"section":"Backlog","title":"Keep merged PR runs successful when closing comments fail","description":"Keep the merged run successful","assignees":[],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
env "${run_env[@]}" MOCK_MODEL_MODE=merged-comment-failure MOCK_LINK_REWRITE_FAIL=yes \
  MOCK_PR_TITLE='AGTE-168: keep merged runs successful' \
  "$ROOT/scripts/agent-board-poll" --once dev >"$TMP/held-comment.out" 2>&1
held_record="$TMP/state/agent-board-poll/run-records/dev-AGTE-168.json"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = QA ] \
   && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$held_record")" = done ] \
   && [ "$(grep -c '^comment AGTE-168 ' "$TMP/board.log")" -eq 1 ] \
   && grep -qF 'closing comment for AGTE-168 remains held: ticket reference rewrite failed' "$TMP/state/agent-board-poll/dev.log" \
   && grep -qF 'run done AGTE-168 exit=0' "$TMP/state/agent-board-poll/dev.log"; then
  echo 'PASS merged-pr-comment-held             a failed rewrite is held without failing the merged run'
else
  echo "FAIL merged-pr-comment-held             task=$(cat "$TMP/tasks.json") record=$(cat "$held_record" 2>/dev/null) board=$(cat "$TMP/board.log") output=$(cat "$TMP/held-comment.out")"; exit 1
fi

reset_case
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","projectId":15,"section":"Review","title":"Change it","description":"Open a PR","assignees":[{"agent":{"id":"agent-dev","displayName":"Dev"}}],"labels":[],"commentCount":1,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":1,"createdAt":"2026-01-01T00:00:00Z","agent":{"id":"agent-dev","displayName":"Dev"},"text":"<p>Done: Shipped in <a href=\"https://github.com/example/repo/pull/9\">https://github.com/example/repo/pull/9</a>.</p>"}]}
EOF
env "${run_env[@]}" MOCK_PR_STATE=MERGED "$ROOT/scripts/agent-board-reconcile"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = QA ] \
   && [ "$(grep -cFx 'move TEST-1 QA' "$TMP/board.log")" -eq 1 ] \
   && ! grep -qFx 'move TEST-1 Done' "$TMP/board.log"; then
  echo 'PASS merged-pr-reconciled               a developer shipped comment and merged PR hand the ticket to QA, not Done'
else
  echo "FAIL merged-pr-reconciled               tasks=$(cat "$TMP/tasks.json") log=$(cat "$TMP/board.log")"; exit 1
fi

reset_case
cat > "$TMP/config/qa.conf" <<EOF
AGENT_ID="agent-qa"
AGENT_NAME="QA"
AGENT_KIND="qa"
AGENT_SLUG="qa"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/board"
PR_REPO="example/repo"
EOF
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","projectId":15,"section":"Review","title":"Change it","description":"<h2>Acceptance criteria</h2><ul><li><p>Checkout completes.</p></li><li><p>Receipt appears.</p></li></ul>","assignees":[{"agent":{"id":"agent-dev","displayName":"Dev"}}],"labels":[],"commentCount":2,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":1,"createdAt":"2026-01-01T00:00:00Z","agent":{"id":"agent-dev","displayName":"Dev"},"text":"<p>Handoff: QA can verify <a href=\"https://github.com/example/repo/pull/9\">https://github.com/example/repo/pull/9</a>.</p>"},{"id":2,"createdAt":"2026-01-01T01:00:00Z","agent":{"id":"agent-qa","displayName":"QA"},"text":"<p>Done: verified on live.</p><ul><li>AC 1, checkout completes. Live evidence: checkout completed at https://live.example.test/checkout.</li><li>AC 2, receipt appears. Live evidence: receipt 42 appeared on the live account.</li></ul>"}]}
EOF
env "${run_env[@]}" MOCK_PR_STATE=MERGED "$ROOT/scripts/agent-board-reconcile"
rm "$TMP/config/qa.conf"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = Done ] \
   && grep -qFx 'move TEST-1 Done' "$TMP/board.log"; then
  echo 'PASS merged-pr-live-qa-verdict          the reconciler completes only after QA records live evidence for every criterion'
else
  echo "FAIL merged-pr-live-qa-verdict          tasks=$(cat "$TMP/tasks.json") log=$(cat "$TMP/board.log")"; exit 1
fi

reset_case
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-158","ticketNumber":"AGTE-158","projectId":15,"section":"Review","title":"Bug: PR #713 stayed red for two hours","description":"<p><a href=\"https://github.com/example/repo/pull/713\">PR 713</a> has stayed red.</p>","assignees":[{"agent":{"id":"agent-dev","displayName":"Dev"}}],"labels":[{"name":"bug"}],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
env "${run_env[@]}" MOCK_PR_STATE=MERGED "$ROOT/scripts/agent-board-reconcile"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = QA ] \
   && grep -qxF 'unassign AGTE-158 agent-dev' "$TMP/board.log" \
   && grep -qxF 'comment AGTE-158 Handoff: QA must verify https://github.com/example/repo/pull/713 on live against every acceptance criterion.' "$TMP/board.log"; then
  echo 'PASS merged-pr-report-reconciled        a stayed-red report enters QA when its described pull request merges'
else
  echo "FAIL merged-pr-report-reconciled        tasks=$(cat "$TMP/tasks.json") log=$(cat "$TMP/board.log")"; exit 1
fi

reset_case
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-9","ticketNumber":"AGTE-9","projectId":15,"section":"Review","title":"Change it","description":"Opened and merged by a human","assignees":[{"agent":{"id":"agent-dev","displayName":"Dev"}}],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
env "${run_env[@]}" MOCK_MERGED_PR_TITLE='Agent template: AGTE-9 x' "$ROOT/scripts/agent-board-reconcile"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = QA ] \
   && grep -qxF 'unassign AGTE-9 agent-dev' "$TMP/board.log" \
   && [ "$(grep -cF 'comment AGTE-9 Handoff: QA must verify https://github.com/example/repo/pull/999 on live against every acceptance criterion.' "$TMP/board.log")" -eq 1 ]; then
  echo 'PASS title-matched-merged-pr            a prefixed merged PR title sends its zero-comment ticket to QA'
else
  echo "FAIL title-matched-merged-pr            tasks=$(cat "$TMP/tasks.json") log=$(cat "$TMP/board.log")"; exit 1
fi

reset_case
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-9","ticketNumber":"AGTE-9","projectId":15,"section":"Review","title":"Change it","description":"A different ticket has merged","assignees":[{"agent":{"id":"agent-dev","displayName":"Dev"}}],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
env "${run_env[@]}" MOCK_MERGED_PR_TITLE='AGTE-90 y' "$ROOT/scripts/agent-board-reconcile"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = Review ] \
   && ! grep -q '^move AGTE-9 ' "$TMP/board.log" \
   && ! grep -q '^unassign AGTE-9 ' "$TMP/board.log" \
   && ! grep -q '^comment AGTE-9 ' "$TMP/board.log"; then
  echo 'PASS title-ticket-token-boundary        AGTE-90 does not match ticket AGTE-9'
else
  echo "FAIL title-ticket-token-boundary        tasks=$(cat "$TMP/tasks.json") log=$(cat "$TMP/board.log")"; exit 1
fi

reset_case
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-999","ticketNumber":"AGTE-999","projectId":15,"section":"Archived","title":"Change it","description":"Already archived","assignees":[{"agent":{"id":"agent-dev","displayName":"Dev"}}],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
env "${run_env[@]}" MOCK_MERGED_PR_TITLE='AGTE-999: shipped by a human' "$ROOT/scripts/agent-board-reconcile"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = Archived ] \
   && ! grep -q '^move AGTE-999 ' "$TMP/board.log" \
   && ! grep -q '^unassign AGTE-999 ' "$TMP/board.log" \
   && ! grep -q '^comment AGTE-999 ' "$TMP/board.log"; then
  echo 'PASS merged-pr-terminal-skip           a terminal ticket stays untouched despite a matching merged PR'
else
  echo "FAIL merged-pr-terminal-skip           tasks=$(cat "$TMP/tasks.json") log=$(cat "$TMP/board.log")"; exit 1
fi

reset_case
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-999","ticketNumber":"AGTE-999","projectId":15,"section":"In Progress","title":"Change it","description":"A run is still active","assignees":[{"agent":{"id":"agent-dev","displayName":"Dev"}}],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
bash -c 'exec -a agent-board-poll sleep 60' &
live_pid=$!
mkdir -p "$TMP/state/agent-board-poll/run-records"
printf '{"status":"running","pid":%s,"ref":"AGTE-999","board":"15","origin_section":"Review"}\n' "$live_pid" > "$TMP/state/agent-board-poll/run-records/dev-AGTE-999.json"
env "${run_env[@]}" MOCK_MERGED_PR_TITLE='AGTE-999: shipped by a human' "$ROOT/scripts/agent-board-reconcile"
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = 'In Progress' ] \
   && ! grep -q '^move AGTE-999 Done$' "$TMP/board.log" \
   && ! grep -q '^unassign AGTE-999 ' "$TMP/board.log" \
   && ! grep -q '^comment AGTE-999 ' "$TMP/board.log"; then
  echo 'PASS merged-pr-live-run-skip           a live run prevents merged-PR completion'
else
  echo "FAIL merged-pr-live-run-skip           tasks=$(cat "$TMP/tasks.json") log=$(cat "$TMP/board.log")"; exit 1
fi

reset_case
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-999","ticketNumber":"AGTE-999","projectId":15,"section":"In Progress","title":"Change it","description":"A namespaced run is still active","assignees":[{"agent":{"id":"agent-dev","displayName":"Dev"}}],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
mkdir -p "$TMP/state/agent-board-poll/run-records"
printf '{"status":"running","slug":"dev","pid":99999999,"ref":"AGTE-999","board":"15","origin_section":"Backlog"}\n' > "$TMP/state/agent-board-poll/run-records/dev-AGTE-999.json"
lock="$TMP/state/agent-board-poll/dev.lock"
lock_ready="$TMP/lock-ready"
bash -c 'exec 9>"$1"; flock 9; touch "$2"; exec sleep 60' _ "$lock" "$lock_ready" &
lock_holder=$!
python3 - "$lock_ready" <<'PYEOF'
import pathlib, sys, time
path = pathlib.Path(sys.argv[1])
for _ in range(400):
    if path.exists():
        break
    time.sleep(0.01)
else:
    raise SystemExit("lock holder did not start")
PYEOF
env "${run_env[@]}" "$ROOT/scripts/agent-board-reconcile"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = 'In Progress' ] \
   && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$TMP/state/agent-board-poll/run-records/dev-AGTE-999.json")" = running ] \
   && ! grep -q '^move AGTE-999 ' "$TMP/board.log"; then
  echo 'PASS namespaced-run-lock-held           a held slug lock keeps a run live when its pid is invisible'
else
  echo "FAIL namespaced-run-lock-held           tasks=$(cat "$TMP/tasks.json") record=$(cat "$TMP/state/agent-board-poll/run-records/dev-AGTE-999.json") log=$(cat "$TMP/board.log")"; exit 1
fi
kill "$lock_holder" 2>/dev/null || true
wait "$lock_holder" 2>/dev/null || true
lock_holder=""
: > "$TMP/board.log"
env "${run_env[@]}" "$ROOT/scripts/agent-board-reconcile"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = Backlog ] \
   && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$TMP/state/agent-board-poll/run-records/dev-AGTE-999.json")" = reconciled ] \
   && grep -qxF 'move AGTE-999 Backlog' "$TMP/board.log"; then
  echo 'PASS namespaced-run-lock-free           a stale slug lock does not keep an invisible run live'
else
  echo "FAIL namespaced-run-lock-free           tasks=$(cat "$TMP/tasks.json") record=$(cat "$TMP/state/agent-board-poll/run-records/dev-AGTE-999.json") log=$(cat "$TMP/board.log")"; exit 1
fi

reset_case
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","projectId":15,"section":"Backlog","title":"Change it","description":"Open a PR","assignees":[{"agent":{"id":"agent-dev","displayName":"Dev"}}],"labels":[],"commentCount":1,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":1,"createdAt":"2026-01-01T00:00:00Z","agent":null,"creator":{"displayName":"Reviewer"},"text":"<p>Done: Shipped in <a href=\"https://github.com/example/repo/pull/9\">https://github.com/example/repo/pull/9</a>.</p>"}]}
EOF
env "${run_env[@]}" MOCK_PR_STATE=MERGED "$ROOT/scripts/agent-board-poll" --once --explain dev >"$TMP/merged-pickup.out" 2>&1
if ! grep -qxF model "$TMP/board.log" \
   && grep -qF 'has a merged pull request, so it cannot start another run' "$TMP/merged-pickup.out"; then
  echo 'PASS merged-pr-ineligible               a ticket with a linked merged PR cannot start a run'
else
  echo "FAIL merged-pr-ineligible               log=$(cat "$TMP/board.log") output=$(cat "$TMP/merged-pickup.out")"; exit 1
fi

reset_case
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-6591","ticketNumber":"HTPR-6591","projectId":15,"section":"Backlog","title":"Show it","description":"Ship directly","assignees":[{"agent":{"id":"agent-dev","displayName":"Dev"}}],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
env "${run_env[@]}" MOCK_GIT_COMMIT=yes MOCK_GIT_BRANCH=master \
  MOCK_GIT_TITLE='HTPR-6591 Show the shipped change' "$ROOT/scripts/agent-board-reconcile"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = QA ] \
   && grep -qxF 'unassign HTPR-6591 agent-dev' "$TMP/board.log" \
   && grep -qxF 'comment HTPR-6591 Handoff: QA must verify commit aaaaaaa on live against every acceptance criterion. https://github.com/example/repo/commit/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$TMP/board.log" \
   && ! grep -qxF 'move HTPR-6591 Done' "$TMP/board.log"; then
  echo 'PASS direct-commit-shipped              a shipped base commit enters QA instead of completing without evidence'
else
  echo "FAIL direct-commit-shipped              tasks=$(cat "$TMP/tasks.json") log=$(cat "$TMP/board.log")"; exit 1
fi
python3 - "$TMP/tasks.json" <<'PYEOF'
import json, sys
path = sys.argv[1]; data = json.load(open(path)); data["tasks"][0]["section"] = "Backlog"; json.dump(data, open(path, "w"))
PYEOF
env "${run_env[@]}" MOCK_GIT_COMMIT=yes MOCK_GIT_BRANCH=master \
  MOCK_GIT_TITLE='HTPR-6591 Show the shipped change' "$ROOT/scripts/agent-board-reconcile"
if [ "$(grep -c '^comment HTPR-6591 Handoff: QA must verify commit ' "$TMP/board.log")" -eq 1 ] \
   && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = Backlog ] \
   && grep -qF -- "--since=48 hours ago refs/remotes/origin/master" "$TMP/git.log" \
   && grep -qF 'log --reverse --format=%H%x09%s ' "$TMP/git.log" \
   && grep -qF '..refs/remotes/origin/master' "$TMP/git.log"; then
  echo 'PASS direct-commit-cursor               a saved base tip prevents duplicate shipping comments'
else
  echo "FAIL direct-commit-cursor               git=$(cat "$TMP/git.log") log=$(cat "$TMP/board.log")"; exit 1
fi

reset_case
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-6591","ticketNumber":"HTPR-6591","projectId":15,"section":"Backlog","title":"Show it","description":"Ship directly","assignees":[{"agent":{"id":"agent-dev","displayName":"Dev"}}],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
env "${run_env[@]}" MOCK_GIT_COMMIT=yes MOCK_GIT_BRANCH=feature \
  MOCK_GIT_TITLE='HTPR-6591 Show the unmerged change' "$ROOT/scripts/agent-board-reconcile"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = Backlog ] \
   && ! grep -q '^move HTPR-6591 ' "$TMP/board.log" \
   && ! grep -q '^comment HTPR-6591 ' "$TMP/board.log" \
   && grep -qF 'refs/remotes/origin/master' "$TMP/git.log"; then
  echo 'PASS direct-commit-base-only            a commit reachable only from a non-base branch does nothing'
else
  echo "FAIL direct-commit-base-only            tasks=$(cat "$TMP/tasks.json") git=$(cat "$TMP/git.log") log=$(cat "$TMP/board.log")"; exit 1
fi

reset_case
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-6591","ticketNumber":"HTPR-6591","projectId":15,"section":"Archived","title":"Show it","description":"Already archived","assignees":[{"agent":{"id":"agent-dev","displayName":"Dev"}}],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
env "${run_env[@]}" MOCK_GIT_COMMIT=yes MOCK_GIT_BRANCH=master \
  MOCK_GIT_TITLE='HTPR-6591 Show the archived change' "$ROOT/scripts/agent-board-reconcile"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = Archived ] \
   && ! grep -q '^move HTPR-6591 ' "$TMP/board.log" \
   && ! grep -q '^unassign HTPR-6591 ' "$TMP/board.log" \
   && ! grep -q '^comment HTPR-6591 ' "$TMP/board.log"; then
  echo 'PASS direct-commit-terminal-skip        archived tickets stay untouched'
else
  echo "FAIL direct-commit-terminal-skip        tasks=$(cat "$TMP/tasks.json") log=$(cat "$TMP/board.log")"; exit 1
fi

if grep -q '^OnUnitActiveSec=5m$' "$ROOT/install.sh" \
   && ! grep -q '^OnCalendar=.*Sun' "$ROOT/install.sh"; then
  echo 'PASS five-minute-self-update            the self-update timer runs every five minutes, not weekly'
else
  echo 'FAIL five-minute-self-update            install.sh has the wrong self-update schedule'; exit 1
fi

# Each setting belongs to this agent conf; default behaviour is exercised above.
printf 'AGENT_ID="agent-qa"\nAGENT_KIND="qa"\nBOARD_ID="15"\n' > "$TMP/config/qa.conf"
for freeze in off on; do
  for shape in section label; do
    reset_case
    if [ "$shape" = section ]; then
      python3 - "$TMP/tasks.json" <<'PYEOF'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['tasks'][0]['section']='Features'; json.dump(d,open(p,'w'))
PYEOF
      sed -i 's/WATCH_SECTIONS="Backlog"/WATCH_SECTIONS="Backlog,Features"/' "$TMP/config/dev.conf"
    else
      python3 - "$TMP/tasks.json" <<'PYEOF'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['tasks'][0]['labels']=[{'name':'Feature'}]; json.dump(d,open(p,'w'))
PYEOF
    fi
    if [ "$freeze" = on ]; then echo 'FEATURE_FREEZE="yes"' >> "$TMP/config/dev.conf"; fi
    env "${run_env[@]}" "$ROOT/scripts/agent-board-poll" --once --explain dev >"$TMP/freeze.out" 2>&1
    if [ "$freeze" = on ]; then
      if ! grep -qF 'skip TEST-1: feature freeze' "$TMP/state/agent-board-poll/dev.log" || grep -qxF model "$TMP/board.log"; then
        echo "FAIL freeze-$shape-$freeze"; exit 1
      fi
      sed -i '/^FEATURE_FREEZE=/d' "$TMP/config/dev.conf"
    elif ! grep -qxF model "$TMP/board.log"; then
      echo "FAIL freeze-$shape-$freeze output=$(cat "$TMP/freeze.out")"; exit 1
    fi
    echo "PASS freeze-$shape-$freeze"
  done
done

# A QA marker from a developer, a human, or another board is never a verdict.
printf 'AGENT_ID="agent-other-qa"\nAGENT_KIND="qa"\nBOARD_ADAPTER="hypertask"\nBOARD_ID="16"\n' > "$TMP/config/other-qa.conf"
for actor in agent-dev agent-other-qa human agent-qa; do
  reset_case
  ACTOR="$actor" python3 - "$TMP/comments.json" <<'PYEOF'
import json, os, sys
actor = os.environ['ACTOR']
rows = [{'id': 1, 'createdAt': '2026-01-01T00:00:00Z', 'agent': {'id': 'agent-qa'}, 'text': 'QA FAIL: retry'},
        {'id': 2, 'createdAt': '2026-01-02T00:00:00Z', 'text': 'QA PASS: fixed'}]
if actor != 'human':
    rows[1]['agent'] = {'id': actor}
json.dump({'comments': rows}, open(sys.argv[1], 'w'))
PYEOF
  verdict="$(env "${run_env[@]}" AGENT_CONFIG_DIR="$TMP/config" ROOT="$ROOT" TOKEN_FILE="$TMP/token" bash -c '
    . "$ROOT/scripts/lib/core.sh"
    . "$ROOT/adapters/hypertask/adapter.sh"
    adapter_latest_qa_verdict "$TOKEN_FILE" task-1 15 "$(adapter_qa_agent_ids 15)"
  ' )"
  expected=fail
  [ "$actor" != agent-qa ] || expected=pass
  if [ "$verdict" != "$expected" ]; then echo "FAIL verdict-actor-$actor expected=$expected actual=$verdict"; exit 1; fi
  echo "PASS verdict-actor-$actor"
done
rm -f "$TMP/config/other-qa.conf"

for setting in default require final both; do
  for verdict in none pass fail blocked runner-pass runner-fail; do
    reset_case
    sed -i '/^REQUIRE_QA_VERDICT=/d; /^VERDICT_FINAL=/d' "$TMP/config/dev.conf"
    case "$setting" in
      require) echo 'REQUIRE_QA_VERDICT="yes"' >> "$TMP/config/dev.conf" ;;
      final) echo 'VERDICT_FINAL="yes"' >> "$TMP/config/dev.conf" ;;
      both) printf 'REQUIRE_QA_VERDICT="yes"\nVERDICT_FINAL="yes"\n' >> "$TMP/config/dev.conf" ;;
    esac
    python3 - "$TMP/tasks.json" <<'PYEOF'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['tasks'][0]['section']='Bugs'; json.dump(d,open(p,'w'))
PYEOF
    case "$verdict" in
      none) printf '{"comments":[]}\n' > "$TMP/comments.json" ;;
      pass) text='QA PASS verified'; actor=qa ;;
      fail) text='QA FAIL broken'; actor=qa ;;
      blocked) text="Can't verify deployment"; actor=qa ;;
      runner-pass) text='Done: verified'; actor=qa ;;
      runner-fail) text='Handoff: fix this'; actor=qa ;;
    esac
    if [ "$verdict" != none ]; then
      TEXT="$text" ACTOR="$actor" python3 - "$TMP/comments.json" <<'PYEOF'
import json,os,sys
row={'id':1,'createdAt':'2026-01-01T00:00:00Z','text':'<p><strong>'+os.environ['TEXT']+'</strong></p>'}
row['agent']={'id':'agent-qa' if os.environ['ACTOR']=='qa' else 'agent-dev'}
json.dump({'comments':[row]},open(sys.argv[1],'w'))
PYEOF
    fi
    expected=QA
    if [ "$setting" != default ]; then
      case "$verdict" in pass|runner-pass) expected=Done ;; esac
    fi
    env "${run_env[@]}" MOCK_MERGED_PR_TITLE='TEST-1: shipped' "$ROOT/scripts/agent-board-reconcile"
    actual="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")"
    if [ "$actual" != "$expected" ]; then echo "FAIL reconcile-$setting-$verdict expected=$expected actual=$actual"; exit 1; fi
    echo "PASS reconcile-$setting-$verdict"
  done
done

for setting in default require final both; do
  reset_case
  sed -i '/^REQUIRE_QA_VERDICT=/d; /^VERDICT_FINAL=/d' "$TMP/config/dev.conf"
  case "$setting" in
    require) echo 'REQUIRE_QA_VERDICT="yes"' >> "$TMP/config/dev.conf" ;;
    final) echo 'VERDICT_FINAL="yes"' >> "$TMP/config/dev.conf" ;;
    both) printf 'REQUIRE_QA_VERDICT="yes"\nVERDICT_FINAL="yes"\n' >> "$TMP/config/dev.conf" ;;
  esac
  cat > "$TMP/tasks.json" <<'JSON'
{"tasks":[{"id":"task-168","ticketNumber":"AGTE-168","projectId":15,"section":"Backlog","title":"Keep merged PR runs successful when closing comments fail","description":"Keep the merged run successful","assignees":[],"labels":[],"commentCount":1,"updatedAt":"2026-01-01T00:00:00Z"}]}
JSON
  cat > "$TMP/comments.json" <<'JSON'
{"comments":[{"id":7,"createdAt":"2026-01-01T00:00:00Z","agent":{"id":"agent-qa"},"text":"<p>QA FAIL: fix checkout</p>"}]}
JSON
  env "${run_env[@]}" MOCK_MODEL_MODE=merged-comment-failure \
    MOCK_MODEL_MOVE="$( [ "$setting" = final ] && printf Done || true )" \
    MOCK_PR_TITLE='AGTE-168: keep merged runs successful' \
    "$ROOT/scripts/agent-board-poll" --once dev >"$TMP/dev-verdict.out" 2>&1
  expected=QA
  actual="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL developer-$setting expected=$expected actual=$actual output=$(cat "$TMP/dev-verdict.out")"; exit 1
  fi
  echo "PASS developer-$setting"
done

reset_case
printf 'REQUIRE_QA_VERDICT="yes"\nVERDICT_FINAL="yes"\n' >> "$TMP/config/dev.conf"
cat > "$TMP/tasks.json" <<'JSON'
{"tasks":[{"id":"task-168","ticketNumber":"AGTE-168","projectId":15,"section":"Backlog","title":"Dev cannot approve QA","description":"Check the verdict","assignees":[],"labels":[],"commentCount":1,"updatedAt":"2026-01-01T00:00:00Z"}]}
JSON
printf '{"comments":[{"id":7,"createdAt":"2026-01-01T00:00:00Z","agent":{"id":"agent-dev"},"text":"QA PASS: self-approved"}]}\n' > "$TMP/comments.json"
env "${run_env[@]}" MOCK_MODEL_MODE=merged-comment-failure MOCK_PR_TITLE='AGTE-168: keep merged runs successful' \
  "$ROOT/scripts/agent-board-poll" --once dev >"$TMP/dev-self-verdict.out" 2>&1
if grep -qxF 'move AGTE-168 QA' "$TMP/board.log" && ! grep -qxF 'move AGTE-168 Done' "$TMP/board.log"; then
  echo 'PASS developer-cannot-self-approve'
else
  echo "FAIL developer-cannot-self-approve log=$(cat "$TMP/board.log") output=$(cat "$TMP/dev-self-verdict.out")"; exit 1
fi
sed -i '/^REQUIRE_QA_VERDICT=/d; /^VERDICT_FINAL=/d' "$TMP/config/dev.conf"

reset_case
printf 'REQUIRE_QA_VERDICT="yes"\nVERDICT_FINAL="yes"\nQA_SECTION="Verification"\n' >> "$TMP/config/dev.conf"
cat > "$TMP/tasks.json" <<'JSON'
{"tasks":[{"id":"task-168","ticketNumber":"AGTE-168","projectId":15,"section":"Backlog","title":"Verify merged change","description":"QA must recheck","assignees":[],"labels":[],"commentCount":1,"updatedAt":"2026-01-01T00:00:00Z"}]}
JSON
printf '{"comments":[{"id":7,"createdAt":"2026-01-01T00:00:00Z","agent":{"id":"agent-qa"},"text":"QA FAIL: fix checkout"}]}\n' > "$TMP/comments.json"
env "${run_env[@]}" MOCK_MODEL_MODE=merged-comment-failure MOCK_PR_TITLE='AGTE-168: keep merged runs successful' \
  "$ROOT/scripts/agent-board-poll" --once dev >"$TMP/custom-qa.out" 2>&1
if grep -qxF 'move AGTE-168 Verification' "$TMP/board.log"; then
  echo 'PASS configured-qa-merged-fail'
else
  echo "FAIL configured-qa-merged-fail log=$(cat "$TMP/board.log") output=$(cat "$TMP/custom-qa.out")"; exit 1
fi
sed -i '/^REQUIRE_QA_VERDICT=/d; /^VERDICT_FINAL=/d; /^QA_SECTION=/d' "$TMP/config/dev.conf"

for verdicts in fail-then-pass pass-then-fail dev-done; do
  reset_case
  sed -i '/^REQUIRE_QA_VERDICT=/d; /^VERDICT_FINAL=/d' "$TMP/config/dev.conf"
  printf 'REQUIRE_QA_VERDICT="yes"\nVERDICT_FINAL="yes"\n' >> "$TMP/config/dev.conf"
  python3 - "$TMP/tasks.json" <<'PYEOF'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['tasks'][0]['section']='Bugs'; json.dump(d,open(p,'w'))
PYEOF
  VERDICTS="$verdicts" python3 - "$TMP/comments.json" <<'PYEOF'
import json,os,sys
kind=os.environ['VERDICTS']; comments=[]
for i,word in enumerate(kind.split('-then-') if kind!='dev-done' else ['dev-done']):
    text={'fail':'QA FAIL: broken','pass':'QA PASS: fixed','dev-done':'Done: developer shipped'}[word]
    comments.append({'id':i+1,'createdAt':f'2026-01-0{i+1}T00:00:00Z',
                     'agent':{'id':'agent-qa' if kind!='dev-done' else 'agent-dev'},'text':'<p>'+text+'</p>'})
json.dump({'comments':comments},open(sys.argv[1],'w'))
PYEOF
  env "${run_env[@]}" MOCK_MERGED_PR_TITLE='TEST-1: shipped' "$ROOT/scripts/agent-board-reconcile"
  expected=QA
  case "$verdicts" in fail-then-pass) expected=Done ;; esac
  actual="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")"
  if [ "$actual" != "$expected" ]; then echo "FAIL latest-$verdicts expected=$expected actual=$actual"; exit 1; fi
  echo "PASS latest-$verdicts"
done

for verdict in none fail pass; do
  reset_case
  sed -i '/^REQUIRE_QA_VERDICT=/d; /^VERDICT_FINAL=/d' "$TMP/config/dev.conf"
  printf 'REQUIRE_QA_VERDICT="yes"\nVERDICT_FINAL="yes"\n' >> "$TMP/config/dev.conf"
  cat > "$TMP/tasks.json" <<'JSON'
{"tasks":[{"id":"task-6591","ticketNumber":"HTPR-6591","projectId":15,"section":"Bugs","title":"Show it","description":"Ship directly","assignees":[],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
JSON
  if [ "$verdict" != none ]; then
    printf '{"comments":[{"id":1,"createdAt":"2026-01-01T00:00:00Z","agent":{"id":"agent-qa"},"text":"QA %s: checked"}]}\n' "${verdict^^}" > "$TMP/comments.json"
  fi
  env "${run_env[@]}" MOCK_GIT_COMMIT=yes MOCK_GIT_TITLE='HTPR-6591 Show the shipped change' "$ROOT/scripts/agent-board-reconcile"
  expected=QA
  case "$verdict" in pass) expected=Done ;; esac
  actual="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")"
  if [ "$actual" != "$expected" ]; then echo "FAIL direct-verdict-$verdict expected=$expected actual=$actual"; exit 1; fi
  echo "PASS direct-verdict-$verdict"
done
