#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
  git -C "$TMP/repo" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree / {print substr($0, 10)}' \
    | while IFS= read -r path; do
        [ "$path" = "$TMP/repo" ] || git -C "$TMP/repo" worktree remove --force "$path" >/dev/null 2>&1 || true
      done
  rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/home" "$TMP/config" "$TMP/bin" "$TMP/company" "$TMP/state" "$TMP/worktrees" "$TMP/remote.git"
printf '# skills\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" config user.name Eval
git -C "$TMP/repo" config user.email eval@example.invalid
printf 'base\n' > "$TMP/repo/base.txt"
git -C "$TMP/repo" add base.txt
git -C "$TMP/repo" commit -qm base
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
git -C "$TMP/repo" push -q -u origin main

cat > "$TMP/bin/df" <<'EOF'
#!/usr/bin/env bash
if [ -n "${MOCK_DISK_USED:-}" ]; then
  available=$((100000 - MOCK_DISK_USED * 1000))
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  printf 'mock 100000 %s %s %s%% /\n' "$((MOCK_DISK_USED * 1000))" "$available" "$MOCK_DISK_USED"
else
  exec /usr/bin/df "$@"
fi
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *'/mcp/tasks?ticket_number='*) cat "$MOCK_TASKS"; printf '\n200' ;;
  *'/mcp/tasks?'*) cat "$MOCK_TASKS"; printf '\n200' ;;
  *'/mcp/comments?'*) printf '%s\n200' '{"comments":[]}' ;;
  *'/mcp/chat/rooms/pending') printf '{"messages":[{"projectId":5500,"roomId":"toolkit-room"}]}' ;;
  *'/mcp/chat/rooms/toolkit-room/messages') printf '{"success":true}' ;;
  *) printf '{}\n404' ;;
esac
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"
EOF
cat > "$TMP/bin/model" <<'EOF'
#!/usr/bin/env bash
case "${MOCK_MODEL_MODE:-success}" in
  success) touch "$MOCK_MODEL_MARKER" ;;
  failure) touch "$MOCK_MODEL_MARKER"; exit 42 ;;
  unpushed)
    git config user.name Eval
    git config user.email eval@example.invalid
    printf 'work\n' > unpushed.txt
    git add unpushed.txt
    git commit -qm unpushed
    touch "$MOCK_MODEL_MARKER"
    ;;
  stall)
    touch "$MOCK_MODEL_MARKER"
    trap 'touch "$MOCK_MODEL_TERM"; exit 143' TERM
    while :; do sleep 10; done
    ;;
esac
EOF
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
args=" $* "
case "$args" in
  *' task get '*) cat "$MOCK_TASKS" ;;
  *' comment list '*) printf '{"comments":[]}\n' ;;
  *' task create '*)
    printf 'create %s\n' "$*" >> "$MOCK_BOARD_LOG"
    printf '{"task":{"ticketNumber":"AGTE-999"}}\n'
    ;;
  *' task assign '*) printf 'assign\n' >> "$MOCK_BOARD_LOG" ;;
  *' task unassign '*) printf 'unassign\n' >> "$MOCK_BOARD_LOG" ;;
  *' task move '*) printf 'move\n' >> "$MOCK_BOARD_LOG" ;;
  *' comment add '*) printf 'comment\n' >> "$MOCK_BOARD_LOG" ;;
  *' project show '*) printf '{"project":{"ownerId":6}}\n' ;;
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
RUN_STALL_SECONDS="1"
RUN_MAX_SECONDS="30"
WORKDIR_MODE="per-run"
WORKDIR_ROOT="$TMP/worktrees"
WORKDIR_BASE_BRANCH="main"
FLEET_PROGRESS_SUPERVISOR="off"
EOF

