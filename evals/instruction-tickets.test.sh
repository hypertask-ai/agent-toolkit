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
BOARD_FIXTURE="$TMP/board-fixture"
mkdir -p "$CONF_DIR" "$TMP/bin" "$STATE_DIR" "$BOARD_FIXTURE"

cat > "$TMP/bin/board" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BOARD_FIXTURE/calls"
if [ "${1:-} ${2:-} ${3:-}" = "--json project show" ]; then
  if [ "${SECTION_MODE:-triage}" = triage ]; then
    printf '%s\n' '{"project":{"id":5500,"defaultSections":["Inbox"],"sections":[{"id":1,"section_title":"Inbox"},{"id":2,"section_title":"Triage"}]}}'
  else
    printf '%s\n' '{"project":{"id":5500,"defaultSections":["Inbox"],"sections":[{"id":1,"section_title":"Inbox"}]}}'
  fi
  exit 0
fi
if [ "${1:-} ${2:-}" = "task create" ]; then
  if [ "${FAIL_CREATE:-no}" = yes ]; then
    printf '%s\n' 'exact ticket API failure' >&2
    exit 42
  fi
  count="$(cat "$BOARD_FIXTURE/create-count" 2>/dev/null || printf 0)"
  count=$((count + 1))
  printf '%s\n' "$count" > "$BOARD_FIXTURE/create-count"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project|--section|--title|--description)
        key="${1#--}"
        printf '%s' "$2" > "$BOARD_FIXTURE/$key"
        shift 2 ;;
      --json) shift ;;
      *) printf 'unexpected create argument %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  printf '{"task":{"id":"task-%s","ticketNumber":"AGTE-%s","projectId":5500,"uniqueIndex":%s}}\n' "$count" "$count" "$count"
  exit 0
fi
if [ "${1:-} ${2:-}" = "task assign" ]; then
  [ "${4:-}" = "--self" ] || { printf 'assignment did not use --self\n' >&2; exit 3; }
  printf '%s\n' "$3" >> "$BOARD_FIXTURE/assigned"
  exit 0
fi
printf 'unexpected board call: %s\n' "$*" >&2
exit 2
EOF
chmod +x "$TMP/bin/board"
: > "$BOARD_FIXTURE/calls"

write_conf() {
  cat > "$CONF_DIR/product-bot.conf" <<EOF
AGENT_SLUG="product-bot"
AGENT_NAME="Product Bot"
AGENT_KIND="worker"
AGENT_ID="agent-product"
BOARD_ADAPTER="hypertask"
BOARD_ID="15,5156,5500"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/bin/board"
MODEL_CLI="$TMP/bin/model"
MANAGER="off"
MAINTAINER="on"
EOF
}
write_conf
printf 'agent-token\n' > "$TMP/token"

run_template() {
  HOME="$HOME_DIR" XDG_STATE_HOME="$STATE_DIR" AGENT_CONFIG_DIR="$CONF_DIR" \
    BOARD_FIXTURE="$BOARD_FIXTURE" PATH="$TMP/bin:$PATH" AGENT_SLUG= \
    "$ROOT/scripts/agent-template" "$@"
}

instruction=$'Review <the setup> now.\n\nThen report the pull request.'
created="$(run_template instruct product-bot "$instruction" \
  --ticket https://app.hypertask.ai/detail/project-15/9)"
marker="$(find "$STATE_DIR/agent-template/instruction-tickets" -name '*.json' -print -quit)"
queued="$(find "$STATE_DIR/agent-board-poll/product-bot-instructions" -name '*.json' -print -quit 2>/dev/null || true)"
if [ "$created" = 'instruction filed: AGTE-1 https://app.hypertask.ai/detail/project-5500/1' ] \
   && [ -z "$queued" ] && [ -f "$marker" ] \
   && [ "$(cat "$BOARD_FIXTURE/section")" = Triage ] \
   && [ "$(cat "$BOARD_FIXTURE/assigned")" = AGTE-1 ] \
   && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ticket_id"])' "$marker")" = task-1 ] \
   && [ "$(cat "$BOARD_FIXTURE/title")" = 'Review <the setup> now.' ] \
   && grep -q '^<p><strong>Instruction</strong></p><p>Then report the pull request\.</p><p><strong>Source ticket</strong>:' "$BOARD_FIXTURE/description"; then
  ok instruct-creates-ticket 'ticket is HTML, assigned to Product Bot, and queue transport is removed'
else
  bad instruct-creates-ticket "output=$created queued=${queued:-none} calls=$(cat "$BOARD_FIXTURE/calls")"
fi

rm -rf "$STATE_DIR/agent-board-poll/product-bot-instructions"
set +e
failed="$(FAIL_CREATE=yes run_template instruct product-bot 'Keep this instruction safe' 2>&1)"
failed_rc=$?
set -e
failed_queue="$(find "$STATE_DIR/agent-board-poll/product-bot-instructions" -name '*.json' -print -quit 2>/dev/null || true)"
if [ "$failed_rc" -ne 0 ] && printf '%s\n' "$failed" | grep -q '^exact ticket API failure$' \
   && [ -n "$failed_queue" ] \
   && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["instruction"])' "$failed_queue")" = 'Keep this instruction safe' ]; then
  ok instruct-retains-failed-queue 'API error is printed and transport remains'
else
  bad instruct-retains-failed-queue "rc=$failed_rc output=$failed queue=${failed_queue:-none}"
fi

rm -rf "$STATE_DIR/agent-board-poll/product-bot-instructions" \
       "$STATE_DIR/agent-template/instruction-tickets"
