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
mkdir -p "$TMP/home/.config/agents" "$TMP/home/.claude/skills/pospeak" \
  "$TMP/home/.claude/skills/unslop" "$TMP/home/.claude/skills/i-have-adhd" \
  "$TMP/home/.codex" "$TMP/company" "$TMP/repo" "$TMP/bin" "$TMP/state"
printf '# company pack\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"
printf '{}\n' > "$TMP/home/.codex/auth.json"
printf 'GLOBAL TERMINAL RULE\n' > "$TMP/home/.claude/CLAUDE.md"
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/feedback.sh"
feedback_update_note "$TMP/home/.claude/CLAUDE.md" "$(cat "$ROOT/VERSION")" no
printf 'POSPEAK TERMINAL RULE\n' > "$TMP/home/.claude/skills/pospeak/SKILL.md"
printf 'UNSLOP TERMINAL RULE\n' > "$TMP/home/.claude/skills/unslop/SKILL.md"
printf 'ADHD TERMINAL RULE\n' > "$TMP/home/.claude/skills/i-have-adhd/SKILL.md"

cat > "$TMP/board" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " = *" comment add "* ]] && [ -n "${BOARD_POST_CAPTURE:-}" ]; then
  args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
      --file) cat "${args[$((i + 1))]}" > "$BOARD_POST_CAPTURE" ;;
      --text) printf '%s' "${args[$((i + 1))]}" > "$BOARD_POST_CAPTURE" ;;
    esac
  done
fi
exit 0
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ -z "${GH_CAPTURE:-}" ] || printf '%s\n' "$*" >> "$GH_CAPTURE"
if [ "${GH_PR_FIXTURE:-}" = "merged-812" ] && [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  printf '{"state":"MERGED","mergedAt":"2026-09-16T14:00:00Z","url":"https://github.com/example/repo/pull/812"}\n'
else
  printf '[]\n'
fi
EOF
cat > "$TMP/bin/hax-stub" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${!#}" > "$PROMPT_CAPTURE"
printf '<p><strong>Answer: The feature uses a flag.</strong></p><p>Next: use that answer.</p>\n'
EOF
cat > "$TMP/bin/timeout-stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" > "$TIMEOUT_CAPTURE"
shift
exec "$@"
EOF
cat > "$TMP/bin/bwrap-stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$BWRAP_CAPTURE"
hax=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "--ro-bind" ] && [ "${args[$((i + 2))]:-}" = "/opt/hax" ]; then
    hax="${args[$((i + 1))]}"
  fi
  if [ "${args[$i]}" = "--" ]; then
    exec "$hax" "${args[@]:$((i + 2))}"
  fi
done
exit 2
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *'/mcp/tasks?'*) cat "$TASKS_JSON"; printf '\n200' ;;
  *'/mcp/comments?'*)
    if [[ "$url" = *'limit='* ]] && [ -n "${COMMENTS_CAPPED_JSON:-}" ]; then
      cat "$COMMENTS_CAPPED_JSON"
    else
      cat "$COMMENTS_JSON"
    fi
    printf '\n200'
    ;;
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

PROMPT_CAPTURE="$TMP/prompt" TIMEOUT_CAPTURE="$TMP/timeout" BWRAP_CAPTURE="$TMP/bwrap" \
  BOARD_POST_CAPTURE="$TMP/answer.post" REPLY_HAX_BIN="$TMP/bin/hax-stub" REPLY_BWRAP_BIN="$TMP/bin/bwrap-stub" \
  REPLY_TIMEOUT_BIN="$TMP/bin/timeout-stub" REPLY_CODEX_AUTH="$TMP/home/.codex/auth.json" \
  HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
  XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
  TASKS_JSON="$TMP/tasks.json" COMMENTS_JSON="$TMP/comments.json" \
  PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once test >/dev/null
