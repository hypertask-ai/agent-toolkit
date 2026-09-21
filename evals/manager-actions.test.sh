#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

CONF_DIR="$TMP/home/.config/managed"
mkdir -p "$CONF_DIR/credentials" "$TMP/home/.config/agents" "$TMP/bin" \
  "$TMP/state" "$TMP/state/agent-identity-shims/manager"
cat > "$CONF_DIR/manager.conf" <<EOF
AGENT_SLUG="manager"
AGENT_NAME="Product Manager"
AGENT_KIND="worker"
AGENT_ID="agent-manager"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$CONF_DIR/credentials/manager-token"
BOARD_CLI="$TMP/bin/board"
MODEL_CLI="manager-model"
QUIET="on"
MANAGER="on"
EOF
cat > "$CONF_DIR/worker.conf" <<EOF
AGENT_SLUG="worker"
AGENT_NAME="Dev Worker"
AGENT_KIND="dev"
AGENT_ID="agent-worker"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$CONF_DIR/credentials/worker-token"
BOARD_CLI="$TMP/bin/worker-board"
MODEL_CLI="old-model"
CLAIM_UNASSIGNED="yes"
QUIET="on"
MANAGER="off"
EOF
cat > "$CONF_DIR/qa.conf" <<EOF
AGENT_SLUG="qa"
AGENT_NAME="QA Worker"
AGENT_KIND="qa"
AGENT_ID="agent-qa"
BOARD_ADAPTER="hypertask"
BOARD_ID="15,20"
TOKEN_FILE="$CONF_DIR/credentials/qa-token"
BOARD_CLI="$TMP/bin/qa-board"
MODEL_CLI="old-model"
CLAIM_UNASSIGNED="yes"
QUIET="on"
MANAGER="off"
EOF
cat > "$CONF_DIR/other.conf" <<EOF
AGENT_SLUG="other"
AGENT_NAME="Other Dev"
AGENT_KIND="dev"
AGENT_ID="agent-other"
BOARD_ADAPTER="hypertask"
BOARD_ID="99"
TOKEN_FILE="$CONF_DIR/credentials/other-token"
BOARD_CLI="$TMP/bin/other-board"
MODEL_CLI="old-model"
CLAIM_UNASSIGNED="yes"
QUIET="on"
MANAGER="off"
EOF
cat > "$CONF_DIR/regular.conf" <<EOF
AGENT_SLUG="regular"
AGENT_NAME="Regular Agent"
AGENT_KIND="worker"
AGENT_ID="agent-regular"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$CONF_DIR/credentials/regular-token"
BOARD_CLI="$TMP/bin/regular-board"
MODEL_CLI="old-model"
QUIET="on"
MANAGER="off"
EOF
cat > "$CONF_DIR/legacy.conf" <<EOF
AGENT_SLUG="legacy"
MANAGER="on"
EOF
cat > "$TMP/home/.config/agents/outside.conf" <<EOF
AGENT_SLUG="outside"
AGENT_NAME="Outside"
AGENT_KIND="dev"
AGENT_ID="agent-outside"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
MODEL_CLI="outside-model"
MANAGER="off"
EOF
printf '%s\n' 'do-not-touch' > "$CONF_DIR/credentials/worker-token"

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
  'task get REQUEST-1'|'task get REQUEST-2')
    printf '%s\n' "{\"tasks\":[{\"ticketNumber\":\"${3}\",\"projectId\":15,\"assignees\":[]}] }" ;;
  'project show 15')
    printf '%s\n' '{"project":{"id":15,"ownerId":6,"owner":{"id":6,"displayName":"Owner"}}}' ;;
  '--json comment list REQUEST-1')
    printf '%s\n' '{"comments":[{"id":41,"createdAt":"2026-09-20T10:00:00Z","creator":{"id":7,"displayName":"Other"},"text":"Do not use this."},{"id":42,"createdAt":"2026-09-20T11:00:00Z","creator":{"id":6,"displayName":"Owner"},"text":"<p>Please freeze the worker fleet.</p>"}]}' ;;
  '--json comment list REQUEST-2')
    printf '%s\n' '{"comments":[{"id":43,"createdAt":"2026-09-20T11:30:00Z","creator":{"id":7,"displayName":"Other"},"text":"Please stop the worker."}]}' ;;
  '--json project show 5500')
    printf '%s\n' '{"project":{"id":5500,"sections":[{"section_title":"Backlog"},{"section_title":"In Progress"},{"section_title":"Review"},{"section_title":"Done"}]}}' ;;
  task\ create*)
    if [ "${BOARD_LABEL_WARNING:-no}" = "yes" ] && [[ "$*" == *' --labels '* ]]; then
      printf '%s\n' 'LabelNotFound: adapter:hypertask'
      exit 1
    fi
    printf '%s\n' '{"task":{"ticketNumber":"AGTE-99","projectId":5500,"uniqueIndex":99}}' ;;