mkdir -p "$STATE_DIR/agent-board-poll/product-bot-instructions"
legacy_queue="$STATE_DIR/agent-board-poll/product-bot-instructions/advisor-legacy-1.json"
printf '%s\n' '{"id":"advisor-legacy-1","source":"advisor","instruction":"Migrate this queued instruction","ticket":"","created":"2026-09-17T00:00:00Z"}' > "$legacy_queue"
printf '0\n' > "$BOARD_FIXTURE/create-count"
: > "$BOARD_FIXTURE/assigned"
install_once() {
  HOME="$HOME_DIR" XDG_STATE_HOME="$STATE_DIR" AGENT_CONFIG_DIR="$CONF_DIR" \
    BOARD_FIXTURE="$BOARD_FIXTURE" SECTION_MODE=fallback PATH="$TMP/bin:$PATH" \
    SKIP_TEMPLATE_EVALS=yes SKIP_COMPANY_SKILLS=yes \
    AGENT_TEMPLATE_INSTALL_STATE="$STATE_DIR/install-state" \
    bash "$ROOT/install.sh" --dest "$TMP/installed-skill" --bin "$TMP/installed-bin" --no-host-notes
}
install_once > "$TMP/install-1.out" 2> "$TMP/install-1.err"
first_marker="$(find "$STATE_DIR/agent-template/instruction-tickets" -name '*advisor-legacy-1.json' -print -quit)"
# Recreate the same transport file to model interruption after the id marker was written.
printf '%s\n' '{"id":"advisor-legacy-1","source":"advisor","instruction":"Migrate this queued instruction","ticket":"","created":"2026-09-17T00:00:00Z"}' > "$legacy_queue"
install_once > "$TMP/install-2.out" 2> "$TMP/install-2.err"
if [ "$(cat "$BOARD_FIXTURE/create-count")" -eq 1 ] \
   && [ ! -f "$legacy_queue" ] && [ -f "$first_marker" ] \
   && [ "$(cat "$BOARD_FIXTURE/section")" = Inbox ] \
   && [ "$(grep -c '^AGTE-1$' "$BOARD_FIXTURE/assigned")" -eq 2 ]; then
  ok install-migration-idempotent 'two installs keep one ticket and consume the recreated transport'
else
  bad install-migration-idempotent "creates=$(cat "$BOARD_FIXTURE/create-count") assigned=$(cat "$BOARD_FIXTURE/assigned")"
fi

POLL="$TMP/poll"
COMPANY="$POLL/company"
REPO="$POLL/repo"
mkdir -p "$POLL/bin" "$POLL/state" "$POLL/conf" "$COMPANY/skills/talk-to-valentin/reference" "$REPO"
printf '# skills\n' > "$COMPANY/INDEX.md"
printf 'test\n' > "$COMPANY/VERSION"
for name in pospeak.md unslop.md i-have-adhd.md; do
  printf 'Use plain words.\n' > "$COMPANY/skills/talk-to-valentin/reference/$name"
done
(
  cd "$REPO"
  git init -q -b main
  git config user.name test
  git config user.email test@example.com
  touch README.md
  git add README.md
  git commit -qm init
)
printf 'agent-token\n' > "$POLL/token"
cat > "$POLL/conf/product-bot.conf" <<EOF
AGENT_SLUG="product-bot"
AGENT_NAME="Product Bot"
AGENT_KIND="worker"
AGENT_ID="agent-product"
AGENT_REPO="$REPO"
AGENT_MISSION="Maintain setup"
PR_REPO="example/product-bot"
BOARD_ADAPTER="hypertask"
BOARD_ID="15,5156,5500"
TOKEN_FILE="$POLL/token"
BOARD_CLI="$POLL/bin/board-wrapper"
WATCH_SECTIONS="Triage,Inbox"
MODEL_CLI="$POLL/bin/model"
QUIET="on"
MANAGER="off"
MAINTAINER="on"
EOF
cat > "$POLL/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *'/mcp/tasks?project_id=5500&limit=100')
    printf '%s\n200' '{"tasks":[{"id":"task-manual","ticketNumber":"AGTE-25","section":"Inbox","title":"Hand-created instruction","description":"<p>Build the requested toolkit change.</p>","assignees":[{"agent":{"id":"agent-product","displayName":"Product Bot"}}],"commentCount":0}]}' ;;
  *'/mcp/tasks?project_id=5500&status=Normal'*)
    printf '%s\n200' '{"tasks":[{"id":"task-manual","ticketNumber":"AGTE-25","section":"Inbox","title":"Hand-created instruction","description":"<p>Build the requested toolkit change.</p>","assignees":[{"agent":{"id":"agent-product","displayName":"Product Bot"}}],"commentCount":0}]}' ;;
  *'/mcp/tasks?'*) printf '%s\n200' '{"tasks":[]}' ;;
  *) printf '%s\n200' '{}' ;;
esac
EOF
cat > "$POLL/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
cat > "$POLL/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
printf '{}\n'
EOF
cat > "$POLL/bin/model" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$POLL/bin"/*
set +e
dry="$(HOME="$POLL" XDG_STATE_HOME="$POLL/state" AGENT_CONFIG_DIR="$POLL/conf" \
  COMPANY_SKILLS_DIR="$COMPANY" PATH="$POLL/bin:/usr/bin:/bin" \
  "$ROOT/scripts/agent-board-poll" --once --dry-run product-bot 2>&1)"
dry_rc=$?
set -e
if [ "$dry_rc" -eq 0 ] && printf '%s\n' "$dry" | grep -q 'AGTE-25' \
   && printf '%s\n' "$dry" | grep -q '1 ticket(s) would be picked up'; then
  ok manual-ticket-is-work 'dry run selects a hand-created assigned board 5500 ticket'
else
  bad manual-ticket-is-work "rc=$dry_rc output=$dry"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
