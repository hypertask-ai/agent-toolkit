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
cat > "$TMP/bin/rewrite-model" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >> "$REWRITE_CALLS"
printf '%s' "${!#}" > "$REWRITE_PROMPT"
printf '%s' "$REWRITE_OUTPUT"
EOF
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *' --json project show '*) printf '{"project":{"ownerId":6}}\n' ;;
  *' --json comment list '*) cat "${MECH_COMMENTS:-/dev/null}" ;;
  *' comment update '*) printf '%s\n' "$*" >> "$MECH_UPDATES"; printf 'updated\n' ;;
  *' comment add '*) printf '%s\n' "$*" >> "$MECH_POSTS"; printf 'posted\n' ;;
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
if grep -qF 'run-activity: action run finished for TEST-1' "$TMP/state/agent-board-poll/test.log" \
   && ! grep -qF 'run-activity: response' "$TMP/state/agent-board-poll/test.log"; then
  ok run-finished-is-action 'a successful run records completion as action with no response activity'
else
  bad run-finished-is-action "log=$(cat "$TMP/state/agent-board-poll/test.log")"
fi
if grep -qF 'When it is on, do not @mention the board owner' "$TMP/prompt"; then
  ok owner-mention-prompt-contract 'quiet runs forbid owner mentions'
else
  bad owner-mention-prompt-contract 'the model prompt omitted quiet owner handling'
fi
if grep -qF 'Question:' "$TMP/prompt" \
   && grep -qF 'Decision:' "$TMP/prompt" \
   && grep -qF 'Handoff:' "$TMP/prompt" \
   && grep -qF 'Done:' "$TMP/prompt" \
   && grep -qF 'Everything else' "$TMP/prompt"; then
  ok comment-kind-prompt-contract 'every run receives the four comment kinds'
else
  bad comment-kind-prompt-contract 'the model prompt omitted the four-kind contract'
fi
if ROOT="$ROOT" TMP="$TMP" python3 - <<'PYEOF'
import os
from pathlib import Path
root = Path(os.environ["ROOT"])
prompt = Path(os.environ["TMP"], "prompt").read_text()
rules = root / "adapters" / "hypertask" / "plain-language"
assert "product owner on a phone" in prompt
assert str(Path(os.environ["TMP"], "company", "skills", "talk-to-valentin", "SKILL.md")) in prompt
for name in ("pospeak.md", "unslop.md", "i-have-adhd.md"):
    assert (rules / name).read_text().rstrip() in prompt
PYEOF
then
  ok plain-language-prompt-contract 'Question and Decision prompts contain all three rule texts verbatim'
else
  bad plain-language-prompt-contract 'the runner prompt omitted the phone reader or verbatim rules'
fi
if grep -qF 'exactly four allowed' "$ROOT/SKILL.md" \
   && grep -qF 'exactly four allowed' "$ROOT/MAINTAINER.md" \
   && grep -qF 'Ticket comments have exactly four kinds' "$ROOT/scripts/create-agent.sh"; then
  ok comment-kind-setup-contract 'docs and setup output state the four kinds'
else
  bad comment-kind-setup-contract 'a required setup surface omitted the four kinds'
fi

# shellcheck disable=SC1090
. "$ROOT/adapters/hypertask/adapter.sh"
printf '{"comments":[]}\n' > "$TMP/mechanical-comments.json"
MECH_COMMENTS="$TMP/mechanical-comments.json"
MECH_POSTS="$TMP/mechanical-posts"
MECH_UPDATES="$TMP/mechanical-updates"
export MECH_COMMENTS MECH_POSTS MECH_UPDATES
adapter_install_board_cli mention-test "$TMP/token" "$TMP/mention-board" "Test Bot" agent-1 1
mention='<p><strong>Decision: <span data-type="mention" data-label="name-6">Owner</span> must approve.</strong></p><p>Next: wait for approval.</p>'
second='<p><strong>Decision: <span data-type="mention" data-label="name-6">Owner</span> must approve again.</strong></p><p>Next: wait for approval.</p>'
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" "$TMP/mention-board" comment add TEST-1 --text "$mention" >/dev/null
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" "$TMP/mention-board" comment add TEST-1 --text "$second" >"$TMP/second.out" 2>"$TMP/second.err"
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" "$TMP/mention-board" comment update 9 --text "$second" >"$TMP/update.out" 2>"$TMP/update.err"
posts="$(wc -l < "$TMP/mechanical-posts")"
if [ "$posts" -eq 2 ] \
   && ! grep -qF 'name-6' "$TMP/mechanical-posts" \
   && ! grep -qF 'name-6' "$TMP/mechanical-updates" \
   && grep -qF 'quiet mode: stripped board-owner mention' "$TMP/state/agent-board-poll/mention-test.log"; then
  ok owner-mention-quiet-strip 'quiet mode strips and logs owner mentions before posting'
