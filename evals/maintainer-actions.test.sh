#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

HOME_DIR="$TMP/home"
CONF_DIR="$HOME_DIR/.config/hypertask-agents"
STATE_DIR="$TMP/state"
BIN="$TMP/bin"
REPO="$TMP/repo"
COMPANY="$TMP/company"
mkdir -p "$CONF_DIR/credentials" "$HOME_DIR/.claude/skills/pospeak" \
  "$HOME_DIR/.claude/skills/unslop" "$HOME_DIR/.claude/skills/i-have-adhd" \
  "$HOME_DIR/.codex" "$STATE_DIR" "$BIN" "$REPO" "$COMPANY/skills/talk-to-valentin/reference"
printf 'token\n' > "$CONF_DIR/credentials/maintainer-token"
printf '{}\n' > "$HOME_DIR/.codex/auth.json"
printf 'global\n' > "$HOME_DIR/.claude/CLAUDE.md"
printf 'pospeak\n' > "$HOME_DIR/.claude/skills/pospeak/SKILL.md"
printf 'unslop\n' > "$HOME_DIR/.claude/skills/unslop/SKILL.md"
printf 'adhd\n' > "$HOME_DIR/.claude/skills/i-have-adhd/SKILL.md"
printf '# skills\n' > "$COMPANY/INDEX.md"
printf 'test\n' > "$COMPANY/VERSION"
for name in pospeak.md unslop.md i-have-adhd.md; do printf 'Use plain words.\n' > "$COMPANY/skills/talk-to-valentin/reference/$name"; done
(
  cd "$REPO"
  git init -q -b main
  git config user.name test
  git config user.email test@example.com
  touch README.md
  git add README.md
  git commit -qm init
  git remote add origin https://github.com/example/allowed.git
)

cat > "$CONF_DIR/maintainer.conf" <<EOF
AGENT_SLUG="maintainer"
AGENT_NAME="Product Bot"
AGENT_KIND="worker"
AGENT_ID="agent-maintainer"
AGENT_REPO="$REPO"
AGENT_MISSION="Maintain setup"
PR_REPO="example/allowed"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$CONF_DIR/credentials/maintainer-token"
BOARD_CLI="$BIN/board"
WATCH_SECTIONS="Inbox"
MODEL_CLI="$BIN/model"
QUIET="on"
MANAGER="off"
MAINTAINER="on"
EOF
cat > "$CONF_DIR/regular.conf" <<EOF
AGENT_SLUG="regular"
AGENT_NAME="Regular"
AGENT_KIND="worker"
AGENT_ID="agent-regular"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$CONF_DIR/credentials/maintainer-token"
BOARD_CLI="$BIN/board"
MODEL_CLI="$BIN/model"
MANAGER="off"
MAINTAINER="off"
EOF
cat > "$CONF_DIR/repos.allow" <<EOF
allowed,$REPO,example/allowed,main,7G
EOF
printf 'Ticket: https://app.hypertask.ai/detail/project-1/2\nWhat: change one file\nDone when: checks pass\nGuardrails: no board writes\n' > "$TMP/spec.md"

cat > "$BIN/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMD_RUN_LOG"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]##*/}" = "agent-board-poll" ]; then
    ( exec 9>&-; exec "${args[@]:$i}" ) </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$INSTRUCTION_PID_FILE"
    disown
    exit 0
  fi
done
while [ "$#" -gt 0 ] && [ "$1" != "bash" ]; do shift; done
[ "$#" -gt 0 ] || exit 1
"$@"
EOF
cat > "$BIN/hax" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HAX_LOG"
printf 'Built the requested change.\nhttps://github.com/example/allowed/pull/7\n'
EOF
cat > "$BIN/model" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" = *'source=advisor'* ]]; then
  sleep "${MODEL_DELAY:-0}"
  printf 'Decision: The detached instruction completed exactly.\nSecond line stays unchanged.\n'
fi
EOF
cat > "$BIN/reply-hax" <<'EOF'
#!/usr/bin/env bash
printf 'reply-only\n' >> "$MODEL_RUN_LOG"
printf '<p><strong>The instruction is still running.</strong></p><p>Next: wait for its result.</p>\n'
EOF
cat > "$BIN/timeout-stub" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
cat > "$BIN/bwrap-stub" <<'EOF'
#!/usr/bin/env bash
hax=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "--ro-bind" ] && [ "${args[$((i + 2))]:-}" = "/opt/hax" ]; then hax="${args[$((i + 1))]}"; fi
  if [ "${args[$i]}" = "--" ]; then exec "$hax" "${args[@]:$((i + 2))}"; fi
