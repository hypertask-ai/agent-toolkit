#!/usr/bin/env bash
# Manager commands must find the adapter's config directory without env hints.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

slug="fallback"
CONF_DIR="$TMP/home/.config/hypertask-agents"
SHIM="$TMP/state/agent-identity-shims/$slug"
mkdir -p "$CONF_DIR" "$SHIM" "$TMP/bin" "$TMP/state"
cat > "$CONF_DIR/$slug.conf" <<EOF
AGENT_SLUG="$slug"
AGENT_NAME="Fallback Manager"
AGENT_KIND="worker"
AGENT_ID="agent-fallback"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/bin/board"
MODEL_CLI="provider"
MANAGER="on"
MAINTAINER="on"
EOF
printf 'token\n' > "$TMP/token"
cat > "$TMP/bin/board" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BOARD_LOG"
case "$*" in
  '--json project show 5500') printf '%s\n' '{"project":{"defaultSections":["Inbox"],"sections":[{"section_title":"Inbox"}]}}' ;;
  task\ create*) printf '%s\n' '{"task":{"id":"task-101","ticketNumber":"AGTE-101","projectId":5500,"uniqueIndex":101}}' ;;
  'task assign AGTE-101 --self') printf '%s\n' '{}' ;;
esac
EOF
chmod +x "$TMP/bin/board"
: > "$TMP/board.log"

run_template() {
  env -u AGENT_CONFIG_DIR -u AGENT_SLUG \
    HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" BOARD_LOG="$TMP/board.log" \
    PATH="$SHIM:$TMP/bin:$PATH" "$ROOT/scripts/agent-template" "$@"
}

feedback="$(run_template feedback --as "$slug" --kind bug \
  --what 'Adapter config fallback regression' --got 'not found' --expected 'found')"
if printf '%s\n' "$feedback" | grep -q '^filed AGTE-101 ' \
   && grep -q '^task create --project 5500 ' "$TMP/board.log"; then
  ok feedback-adapter-conf-fallback 'feedback --as finds only the Hypertask default conf'
else
  bad feedback-adapter-conf-fallback "output=$feedback board=$(cat "$TMP/board.log")"
fi

instruction="$(run_template instruct "$slug" 'Review the adapter config fallback')"
instruction_file="$(find "$TMP/state/agent-board-poll/$slug-instructions" -name '*.json' -print -quit 2>/dev/null || true)"
marker="$(find "$TMP/state/agent-template/instruction-tickets" -name '*.json' -print -quit 2>/dev/null || true)"
if [[ "$instruction" == 'instruction filed: AGTE-101 '* ]] \
   && [ -z "$instruction_file" ] && [ -n "$marker" ] \
   && grep -q '^task assign AGTE-101 --self$' "$TMP/board.log"; then
  ok instruct-adapter-conf-fallback 'instruct finds the Hypertask conf and its agent board CLI'
else
  bad instruct-adapter-conf-fallback "output=$instruction file=${instruction_file:-none} marker=${marker:-missing}"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