else
  bad owner-mention-quiet-strip "posts=$posts add=$(cat "$TMP/second.err") update=$(cat "$TMP/update.err")"
fi

MECH_POSTS="$TMP/kind-posts"
MECH_UPDATES="$TMP/kind-updates"
export MECH_POSTS MECH_UPDATES
: > "$MECH_POSTS"
printf '{"comments":[]}\n' > "$TMP/mechanical-comments.json"
adapter_install_board_cli kind-test "$TMP/token" "$TMP/kind-board" "Test Bot" agent-1 1
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" "$TMP/kind-board" comment add TEST-1 --text '<p>Routine progress update</p>' >"$TMP/unmarked.out" 2>"$TMP/unmarked.err"
if [ ! -s "$MECH_POSTS" ] \
   && grep -qF 'run-activity: action Routine progress update' "$TMP/state/agent-board-poll/kind-test.log" \
   && grep -qF 'redirected unmarked ticket comment to run activity' "$TMP/unmarked.err"; then
  ok unmarked-comment-is-activity 'an unmarked comment is logged as activity and never posted'
else
  bad unmarked-comment-is-activity "posts=$(cat "$MECH_POSTS") error=$(cat "$TMP/unmarked.err")"
fi

for allowed in \
  '<p><strong>Question: Which release number is needed?</strong></p>' \
  '<p><strong>Decision: Legal approval is required.</strong></p><p>Next: wait for approval.</p>' \
  '<p>Handoff: QA Bot owns verification.</p>' \
  '<p>Done: https://github.com/example/repo/pull/1</p>'
do
  HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" "$TMP/kind-board" comment add TEST-1 --text "$allowed" >/dev/null
done
if [ "$(wc -l < "$MECH_POSTS")" -eq 4 ]; then
  ok four-comment-markers-pass 'all four marked comment kinds reach the board CLI'
else
  bad four-comment-markers-pass "posts=$(cat "$MECH_POSTS")"
fi

MECH_POSTS="$TMP/plain-posts"
MECH_UPDATES="$TMP/plain-updates"
REWRITE_CALLS="$TMP/rewrite-calls"
REWRITE_PROMPT="$TMP/rewrite-prompt"
export MECH_POSTS MECH_UPDATES REWRITE_CALLS REWRITE_PROMPT
: > "$MECH_POSTS"
: > "$MECH_UPDATES"
: > "$REWRITE_CALLS"
adapter_install_board_cli plain-test "$TMP/token" "$TMP/plain-board" "Test Bot" agent-1 1
technical='<p>Question: Should runThing() in src/app.ts ship?</p>'
REWRITE_OUTPUT='<p><strong>Question: Should this change ship today?</strong></p>'
export REWRITE_OUTPUT
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
  AGENT_COMMENT_REWRITE_CLI="$TMP/bin/rewrite-model" \
  "$TMP/plain-board" comment add TEST-1 --text "$technical" >"$TMP/technical.out" 2>"$TMP/technical.err"
if [ "$(wc -l < "$REWRITE_CALLS")" -eq 1 ] \
   && grep -qF '<p><strong>Question: Should this change ship today?</strong></p>' "$MECH_POSTS" \
   && grep -qF 'comment contains a file path' "$REWRITE_PROMPT" \
   && grep -qF 'POSPEAK RULES, VERBATIM:' "$REWRITE_PROMPT"; then
  ok technical-comment-rewritten 'a technical draft is rewritten once and the passing replacement posts'
else
  bad technical-comment-rewritten "calls=$(cat "$REWRITE_CALLS") posts=$(cat "$MECH_POSTS") error=$(cat "$TMP/technical.err")"
fi

: > "$MECH_POSTS"
: > "$REWRITE_CALLS"
passing='<p><strong>Decision: The release is ready.</strong></p><p>Next: approve the release.</p>'
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
  AGENT_COMMENT_REWRITE_CLI="$TMP/bin/rewrite-model" \
  "$TMP/plain-board" comment add TEST-1 --text "$passing" >/dev/null
if [ ! -s "$REWRITE_CALLS" ] && grep -qF "$passing" "$MECH_POSTS"; then
  ok passing-comment-unchanged 'a passing draft posts unchanged without a model call'
else
  bad passing-comment-unchanged "calls=$(cat "$REWRITE_CALLS") posts=$(cat "$MECH_POSTS")"
fi

: > "$MECH_POSTS"
: > "$REWRITE_CALLS"
REWRITE_OUTPUT='<p><strong>Decision: The release is ready — now.</strong></p><p>Next: approve the release.</p>'
export REWRITE_OUTPUT
em_dash='<p><strong>Decision: The release is ready — now.</strong></p><p>Next: approve the release.</p>'
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
  AGENT_COMMENT_REWRITE_CLI="$TMP/bin/rewrite-model" \
  "$TMP/plain-board" comment add TEST-1 --text "$em_dash" >"$TMP/em-dash.out" 2>"$TMP/em-dash.err"