if grep -qF 'You are Test Bot in a read-only reply run for TEST-1.' "$TMP/prompt" \
   && grep -qF 'Full ticket thread, verbatim normalized JSON.' "$TMP/prompt" \
   && grep -qF '"id": 3' "$TMP/prompt" \
   && grep -qF 'GLOBAL TERMINAL RULE' "$TMP/prompt" \
   && grep -qF 'Owner-question replies start with `Answer:`, not `Decision:`.' "$TMP/prompt" \
   && grep -qF '`Decision needed:` question only when the owner must choose something.' "$TMP/prompt" \
   && grep -qF 'POSPEAK TERMINAL RULE' "$TMP/prompt" \
   && grep -qF 'UNSLOP TERMINAL RULE' "$TMP/prompt" \
   && grep -qF 'ADHD TERMINAL RULE' "$TMP/prompt" \
   && grep -qF 'This reply-only run must leave the ticket in its current column.' "$TMP/prompt" \
   && grep -qF '<strong>Answer:' "$TMP/answer.post" \
   && ! grep -qF '<strong>Decision:' "$TMP/answer.post" \
   && ! grep -qF 'COMMENT CONTRACT:' "$TMP/prompt" \
   && ! grep -qF 'Decision: concise answer' "$TMP/prompt"; then
  ok reply-only-prompt-contract 'reply-only defaults to Answer under the exact terminal rules'
else
  bad reply-only-prompt-contract "prompt=$(cat "$TMP/prompt" 2>/dev/null || true)"
fi

if [ "$(cat "$TMP/timeout")" = 300 ] \
   && grep -qxF -- '--ro-bind' "$TMP/bwrap" \
   && grep -qxF '/workspace' "$TMP/bwrap" \
   && grep -qxF '/logs' "$TMP/bwrap" \
   && grep -qxF -- '--tmpfs' "$TMP/bwrap" \
   && grep -qxF -- '--clearenv' "$TMP/bwrap" \
   && grep -qxF -- '--provider=codex' "$TMP/bwrap" \
   && grep -qxF -- '--model=gpt-5.6-sol' "$TMP/bwrap" \
   && grep -qxF -- '--effort=high' "$TMP/bwrap" \
   && grep -qxF -- '--no-session' "$TMP/bwrap" \
   && grep -qxF -- '--bare' "$TMP/bwrap" \
   && ! grep -qF "$TMP/token" "$TMP/bwrap"; then
  ok reply-only-sandbox-contract 'Codex Sol high gets five minutes, read-only mounts, writable tmp, and no board token'
else
  bad reply-only-sandbox-contract "timeout=$(cat "$TMP/timeout" 2>/dev/null) bwrap=$(tr '\n' ' ' < "$TMP/bwrap" 2>/dev/null)"
fi

if printf '%s\n' '<p><strong>Answer: Both options are available.</strong></p><p>Decision needed: Which option should ship?</p>' \
  | python3 "$ROOT/adapters/hypertask/plain-language/check-comment.py"; then
  ok answer-decision-needed-shape 'Answer with an optional Decision needed question passes the plain-language check'
else
  bad answer-decision-needed-shape 'the plain-language check rejected the fifth marker or decision question'
fi

cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-3533","ticketNumber":"HTPR-3533","section":"Done","title":"Google sign-in fails","description":"The customer attached the error screen.","assignees":[],"labels":[],"commentCount":2,"updatedAt":"2026-01-02T00:01:00Z"}]}
EOF
cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":30,"createdAt":"2026-01-02T00:00:00Z","agent":{"id":"agent-1","displayName":"Test Bot"},"creator":{"displayName":"Valentin"},"text":"<p>Please send the login error.</p>"},{"id":31,"createdAt":"2026-01-02T00:01:00Z","agent":null,"creator":{"id":6,"displayName":"Valentin"},"text":"<p><span data-label=\"agent-agent-1\">Test Bot</span>, what do I need to change?</p><p><img src=\"https://screencast2.com/MFrrv.png?raw\"></p>"}]}
EOF
sed -i 's/BOARD_ID="1"/BOARD_ID="15"/' "$TMP/home/.config/agents/test.conf"
rm -f "$TMP/state/agent-board-poll/test.seen" "$TMP/state/agent-board-poll/test.ticket-runs"
cat > "$TMP/bin/hax-stub" <<'EOF'
#!/usr/bin/env bash
prompt="${!#}"
printf '%s' "$prompt" > "$PROMPT_CAPTURE"
[ -s "$SCREENSHOT_FIXTURE" ]
printf '%s' "$prompt" | grep -qF 'https://screencast2.com/MFrrv.png?raw'
printf '<p><strong>Answer: Google rejected sign-in because the redirect address does not match.</strong></p><p>Next: add the app callback URL exactly to Google\x27s authorized redirect addresses.</p>\n'
EOF
chmod +x "$TMP/bin/hax-stub"
PROMPT_CAPTURE="$TMP/htpr-3533.prompt" TIMEOUT_CAPTURE="$TMP/timeout" BWRAP_CAPTURE="$TMP/bwrap" \
  BOARD_POST_CAPTURE="$TMP/htpr-3533.post" \
  SCREENSHOT_FIXTURE="$ROOT/evals/fixtures/htpr-3533-redirect-uri-mismatch.png" \
  REPLY_HAX_BIN="$TMP/bin/hax-stub" REPLY_BWRAP_BIN="$TMP/bin/bwrap-stub" \
  REPLY_TIMEOUT_BIN="$TMP/bin/timeout-stub" REPLY_CODEX_AUTH="$TMP/home/.codex/auth.json" \
  HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
  XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
  TASKS_JSON="$TMP/tasks.json" COMMENTS_JSON="$TMP/comments.json" \
  PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once test >/dev/null
if file "$ROOT/evals/fixtures/htpr-3533-redirect-uri-mismatch.png" | grep -qF 'PNG image data' \
   && grep -qF 'Download every relevant image URL to /tmp and inspect the image' "$TMP/htpr-3533.prompt" \
   && grep -qF 'https://screencast2.com/MFrrv.png?raw' "$TMP/htpr-3533.prompt" \
   && grep -qF '<strong>Answer:' "$TMP/htpr-3533.post" \
   && grep -qF 'redirect address does not match' "$TMP/htpr-3533.post" \
   && grep -qF 'authorized redirect addresses' "$TMP/htpr-3533.post" \
   && ! grep -qF '<strong>Decision:' "$TMP/htpr-3533.post"; then
  ok screenshot-redirect-fix 'HTPR-3533 image evidence produces the Google authorized redirect-address fix'
else
  bad screenshot-redirect-fix "prompt=$(cat "$TMP/htpr-3533.prompt" 2>/dev/null) post=$(cat "$TMP/htpr-3533.post" 2>/dev/null)"
fi

python3 - "$ROOT/evals/fixtures/htpr-4370-state.json" \
  "$TMP/tasks.json" "$TMP/comments.json" "$TMP/comments-capped.json" <<'PYEOF'
import json
import sys

fixture = json.load(open(sys.argv[1], encoding="utf-8"))
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump({"tasks": [fixture["task"]]}, handle)
with open(sys.argv[3], "w", encoding="utf-8") as handle:
    json.dump({"comments": fixture["comments"]}, handle)
with open(sys.argv[4], "w", encoding="utf-8") as handle:
    json.dump({"comments": fixture["comments"][-40:]}, handle)
