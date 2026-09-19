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
if [ "${1:-} ${2:-}" = "pr list" ]; then
  if [ -s "$MOCK_PR_OPEN" ]; then
    printf '[{"number":9,"state":"OPEN","url":"https://github.com/example/repo/pull/9","title":"TEST-1: change","body":"","headRefName":"agent/dev-TEST-1","createdAt":"2026-01-01T00:00:00Z","author":{"login":"bot"}}]\n'
  else
    printf '[]\n'
  fi
  exit 0
fi
printf '[]\n'
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
case "$args" in
  *' task get '*) cat "$MOCK_TASKS" ;;
  *' comment list '*) printf '{"comments":[]}\n' ;;
  *' task assign '*)
    printf 'assign TEST-1 agent-dev\n' >> "$MOCK_BOARD_LOG"
    python3 - "$MOCK_TASKS" <<'PYEOF'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d["tasks"][0]["assignees"]=[{"agent":{"id":"agent-dev","displayName":"Dev"}}]; json.dump(d,open(p,"w"))
PYEOF
    ;;
  *' task move '*)
    argv=("$@"); section=""
    for ((i=0;i<${#argv[@]};i++)); do [ "${argv[$i]}" != --section ] || section="${argv[$((i+1))]}"; done
    printf 'move TEST-1 %s\n' "$section" >> "$MOCK_BOARD_LOG"
    SECTION="$section" python3 - "$MOCK_TASKS" <<'PYEOF'
import json, os, sys
p=sys.argv[1]; d=json.load(open(p)); d["tasks"][0]["section"]=os.environ["SECTION"]; json.dump(d,open(p,"w"))
PYEOF
    ;;
  *' comment add '*) printf 'comment added\n' ;;
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

reset_case() {
  rm -rf "$TMP/state"; mkdir -p "$TMP/state"
  : > "$TMP/board.log"; : > "$TMP/pr-open"
  printf '{"comments":[]}\n' > "$TMP/comments.json"
  cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","projectId":15,"section":"Backlog","title":"Change it","description":"Open a PR","assignees":[],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
}
run_env=(HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" PATH="$TMP/bin:$PATH" MOCK_TASKS="$TMP/tasks.json" MOCK_COMMENTS="$TMP/comments.json" MOCK_BOARD_LOG="$TMP/board.log" MOCK_PR_OPEN="$TMP/pr-open" MOCK_MODEL_PID="$TMP/model.pid")

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
   && [ "$(sed -n '2p' "$TMP/board.log")" = 'move TEST-1 In Progress' ] \
   && [ "$(sed -n '3p' "$TMP/board.log")" = model ]; then
  echo 'PASS run-start-state                    assignment and In Progress move precede model invocation'
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

if grep -q '^OnUnitActiveSec=5m$' "$ROOT/install.sh" \
   && ! grep -q '^OnCalendar=.*Sun' "$ROOT/install.sh"; then
  echo 'PASS five-minute-self-update            the self-update timer runs every five minutes, not weekly'
else
  echo 'FAIL five-minute-self-update            install.sh has the wrong self-update schedule'; exit 1
fi
