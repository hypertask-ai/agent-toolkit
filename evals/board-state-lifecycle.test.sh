#!/usr/bin/env bash
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
  *'/mcp/tasks?'*) cat "$MOCK_TASKS"; printf '\n200' ;;
  *'/mcp/comments?'*) cat "$MOCK_COMMENTS"; printf '\n200' ;;
  *) printf '{}\n404' ;;
esac
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "pr view" ]; then
  printf '{"state":"%s","url":"https://github.com/example/repo/pull/%s"}\n' "${MOCK_PR_STATE:-OPEN}" "$3"
  exit 0
fi
if [ "${1:-}" = api ] && [[ "${2:-}" == repos/example/repo/pulls\?state=* ]]; then
  case "${2:-}" in
    *state=open*)
      if [ -s "$MOCK_PR_OPEN" ]; then
        printf '[{"number":9,"title":"TEST-1: change","html_url":"https://github.com/example/repo/pull/9","head":{"ref":"dev/TEST-1"},"base":{"ref":"main"},"user":{"login":"bot"},"draft":false,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","merged_at":null}]\n'
      else
        printf '[]\n'
      fi
      ;;
    *)
      if [ -n "${MOCK_MERGED_PR_TITLE:-}" ]; then
        now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
printf 'yes\n' > "$MOCK_PR_OPEN"
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
  *' comment list '*) printf '{"comments":[]}\n' ;;
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
printf 'app,%s,example/repo,master\n' "$TMP/repo" > "$TMP/config/repos.allow"

reset_case() {
  rm -rf "$TMP/state"; mkdir -p "$TMP/state"
  : > "$TMP/board.log"; : > "$TMP/pr-open"; : > "$TMP/git.log"
  printf '{"comments":[]}\n' > "$TMP/comments.json"
  cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","projectId":15,"section":"Backlog","title":"Change it","description":"Open a PR","assignees":[],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
}
run_env=(HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state" AGENT_PR_CACHE_DIR="$TMP/state/pr-cache" COMPANY_SKILLS_DIR="$TMP/company" PATH="$TMP/bin:$PATH" ADAPTER_CLAIM_TEST_JITTER_SECONDS=0 ADAPTER_CLAIM_TEST_SETTLE_SECONDS=0 MOCK_TASKS="$TMP/tasks.json" MOCK_COMMENTS="$TMP/comments.json" MOCK_BOARD_LOG="$TMP/board.log" MOCK_PR_OPEN="$TMP/pr-open" MOCK_MODEL_PID="$TMP/model.pid" MOCK_GIT_LOG="$TMP/git.log")

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
if tail -n1 "$TMP/board.log" | grep -qxF 'move TEST-1 AI Review'; then
  echo 'PASS pr-outcome-review                  a newly opened PR moves the ticket to AI Review'
else
  echo "FAIL pr-outcome-review                  log=$(cat "$TMP/board.log") output=$(cat "$TMP/pr.out")"; exit 1
fi

reset_case
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","projectId":15,"section":"Review","title":"Change it","description":"Open a PR","assignees":[{"agent":{"id":"agent-dev","displayName":"Dev"}}],"labels":[],"commentCount":1,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":1,"createdAt":"2026-01-01T00:00:00Z","agent":{"id":"agent-dev","displayName":"Dev"},"text":"<p>Done: Shipped in <a href=\"https://github.com/example/repo/pull/9\">https://github.com/example/repo/pull/9</a>.</p>"}]}
EOF
env "${run_env[@]}" MOCK_PR_STATE=MERGED "$ROOT/scripts/agent-board-reconcile"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = Done ] \
   && [ "$(grep -cFx 'move TEST-1 Done' "$TMP/board.log")" -eq 1 ]; then
  echo 'PASS merged-pr-reconciled               one pass moves a Review ticket with a linked merged PR to Done'
else
  echo "FAIL merged-pr-reconciled               tasks=$(cat "$TMP/tasks.json") log=$(cat "$TMP/board.log")"; exit 1
fi

reset_case
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-999","ticketNumber":"AGTE-999","projectId":15,"section":"Review","title":"Change it","description":"Opened and merged by a human","assignees":[{"agent":{"id":"agent-dev","displayName":"Dev"}}],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
env "${run_env[@]}" MOCK_MERGED_PR_TITLE='AGTE-999: shipped by a human' "$ROOT/scripts/agent-board-reconcile"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = Done ] \
   && grep -qxF 'unassign AGTE-999 agent-dev' "$TMP/board.log" \
   && [ "$(grep -cF 'comment AGTE-999 Shipped by merged pull request https://github.com/example/repo/pull/999, moved to Done.' "$TMP/board.log")" -eq 1 ]; then
  echo 'PASS title-matched-merged-pr            a zero-comment ticket closes from a merged PR title and records shipping once'
else
  echo "FAIL title-matched-merged-pr            tasks=$(cat "$TMP/tasks.json") log=$(cat "$TMP/board.log")"; exit 1
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
sed -i 's/WATCH_SECTIONS="Backlog"/WATCH_SECTIONS="*"/' "$TMP/config/dev.conf"
env "${run_env[@]}" "$ROOT/scripts/agent-board-poll" --once --explain dev >"$TMP/direct-pickup.out" 2>&1
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"][0]["section"])' "$TMP/tasks.json")" = Done ] \
   && grep -qxF 'unassign HTPR-6591 agent-dev' "$TMP/board.log" \
   && grep -qxF 'comment HTPR-6591 Shipped by commit aaaaaaa https://github.com/example/repo/commit/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, moved to Done.' "$TMP/board.log" \
   && grep -qF 'HTPR-6591 is done, nothing left to do' "$TMP/direct-pickup.out" \
   && ! grep -qxF model "$TMP/board.log"; then
  echo 'PASS direct-commit-shipped              a base commit closes, unassigns, comments, and prevents pickup'
else
  echo "FAIL direct-commit-shipped              tasks=$(cat "$TMP/tasks.json") log=$(cat "$TMP/board.log") output=$(cat "$TMP/direct-pickup.out")"; exit 1
fi
python3 - "$TMP/tasks.json" <<'PYEOF'
import json, sys
path = sys.argv[1]; data = json.load(open(path)); data["tasks"][0]["section"] = "Backlog"; json.dump(data, open(path, "w"))
PYEOF
env "${run_env[@]}" MOCK_GIT_COMMIT=yes MOCK_GIT_BRANCH=master \
  MOCK_GIT_TITLE='HTPR-6591 Show the shipped change' "$ROOT/scripts/agent-board-reconcile"
if [ "$(grep -c '^comment HTPR-6591 Shipped by commit ' "$TMP/board.log")" -eq 1 ] \
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
