#!/usr/bin/env bash
# AGTE-114: one comment per owner message, and an owner rule proposal is filed
# on the toolkit board and named in that one comment.
#
# The owner asked a question on HTPR-6564 and got two comments: a cryptic
# "I read your comment as a question", then the answer. He also asked for the
# rule he proposed to be filed so every dev follows it, which nothing did.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
ok() { printf 'PASS %-38s %s\n' "$1" "$2"; }
bad() { printf 'FAIL %-38s %s\n' "$1" "$2"; fails=$((fails + 1)); }

mkdir -p "$TMP/home/.claude/skills/pospeak" "$TMP/home/.claude/skills/unslop" \
  "$TMP/home/.claude/skills/i-have-adhd" "$TMP/config" "$TMP/bin" "$TMP/repo" \
  "$TMP/company" "$TMP/state"
printf '# company skills\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"
printf 'rules\n' > "$TMP/home/.claude/CLAUDE.md"
printf 'pospeak\n' > "$TMP/home/.claude/skills/pospeak/SKILL.md"
printf 'unslop\n' > "$TMP/home/.claude/skills/unslop/SKILL.md"
printf 'adhd\n' > "$TMP/home/.claude/skills/i-have-adhd/SKILL.md"
printf '{}\n' > "$TMP/codex-auth.json"

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *'/mcp/tasks?'*) cat "$MOCK_TASKS"; printf '\n200' ;;
  *'/mcp/comments?'*) cat "$MOCK_COMMENTS"; printf '\n200' ;;
  *) printf '{}\n200' ;;