set_task() {
  cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","projectId":15,"section":"Backlog","title":"Change it","description":"Open a PR","assignees":[],"labels":[],"commentCount":0,"updatedAt":"2026-01-01T00:00:00Z"}]}
EOF
}
empty_tasks() { printf '{"tasks":[]}\n' > "$TMP/tasks.json"; }
reset_runtime() {
  git -C "$TMP/repo" worktree list --porcelain \
    | awk '/^worktree / {print substr($0, 10)}' \
    | while IFS= read -r path; do
        [ "$path" = "$TMP/repo" ] || git -C "$TMP/repo" worktree remove --force "$path" >/dev/null 2>&1 || true
      done
  git -C "$TMP/repo" worktree prune
  rm -rf "$TMP/state" "$TMP/worktrees"
  mkdir -p "$TMP/state" "$TMP/worktrees"
  : > "$TMP/board.log"
  : > "$TMP/docker.log"
  rm -f "$TMP/model-marker" "$TMP/model-term"
  set_task
}
run_tick() {
  env HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state" \
    COMPANY_SKILLS_DIR="$TMP/company" PATH="$TMP/bin:$PATH" MOCK_TASKS="$TMP/tasks.json" \
    MOCK_BOARD_LOG="$TMP/board.log" MOCK_MODEL_MARKER="$TMP/model-marker" \
    MOCK_MODEL_TERM="$TMP/model-term" MOCK_DOCKER_LOG="$TMP/docker.log" CLEANUP_DOCKER=no "$@" \
    "$ROOT/scripts/agent-board-poll" --once dev
}

pass() { printf 'PASS %-36s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %-36s %s\n' "$1" "$2"; exit 1; }

reset_runtime
run_tick MOCK_MODEL_MODE=success > "$TMP/success.out" 2>&1
if [ -f "$TMP/model-marker" ] && [ ! -e "$TMP/worktrees/dev-TEST-1" ] \
   && [ ! -e "$TMP/state/agent-board-poll/dev.stderr" ]; then
  pass cleanup-success 'a successful run removes its worktree and temporary files'
else
  fail cleanup-success "worktree or temporary file remained: $(cat "$TMP/success.out")"
fi

reset_runtime
run_tick MOCK_MODEL_MODE=failure > "$TMP/failure.out" 2>&1
if [ -f "$TMP/model-marker" ] && [ ! -e "$TMP/worktrees/dev-TEST-1" ]; then
  pass cleanup-failure 'a failed model exit still removes a clean worktree'
else
  fail cleanup-failure "clean failed-run worktree remained: $(cat "$TMP/failure.out")"
fi

reset_runtime
run_tick MOCK_MODEL_MODE=stall > "$TMP/watchdog.out" 2>&1
if [ -f "$TMP/model-term" ] && [ ! -e "$TMP/worktrees/dev-TEST-1" ]; then
  pass cleanup-watchdog 'the watchdog killer removes the victim run worktree'
else
  fail cleanup-watchdog "watchdog did not clean its victim: $(cat "$TMP/watchdog.out")"
fi

reset_runtime
sed -i 's/RUN_STALL_SECONDS="1"/RUN_STALL_SECONDS="30"/' "$TMP/config/dev.conf"
run_tick MOCK_MODEL_MODE=stall > "$TMP/killed.out" 2>&1 &
launcher_pid=$!
record="$TMP/state/agent-board-poll/run-records/dev-TEST-1.json"
for _ in $(seq 1 200); do
  [ -s "$record" ] && [ -d "$TMP/worktrees/dev-TEST-1" ] && [ -f "$TMP/model-marker" ] && break
  sleep 0.05
done
runner_pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$record")"
kill -TERM "$runner_pid"
wait "$launcher_pid" 2>/dev/null || true
sed -i 's/RUN_STALL_SECONDS="30"/RUN_STALL_SECONDS="1"/' "$TMP/config/dev.conf"
if [ -f "$TMP/model-term" ] && [ ! -e "$TMP/worktrees/dev-TEST-1" ]; then
  pass cleanup-signal 'a terminated runner stops its model and removes the run worktree'
else
  fail cleanup-signal "signal exit left a model or worktree: $(cat "$TMP/killed.out")"
fi