PYEOF
mkdir -p "$TMP/repo/config"
printf '{"slackAppId": null, "connectEnabled": false}\n' > "$TMP/repo/config/integrations.json"
sed -i 's/BOARD_ID="15"/BOARD_ID="1"/' "$TMP/home/.config/agents/test.conf"
rm -f "$TMP/state/agent-board-poll/test.seen" "$TMP/state/agent-board-poll/test.ticket-runs"
cat > "$TMP/bin/hax-stub" <<'EOF'
#!/usr/bin/env bash
prompt="${!#}"
printf '%s' "$prompt" > "$PROMPT_CAPTURE"
printf '%s' "$prompt" | grep -qF '/tmp/reply-state.md'
printf '%s' "$prompt" | grep -qF 'answered ticket is exempt from comment read caps'
printf '%s' "$prompt" | grep -qF 'current state verified with `gh`'
printf '%s' "$prompt" | grep -qF 'latest QA verdict and its date'
printf '%s' "$prompt" | grep -qF 'configuration that is present or missing'
printf '%s' "$prompt" | grep -qF 'Connect is available now. Tap Connect'
printf '%s' "$prompt" | grep -qF 'Connect is greyed out and no Slack app exists'
gh pr view 812 --repo example/repo --json state,mergedAt,url | grep -qF '"state":"MERGED"'
grep -qF '"slackAppId": null' "$CONFIG_FIXTURE"
cat > /tmp/reply-state.md <<'STATE'
PR 812: merged 16 September 2026
Latest QA, 17 September 2026: Connect greyed out; Slack app absent
Configuration: slackAppId absent; Connect disabled
Superseded: 15 September comments saying Connect was available
STATE
cp /tmp/reply-state.md "$STATE_SHEET_CAPTURE"
rm -f /tmp/reply-state.md
printf '<p><strong>Answer: Connect is greyed out, and the Slack app is missing.</strong></p><p>QA’s 17 September check supersedes the older comments that say to tap Connect.</p><p>Next: configure the Slack app and enable Connect.</p>\n'
EOF
chmod +x "$TMP/bin/hax-stub"
: > "$TMP/gh-capture"
PROMPT_CAPTURE="$TMP/htpr-4370.prompt" TIMEOUT_CAPTURE="$TMP/timeout" BWRAP_CAPTURE="$TMP/bwrap" \
  BOARD_POST_CAPTURE="$TMP/htpr-4370.post" STATE_SHEET_CAPTURE="$TMP/htpr-4370.state" \
  CONFIG_FIXTURE="$TMP/repo/config/integrations.json" GH_CAPTURE="$TMP/gh-capture" GH_PR_FIXTURE=merged-812 \
  OWNED_COMMENT_READ_CEILING=40 COMMENTS_CAPPED_JSON="$TMP/comments-capped.json" \
  REPLY_HAX_BIN="$TMP/bin/hax-stub" REPLY_BWRAP_BIN="$TMP/bin/bwrap-stub" \
  REPLY_TIMEOUT_BIN="$TMP/bin/timeout-stub" REPLY_CODEX_AUTH="$TMP/home/.codex/auth.json" \
  HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
  XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
  TASKS_JSON="$TMP/tasks.json" COMMENTS_JSON="$TMP/comments.json" \
  PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once test >/dev/null
if ! grep -qF '4370001' "$TMP/comments-capped.json" \
   && grep -qF '"id": 4370001' "$TMP/htpr-4370.prompt" \
   && grep -qF '"id": 4370043' "$TMP/htpr-4370.prompt" \
   && grep -qF 'pr view 812 --repo example/repo --json state,mergedAt,url' "$TMP/gh-capture" \
   && grep -qF 'Latest QA, 17 September 2026' "$TMP/htpr-4370.state" \
   && grep -qF 'Superseded: 15 September comments' "$TMP/htpr-4370.state" \
   && grep -qF 'Connect is greyed out' "$TMP/htpr-4370.post" \
   && grep -qF 'Slack app is missing' "$TMP/htpr-4370.post" \
   && grep -qF 'supersedes the older comments' "$TMP/htpr-4370.post"; then
  ok htpr-4370-verified-state 'full uncapped thread, PR, QA, and config state override the stale Connect advice'
else
  bad htpr-4370-verified-state "prompt=$(cat "$TMP/htpr-4370.prompt" 2>/dev/null) state=$(cat "$TMP/htpr-4370.state" 2>/dev/null) post=$(cat "$TMP/htpr-4370.post" 2>/dev/null)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
