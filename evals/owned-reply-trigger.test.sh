#!/usr/bin/env bash
# Owned-reply checks use local command stubs and never call the board or GitHub.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.config/agents" "$TMP/company" "$TMP/repo" "$TMP/bin" "$TMP/state"
printf '# company pack\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"

cat > "$TMP/board" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
cat > "$TMP/bin/provider" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${!#}" > "$PROMPT_CAPTURE"
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *'/mcp/tasks?'*) cat "$TASKS_JSON"; printf '\n200' ;;
  *'/mcp/comments?'*) cat "$COMMENTS_JSON"; printf '\n200' ;;
  *) printf '%s\n200' '{}' ;;
esac
EOF
chmod +x "$TMP/board" "$TMP/bin/"*

cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","section":"Review","title":"Reply to the human","description":"A human replied","assignees":[],"labels":[],"commentCount":2,"updatedAt":"2026-01-01T00:01:00Z"}]}
EOF
cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":1,"createdAt":"2026-01-01T00:00:00Z","agent":{"id":"agent-1","displayName":"Test Bot"},"author":{"displayName":"Test Bot"},"text":"Claimed."},{"id":2,"createdAt":"2026-01-01T00:01:00Z","agent":null,"creator":{"displayName":"Valentin"},"author":{"displayName":"Valentin"},"text":"Please revise this."}]}
EOF
cat > "$TMP/home/.config/agents/test.conf" <<EOF
AGENT_ID="agent-1"
AGENT_NAME="Test Bot"
AGENT_KIND="dev"
AGENT_REPO="$TMP/repo"
BOARD_ADAPTER="hypertask"
BOARD_ID="1"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/board"
WATCH_SECTIONS="*"
SKILLS_INDEX=""
MODEL_CLI="provider"
PR_REPO="example/repo"
TRIAGE="no"
CLAIM_UNASSIGNED="no"
EOF

output="$(HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
  XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
  TASKS_JSON="$TMP/tasks.json" COMMENTS_JSON="$TMP/comments.json" \
  PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once --dry-run test)"
count="$(printf '%s\n' "$output" | grep -c '^would pick up TEST-1 ' || true)"
if [ "$count" -eq 1 ]; then
  ok watch-all-owned-human-reply 'WATCH_SECTIONS=* yields one eligible owned reply'
else
  bad watch-all-owned-human-reply "output=$output"
fi

cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","section":"Done","title":"Answer the human","description":"Already completed","assignees":[],"labels":[],"commentCount":1,"updatedAt":"2026-01-01T00:02:00Z"}]}
EOF
cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":3,"createdAt":"2026-01-01T00:02:00Z","agent":null,"creator":{"displayName":"Valentin"},"text":"<p><span data-label=\"agent-agent-1\">Test Bot</span> is that a feature flag?</p>"}]}
EOF
rm -f "$TMP/state/agent-board-poll/test.seen" "$TMP/state/agent-board-poll/test.ticket-runs"
output="$(HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
  XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
  TASKS_JSON="$TMP/tasks.json" COMMENTS_JSON="$TMP/comments.json" \
  PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once --dry-run --explain test)"
if printf '%s\n' "$output" | grep -qF 'would pick up TEST-1 (rank -3): TEST-1 has a human direct mention or question, so it is a reply-only candidate in done' \
   && printf '%s\n' "$output" | grep -qF 'reply-only: answer the human; no code, claim, pull request, or column move'; then
  ok done-mention-reply-only 'a human mention on a Done ticket is eligible only for an answer'
else
  bad done-mention-reply-only "output=$output"
fi

PROMPT_CAPTURE="$TMP/prompt" HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
  XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
  TASKS_JSON="$TMP/tasks.json" COMMENTS_JSON="$TMP/comments.json" \
  PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once test >/dev/null
if grep -qF 'REPLY-ONLY CONTRACT: A direct mention or question from a human must always get' "$TMP/prompt" \
   && grep -qF 'Do not edit files, run a' "$TMP/prompt" \
   && grep -qF 'This reply-only run must leave the ticket in its current column.' "$TMP/prompt"; then
  ok reply-only-prompt-contract 'the answer run forbids code, claims, and column moves'
else
  bad reply-only-prompt-contract "prompt=$(cat "$TMP/prompt" 2>/dev/null || true)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