done
exit 2
EOF
cat > "$BIN/board" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BOARD_NATIVE_LOG"
case "$*" in
  '--json project show 5500') printf '%s\n' '{"project":{"defaultSections":["Inbox"],"sections":[{"section_title":"Inbox"}]}}' ;;
  task\ create*) printf '%s\n' '{"task":{"id":"task-4","ticketNumber":"AGTE-4","projectId":5500,"uniqueIndex":4}}' ;;
  'task assign AGTE-4 --self') printf '%s\n' '{}' ;;
  *) printf 'unexpected board call: %s\n' "$*" >&2; exit 2 ;;
esac
EOF
cat > "$BIN/hypertask" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BOARD_NATIVE_LOG"
case " $* " in
  *' project show 1 '*) printf '{"project":{"id":1,"ticketPrefix":"ONE","ownerId":6}}\n' ;;
  *' project show 15 '*) printf '{"project":{"id":15,"ticketPrefix":"OWNER","ownerId":6}}\n' ;;
  *' comment list '*) printf '{"comments":[]}\n' ;;
  *' comment add ONE-3 '*) printf 'exact cli failure from hypertask\n' >&2; exit 37 ;;
  *' comment add '*)
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [ "${args[$i]}" = "--file" ]; then cp "${args[$((i + 1))]}" "$ADVISOR_POST_FILE"; fi
    done
    printf '{"comment":{"id":1}}\n' ;;
  *) printf '{}\n' ;;
esac
EOF
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
if [[ "$*" = *'codex-allowed-oom'* ]]; then
  printf 'LoadState=loaded\nActiveState=failed\nSubState=failed\nResult=oom-kill\nExecMainStatus=9\n'
elif find "$XDG_STATE_HOME/agent-board-poll/maintainer-instructions" -name '*.result' -size +0c -print -quit 2>/dev/null | grep -q .; then
  printf 'LoadState=loaded\nActiveState=inactive\nSubState=dead\nResult=success\nExecMainStatus=0\n'
else
  printf 'LoadState=loaded\nActiveState=active\nSubState=running\nResult=success\nExecMainStatus=0\n'
fi
EOF
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
if [[ " $* " = *' -X POST '* ]] && [[ "$url" = *'/mcp/comments' ]]; then
  args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [ "${args[$i]}" = "--data" ]; then
      [ -z "${REPLY_POST_LOG:-}" ] || printf '%s\n' "${args[$((i + 1))]:-}" >> "$REPLY_POST_LOG"
    fi
  done
  printf '%s\n200' '{"success":true,"comment":{"id":91}}'
  exit 0
fi
case "$url" in
  *'/mcp/tasks?project_id=1&'*)
    printf '%s\n200' '{"tasks":[{"id":"task-2","ticketNumber":"ONE-2","section":"Inbox","title":"Build","description":"","assignees":[],"commentCount":0},{"id":"task-3","ticketNumber":"ONE-3","section":"Inbox","title":"Failed build","description":"","assignees":[],"commentCount":0},{"id":"task-4","ticketNumber":"ONE-4","section":"Inbox","title":"Advisor","description":"","assignees":[],"commentCount":0}]}' ;;
  *'/mcp/tasks?project_id=15'*)
    printf '%s\n200' '{"tasks":[{"id":"task-9","ticketNumber":"OWNER-9","section":"Inbox","title":"Owner question","description":"Answer promptly","assignees":[{"agent":{"id":"agent-maintainer","displayName":"Product Bot"}}],"commentCount":1,"updatedAt":"2026-09-18T00:00:00Z"}]}' ;;
  *'/mcp/comments?task_id=task-9'*)
    printf '%s\n200' '{"comments":[{"id":90,"createdAt":"2026-09-18T00:00:00Z","creator":{"displayName":"Owner"},"text":"Is the instruction still running?"}]}' ;;
  *'/mcp/agents/runs'*) printf '{}\n404' ;;
  *) printf '{}\n200' ;;
esac
EOF
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "${1:-}" = api ] && [[ "${2:-}" == repos/example/allowed/pulls\?state=* ]]; then
  printf '[]\n'
  exit 0
