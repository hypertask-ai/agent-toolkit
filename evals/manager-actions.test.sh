#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/home/.config/agents" "$TMP/bin" "$TMP/state" "$TMP/state/agent-identity-shims/manager"
cat > "$TMP/home/.config/agents/manager.conf" <<EOF
AGENT_SLUG="manager"
AGENT_NAME="Product Manager"
AGENT_ID="agent-manager"
BOARD_ADAPTER="hypertask"
BOARD_CLI="$TMP/bin/board"
MANAGER="on"
EOF
cat > "$TMP/home/.config/agents/worker.conf" <<EOF
AGENT_SLUG="worker"
AGENT_NAME="Dev Worker"
AGENT_ID="agent-worker"
BOARD_ADAPTER="hypertask"
BOARD_CLI="$TMP/bin/worker-board"
MANAGER="off"
EOF
cat > "$TMP/home/.config/agents/regular.conf" <<EOF
AGENT_SLUG="regular"
AGENT_NAME="Regular Agent"
AGENT_ID="agent-regular"
BOARD_ADAPTER="hypertask"
BOARD_CLI="$TMP/bin/regular-board"
EOF
cat > "$TMP/home/.config/agents/legacy.conf" <<EOF
AGENT_SLUG="legacy"
MANAGER="on"
EOF

cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$*" in
  *'is-active agent-board-poll@worker.timer'*) echo active ;;
  *'is-active agent-board-poll@worker.service'*) echo inactive; exit 3 ;;
esac
EOF
cat > "$TMP/bin/board" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BOARD_LOG"
case "$*" in
  'task get OWNER-1')
    printf '%s\n' '{"tasks":[{"ticketNumber":"OWNER-1","projectId":15,"assignees":[{"id":6,"displayName":"Owner"}]}]}' ;;
  'task get OPEN-1')
    printf '%s\n' '{"tasks":[{"ticketNumber":"OPEN-1","projectId":15,"assignees":[]}]}' ;;
  'project show 15')
    printf '%s\n' '{"project":{"id":15,"ownerId":6}}' ;;
  task\ create*)
    printf '%s\n' '{"task":{"ticketNumber":"AGTE-99","projectId":5500,"uniqueIndex":99}}' ;;
esac
EOF
chmod +x "$TMP/bin/systemctl" "$TMP/bin/board"
: > "$TMP/systemctl.log"
: > "$TMP/board.log"

run_template() {
  HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
    SYSTEMCTL_LOG="$TMP/systemctl.log" BOARD_LOG="$TMP/board.log" PATH="$TMP/bin:$PATH" \
    "$ROOT/scripts/agent-template" "$@"
}

set +e
nonmanager="$(AGENT_SLUG=regular run_template ctl stop worker 2>&1)"
nonmanager_rc=$?
set -e
if [ "$nonmanager_rc" -ne 0 ] && [ "$nonmanager" = "ctl refused: caller regular is not a manager" ] \
   && [ ! -s "$TMP/systemctl.log" ]; then
  ok manager-gate-refuses-non-manager "non-manager cannot reach systemctl"
else
  bad manager-gate-refuses-non-manager "rc=$nonmanager_rc output=$nonmanager systemctl=$(cat "$TMP/systemctl.log")"
fi

set +e
foreign="$(AGENT_SLUG=manager run_template ctl stop 'agent-board-poll@worker.timer' 2>&1)"
foreign_rc=$?
set -e
if [ "$foreign_rc" -ne 0 ] && [ "$foreign" = "ctl refused: agent-board-poll@worker.timer is not a current agent slug" ] \
   && [ ! -s "$TMP/systemctl.log" ]; then
  ok ctl-refuses-foreign-unit "unit-shaped input never reaches systemctl"
else
  bad ctl-refuses-foreign-unit "rc=$foreign_rc output=$foreign systemctl=$(cat "$TMP/systemctl.log")"
fi

