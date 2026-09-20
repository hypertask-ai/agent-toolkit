#!/usr/bin/env bash
# Task Writer checks use fixture JSON and never call the AI service.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/bin" "$TMP/conf" "$TMP/state" "$TMP/board"
printf 'token\n' > "$TMP/token"
cat > "$TMP/bin/board" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-} ${2:-} ${3:-}" = "--json ai write" ]; then
  [ "${REFUSE_WRITES:-no}" = yes ] || { printf 'unexpected AI write\n' >&2; exit 3; }
  count="$(cat "$BOARD_FIXTURE/rewrite-count" 2>/dev/null || printf 0)"
  count=$((count + 1))
  printf '%s\n' "$count" > "$BOARD_FIXTURE/rewrite-count"
  printf '%s' "$4" > "$BOARD_FIXTURE/rewrite-prompt-$count"
  printf '%s\n' '{"success":true,"title":"Valid rewrite title","html":"<p><strong>The outcome is clear.</strong></p><h2>What went wrong</h2><p>One. Two. Three. Four.</p><h2>What changes</h2><ol><li>Keep it.</li></ol><h2>Done when</h2><p>The ticket is posted.</p>"}'
  exit 0
fi
if [ "${1:-} ${2:-} ${3:-}" = "--json project show" ]; then
  printf '%s\n' '{"project":{"id":5500,"sections":[{"section_title":"Backlog"},{"section_title":"In Progress"},{"section_title":"Review"},{"section_title":"Done"}]}}'
  exit 0
fi
if [ "${1:-} ${2:-}" = "task create" ]; then
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title|--description|--section|--project|--labels|--due|--priority)
        printf '%s' "$2" > "$BOARD_FIXTURE/${1#--}"
        shift 2 ;;
      --json) shift ;;
      *) printf 'unexpected argument: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  printf '%s\n' '{"task":{"id":"task-77","ticketNumber":"AGTE-77","projectId":5500,"uniqueIndex":77}}'
  exit 0
fi
if [ "${1:-} ${2:-}" = "task assign" ]; then exit 0; fi
printf 'the AI fixture should have prevented this call: %s\n' "$*" >&2
exit 3
EOF
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *' --json project show '*) printf '%s\n' '{"project":{"ownerId":6}}' ;;
  *' --json comment list '*) printf '%s\n' '{"comments":[]}' ;;
  *' comment add '*)
    if [[ " $* " = *' --improve '* ]]; then
      printf 'error: unknown option --improve\n' >&2
      exit 2
    fi
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [ "${args[$i]}" = "--text" ]; then printf '%s' "${args[$((i + 1))]}" > "$COMMENT_CAPTURE"; fi
    done
    printf 'posted\n' ;;
  *) printf '{}\n' ;;
esac
EOF
chmod +x "$TMP/bin/"*
cat > "$TMP/conf/product-bot.conf" <<EOF
AGENT_SLUG="product-bot"
AGENT_NAME="Product Bot"
AGENT_ID="agent-product"
BOARD_ADAPTER="hypertask"
BOARD_ID="5500"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/bin/board"
MAINTAINER="on"
MANAGER="off"
EOF

run_template() {
  HOME="$TMP" XDG_STATE_HOME="$TMP/state" AGENT_CONFIG_DIR="$TMP/conf" \
    BOARD_FIXTURE="$TMP/board" PATH="$TMP/bin:/usr/bin:/bin" AGENT_SLUG= "$ROOT/scripts/agent-template" "$@"
}

blob=$'Please fix ticket writing because this long block mixes the customer result, the current failure, implementation notes, and proof.\nKeep every detail, but make the ticket easy for a product owner to scan and verify.'
created="$(AGENT_AI_WRITER_FIXTURE="$ROOT/evals/fixtures/task-writer-ticket.json" run_template instruct product-bot "$blob")"
written_title="$(cat "$TMP/board/title")"
if [ "$written_title" = 'Turn blob instructions into clear toolkit tickets' ] \
   && [ "${#written_title}" -lt 80 ] \
   && grep -q '<strong>Maintainers receive one clear ticket' "$TMP/board/description" \
   && grep -q '<h2>What went wrong</h2>' "$TMP/board/description" \
   && grep -q '<h2>What changes</h2><ol>' "$TMP/board/description" \
   && grep -q '<h2>Done when</h2>' "$TMP/board/description" \
   && printf '%s\n' "$created" | grep -q '^instruction filed: AGTE-77 '; then
  ok blob-instruction-task-writer 'fixture rewrite supplies a short title and all four parts'
