#!/usr/bin/env bash
# Bot writer gate checks use a fake Hypertask CLI and never call the board.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state"
printf 'test-token\n' > "$TMP/token"
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "--token" ]; then shift 2; fi
if [ "${1:-} ${2:-} ${3:-}" = "--json project show" ]; then
  printf '%s\n' '{"project":{"ownerId":"owner-1"}}'
  exit 0
fi
if [ "${1:-} ${2:-} ${3:-}" = "--json comment list" ]; then
  printf '%s\n' '{"comments":[]}'
  exit 0
fi
if [ "${1:-} ${2:-} ${3:-}" = "--json ai write" ]; then
  printf '%s\n' "$*" >> "$AI_CALLS"
  [ "${WRITER_FAIL:-no}" != yes ] || exit 42
  printf '%s\n' "$WRITER_JSON"
  exit 0
fi
if { [ "${1:-}" = task ] || [ "${1:-}" = tasks ]; } && [ "${2:-}" = create ]; then
  shift 2
  : > "$TASK_ARGS"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) printf '%s' "$2" > "$TASK_TITLE"; shift 2 ;;
      --description) printf '%s' "$2" > "$TASK_DESCRIPTION"; shift 2 ;;
      *) printf '%s\n' "$1" >> "$TASK_ARGS"; shift ;;
    esac
  done
  printf '%s\n' '{"task":{"id":"task-1","ticketNumber":"TEST-1"}}'
  exit 0
fi
if [ "${1:-} ${2:-}" = "comment add" ]; then
  shift 2
  text=""
  improve=no
  improve_command=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --text|--body) text="$2"; shift 2 ;;
      --improve) improve=yes; shift ;;
      --improve-command) improve_command="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ "$improve" = yes ]; then
    printf '%s\n' "${improve_command:-improve-readability}" >> "$IMPROVE_CALLS"
  else
    printf '%s\n' no >> "$IMPROVE_CALLS"
  fi
  if [ "$improve" != no ] && [ "${IMPROVE_UNSUPPORTED:-no}" = yes ]; then
    printf 'error: unknown option --improve\n' >&2
    exit 2
  fi
  if [ "$improve" != no ] && [ "${WRITER_FAIL:-no}" = yes ]; then
    printf 'AI writer failed\n' >&2
    exit 43
  fi
  if [ "$improve" != no ]; then text="$IMPROVED_COMMENT"; fi
  printf '%s' "$text" > "$COMMENT_TEXT"
  printf 'posted\n'
  exit 0
fi
printf 'unexpected fake Hypertask call\n' >&2
exit 2
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
data=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --data) data="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "$data" > "$API_POST_CAPTURE"
printf '%s\n%s' '{"success":true,"comment":{"id":71}}' "${API_POST_STATUS:-200}"
EOF
chmod +x "$TMP/bin/hypertask" "$TMP/bin/curl"

# shellcheck source=/dev/null
. "$ROOT/adapters/hypertask/adapter.sh"
adapter_install_board_cli writer-gate "$TMP/token" "$TMP/htbot" 'Product Bot' agent-product 5500 off

export PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_STATE_HOME="$TMP/state"
export AI_CALLS="$TMP/ai-calls" TASK_ARGS="$TMP/task-args"
export TASK_TITLE="$TMP/task-title" TASK_DESCRIPTION="$TMP/task-description"
export IMPROVE_CALLS="$TMP/improve-calls" COMMENT_TEXT="$TMP/comment-text"
export API_POST_CAPTURE="$TMP/api-post"
: > "$AI_CALLS"
: > "$IMPROVE_CALLS"
: > "$API_POST_CAPTURE"

WRITER_JSON='{"success":true,"title":"Clear rewritten title","html":"<p>Clear rewritten description.</p>"}' \
  "$TMP/htbot" tasks create --project 5500 --title 'Original title' \
    --description 'Original description' >/dev/null