esac
EOF
chmod +x "$TMP/bin/systemctl" "$TMP/bin/board"
: > "$TMP/systemctl.log"
: > "$TMP/board.log"

run_template() {
  HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" AGENT_CONFIG_DIR="$CONF_DIR" \
    SYSTEMCTL_LOG="$TMP/systemctl.log" BOARD_LOG="$TMP/board.log" PATH="$TMP/bin:$PATH" \
    "$ROOT/scripts/agent-template" "$@"
}

assert_refused_without_change() {
  local name="$1" expected="$2" before="$3"
  shift 3
  set +e
  output="$(AGENT_SLUG=manager run_template "$@" 2>&1)"
  rc=$?
  set -e
  after="$(sha256sum "$CONF_DIR"/*.conf "$CONF_DIR"/credentials/* | sha256sum)"
  if [ "$rc" -ne 0 ] && printf '%s' "$output" | grep -qF "$expected" && [ "$before" = "$after" ]; then
    ok "$name" "$expected"
  else
    bad "$name" "rc=$rc output=$output"
  fi
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
foreign="$(AGENT_SLUG=manager run_template ctl stop 'ssh.service' 2>&1)"
foreign_rc=$?
set -e
if [ "$foreign_rc" -ne 0 ] && [ "$foreign" = "ctl refused: ssh.service is not a current agent slug" ] \
   && [ ! -s "$TMP/systemctl.log" ]; then
  ok ctl-refuses-foreign-unit "foreign unit never reaches systemctl"
else
  bad ctl-refuses-foreign-unit "rc=$foreign_rc output=$foreign systemctl=$(cat "$TMP/systemctl.log")"
fi

set +e
unapproved_stop="$(AGENT_SLUG=manager run_template ctl stop worker 2>&1)"
unapproved_stop_rc=$?
set -e
if [ "$unapproved_stop_rc" -ne 0 ] \
   && [ "$unapproved_stop" = 'ctl refused: stop requires --owner-request <ticket>' ] \
   && [ ! -s "$TMP/systemctl.log" ]; then
  ok ctl-stop-requires-owner-request "an unapproved stop cannot reach systemctl"
else
  bad ctl-stop-requires-owner-request "rc=$unapproved_stop_rc output=$unapproved_stop systemctl=$(cat "$TMP/systemctl.log")"
fi

set +e
nonowner_stop="$(AGENT_SLUG=manager run_template ctl stop worker --owner-request REQUEST-2 2>&1)"
nonowner_stop_rc=$?
set -e
if [ "$nonowner_stop_rc" -ne 0 ] \
   && [ "$nonowner_stop" = 'ctl refused: REQUEST-2 has no owner-authored request comment' ] \
   && [ ! -s "$TMP/systemctl.log" ]; then
  ok ctl-stop-rejects-nonowner-comment "another user's request cannot authorize a stop"
else
  bad ctl-stop-rejects-nonowner-comment "rc=$nonowner_stop_rc output=$nonowner_stop systemctl=$(cat "$TMP/systemctl.log")"
fi

approved_stop="$(AGENT_SLUG=manager run_template ctl stop worker --owner-request REQUEST-1)"
if [ "$approved_stop" = 'ctl stop worker: stopped agent-board-poll@worker.timer and agent-board-poll@worker.service' ] \
   && grep -q '^--user stop agent-board-poll@worker.timer agent-board-poll@worker.service$' "$TMP/systemctl.log" \
   && grep -qF 'comment add REQUEST-1 --text <p><strong>Decision: Agent mode change alarm.</strong>' "$TMP/board.log" \
   && grep -qF '<q>Please freeze the worker fleet.</q>' "$TMP/board.log"; then
  ok ctl-stop-owner-approved "owner request is verified, quoted, commented, and alarmed"
else
  bad ctl-stop-owner-approved "output=$approved_stop systemctl=$(cat "$TMP/systemctl.log") board=$(cat "$TMP/board.log")"
fi

set +e
owner="$(AGENT_SLUG=manager run_template delegate OWNER-1 worker --why 'Please take this' 2>&1)"
owner_rc=$?
set -e
if [ "$owner_rc" -ne 0 ] && [ "$owner" = "delegate refused: OWNER-1 is held by the board owner" ] \
   && ! grep -qE '^task assign OWNER-1|^comment add OWNER-1' "$TMP/board.log"; then
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
  HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" AGENT_CONFIG_DIR="$CONF_DIR" \
  SYSTEMCTL_LOG="$TMP/systemctl.log" BOARD_LOG="$TMP/board.log" "$ROOT/scripts/agent-template" ctl status worker)"
if [ "$status" = "ctl status worker: timer=active service=inactive" ]; then
  ok manager-identity-from-path "identity shim directory identifies the caller"
else
  bad manager-identity-from-path "output=$status"
fi

before_manual="$(sha256sum "$CONF_DIR"/*.conf "$CONF_DIR"/credentials/* | sha256sum)"
set +e
unapproved_manual="$(AGENT_SLUG=manager run_template mode manual --board 15 2>&1)"
unapproved_manual_rc=$?
set -e
after_manual="$(sha256sum "$CONF_DIR"/*.conf "$CONF_DIR"/credentials/* | sha256sum)"
if [ "$unapproved_manual_rc" -ne 0 ] \
   && [ "$unapproved_manual" = 'mode refused: manual mode requires --owner-request <ticket>' ] \
   && [ "$before_manual" = "$after_manual" ]; then
  ok mode-manual-requires-owner-request "an unapproved freeze changes no conf"
else
  bad mode-manual-requires-owner-request "rc=$unapproved_manual_rc output=$unapproved_manual"
fi

mode="$(AGENT_SLUG=manager run_template mode manual --board 15 --owner-request REQUEST-1)"
if printf '%s' "$mode" | grep -qF 'mode manual board 15: changed' \
   && printf '%s' "$mode" | grep -qF 'qa.conf' && printf '%s' "$mode" | grep -qF 'worker.conf' \
   && grep -q '^CLAIM_UNASSIGNED="no"$' "$CONF_DIR/worker.conf" \
   && grep -q '^CLAIM_UNASSIGNED="no"$' "$CONF_DIR/qa.conf" \
   && grep -q '^CLAIM_UNASSIGNED="yes"$' "$CONF_DIR/other.conf" \
   && compgen -G "$CONF_DIR/worker.conf.bak-*" >/dev/null \
   && compgen -G "$CONF_DIR/qa.conf.bak-*" >/dev/null; then
  ok mode-board-settings "manual changes only dev and QA confs on board 15"
else
  bad mode-board-settings "output=$mode"
fi

mode_default="$(AGENT_SLUG=manager run_template mode auto)"
if printf '%s' "$mode_default" | grep -qF 'mode auto board 15: changed' \
   && grep -q '^CLAIM_UNASSIGNED="yes"$' "$CONF_DIR/worker.conf" \
   && grep -q '^CLAIM_UNASSIGNED="yes"$' "$CONF_DIR/qa.conf"; then
  ok mode-defaults-manager-board "manager BOARD_ID supplies the omitted board"
else
  bad mode-defaults-manager-board "output=$mode_default"
fi

mode_runner="$(AGENT_SLUG=manager run_template mode manual --runner worker --owner-request REQUEST-1)"
if [ "$mode_runner" = 'mode manual runner worker: changed worker.conf' ] \
   && grep -q '^CLAIM_UNASSIGNED="no"$' "$CONF_DIR/worker.conf" \
   && grep -q '^CLAIM_UNASSIGNED="yes"$' "$CONF_DIR/qa.conf"; then
  ok mode-one-runner "manual escalation changes only the named runner"
else
  bad mode-one-runner "output=$mode_runner"
fi

worker_backups_before="$(find "$CONF_DIR" -maxdepth 1 -name 'worker.conf.bak-*' | wc -l)"
model="$(AGENT_SLUG=manager run_template model worker grok-fast)"
worker_backups_after="$(find "$CONF_DIR" -maxdepth 1 -name 'worker.conf.bak-*' | wc -l)"
if [ "$model" = 'model worker grok-fast: changed worker.conf' ] \
   && grep -q '^MODEL_CLI="cursor-agent -p --output-format text --model cursor-grok-4.6-high-fast -f --trust"$' "$CONF_DIR/worker.conf" \
   && [ "$worker_backups_after" -eq $((worker_backups_before + 1)) ]; then
  ok model-uses-named-preset "MODEL_CLI changed to the exact policy command"
else
  bad model-uses-named-preset "output=$model value=$(sed -n 's/^MODEL_CLI=//p' "$CONF_DIR/worker.conf")"
fi

worker_backups_before="$(find "$CONF_DIR" -maxdepth 1 -name 'worker.conf.bak-*' | wc -l)"
model="$(AGENT_SLUG=manager run_template model worker codex-sol)"
worker_backups_after="$(find "$CONF_DIR" -maxdepth 1 -name 'worker.conf.bak-*' | wc -l)"
if [ "$model" = 'model worker codex-sol: changed worker.conf' ] \
   && grep -q '^MODEL_CLI="/home/valentin/.local/bin/hax --provider=codex --model=gpt-5.6-sol --effort=high --no-session -p"$' "$CONF_DIR/worker.conf" \
   && [ "$worker_backups_after" -eq $((worker_backups_before + 1)) ]; then
  ok model-uses-codex-sol "MODEL_CLI changed to the exact Codex subscription command"
else
  bad model-uses-codex-sol "output=$model value=$(sed -n 's/^MODEL_CLI=//p' "$CONF_DIR/worker.conf")"
fi

qa_backups_before="$(find "$CONF_DIR" -maxdepth 1 -name 'qa.conf.bak-*' | wc -l)"
sections="$(AGENT_SLUG=manager run_template sections qa 'AI Review, QA')"
qa_backups_after="$(find "$CONF_DIR" -maxdepth 1 -name 'qa.conf.bak-*' | wc -l)"
if [ "$sections" = 'sections qa AI Review,QA: changed qa.conf' ] \
   && grep -q '^WATCH_SECTIONS="AI Review,QA"$' "$CONF_DIR/qa.conf" \
   && [ "$qa_backups_after" -eq $((qa_backups_before + 1)) ]; then
  ok sections-one-agent "WATCH_SECTIONS changed to the normalized column list"
else
  bad sections-one-agent "output=$sections value=$(sed -n 's/^WATCH_SECTIONS=//p' "$CONF_DIR/qa.conf")"
fi

qa_backups_before="$(find "$CONF_DIR" -maxdepth 1 -name 'qa.conf.bak-*' | wc -l)"
quiet="$(AGENT_SLUG=manager run_template quiet off qa)"
qa_backups_after="$(find "$CONF_DIR" -maxdepth 1 -name 'qa.conf.bak-*' | wc -l)"
if [ "$quiet" = 'quiet off qa: changed qa.conf' ] \
   && grep -q '^QUIET="off"$' "$CONF_DIR/qa.conf" \
   && grep -q '^QUIET="on"$' "$CONF_DIR/worker.conf" \
   && [ "$qa_backups_after" -eq $((qa_backups_before + 1)) ]; then
  ok quiet-one-agent "only the named current conf changed"
else
  bad quiet-one-agent "output=$quiet"
fi

quiet_all="$(AGENT_SLUG=manager run_template quiet off all)"
if printf '%s' "$quiet_all" | grep -qF 'quiet off all: changed' \
   && grep -q '^QUIET="off"$' "$CONF_DIR/manager.conf" \
   && grep -q '^QUIET="off"$' "$CONF_DIR/worker.conf" \
   && ! grep -q '^QUIET=' "$CONF_DIR/legacy.conf"; then
  ok quiet-all-current-confs "all skips the markerless legacy conf"
else
  bad quiet-all-current-confs "output=$quiet_all"
fi

before="$(sha256sum "$CONF_DIR"/*.conf "$CONF_DIR"/credentials/* | sha256sum)"
assert_refused_without_change model-refuses-free-command 'model refused: preset must be grok-fast, glm-flash, or codex-sol' "$before" \
  model worker 'sh -c touch /tmp/no'
assert_refused_without_change model-refuses-token-setting 'model refused: preset must be grok-fast, glm-flash, or codex-sol' "$before" \
  model worker 'TOKEN_FILE=/tmp/replacement'
assert_refused_without_change model-refuses-path-slug 'model refused: ../outside is not a current agent slug in the conf dir' "$before" \
  model ../outside grok-fast
assert_refused_without_change model-refuses-outside-conf 'model refused: outside is not a current agent slug in the conf dir' "$before" \
  model outside grok-fast
assert_refused_without_change model-refuses-markerless-conf 'model refused: legacy is not a current agent slug in the conf dir' "$before" \
  model legacy grok-fast
assert_refused_without_change quiet-refuses-credential-path 'quiet refused: credentials is not a current agent slug in the conf dir' "$before" \
  quiet on credentials
assert_refused_without_change sections-refuses-empty-column 'sections refused: list must be * or comma-separated non-empty section names' "$before" \
  sections qa 'AI Review,,QA'

for spec in \
  'mode|mode refused: caller regular is not a manager|mode manual' \
  'model|model refused: caller regular is not a manager|model worker grok-fast' \
  'sections|sections refused: caller regular is not a manager|sections worker QA' \
  'quiet|quiet refused: caller regular is not a manager|quiet on worker'; do
  IFS='|' read -r name expected args <<< "$spec"
  set +e
  output="$(AGENT_SLUG=regular run_template $args 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && [ "$output" = "$expected" ]; then
    ok "$name-manager-gate" "non-manager refused"
  else
    bad "$name-manager-gate" "rc=$rc output=$output"
  fi
done

feedback="$(AGENT_SLUG=manager run_template feedback --as manager --kind bug --what 'Session feedback' \
  --got 'bad' --expected 'good')"
if printf '%s' "$feedback" | grep -qF 'Feedback filed: bug: Session feedback. Ticket: AGTE-99 https://app.hypertask.ai/detail/project-5500/99' \
   && grep -q '^task create --project 5500 ' "$TMP/board.log"; then
  ok feedback-as-files "manager --as reads BOARD_CLI and files with the mock"
else
  bad feedback-as-files "output=$feedback board=$(cat "$TMP/board.log")"
fi

before_creates="$(grep -c '^task create ' "$TMP/board.log" || true)"
set +e
feedback_regular="$(AGENT_SLUG=regular run_template feedback --as regular --kind idea --what bad --got bad --expected good 2>&1)"
feedback_regular_rc=$?
feedback_mismatch="$(AGENT_SLUG=regular run_template feedback --as manager --kind idea --what bad --got bad --expected good 2>&1)"
feedback_mismatch_rc=$?
set -e
after_creates="$(grep -c '^task create ' "$TMP/board.log" || true)"
if [ "$feedback_regular_rc" -ne 0 ] \
   && [ "$feedback_regular" = 'feedback refused: caller regular is not a manager' ] \
   && [ "$feedback_mismatch_rc" -ne 0 ] \
   && [ "$feedback_mismatch" = 'feedback refused: --as manager does not match caller regular' ] \
   && [ "$before_creates" = "$after_creates" ]; then
  ok feedback-as-manager-gate "non-manager and identity mismatch make no board write"
else
  bad feedback-as-manager-gate "regular=$feedback_regular mismatch=$feedback_mismatch"
fi

feedback_cli="$(AGENT_SLUG= run_template feedback --board-cli "$TMP/bin/board" --kind bug \
  --what 'Direct session feedback' --got 'bad' --expected 'good')"
if printf '%s' "$feedback_cli" | grep -qF 'Feedback filed: bug: Direct session feedback. Ticket: AGTE-99 https://app.hypertask.ai/detail/project-5500/99'; then
  ok feedback-board-cli-files "direct --board-cli remains available"
else
  bad feedback-board-cli-files "output=$feedback_cli"
fi

feedback_env="$(AGENT_SLUG= AGENT_BOARD_CLI="$TMP/bin/board" run_template feedback --kind bug \
  --what 'Runner session feedback' --got 'bad' --expected 'good')"
if printf '%s' "$feedback_env" | grep -qF 'Feedback filed: bug: Runner session feedback. Ticket: AGTE-99 https://app.hypertask.ai/detail/project-5500/99'; then
  ok feedback-env-cli-files "AGENT_BOARD_CLI infers the adapter and files"
else
  bad feedback-env-cli-files "output=$feedback_env"
fi

feedback_retry="$(BOARD_LABEL_WARNING=yes AGENT_SLUG= run_template feedback \
  --board-cli "$TMP/bin/board" --kind idea --what 'Clear retry result' \
  --got 'labels unavailable' --expected 'show only the filed ticket' 2>&1)"
if [ "$feedback_retry" = 'Feedback filed: idea: Clear retry result. Ticket: AGTE-99 https://app.hypertask.ai/detail/project-5500/99' ]; then
  ok feedback-label-retry-quiet "successful retry hides the internal label warning"
else
  bad feedback-label-retry-quiet "output=$feedback_retry"
fi

if grep -q $'who=regular\twhat=ctl stop worker' "$TMP/state/agent-board-poll/manager-actions.log" \
   && grep -qF $'who=manager\twhat=approved_change=stopped runner worker owner_request="Please freeze the worker fleet."' "$TMP/state/agent-board-poll/manager-actions.log" \
   && grep -qF $'who=manager\twhat=approved_change=set board 15 to manual mode for qa.conf worker.conf owner_request="Please freeze the worker fleet."' "$TMP/state/agent-board-poll/manager-actions.log" \
   && grep -q $'who=manager\twhat=mode manual --board 15' "$TMP/state/agent-board-poll/manager-actions.log" \
   && grep -q $'who=manager\twhat=model worker grok-fast' "$TMP/state/agent-board-poll/manager-actions.log" \
   && grep -q $'who=manager\twhat=sections qa AI Review, QA' "$TMP/state/agent-board-poll/manager-actions.log" \
   && grep -q $'who=manager\twhat=quiet off qa' "$TMP/state/agent-board-poll/manager-actions.log" \
   && grep -q $'who=manager\twhat=feedback --as manager' "$TMP/state/agent-board-poll/manager-actions.log"; then
  ok manager-actions-audited "accepted and refused calls include caller and command"
else
  bad manager-actions-audited "log=$(cat "$TMP/state/agent-board-poll/manager-actions.log")"
fi

if grep -qF 'if { [ "${MANAGER:-off}" = "on" ] || [ "$MAINTAINER" = "on" ]; }' "$ROOT/scripts/agent-board-poll" \
   && grep -qF 'agent-template mode manual|auto [--board <id>|--runner <slug>]' "$ROOT/scripts/agent-board-poll" \
   && grep -qF 'agent-template model <slug> <preset>' "$ROOT/scripts/agent-board-poll" \
   && grep -qF 'codex-sol' "$ROOT/scripts/agent-board-poll" \
   && grep -qF 'agent-template quiet on|off [<slug>|all]' "$ROOT/scripts/agent-board-poll" \
   && grep -qF 'agent-template feedback --as <slug>' "$ROOT/scripts/agent-board-poll" \
   && grep -qF 'switch the product board to manual' "$ROOT/scripts/agent-board-poll" \
   && grep -qF 'put dev 2 on grok fast' "$ROOT/scripts/agent-board-poll" \
   && grep -qF 'quiet off for qa-1' "$ROOT/scripts/agent-board-poll" \
   && grep -qF 'file a toolkit ticket:' "$ROOT/scripts/agent-board-poll"; then
  ok runner-manager-prompt-gated "run prompt lists exact syntax and examples"
else
  bad runner-manager-prompt-gated "runner manager command contract is missing"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