reset_runtime
run_tick MOCK_MODEL_MODE=unpushed > "$TMP/unpushed.out" 2>&1
kept="$TMP/worktrees/dev-TEST-1"
if [ -d "$kept" ] && grep -qF "kept worktree $kept: unpushed commits" \
   "$TMP/state/agent-board-poll/dev.log"; then
  pass cleanup-keeps-unpushed 'an unpushed commit keeps the worktree with the required log line'
else
  fail cleanup-keeps-unpushed "unpushed worktree was lost: $(cat "$TMP/unpushed.out")"
fi
mkdir -p "$kept/node_modules/pkg" "$kept/.next/cache" "$kept/dist" "$kept/build"
touch -d '3 days ago' "$kept"
empty_tasks
run_tick > "$TMP/kept-sweep.out" 2>&1
if [ -d "$kept" ] && [ ! -e "$kept/node_modules" ] && [ ! -e "$kept/.next" ] \
   && [ ! -e "$kept/dist" ] && [ ! -e "$kept/build" ] \
   && grep -qF 'cleanup: freed ' "$TMP/state/agent-board-poll/dev.log" \
   && grep -qF 'kept 1 worktrees' "$TMP/state/agent-board-poll/dev.log"; then
  pass cleanup-prunes-kept 'a stale unpushed worktree stays while generated artifacts are pruned'
else
  fail cleanup-prunes-kept "kept worktree artifacts or summary are wrong: $(cat "$TMP/kept-sweep.out")"
fi

reset_runtime
stale="$TMP/worktrees/stale-empty"
git -C "$TMP/repo" worktree add -q --detach "$stale" origin/main
touch -d '3 days ago' "$stale"
empty_tasks
run_tick > "$TMP/stale.out" 2>&1
if [ ! -e "$stale" ]; then
  pass cleanup-stale-sweep 'a stale worktree with no live run and no unpushed work is removed'
else
  fail cleanup-stale-sweep "stale clean worktree remained: $(cat "$TMP/stale.out")"
fi

reset_runtime
empty_tasks
run_tick CLEANUP_DOCKER=yes > "$TMP/docker-first.out" 2>&1
run_tick CLEANUP_DOCKER=yes > "$TMP/docker-second.out" 2>&1
if [ "$(grep -cFx 'volume prune -f' "$TMP/docker.log")" -eq 1 ] \
   && [ "$(grep -cFx 'image prune -f' "$TMP/docker.log")" -eq 1 ]; then
  pass cleanup-docker-daily 'anonymous volumes and dangling images are pruned once per UTC day'
else
  fail cleanup-docker-daily "docker prune calls=$(cat "$TMP/docker.log")"
fi

reset_runtime
run_tick MOCK_DISK_USED=96 MOCK_MODEL_MODE=success > "$TMP/disk.out" 2>&1
run_tick MOCK_DISK_USED=96 MOCK_MODEL_MODE=success > "$TMP/disk-second.out" 2>&1
if [ ! -e "$TMP/model-marker" ] \
   && grep -qF 'disk usage 96%: no new run started above the 95% limit' "$TMP/state/agent-board-poll/dev.log" \
   && [ "$(grep -c '^create ' "$TMP/board.log")" -eq 1 ] \
   && grep -q -- '--section Review --priority high' "$TMP/board.log" \
   && STATE="$TMP/state/agent-board-poll" python3 -c 'import json,os; state=json.load(open(os.path.join(os.environ["STATE"],"host-alarms.json"))); alarm=next(iter(state["alarms"].values())); health=json.load(open(os.path.join(os.environ["STATE"],"board-health.json"))); assert alarm["alarm_chat_notified_at"] and alarm["alarm_telegram_notified_at"] and len(health["alarms"]) == 1'; then
  pass cleanup-disk-block 'fake 96% disk usage posts one alarm and starts no model run'
else
  fail cleanup-disk-block "disk guard failed: board=$(cat "$TMP/board.log") output=$(cat "$TMP/disk.out")"
fi
