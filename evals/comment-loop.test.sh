#!/usr/bin/env bash
# Comment-loop checks use local command stubs and never call a board or model.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/home/.config/agents" "$TMP/company" "$TMP/repo" "$TMP/bin" "$TMP/state/agent-board-poll"
printf '# company pack\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *'/mcp/tasks?'*) cat "$TASKS_JSON"; printf '\n200' ;;
  *'/mcp/comments?'*) cat "$COMMENTS_JSON"; printf '\n200' ;;
  *) printf '%s\n200' '{}' ;;
esac
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
cat > "$TMP/bin/provider" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${!#}" > "$PROMPT_CAPTURE"
EOF
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *' --json project show '*) printf '{"project":{"ownerId":6}}\n' ;;
  *' --json comment list '*) cat "${MECH_COMMENTS:-/dev/null}" ;;
  *' comment add '*) printf 'post\n' >> "$MECH_POSTS"; printf 'posted\n' ;;
  *) printf '{}\n' ;;
esac
EOF
chmod +x "$TMP/bin/"*

cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","section":"Review","title":"Loop guard","description":"Check activity","assignees":[{"agent":{"id":"agent-1"}}],"labels":[],"commentCount":2,"updatedAt":"2026-01-01T00:01:00Z"}]}
EOF
cat > "$TMP/home/.config/agents/test.conf" <<EOF
AGENT_ID="agent-1"
AGENT_NAME="Test Bot"
AGENT_KIND="worker"
AGENT_REPO="$TMP/repo"
AGENT_SLUG="test"
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

run_dry() {
  HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
    XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
    TASKS_JSON="$TMP/tasks.json" COMMENTS_JSON="$TMP/comments.json" \
    PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once --dry-run --explain test
}

cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":1,"createdAt":"2026-01-01T00:00:00Z","agent":{"id":"other-agent","displayName":"Other Bot"},"text":"Earlier"},{"id":2,"createdAt":"2026-01-01T00:01:00Z","agent":{"id":"agent-1","displayName":"Test Bot"},"text":"<p><span data-label=\"agent-agent-1\">Test Bot</span> done</p>"}]}
EOF
output="$(run_dry)"
if printf '%s\n' "$output" | grep -qF "newest comment 2 is by this agent's own identity" \
   && ! printf '%s\n' "$output" | grep -q '^would pick up TEST-1 '; then
  ok own-comment-never-triggers 'own agent id is rejected in mention and assigned paths'
else
  bad own-comment-never-triggers "output=$output"
fi

cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":1,"createdAt":"2026-01-01T00:00:00Z","agent":{"id":"agent-1","displayName":"Test Bot"},"text":"Claimed"},{"id":2,"createdAt":"2026-01-01T00:01:00Z","agent":null,"creator":{"displayName":"Human"},"text":"Please revise"}]}
EOF
printf 'TEST-1\t%s\t2\n' "$(date +%s)" > "$TMP/state/agent-board-poll/test.ticket-runs"
output="$(run_dry)"
if printf '%s\n' "$output" | grep -qF 'no new human or other-agent comment bypasses the 1800s ticket cooldown' \
   && ! printf '%s\n' "$output" | grep -q '^would pick up TEST-1 '; then
  ok per-ticket-thirty-minute-cooldown 'the same trigger cannot start a second run within 30 minutes'
else
  bad per-ticket-thirty-minute-cooldown "output=$output"
fi

cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":1,"createdAt":"2026-01-01T00:00:00Z","agent":{"id":"agent-1","displayName":"Test Bot"},"text":"Claimed"},{"id":3,"createdAt":"2026-01-01T00:02:00Z","agent":null,"creator":{"displayName":"Human"},"text":"New human instruction"}]}
EOF
output="$(run_dry)"
if printf '%s\n' "$output" | grep -q '^would pick up TEST-1 '; then
  ok cooldown-human-bypass 'a newer human comment bypasses the cooldown'
else
  bad cooldown-human-bypass "output=$output"
fi

cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":1,"createdAt":"2026-01-01T00:00:00Z","agent":{"id":"agent-1","displayName":"Test Bot"},"text":"Claimed"},{"id":4,"createdAt":"2026-01-01T00:03:00Z","agent":{"id":"agent-2","displayName":"Other Bot"},"text":"New agent instruction"}]}
EOF
output="$(run_dry)"
if printf '%s\n' "$output" | grep -q '^would pick up TEST-1 '; then
  ok cooldown-other-agent-bypass 'a newer comment from another agent bypasses the cooldown'
else
  bad cooldown-other-agent-bypass "output=$output"
fi

rm -f "$TMP/state/agent-board-poll/test.ticket-runs"
cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":5,"createdAt":"2026-01-01T00:04:00Z","agent":null,"creator":{"displayName":"Human"},"text":"Capture the prompt"}]}
EOF
PROMPT_CAPTURE="$TMP/prompt" HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
  XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
  TASKS_JSON="$TMP/tasks.json" COMMENTS_JSON="$TMP/comments.json" \
  PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once test
if grep -qF 'You may @mention the board owner at most once on this ticket in any 24-hour period.' "$TMP/prompt"; then
  ok owner-mention-prompt-contract 'every run receives the 24-hour owner-mention contract'
else
  bad owner-mention-prompt-contract 'the model prompt omitted the owner-mention budget'
fi

# shellcheck disable=SC1090
. "$ROOT/adapters/hypertask/adapter.sh"
printf '{"comments":[]}\n' > "$TMP/mechanical-comments.json"
MECH_COMMENTS="$TMP/mechanical-comments.json"
MECH_POSTS="$TMP/mechanical-posts"
export MECH_COMMENTS MECH_POSTS
adapter_install_board_cli mention-test "$TMP/token" "$TMP/mention-board" "Test Bot" agent-1 1
mention='<p><span data-type="mention" data-label="name-6">Owner</span> first</p>'
second='<p>Again <span data-type="mention" data-label="name-6">Owner</span></p>'
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" "$TMP/mention-board" comment add TEST-1 --text "$mention" >/dev/null
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" "$TMP/mention-board" comment add TEST-1 --text "$second" >"$TMP/second.out" 2>"$TMP/second.err"
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" "$TMP/mention-board" comment update 9 --text "$second" >"$TMP/update.out" 2>"$TMP/update.err"
posts="$(wc -l < "$TMP/mechanical-posts")"
if [ "$posts" -eq 1 ] \
   && grep -qF 'already @mentioned the board owner in the last 24 hours' "$TMP/second.err" \
   && grep -qF 'owner mention must use a ticket-addressed comment add' "$TMP/update.err" \
   && grep -qF 'owner-mention budget' "$TMP/state/agent-board-poll/mention-test.log"; then
  ok owner-mention-mechanical-budget 'the wrapper refuses and logs owner-mention budget bypasses'
else
  bad owner-mention-mechanical-budget "posts=$posts add=$(cat "$TMP/second.err") update=$(cat "$TMP/update.err")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