if [ "$(cat "$TASK_TITLE")" = 'Clear rewritten title' ] \
   && [ "$(cat "$TASK_DESCRIPTION")" = '<p>Clear rewritten description.</p>' ] \
   && grep -q -- '--project 5500 --mode task-writer' "$AI_CALLS"; then
  ok task-rewrite-applied 'task title and description come from task-writer mode'
else
  bad task-rewrite-applied "title=$(cat "$TASK_TITLE") description=$(cat "$TASK_DESCRIPTION")"
fi

: > "$AI_CALLS"
WRITER_JSON='{"success":true,"title":"unused","html":"<p>unused</p>"}' \
  "$TMP/htbot" task create --raw --project 5500 --title 'Machine title' \
    --description '{"resume":"run-7"}' >/dev/null
if [ ! -s "$AI_CALLS" ] && [ "$(cat "$TASK_TITLE")" = 'Machine title' ] \
   && [ "$(cat "$TASK_DESCRIPTION")" = '{"resume":"run-7"}' ] \
   && ! grep -q -- '--raw' "$TASK_ARGS"; then
  ok task-raw-bypasses-writer '--raw posts machine task text unchanged'
else
  bad task-raw-bypasses-writer "ai=$(cat "$AI_CALLS") title=$(cat "$TASK_TITLE")"
fi

: > "$AI_CALLS"
WRITER_FAIL=yes WRITER_JSON='{}' \
  "$TMP/htbot" task create --project 5500 --title 'Fallback title' \
    --description 'Fallback description' >/dev/null 2>"$TMP/task-failure.err"
if [ "$(cat "$TASK_TITLE")" = 'Fallback title' ] \
   && [ "$(cat "$TASK_DESCRIPTION")" = 'Fallback description' ] \
   && [ "$(grep -c '^WARNING: Hypertask AI writer failed; posting the original task text$' "$TMP/task-failure.err")" -eq 1 ]; then
  ok task-writer-fallback 'writer failure posts original task text with one warning'
else
  bad task-writer-fallback "error=$(cat "$TMP/task-failure.err")"
fi

original='<p><strong>Decision: The original release is ready.</strong></p><p>Next: approve it.</p>'
rewritten='<p><strong>Decision: The clearer release is ready.</strong></p><p>Next: approve it.</p>'
: > "$IMPROVE_CALLS"
: > "$API_POST_CAPTURE"
IMPROVED_COMMENT="$rewritten" "$TMP/htbot" comment add TEST-1 --text "$original" >/dev/null
if [ "$(cat "$COMMENT_TEXT")" = "$rewritten" ] \
   && [ "$(cat "$IMPROVE_CALLS")" = improve-readability ] \
   && [ ! -s "$API_POST_CAPTURE" ] \
   && printf '%s' "$(cat "$COMMENT_TEXT")" | grep -q '^<p><strong>Decision:'; then
  ok comment-rewrite-applied 'an unstamped ticket-run status uses the normal CLI writer path'
else
  bad comment-rewrite-applied "comment=$(cat "$COMMENT_TEXT") calls=$(cat "$IMPROVE_CALLS") api=$(cat "$API_POST_CAPTURE")"
fi

: > "$AI_CALLS"
: > "$COMMENT_TEXT"
: > "$API_POST_CAPTURE"
stamped_original='<p><strong>Answer: The original answer is ready.</strong></p><p>Next: read it.</p>'
stamped_rewrite='<p><strong>Answer: The rewritten answer is ready.</strong></p><p>Next: read it.</p>'
WRITER_JSON="{\"success\":true,\"html\":\"$stamped_rewrite\"}" AGENT_REPLY_TO_COMMENT_ID=240575 \
  "$TMP/htbot" comment add TEST-1 --text "$stamped_original" >/dev/null
