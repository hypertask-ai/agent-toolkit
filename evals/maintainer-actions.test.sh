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
mkdir -p "$CONF_DIR/credentials" "$STATE_DIR" "$BIN" "$REPO" "$COMPANY/skills/talk-to-valentin/reference"
printf 'token\n' > "$CONF_DIR/credentials/maintainer-token"
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
allowed,$REPO,example/allowed,main
EOF
printf 'Ticket: https://app.hypertask.ai/detail/project-1/2\nWhat: change one file\nDone when: checks pass\nGuardrails: no board writes\n' > "$TMP/spec.md"

cat > "$BIN/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMD_RUN_LOG"
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
printf 'The requested setup review is complete.\n'
EOF
cat > "$BIN/hypertask" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BOARD_NATIVE_LOG"
case " $* " in
  *' project show '*) printf '{"project":{"id":15,"ownerId":6}}\n' ;;
  *' comment list '*) printf '{"comments":[]}\n' ;;
  *' comment add '*) printf '{"comment":{"id":1}}\n' ;;
  *) printf '{}\n' ;;
esac
EOF
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  'pr view')
    if [ "${GH_MODE:-red}" = green ]; then
      printf '{"isDraft":false,"state":"OPEN","baseRefName":"main","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}\n'
    else
      printf '{"isDraft":false,"state":"OPEN","baseRefName":"main","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]}\n'
    fi ;;
  'pr merge') exit 0 ;;
esac
EOF
chmod +x "$BIN"/*
: > "$TMP/systemd-run.log"
: > "$TMP/hax.log"
: > "$TMP/gh.log"
: > "$TMP/board-native.log"

run_template() {
  HOME="$HOME_DIR" XDG_STATE_HOME="$STATE_DIR" AGENT_CONFIG_DIR="$CONF_DIR" \
    PATH="$BIN:$PATH" SYSTEMD_RUN_LOG="$TMP/systemd-run.log" HAX_LOG="$TMP/hax.log" \
    GH_LOG="$TMP/gh.log" BOARD_NATIVE_LOG="$TMP/board-native.log" \
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

build="$(AGENT_SLUG=maintainer run_template build --repo allowed \
  --ticket https://app.hypertask.ai/detail/project-1/2 --spec "$TMP/spec.md" --effort xhigh)"
build_id="${build#build started: }"
record="$STATE_DIR/agent-board-poll/maintainer-builds.json"
prompt="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["prompt"])' "$record")"
if [ "$build" = "build started: $build_id" ] \
   && grep -q 'STANDARD BUILD GUARDRAILS' "$prompt" \
   && grep -q 'Summary for non-engineers' "$prompt" \
   && grep -q 'change one file' "$prompt" \
   && grep -q -- '--provider=codex --model=gpt-5.6-sol --effort=xhigh --no-session' "$TMP/hax.log" \
   && grep -q -- '--collect -p MemoryMax=3G --setenv=PATH=' "$TMP/systemd-run.log" \
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

instruction="$(AGENT_SLUG= run_template instruct maintainer 'Review the setup and report back')"
instruction_file="$(find "$STATE_DIR/agent-board-poll/maintainer-instructions" -name '*.json' -print -quit)"
if [[ "$instruction" == instruction\ queued:* ]] \
   && [ "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["source"],r["instruction"])' "$instruction_file")" = 'advisor Review the setup and report back' ]; then
  ok instruct-queues-advisor-run "identity-free advisor entry targets maintainer only"
else
  bad instruct-queues-advisor-run "output=$instruction file=${instruction_file:-missing}"
fi

run_poll() {
  HOME="$HOME_DIR" XDG_STATE_HOME="$STATE_DIR" AGENT_CONFIG_DIR="$CONF_DIR" \
    COMPANY_SKILLS_DIR="$COMPANY" PATH="$BIN:$PATH" BOARD_NATIVE_LOG="$TMP/board-native.log" \
    "$ROOT/scripts/agent-board-poll" "$@" maintainer
}

dry="$(run_poll --dry-run)"
if printf '%s' "$dry" | grep -q 'would run instruction .* source=advisor; nothing was started' \
   && [ -f "$instruction_file" ] \
   && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["status"])' "$record")" = running ]; then
  ok instruction-dry-run-pickup "next instruction is shown without consuming state"
else
  bad instruction-dry-run-pickup "output=$dry"
fi

failed_dir="$STATE_DIR/agent-board-poll/maintainer-builds/failed-build"
mkdir -p "$failed_dir"
printf 'The build stopped.\nhax rc=1\n' > "$failed_dir/out"
FAILED_OUT="$failed_dir/out" python3 - "$record" <<'PYEOF'
import json
import os
import sys

path = sys.argv[1]
rows = json.load(open(path, encoding="utf-8"))
rows.append({"id": "failed-build", "repo": "allowed",
             "ticket": "https://app.hypertask.ai/detail/project-1/3",
             "unit": "codex-allowed-failed", "started": "2026-01-01T00:00:00Z",
             "out": os.environ["FAILED_OUT"], "status": "running"})
with open(path, "w", encoding="utf-8") as handle:
    json.dump(rows, handle)
    handle.write("\n")
PYEOF

run_poll >"$TMP/poll.out" 2>"$TMP/poll.err"
done_count="$(grep -c ' comment add https://app.hypertask.ai/detail/project-1/2 ' "$TMP/board-native.log" || true)"
failed_count="$(grep -c ' comment add https://app.hypertask.ai/detail/project-1/3 ' "$TMP/board-native.log" || true)"
states="$(python3 -c 'import json,sys; print(" ".join(r["status"] for r in json.load(open(sys.argv[1]))))' "$record")"
if [ "$done_count" -eq 1 ] && [ "$failed_count" -eq 1 ] && [ ! -f "$instruction_file" ] \
   && [ "$states" = 'done failed' ] \
   && grep -q 'Decision: build failed:' "$TMP/board-native.log" \
   && grep -q "run done instruction=.* source=advisor exit=0" "$STATE_DIR/agent-board-poll/maintainer.log"; then
  ok tick-closes-build-and-instruction "one completion comment per build and advisor reply logged"
else
  bad tick-closes-build-and-instruction "done=$done_count failed=$failed_count state=$(cat "$record") log=$(cat "$STATE_DIR/agent-board-poll/maintainer.log")"
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