set +e
owner="$(AGENT_SLUG=manager run_template delegate OWNER-1 worker --why 'Please take this' 2>&1)"
owner_rc=$?
set -e
if [ "$owner_rc" -ne 0 ] && [ "$owner" = "delegate refused: OWNER-1 is held by the board owner" ] \
   && ! grep -qE '^task assign|^comment add' "$TMP/board.log"; then
  ok delegate-refuses-owner-held "owner-held ticket receives no write"
else
  bad delegate-refuses-owner-held "rc=$owner_rc output=$owner board=$(cat "$TMP/board.log")"
fi

handoff="$(AGENT_SLUG=manager run_template delegate OPEN-1 worker --why 'Please take this')"
if [ "$handoff" = "Handed to Dev Worker by Product Manager: Please take this" ] \
   && grep -q '^task assign OPEN-1 --assignee agent-worker$' "$TMP/board.log" \
   && grep -q '^comment add OPEN-1 --text Handed to Dev Worker by Product Manager: Please take this$' "$TMP/board.log"; then
  ok delegate-uses-manager-cli "agent UUID and one exact handoff are sent"
else
  bad delegate-uses-manager-cli "output=$handoff board=$(cat "$TMP/board.log")"
fi

status="$(env -u AGENT_SLUG PATH="$TMP/state/agent-identity-shims/manager:$TMP/bin:$PATH" \
  HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
  SYSTEMCTL_LOG="$TMP/systemctl.log" BOARD_LOG="$TMP/board.log" "$ROOT/scripts/agent-template" ctl status worker)"
if [ "$status" = "ctl status worker: timer=active service=inactive" ]; then
  ok manager-identity-from-path "identity shim directory identifies the caller"
else
  bad manager-identity-from-path "output=$status"
fi

feedback="$(AGENT_SLUG= run_template feedback --as manager --kind bug --what 'Session feedback' \
  --got 'bad' --expected 'good')"
if printf '%s' "$feedback" | grep -q '^filed AGTE-99 https://app.hypertask.ai/detail/project-5500/99$' \
   && grep -q '^task create --project 5500 ' "$TMP/board.log"; then
  ok feedback-as-files "--as reads BOARD_CLI and files with the mock"
else
  bad feedback-as-files "output=$feedback board=$(cat "$TMP/board.log")"
fi

feedback_cli="$(AGENT_SLUG= run_template feedback --board-cli "$TMP/bin/board" --kind bug \
  --what 'Direct session feedback' --got 'bad' --expected 'good')"
if printf '%s' "$feedback_cli" | grep -q '^filed AGTE-99 https://app.hypertask.ai/detail/project-5500/99$'; then
  ok feedback-board-cli-files "--board-cli infers the adapter and files"
else
  bad feedback-board-cli-files "output=$feedback_cli"
fi

feedback_env="$(AGENT_SLUG= AGENT_BOARD_CLI="$TMP/bin/board" run_template feedback --kind bug \
  --what 'Runner session feedback' --got 'bad' --expected 'good')"
if printf '%s' "$feedback_env" | grep -q '^filed AGTE-99 https://app.hypertask.ai/detail/project-5500/99$'; then
  ok feedback-env-cli-files "AGENT_BOARD_CLI infers the adapter and files"
else
  bad feedback-env-cli-files "output=$feedback_env"
fi

if [ "$(wc -l < "$TMP/state/agent-board-poll/manager-actions.log")" -eq 5 ] \
   && grep -q $'who=regular\twhat=ctl stop worker' "$TMP/state/agent-board-poll/manager-actions.log"; then
  ok manager-actions-audited "accepted and refused calls include who, what, and when"
else
  bad manager-actions-audited "log=$(cat "$TMP/state/agent-board-poll/manager-actions.log")"
fi

if grep -qF 'if [ "${MANAGER:-off}" = "on" ]' "$ROOT/scripts/agent-board-poll" \
   && grep -qF 'agent-template ctl start|stop|status <slug>' "$ROOT/scripts/agent-board-poll" \
   && grep -qF 'agent-template delegate <ticket> <slug> --why' "$ROOT/scripts/agent-board-poll"; then
  ok runner-manager-prompt-gated "runner lists both commands only inside the manager gate"
else
  bad runner-manager-prompt-gated "runner manager command contract is missing"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