if python3 - "$API_POST_CAPTURE" "$stamped_rewrite" <<'PYEOF'
import json, sys
row = json.load(open(sys.argv[1], encoding="utf-8"))
assert row == {"ticket_number": "TEST-1", "text": sys.argv[2], "reply_to_comment_id": 240575}
PYEOF
then
  if [ ! -s "$COMMENT_TEXT" ] \
     && grep -q -- '--task TEST-1 --mode write-with-ai' "$AI_CALLS" \
     && grep -qx 'TEST-1 71' "$TMP/state/agent-board-poll/writer-gate.posted-comments"; then
    ok stamped-comment-api 'a stamped comment rewrites first, then posts the rewritten HTML with its reply id'
  else
    bad stamped-comment-api "cli=$(cat "$COMMENT_TEXT") ai=$(cat "$AI_CALLS")"
  fi
else
  bad stamped-comment-api "payload=$(cat "$API_POST_CAPTURE")"
fi

: > "$COMMENT_TEXT"
: > "$API_POST_CAPTURE"
API_POST_STATUS=503 AGENT_REPLY_TO_COMMENT_ID=240576 \
  "$TMP/htbot" comment add TEST-2 --raw --text "$original" >/dev/null 2>"$TMP/reply-api-failure.err"
if [ "$(cat "$COMMENT_TEXT")" = "$original" ] \
   && grep -q '^reply-stamped comment API failed on TEST-2 (HTTP 503); falling back to CLI without reply stamp$' "$TMP/reply-api-failure.err"; then
  ok stamped-comment-fallback 'a failed stamped API post logs the failure and falls back to the unstamped CLI'
else
  bad stamped-comment-fallback "comment=$(cat "$COMMENT_TEXT") error=$(cat "$TMP/reply-api-failure.err")"
fi

: > "$IMPROVE_CALLS"
raw='{"run":"run-7","resume":"opaque"}'
IMPROVED_COMMENT='unused' "$TMP/htbot" comment add TEST-2 --raw --text "$raw" >/dev/null
if [ "$(cat "$COMMENT_TEXT")" = "$raw" ] && [ "$(cat "$IMPROVE_CALLS")" = no ]; then
  ok comment-raw-bypasses-writer '--raw posts machine comments without the writer'
else
  bad comment-raw-bypasses-writer "comment=$(cat "$COMMENT_TEXT") calls=$(cat "$IMPROVE_CALLS")"
fi

: > "$IMPROVE_CALLS"
WRITER_FAIL=yes IMPROVED_COMMENT='unused' \
  "$TMP/htbot" comment add TEST-3 --text "$original" >/dev/null 2>"$TMP/comment-failure.err"
if [ "$(cat "$COMMENT_TEXT")" = "$original" ] \
   && [ "$(paste -sd, "$IMPROVE_CALLS")" = 'improve-readability,no' ] \
   && [ "$(grep -c '^AI writer failed$' "$TMP/comment-failure.err")" -eq 1 ] \
   && [ "$(grep -c '^WARNING: Hypertask AI writer failed on TEST-3; posting the original comment$' "$TMP/comment-failure.err")" -eq 1 ]; then
  ok comment-writer-fallback 'a refused write prints the CLI error and posts the original'
else
  bad comment-writer-fallback "comment=$(cat "$COMMENT_TEXT") calls=$(cat "$IMPROVE_CALLS") error=$(cat "$TMP/comment-failure.err")"
fi

: > "$AI_CALLS"
: > "$IMPROVE_CALLS"
fallback_rewrite='<p><strong>Decision: The fallback writer kept this marker.</strong></p><p>Next: approve it.</p>'
IMPROVE_UNSUPPORTED=yes WRITER_JSON="{\"success\":true,\"html\":\"$fallback_rewrite\"}" \
  "$TMP/htbot" comment add TEST-4 --text "$original" >/dev/null
if [ "$(cat "$COMMENT_TEXT")" = "$fallback_rewrite" ] \
   && grep -q -- '--task TEST-4 --mode write-with-ai' "$AI_CALLS"; then
  ok old-cli-comment-writer 'CLIs without --improve use write-with-ai mode'
else
  bad old-cli-comment-writer "comment=$(cat "$COMMENT_TEXT") ai=$(cat "$AI_CALLS")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