esac
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
cat > "$TMP/bin/classifier" <<'EOF'
#!/usr/bin/env bash
printf 'question\n'
EOF
cat > "$TMP/bin/model" <<'EOF'
#!/usr/bin/env bash
printf 'work\n' >> "$MOCK_MODEL_LOG"
EOF
# The fixed reply model. It answers with the yes/no sentence the reply prompt
# asks for and never mentions the toolkit ticket: the runner adds that itself.
cat > "$TMP/bin/hax" <<'EOF'
#!/usr/bin/env bash
printf 'reply\n' >> "$MOCK_MODEL_LOG"
printf '%s\n' "${!#}" > "$MOCK_PROMPT"
printf '<p><strong>Yes, a flagged ticket should name its flag before it moves to Done.</strong></p><p>Next: I will name the flag and its audience in the closing comment.</p>\n'
EOF
# The feedback filer, standing in for scripts/agent-template feedback.
cat > "$TMP/bin/agent-template" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_FEEDBACK_LOG"
printf 'Feedback filed: owner rule. Ticket: AGTE-777 https://app.hypertask.ai/detail/project-5500/777\n'
EOF
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
args=" $* "
case "$args" in
  *' project show '*)
    printf '%s\n' '{"project":{"id":15,"ownerId":6,"sections":[{"name":"Backlog"},{"name":"In Progress"},{"name":"Review"}]}}'
    ;;
  *' task get '*) cat "$MOCK_TASKS" ;;
  *' comment list '*) cat "$MOCK_COMMENTS" ;;
  *' task assign '*|*' task unassign '*|*' task move '*) : ;;
  *' comment add '*)
    text=""
    argv=("$@")
    for ((i = 0; i < ${#argv[@]}; i++)); do
      case "${argv[$i]}" in
        --text) text="${argv[$((i + 1))]:-}" ;;
        --file) text="$(cat "${argv[$((i + 1))]:-/dev/null}")" ;;
      esac
    done
    printf '%s\n' "$text" >> "$MOCK_BOARD_LOG"
    printf '%s\n' '{"comment":{"id":91}}'
    ;;
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
BOARD_CLI="$TMP/bin/hypertask"
WATCH_SECTIONS="Backlog"
MODEL_CLI="$TMP/bin/model"
OWNER_COMMENT_CLASSIFIER_CLI="$TMP/bin/classifier"
PR_REPO="example/repo"
TRIAGE="no"
CLAIM_UNASSIGNED="yes"
IN_PROGRESS_SECTION="In Progress"
REVIEW_SECTION="Review"
FLEET_PROGRESS_SUPERVISOR="off"
EOF

cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","projectId":15,"section":"Backlog","title":"Hide the empty row","description":"A UI change","assignees":[{"agent":{"id":"agent-dev","displayName":"Dev"}}],"labels":[],"commentCount":1,"updatedAt":"2026-09-19T08:02:00Z"}]}
EOF

run_tick() {
  : > "$TMP/board.log"
  : > "$TMP/model.log"
  : > "$TMP/feedback.log"
  rm -rf "$TMP/state"
  mkdir -p "$TMP/state"
  HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state" \
    COMPANY_SKILLS_DIR="$TMP/company" PATH="$TMP/bin:$PATH" \
    MOCK_TASKS="$TMP/tasks.json" MOCK_COMMENTS="$TMP/comments.json" \
    MOCK_BOARD_LOG="$TMP/board.log" MOCK_MODEL_LOG="$TMP/model.log" \
    MOCK_FEEDBACK_LOG="$TMP/feedback.log" MOCK_PROMPT="$TMP/prompt.txt" \
    AGENT_TEMPLATE_CLI="$TMP/bin/agent-template" \
    REPLY_HAX_BIN="$TMP/bin/hax" REPLY_CODEX_AUTH="$TMP/codex-auth.json" \
    "$ROOT/scripts/agent-board-poll" --once dev > "$TMP/out" 2>&1 || true
}

# --- 1. a rule proposal: one comment, a yes/no sentence, and the filed link ---
cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":90,"createdAt":"2026-09-19T08:02:00Z","agent":null,"creator":{"id":6,"displayName":"Valentin"},"text":"<p>Is this a feature flag? If it is, can we agree that every ticket that receives a feature flag mentions it in the closing comment?</p>"}]}
EOF
run_tick
comments="$(grep -c . "$TMP/board.log" || true)"
posted="$(cat "$TMP/board.log")"
if [ "$comments" = "1" ] \
  && printf '%s' "$posted" | grep -qiE '<strong>(yes|no),' \
  && printf '%s' "$posted" | grep -qF 'https://app.hypertask.ai/detail/project-5500/777' \
  && printf '%s' "$posted" | grep -qF 'AGTE-777' \
  && ! printf '%s' "$posted" | grep -qF 'I read your comment as a question' \
  && grep -qF -- '--kind bug' "$TMP/feedback.log" \
  && grep -qF -- 'can we agree that every ticket' "$TMP/feedback.log"; then
  ok rule-proposal-one-comment-and-filed 'one comment carries the verdict and the filed toolkit link'
else
  bad rule-proposal-one-comment-and-filed "comments=$comments board=$posted feedback=$(cat "$TMP/feedback.log")"
fi

# --- 2. an answer within the wait window: no acknowledgement comment at all ---
cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":92,"createdAt":"2026-09-19T08:02:00Z","agent":null,"creator":{"id":6,"displayName":"Valentin"},"text":"<p>Which build is this on?</p>"}]}
EOF
run_tick
comments="$(grep -c . "$TMP/board.log" || true)"
posted="$(cat "$TMP/board.log")"
if [ "$comments" = "1" ] \
  && ! printf '%s' "$posted" | grep -qF 'I read your comment as a question' \
  && [ ! -s "$TMP/feedback.log" ]; then
  ok answer-inside-wait-window-has-no-ack 'the answer is the only comment and nothing is filed'
else
  bad answer-inside-wait-window-has-no-ack "comments=$comments board=$posted feedback=$(cat "$TMP/feedback.log")"
fi

exit "$([ "$fails" -eq 0 ] && echo 0 || echo 1)"