if [ ! -s "$MECH_POSTS" ] \
   && [ "$(wc -l < "$REWRITE_CALLS")" -eq 1 ] \
   && grep -qF 'comment contains an em dash' "$TMP/state/agent-board-poll/plain-test.log" \
   && grep -qF 'run-activity: action Question held: did not pass the plain-language check' "$TMP/state/agent-board-poll/plain-test.log"; then
  ok em-dash-comment-held 'an em dash fails twice, logs the draft and posts only held activity'
else
  bad em-dash-comment-held "calls=$(cat "$REWRITE_CALLS") posts=$(cat "$MECH_POSTS") error=$(cat "$TMP/em-dash.err")"
fi

: > "$MECH_POSTS"
: > "$REWRITE_CALLS"
for unaffected in \
  '<p>Handoff: QA checks src/app.ts with runThing() — today.</p>' \
  '<p>Done: PR-12 at deadbeef</p>'
do
  HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
    AGENT_COMMENT_REWRITE_CLI="$TMP/bin/rewrite-model" \
    "$TMP/plain-board" comment add TEST-1 --text "$unaffected" >/dev/null
done
if [ "$(wc -l < "$MECH_POSTS")" -eq 2 ] && [ ! -s "$REWRITE_CALLS" ]; then
  ok handoff-done-unaffected 'Handoff and Done comments bypass plain-language enforcement'
else
  bad handoff-done-unaffected "calls=$(cat "$REWRITE_CALLS") posts=$(cat "$MECH_POSTS")"
fi

MECH_POSTS="$TMP/dedupe-posts"
MECH_UPDATES="$TMP/dedupe-updates"
export MECH_POSTS MECH_UPDATES
touch "$MECH_POSTS" "$MECH_UPDATES"
adapter_install_board_cli noise-test "$TMP/token" "$TMP/noise-board" "Test Bot" agent-1 1
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$TMP/mechanical-comments.json" <<EOF
{"comments":[{"id":41,"createdAt":"$now_iso","agent":{"id":"agent-1","displayName":"Test Bot"},"text":"<p><strong>Decision: The filing deadline is 22 September.</strong></p><p>Next: review the deadline.</p>"}]}
EOF
printf '<p><strong>Decision: The filing deadline is 22 September.</strong></p><p>Next: confirm the deadline.</p>\n' > "$TMP/reminder.html"
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" "$TMP/noise-board" comment add TEST-1 --file "$TMP/reminder.html" >"$TMP/dedupe.out" 2>"$TMP/dedupe.err"
if [ ! -s "$MECH_POSTS" ] \
   && grep -qF 'comment update 41 --text' "$MECH_UPDATES" \
   && grep -qF 'updated near-identical comment 41 instead of posting a new one' "$TMP/dedupe.err"; then
  ok near-duplicate-updates-in-place 'a file-backed near-duplicate updates the recent agent comment'
else
  bad near-duplicate-updates-in-place "posts=$(cat "$MECH_POSTS") updates=$(cat "$MECH_UPDATES") error=$(cat "$TMP/dedupe.err")"
fi

: > "$MECH_POSTS"
: > "$MECH_UPDATES"
cat > "$TMP/mechanical-comments.json" <<EOF
{"comments":[
  {"id":51,"createdAt":"$now_iso","agent":{"id":"agent-1","displayName":"Test Bot"},"text":"<p><strong>Decision: The first distinct update is ready.</strong></p><p>Next: review the first update.</p>"},
  {"id":52,"createdAt":"$now_iso","agent":{"id":"agent-1","displayName":"Test Bot"},"text":"<p><strong>Decision: The second distinct update is ready.</strong></p><p>Next: review the second update.</p>"},
  {"id":53,"createdAt":"$now_iso","agent":{"id":"agent-1","displayName":"Test Bot"},"text":"<p><strong>Decision: The third distinct update is ready.</strong></p><p>Next: review the third update.</p>"}
]}
EOF
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" "$TMP/noise-board" comment add TEST-1 --text '<p><strong>Decision: The fourth distinct update is ready.</strong></p><p>Next: review the fourth update.</p>' >"$TMP/cap.out" 2>"$TMP/cap.err"
if [ ! -s "$MECH_POSTS" ] \
   && grep -qF 'daily cap reached (3 agent comments on this ticket today UTC)' "$TMP/cap.err" \
   && grep -qF 'daily cap reached' "$TMP/state/agent-board-poll/noise-test.log"; then
  ok daily-comment-cap 'a fourth agent comment in one UTC day is refused and logged'
else
  bad daily-comment-cap "posts=$(cat "$MECH_POSTS") error=$(cat "$TMP/cap.err")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