else
  bad blob-instruction-task-writer "output=$created title=$(cat "$TMP/board/title" 2>/dev/null)"
fi

feedback="$(FEEDBACK_BOARD_SECTION=Inbox AGENT_AI_WRITER_FIXTURE="$ROOT/evals/fixtures/task-writer-without-done.json" \
  run_template feedback --board-cli "$TMP/bin/board" --kind change --what 'Explain the expected result' \
    --got 'The result is buried in setup details.' --expected 'The ticket names one checkable result.' 2>&1)"
if grep -q '<h2>Done when</h2><p>The ticket names one checkable result.</p>' "$TMP/board/description" \
   && [ "$(cat "$TMP/board/section")" = Backlog ] \
   && printf '%s\n' "$feedback" | grep -qF 'WARNING: feedback board section "Inbox" was not found; using first section "Backlog".' \
   && printf '%s\n' "$feedback" | grep -qF 'Feedback filed: Make feedback tickets explain the expected result. Ticket: AGTE-77 https://app.hypertask.ai/detail/project-5500/77'; then
  ok feedback-backlog-first-column 'missing configured column falls back to the first column named Backlog'
else
  bad feedback-backlog-first-column "output=$feedback body=$(cat "$TMP/board/description" 2>/dev/null)"
fi

original_body='<p>Keep this original instruction body unchanged.</p>'
refused="$(REFUSE_WRITES=yes run_template instruct product-bot "Original instruction title
$original_body" 2>&1)"
if [ "$(cat "$TMP/board/rewrite-count")" -eq 2 ] \
   && grep -qF 'Shape rule: What went wrong must contain one to three sentences' "$TMP/board/rewrite-prompt-2" \
   && [ "$(cat "$TMP/board/description")" = "$original_body" ] \
   && printf '%s\n' "$refused" | grep -qF 'WARNING: Task Writer rewrite failed two shape checks; using the original instruction unchanged.' \
   && printf '%s\n' "$refused" | grep -q '^instruction filed: AGTE-77 '; then
  ok instruct-refusal-keeps-original 'two refused rewrites post the original body with one warning'
else
  bad instruct-refusal-keeps-original "output=$refused calls=$(cat "$TMP/board/rewrite-count" 2>/dev/null) body=$(cat "$TMP/board/description" 2>/dev/null)"
fi

set +e
missing="$(python3 "$ROOT/adapters/hypertask/plain-language/check-ticket.py" 'Valid short title' \
  <(printf '%s' '<p><strong>The outcome is clear.</strong></p><h2>What went wrong</h2><p>It was missing.</p><h2>What changes</h2><ol><li>Add it.</li></ol>') 2>&1)"
missing_rc=$?
set -e
if [ "$missing_rc" -ne 0 ] && printf '%s\n' "$missing" | grep -q 'Done When section is missing'; then
  ok ticket-gate-requires-done-when 'the validator names the missing section'
else
  bad ticket-gate-requires-done-when "rc=$missing_rc output=$missing"
fi

# shellcheck source=/dev/null
. "$ROOT/adapters/hypertask/adapter.sh"
COMMENT_CAPTURE="$TMP/comment"
export COMMENT_CAPTURE
adapter_install_board_cli writer-test "$TMP/token" "$TMP/comment-board" 'Test Bot' agent-1 5500 off
original='<p><strong>Question: Can <span data-type="mention" data-label="name-6">Owner</span> approve this release plan after reviewing the customer impact, rollout steps, rollback steps, support notes, and expected result for everyone affected?</strong></p><p>Next: review the complete plan and answer when ready.</p>'
HOME="$TMP" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:/usr/bin:/bin" \
  AGENT_AI_WRITER_FIXTURE="$ROOT/evals/fixtures/write-with-ai-comment.json" \
  "$TMP/comment-board" comment add TEST-1 --text "$original" >/dev/null
if grep -q '^<p><strong>Question:' "$COMMENT_CAPTURE" \
   && grep -q '<span data-type="mention" data-label="name-6">Owner</span>' "$COMMENT_CAPTURE" \
   && ! grep -q 'support notes' "$COMMENT_CAPTURE"; then
  ok comment-writer-keeps-routing 'long rewrite keeps its marker and owner mention'
else
  bad comment-writer-keeps-routing "comment=$(cat "$COMMENT_CAPTURE" 2>/dev/null)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