fi
case "$1 $2" in
  'pr view')
    if [ "${GH_MODE:-red}" = green ]; then
      printf '{"isDraft":false,"state":"OPEN","baseRefName":"main","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}\n'
    else
      printf '{"isDraft":false,"state":"OPEN","baseRefName":"main","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]}\n'
    fi ;;
  'pr merge') exit 0 ;;
  'pr list') printf '[]\n' ;;
esac
EOF
chmod +x "$BIN"/*
: > "$TMP/systemd-run.log"
: > "$TMP/hax.log"
: > "$TMP/gh.log"
: > "$TMP/board-native.log"
: > "$TMP/systemctl.log"
: > "$TMP/model-runs.log"
: > "$TMP/reply-posts.log"

run_template() {
  HOME="$HOME_DIR" XDG_STATE_HOME="$STATE_DIR" AGENT_CONFIG_DIR="$CONF_DIR" \
    PATH="$BIN:/usr/bin:/bin" SYSTEMD_RUN_LOG="$TMP/systemd-run.log" HAX_LOG="$TMP/hax.log" \
    GH_LOG="$TMP/gh.log" BOARD_NATIVE_LOG="$TMP/board-native.log" \
    INSTRUCTION_PID_FILE="$TMP/instruction.pid" ADVISOR_POST_FILE="$TMP/advisor-post" \
    SYSTEMCTL_LOG="$TMP/systemctl.log" MODEL_RUN_LOG="$TMP/model-runs.log" \
    "$ROOT/scripts/agent-template" "$@"
}

set +e
unknown="$(AGENT_SLUG=maintainer run_template build --repo missing \
  --ticket https://app.hypertask.ai/detail/project-1/2 --spec "$TMP/spec.md" 2>&1)"
unknown_rc=$?
set -e
if [ "$unknown_rc" -ne 0 ] && [ "$unknown" = 'build refused: repository missing is not in repos.allow' ] \
   && [ ! -s "$TMP/systemd-run.log" ]; then
  ok build-refuses-unlisted-repo "unlisted path never reaches systemd-run"
else
  bad build-refuses-unlisted-repo "rc=$unknown_rc output=$unknown"
fi

git -C "$REPO" remote set-url origin https://github.com/example/actual.git
set +e
mismatch="$(AGENT_SLUG=maintainer run_template build --repo allowed \
  --ticket https://app.hypertask.ai/detail/project-1/2 --spec "$TMP/spec.md" 2>&1)"
mismatch_rc=$?
set -e
git -C "$REPO" remote set-url origin https://github.com/example/allowed.git
if [ "$mismatch_rc" -ne 0 ] \
   && [ "$mismatch" = 'build refused: checkout origin example/actual does not match repos.allow example/allowed' ] \
   && [ ! -s "$TMP/systemd-run.log" ]; then
  ok build-refuses-origin-mismatch "actual and allowlisted repositories are printed before launch"
else
  bad build-refuses-origin-mismatch "rc=$mismatch_rc output=$mismatch"
fi

build="$(AGENT_SLUG=maintainer run_template build --repo allowed \
  --ticket https://app.hypertask.ai/detail/project-1/2 --spec "$TMP/spec.md" --effort xhigh)"
build_id="${build#build started: }"
record="$STATE_DIR/agent-board-poll/maintainer-builds.json"
prompt="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["prompt"])' "$record")"
if [ "$build" = "build started: $build_id" ] \
   && grep -q 'STANDARD BUILD GUARDRAILS' "$prompt" \
   && grep -q 'Summary for non-engineers' "$prompt" \
   && grep -q 'gh pr merge --auto --squash' "$prompt" \
   && grep -q 'never edit VERSION or CHANGELOG.md' "$prompt" \
   && grep -q 'change one file' "$prompt" \
   && grep -q -- '--provider=codex --model=gpt-5.6-sol --effort=xhigh --no-session' "$TMP/hax.log" \
   && grep -q -- '-p MemoryMax=7G --setenv=PATH=' "$TMP/systemd-run.log" \
   && ! grep -q -- '--collect' "$TMP/systemd-run.log" \
   && [ "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[0]; print(r["status"],r["unit"])' "$record")" = "running codex-allowed-${build_id#allowed-}" ]; then
  ok build-records-guarded-job "prompt, unit, output, and running state recorded"
else
  bad build-records-guarded-job "output=$build record=$(cat "$record")"
fi

status="$(AGENT_SLUG=maintainer run_template build status "$build_id")"
list="$(AGENT_SLUG=maintainer run_template build list)"
if printf '%s' "$status" | grep -q "build $build_id: rc=0 status=running" \
   && printf '%s' "$status" | grep -q 'Built the requested change' \
   && printf '%s' "$list" | grep -q "$build_id repo=allowed status=running"; then
  ok build-status-and-list "status tails output and list reports durable state"
else
  bad build-status-and-list "status=$status list=$list"
fi

set +e
red="$(AGENT_SLUG=maintainer run_template merge https://github.com/example/allowed/pull/7 2>&1)"
red_rc=$?
set -e
if [ "$red_rc" -ne 0 ] && [ "$red" = 'merge refused: checks are not green: ci' ] \
   && ! grep -q '^pr merge ' "$TMP/gh.log"; then
  ok merge-refuses-red-checks "red pull request is not merged"
else
  bad merge-refuses-red-checks "rc=$red_rc output=$red gh=$(cat "$TMP/gh.log")"
fi

green="$(GH_MODE=green AGENT_SLUG=maintainer run_template merge https://github.com/example/allowed/pull/7)"
if [ "$green" = 'merged: https://github.com/example/allowed/pull/7' ] \
   && grep -q '^pr merge https://github.com/example/allowed/pull/7 --squash$' "$TMP/gh.log"; then
  ok merge-squashes-green-pr "allowlisted green pull request is squash merged"
else
  bad merge-squashes-green-pr "output=$green gh=$(cat "$TMP/gh.log")"
fi

set +e
regular_build="$(AGENT_SLUG=regular run_template build list 2>&1)"
regular_build_rc=$?
regular_merge="$(AGENT_SLUG=regular run_template merge https://github.com/example/allowed/pull/7 2>&1)"
regular_merge_rc=$?
regular_instruction="$(AGENT_SLUG= run_template instruct regular 'do work' 2>&1)"
regular_instruction_rc=$?
regular_update="$(AGENT_SLUG=regular run_template update --keep-timers 2>&1)"
regular_update_rc=$?
set -e
if [ "$regular_build_rc" -ne 0 ] && [ "$regular_build" = 'build refused: caller regular is not a maintainer' ] \
   && [ "$regular_merge_rc" -ne 0 ] && [ "$regular_merge" = 'merge refused: caller regular is not a maintainer' ] \
   && [ "$regular_instruction_rc" -ne 0 ] && [ "$regular_instruction" = 'instruct refused: regular is not a maintainer' ] \
   && [ "$regular_update_rc" -ne 0 ] && [ "$regular_update" = 'update refused: caller regular is not a maintainer' ]; then
  ok maintainer-gate-refuses-regular "build, merge, instruct, and agent update stay off"
else
  bad maintainer-gate-refuses-regular "build=$regular_build merge=$regular_merge instruct=$regular_instruction update=$regular_update"
fi

instruction="$(AGENT_SLUG= run_template instruct maintainer 'Review the setup and report back' --ticket https://app.hypertask.ai/detail/project-1/4)"
instruction_file="$(find "$STATE_DIR/agent-board-poll/maintainer-instructions" -name '*.json' -print -quit 2>/dev/null || true)"
marker="$(find "$STATE_DIR/agent-template/instruction-tickets" -name '*.json' -print -quit 2>/dev/null || true)"
if [[ "$instruction" == 'instruction filed: AGTE-4 '* ]] \
   && [ -z "$instruction_file" ] && [ -n "$marker" ] \
   && grep -q '^task assign AGTE-4 --self$' "$TMP/board-native.log"; then
  ok instruct-files-board-ticket "identity-free advisor entry creates assigned visible work"
else
  bad instruct-files-board-ticket "output=$instruction file=${instruction_file:-none} marker=${marker:-missing}"
fi

run_poll() {
  HOME="$HOME_DIR" XDG_STATE_HOME="$STATE_DIR" AGENT_CONFIG_DIR="$CONF_DIR" \
    COMPANY_SKILLS_DIR="$COMPANY" PATH="$BIN:/usr/bin:/bin" BOARD_NATIVE_LOG="$TMP/board-native.log" \
    SYSTEMD_RUN_LOG="$TMP/systemd-run.log" INSTRUCTION_PID_FILE="$TMP/instruction.pid" \
    ADVISOR_POST_FILE="$TMP/advisor-post" SYSTEMCTL_LOG="$TMP/systemctl.log" \
    GH_LOG="$TMP/gh.log" MODEL_RUN_LOG="$TMP/model-runs.log" REPLY_POST_LOG="$TMP/reply-posts.log" \
    MODEL_DELAY="${MODEL_DELAY:-6}" \
    REPLY_HAX_BIN="$BIN/reply-hax" REPLY_BWRAP_BIN="$BIN/bwrap-stub" \
    REPLY_TIMEOUT_BIN="$BIN/timeout-stub" REPLY_CODEX_AUTH="$HOME_DIR/.codex/auth.json" \
    "$ROOT/scripts/agent-board-poll" "$@" maintainer
}

failed_dir="$STATE_DIR/agent-board-poll/maintainer-builds/failed-build"
inflight_dir="$STATE_DIR/agent-board-poll/maintainer-builds/inflight-build"
mkdir -p "$failed_dir" "$inflight_dir"
printf 'The build stopped.\nhax rc=1\n' > "$failed_dir/out"
printf 'The build is still running.\n' > "$inflight_dir/out"
FAILED_OUT="$failed_dir/out" INFLIGHT_OUT="$inflight_dir/out" python3 - "$record" <<'PYEOF'
import json
import os
import sys

path = sys.argv[1]
rows = json.load(open(path, encoding="utf-8"))
rows.append({"id": "failed-build", "repo": "allowed",
             "ticket": "https://app.hypertask.ai/detail/project-1/3",
             "unit": "codex-allowed-failed", "started": "2026-01-01T00:00:00Z",
             "out": os.environ["FAILED_OUT"], "status": "running"})
rows.append({"id": "inflight-build", "repo": "allowed",
             "ticket": "https://app.hypertask.ai/detail/project-1/2",
             "unit": "codex-allowed-inflight", "started": "2026-01-01T00:00:00Z",
             "out": os.environ["INFLIGHT_OUT"], "status": "running"})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(rows, handle)
    handle.write("\n")
PYEOF

run_poll >"$TMP/first-poll.out" 2>"$TMP/first-poll.err"
run_poll >"$TMP/second-poll.out" 2>"$TMP/second-poll.err"
run_poll >"$TMP/third-poll.out" 2>"$TMP/third-poll.err"
if grep -q '^reply-only$' "$TMP/model-runs.log" \
   && python3 -c 'import json,sys; row=json.load(open(sys.argv[1])); assert row["ticket_number"] == "OWNER-9" and row["reply_to_comment_id"] == 90' "$TMP/reply-posts.log"; then
  ok reply-only-bypasses-inflight-work "owner question ran while build records were in flight"
else
  bad reply-only-bypasses-inflight-work "models=$(cat "$TMP/model-runs.log") reply=$(cat "$TMP/reply-posts.log") board=$(cat "$TMP/board-native.log")"
fi

done_count="$(grep -c ' comment add ONE-2 ' "$TMP/board-native.log" || true)"
failed_count="$(grep -c ' comment add ONE-3 ' "$TMP/board-native.log" || true)"
states="$(python3 -c 'import json,sys; print(" ".join(r["status"] for r in json.load(open(sys.argv[1]))))' "$record")"
if [ "$done_count" -eq 1 ] && [ "$states" = 'done comment-failed running' ] \
   && ! grep -qE ' comment add https://app\.hypertask\.ai/' "$TMP/board-native.log"; then
  ok later-tick-reports-completion "later ticks resolved ticket URLs and closed completed builds"
else
  bad later-tick-reports-completion "done=$done_count states=$states board=$(cat "$TMP/board-native.log")"
fi

if [ "$failed_count" -eq 2 ] \
   && grep -q 'comment add failed: attempt=2 command=.*comment add ONE-3.*exit=37 stderr follows' "$STATE_DIR/agent-board-poll/maintainer.log" \
   && grep -q '^exact cli failure from hypertask$' "$STATE_DIR/agent-board-poll/maintainer.log"; then
  ok comment-failure-stops-at-two "build comment stopped permanently after two attempts with command, exit code, and exact stderr logged"
else
  bad comment-failure-stops-at-two "attempts=$failed_count log=$(cat "$STATE_DIR/agent-board-poll/maintainer.log")"
fi

oom_dir="$STATE_DIR/agent-board-poll/maintainer-builds/oom-build"
mkdir -p "$oom_dir"
: > "$oom_dir/out"
OOM_OUT="$oom_dir/out" python3 - "$record" <<'PYEOF'
import json
import os
import sys

path = sys.argv[1]
rows = json.load(open(path, encoding="utf-8"))
rows.append({"id": "oom-build", "repo": "allowed",
             "ticket": "https://app.hypertask.ai/detail/project-1/4",
             "unit": "codex-allowed-oom", "started": "2026-01-01T00:00:00Z",
             "out": os.environ["OOM_OUT"], "status": "running"})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(rows, handle)
    handle.write("\n")
PYEOF
AGENT_SLUG=maintainer run_template build reconcile
oom_state="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[-1]; print(r["status"],r["result"],r["rc"])' "$record")"
oom_comments="$(grep -c 'comment add ONE-4 --text <p><strong>Decision: build failed: out of memory.</strong>' "$TMP/board-native.log" || true)"
if [ "$oom_state" = 'failed oom-kill 9' ] && [ "$oom_comments" -eq 1 ] \
   && grep -q '^systemd result=oom-kill$' "$oom_dir/out" \
   && grep -q '^hax rc=9$' "$oom_dir/out"; then
  ok oom-unit-fails-and-comments "oom-kill was closed and explained in one reconciliation tick"
else
  bad oom-unit-fails-and-comments "state=$oom_state comments=$oom_comments board=$(cat "$TMP/board-native.log")"
fi

printf 'default,%s,example/allowed,main\n' "$REPO" >> "$CONF_DIR/repos.allow"
mem_kb="$(sed -n 's/^MemTotal:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*kB$/\1/p' /proc/meminfo | head -n1)"
if [ "$mem_kb" -gt 33554432 ]; then default_cap=12G; else default_cap="$((mem_kb / 2))K"; fi
AGENT_SLUG=maintainer run_template build --repo default \
  --ticket https://app.hypertask.ai/detail/project-1/2 --spec "$TMP/spec.md" >/dev/null
if tail -n1 "$TMP/systemd-run.log" | grep -q -- "-p MemoryMax=$default_cap --setenv=PATH="; then
  ok build-default-memory-cap "host RAM selected MemoryMax=$default_cap"
else
  bad build-default-memory-cap "expected=$default_cap launch=$(tail -n1 "$TMP/systemd-run.log")"
fi

units="$TMP/systemd-user"
bash -c '. "$1"; core_write_poll_units "$2" "$3"' _ "$ROOT/scripts/lib/core.sh" "$units" "$BIN"
if grep -q '^Environment=AGENT_SLUG=%i$' "$units/agent-board-poll@.service" \
   && grep -q "^ExecStartPre=$BIN/agent-template build reconcile$" "$units/agent-board-poll@.service"; then
  ok build-reconcile-precedes-tick "the timer service checks failed units before polling"
else
  bad build-reconcile-precedes-tick "unit=$(cat "$units/agent-board-poll@.service")"
fi

fixture="$ROOT/evals/fixtures/maintainer-actions/execute-in-run.json"
if python3 - "$fixture" "$ROOT/scripts/agent-board-poll" <<'PYEOF'
import json, sys
fixture = json.load(open(sys.argv[1], encoding="utf-8"))
prompt = open(sys.argv[2], encoding="utf-8").read()
assert "A request to merge, release, update, or build is yours to execute in this run." in prompt
for command in fixture["required_commands"]:
    assert command in prompt
for outcome in fixture["forbidden_outcomes"]:
    assert outcome in prompt
assert len(fixture["instructions"]) == 4
PYEOF
then
  ok maintainer-executes-action-fixture "merge, release, update, and build stay with the maintainer run"
else
  bad maintainer-executes-action-fixture "maintainer execution contract did not satisfy the fixture"
fi

if grep -q $'who=maintainer\twhat=build --repo allowed' "$STATE_DIR/agent-board-poll/manager-actions.log" \
   && grep -q $'who=maintainer\twhat=merge https://github.com/example/allowed/pull/7' "$STATE_DIR/agent-board-poll/manager-actions.log" \
   && grep -q $'who=advisor\twhat=instruct maintainer' "$STATE_DIR/agent-board-poll/manager-actions.log"; then
  ok maintainer-actions-audited "accepted and refused setup actions are logged"
else
  bad maintainer-actions-audited "log=$(cat "$STATE_DIR/agent-board-poll/manager-actions.log")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
