#!/usr/bin/env bash
# Comment-loop checks use local command stubs and never call a board or model.
set -euo pipefail
unset AGENT_ORIGINAL_PATH AGENT_IDENTITY_PATH

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/home/.config/agents" "$TMP/company" "$TMP/repo/graft/.graph" "$TMP/bin" "$TMP/state/agent-board-poll"
printf '{}\n' > "$TMP/repo/graft/.graph/wiring.json"
printf '# company pack\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"
GRAFT_RUN_CAPTURE="$TMP/graft-run"
GRAFT_WRAPPER_CAPTURE="$TMP/graft-wrapper"
MODEL_ARGS_CAPTURE="$TMP/model-args"
export GRAFT_RUN_CAPTURE GRAFT_WRAPPER_CAPTURE MODEL_ARGS_CAPTURE

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
printf '%s\n' "$*" > "$MODEL_ARGS_CAPTURE"
printf '%s\n' "$GRAFT|$GRAFT_MCP_COMMAND|$GRAFT_MCP_CONFIG" > "$GRAFT_RUN_CAPTURE"
graft probe
EOF
cat > "$TMP/bin/graft" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "api=${GRAFT_API_KEY-unset} dnt=${DO_NOT_TRACK-unset} args=$*" > "$GRAFT_WRAPPER_CAPTURE"
EOF
cp "$TMP/bin/provider" "$TMP/bin/claude"
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
export TASKS_JSON="$TMP/tasks.json"
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
MODEL_CLI="claude --print"
PR_REPO="example/repo"
TRIAGE="no"
CLAIM_UNASSIGNED="no"
GRAFT="on"
EOF

run_dry() {
  HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
    XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
    TASKS_JSON="$TMP/tasks.json" COMMENTS_JSON="$TMP/comments.json" \
    PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once --dry-run --explain test
}

cat > "$TMP/home/.config/agents/product-bot.conf" <<EOF
AGENT_ID="agent-product"
AGENT_NAME="Product Bot"
AGENT_KIND="manager"
AGENT_REPO="$TMP/repo"
AGENT_SLUG="product-bot"
BOARD_ADAPTER="hypertask"
BOARD_ID="1"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/board"
WATCH_SECTIONS="*"
SKILLS_INDEX=""
MODEL_CLI="claude --print"
PR_REPO="example/repo"
TRIAGE="no"
CLAIM_UNASSIGNED="yes"
GRAFT="off"
EOF
run_product_dry() {
  HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
    XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
    TASKS_JSON="$TMP/product-tasks.json" COMMENTS_JSON="$TMP/product-comments.json" \
    PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once --dry-run --explain product-bot
}
cat > "$TMP/product-tasks.json" <<'EOF'
{"tasks":[{"id":"task-product","ticketNumber":"TEST-2","section":"Review","title":"Quiet routing","description":"Check bot comments","assignees":[],"labels":[],"commentCount":1,"updatedAt":"2026-01-01T00:01:00Z"}]}
EOF

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
{"comments":[{"id":3,"createdAt":"2026-01-01T00:01:00Z","agent":{"id":"agent-builder","displayName":"Builder Bot"},"text":"<p>Done: The build is ready.</p>"}]}
EOF
output="$(run_dry)"
if printf '%s\n' "$output" | grep -qF "newest comment 3 is another bot's status marker" \
   && ! printf '%s\n' "$output" | grep -q '^would pick up TEST-1 '; then
  ok owned-rerun-gates-bot-marker 'an assigned ticket still rejects another bot status marker'
else
  bad owned-rerun-gates-bot-marker "output=$output"
fi

cat > "$TMP/product-comments.json" <<'EOF'
{"comments":[{"id":5,"createdAt":"2026-01-01T00:01:00Z","agent":{"id":"agent-product","displayName":"Product Bot"},"text":"<p>Decision: Queue note.</p>"}]}
EOF
output="$(run_product_dry)"
if printf '%s\n' "$output" | grep -q '^would pick up TEST-2 '; then
  ok first-pickup-ignores-own-comment 'an unassigned queue ticket ignores its own newest comment'
else
  bad first-pickup-ignores-own-comment "output=$output"
fi

cat > "$TMP/product-comments.json" <<'EOF'
{"comments":[{"id":6,"createdAt":"2026-01-01T00:01:00Z","agent":{"id":"agent-builder","displayName":"Builder Bot"},"text":"<p>Done: The quiet-mode fixes shipped. Did it work?</p>"}]}
EOF
output="$(run_product_dry)"
if printf '%s\n' "$output" | grep -q '^would pick up TEST-2 '; then
  ok first-pickup-ignores-bot-marker "an unassigned queue ticket ignores another bot's status marker"
else
  bad first-pickup-ignores-bot-marker "output=$output"
fi

cat > "$TMP/product-comments.json" <<'EOF'
{"comments":[{"id":7,"createdAt":"2026-01-01T00:02:00Z","agent":{"id":"agent-builder","displayName":"Builder Bot"},"text":"<p>Question: Can <span data-label=\"agent-agent-product\">Product Bot</span> confirm the release?</p>"}]}
EOF
output="$(run_product_dry)"
if printf '%s\n' "$output" | grep -q '^would pick up TEST-2 '; then
  ok bot-question-mention-triggers-product 'a bot Question mentioning Product Bot remains new work'
else
  bad bot-question-mention-triggers-product "output=$output"
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
  TASKS_JSON="$TMP/tasks.json" COMMENTS_JSON="$TMP/comments.json" GRAFT_API_KEY="paid-key-must-not-pass" \
  PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once test
if grep -qF 'run-activity: action run finished for TEST-1' "$TMP/state/agent-board-poll/test.log" \
   && ! grep -qF 'run-activity: response' "$TMP/state/agent-board-poll/test.log"; then
  ok run-finished-is-action 'a successful run records completion as action with no response activity'
else
  bad run-finished-is-action "log=$(cat "$TMP/state/agent-board-poll/test.log")"
fi
if grep -qF 'Question: comments keep the board owner mention' "$TMP/prompt"; then
  ok owner-mention-prompt-contract 'quiet runs forbid owner mentions'
else
  bad owner-mention-prompt-contract 'the model prompt omitted quiet owner handling'
fi
if grep -qF "Ask Graft before grepping: use \`graft ask '<question>'\` or the Graft MCP tools first." "$TMP/prompt" \
   && grep -qF "on|graft mcp $TMP/repo|$TMP/state/agent-board-poll/test-graft-mcp.json" "$GRAFT_RUN_CAPTURE" \
   && GRAFT_MCP_CONFIG="$TMP/state/agent-board-poll/test-graft-mcp.json" GRAFT_DIR="$TMP/repo" python3 -c 'import json,os; d=json.load(open(os.environ["GRAFT_MCP_CONFIG"])); assert d["mcpServers"]["graft"]["args"] == ["mcp",os.environ["GRAFT_DIR"]]' \
   && grep -qF -- "--mcp-config $TMP/state/agent-board-poll/test-graft-mcp.json" "$MODEL_ARGS_CAPTURE" \
   && grep -qF 'api=unset dnt=1 args=probe' "$GRAFT_WRAPPER_CAPTURE" \
   && grep -qF 'graft=on' "$TMP/state/agent-board-poll/test.log"; then
  ok graft-run-contract 'enabled runs get the prompt, CLI, MCP command, keyless wrapper, and run record'
else
  bad graft-run-contract "prompt=$(cat "$TMP/prompt") run=$(cat "$GRAFT_RUN_CAPTURE" 2>/dev/null) wrapper=$(cat "$GRAFT_WRAPPER_CAPTURE" 2>/dev/null)"
fi
if grep -qF 'Question:' "$TMP/prompt" \
   && grep -qF 'Answer:' "$TMP/prompt" \
   && grep -qF 'Decision:' "$TMP/prompt" \
   && grep -qF 'Handoff:' "$TMP/prompt" \
   && grep -qF 'Done:' "$TMP/prompt" \
   && grep -qF 'Everything else' "$TMP/prompt"; then
  ok comment-kind-prompt-contract 'every run receives the five comment kinds'
else
  bad comment-kind-prompt-contract 'the model prompt omitted the five-kind contract'
fi
if ROOT="$ROOT" TMP="$TMP" python3 - <<'PYEOF'
import os
from pathlib import Path
root = Path(os.environ["ROOT"])
prompt = Path(os.environ["TMP"], "prompt").read_text()
rules = root / "adapters" / "hypertask" / "plain-language"
assert "product owner on a phone" in prompt
assert str(Path(os.environ["TMP"], "company", "skills", "talk-to-valentin", "SKILL.md")) in prompt
for name in ("pospeak.md", "ticket-format.md", "unslop.md", "i-have-adhd.md"):
    assert (rules / name).read_text().rstrip() in prompt
PYEOF
then
  ok plain-language-prompt-contract 'all five comment kinds receive the four rule texts verbatim'
else
  bad plain-language-prompt-contract 'the runner prompt omitted the phone reader or verbatim rules'
fi
if grep -qF 'exactly five allowed' "$ROOT/SKILL.md" \
   && grep -qF 'exactly five allowed' "$ROOT/MAINTAINER.md" \
   && grep -qF 'Ticket comments have exactly five kinds' "$ROOT/scripts/create-agent.sh" \
   && grep -qF 'Reply-only runs default to `Answer:`' "$ROOT/project-template/AGENTS.md"; then
  ok comment-kind-setup-contract 'docs and setup output state all five kinds and the reply default'
else
  bad comment-kind-setup-contract 'a required setup surface omitted Answer or its reply-only default'
fi

# shellcheck disable=SC1090
. "$ROOT/adapters/hypertask/adapter.sh"
cat > "$TMP/mechanical-tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","assignees":[{"agent":{"id":"agent-1"}}],"labels":[]},{"id":"task-2","ticketNumber":"TEST-2","assignees":[],"labels":[]},{"id":"task-3","ticketNumber":"TEST-3","assignees":[],"labels":[]}]}
EOF
export TASKS_JSON="$TMP/mechanical-tasks.json"
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

printf 'TEST-1\t%s\n' "$(date +%s)" > "$TMP/state/agent-board-poll/mention-test.owner-mentions"
owner_answer='<p><strong>Answer: <span data-type="mention" data-label="name-6">Owner</span>, the release is ready.</strong></p><p>Next: review the result.</p>'
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
  AGENT_REPLY_ONLY=yes AGENT_OWNER_MENTION_REPLY=yes \
  "$TMP/mention-board" comment add TEST-1 --text "$owner_answer" >"$TMP/owner-answer.out" 2>"$TMP/owner-answer.err"
if [ "$(wc -l < "$TMP/mechanical-posts")" -eq 3 ] \
   && tail -1 "$TMP/mechanical-posts" | grep -qF 'name-6' \
   && ! grep -qF 'owner-mention budget' "$TMP/owner-answer.err"; then
  ok owner-mention-answer-exception 'an Answer to an owner mention keeps the owner mention after its daily allowance was used'
else
  bad owner-mention-answer-exception "posts=$(cat "$TMP/mechanical-posts") error=$(cat "$TMP/owner-answer.err")"
fi


question='<p><strong>Question: Can <span data-type="mention" data-label="name-6">Owner</span> approve the release?</strong></p>'
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" "$TMP/mention-board" comment add TEST-2 --text "$question" >"$TMP/question.out" 2>"$TMP/question.err"
if [ "$(wc -l < "$TMP/mechanical-posts")" -eq 4 ] \
   && tail -1 "$TMP/mechanical-posts" | grep -qF 'name-6'; then
  ok question-owner-mention 'Question: reaches the ticket with owner mention intact'
else
  bad question-owner-mention "posts=$(cat "$TMP/mechanical-posts") error=$(cat "$TMP/question.err")"
fi
printf 'TEST-3\t%s\n' "$(date +%s)" >> "$TMP/state/agent-board-poll/mention-test.owner-mentions"
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" "$TMP/mention-board" comment add TEST-3 --text "$question" >"$TMP/throttled.out" 2>"$TMP/throttled.err"
if [ "$(wc -l < "$TMP/mechanical-posts")" -eq 5 ] \
   && ! tail -1 "$TMP/mechanical-posts" | grep -qF 'name-6' \
   && grep -qF 'run-activity: action owner-mention budget: throttled Question:' "$TMP/state/agent-board-poll/mention-test.log"; then
  ok throttled-question-still-posted 'a throttled mention logs activity and posts the question without the mention'
else
  bad throttled-question-still-posted "posts=$(cat "$TMP/mechanical-posts") error=$(cat "$TMP/throttled.err")"
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
  '<p><strong>Answer: The release number is 42.</strong></p><p>Next: use release 42.</p>' \
  '<p><strong>Decision: Legal approval is required.</strong></p><p>Next: wait for approval.</p>' \
  '<p><strong>Handoff: The quiet-mode fixes shipped.</strong></p><p>Next: QA Bot owns verification.</p>' \
  '<p><strong>Done: The quiet-mode fixes shipped.</strong></p><p>Next: Review <a href="https://github.com/example/repo/pull/1">PR 1</a>.</p>'
do
  HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" "$TMP/kind-board" comment add TEST-1 --text "$allowed" >/dev/null
done
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" "$TMP/kind-board" comment add TEST-2 --text '<p><strong>Claimed.</strong> A session is working this ticket now.</p>' >/dev/null
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" "$TMP/kind-board" comment add TEST-3 --text '<p><strong>Claimed: A session is working this ticket now.</strong></p>' >/dev/null
if [ "$(wc -l < "$MECH_POSTS")" -eq 7 ]; then
  ok claim-comment-markers-pass 'five outcome kinds plus Claimed: and legacy Claimed. reach the board CLI'
else
  bad claim-comment-markers-pass "posts=$(cat "$MECH_POSTS")"
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
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
  AGENT_COMMENT_REWRITE_CLI="$TMP/bin/rewrite-model" \
  "$TMP/plain-board" comment add TEST-1 --text "$technical" >"$TMP/technical.out" 2>"$TMP/technical.err"
if [ ! -s "$REWRITE_CALLS" ] && [ ! -s "$MECH_POSTS" ] \
   && grep -qF "$technical" "$TMP/state/agent-board-poll/plain-test.log" \
   && grep -qF 'comment contains a file path' "$TMP/state/agent-board-poll/plain-test.log"; then
  ok invalid-comment-held-verbatim 'an invalid draft is logged unchanged and never sent to a rewrite model'
else
  bad invalid-comment-held-verbatim "calls=$(cat "$REWRITE_CALLS") posts=$(cat "$MECH_POSTS") error=$(cat "$TMP/technical.err")"
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
em_dash='<p><strong>Decision: The release is ready — now.</strong></p><p>Next: approve the release.</p>'
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
  AGENT_COMMENT_REWRITE_CLI="$TMP/bin/rewrite-model" \
  "$TMP/plain-board" comment add TEST-1 --text "$em_dash" >"$TMP/em-dash.out" 2>"$TMP/em-dash.err"
if [ ! -s "$REWRITE_CALLS" ] && [ ! -s "$MECH_POSTS" ] \
   && grep -qF "$em_dash" "$TMP/state/agent-board-poll/plain-test.log" \
   && grep -qF 'comment contains an em dash' "$TMP/state/agent-board-poll/plain-test.log"; then
  ok em-dash-comment-held 'the final gate holds an em dash unchanged instead of changing the words'
else
  bad em-dash-comment-held "calls=$(cat "$REWRITE_CALLS") posts=$(cat "$MECH_POSTS") error=$(cat "$TMP/em-dash.err")"
fi

: > "$MECH_POSTS"
: > "$REWRITE_CALLS"
link_only='<p><strong>Done: <a href="https://github.com/example/repo/pull/1">PR 1</a>.</strong></p><p>Next: review the release.</p>'
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
  AGENT_COMMENT_REWRITE_CLI="$TMP/bin/rewrite-model" \
  "$TMP/plain-board" comment add TEST-1 --text "$link_only" >"$TMP/link-only.out" 2>"$TMP/link-only.err"
if [ ! -s "$REWRITE_CALLS" ] && [ ! -s "$MECH_POSTS" ] \
   && grep -qF "$link_only" "$TMP/state/agent-board-poll/plain-test.log" \
   && grep -qF 'Done and Handoff must explain what shipped, not only link to it' "$TMP/state/agent-board-poll/plain-test.log"; then
  ok link-only-comment-held 'a link-only result is held unchanged rather than given invented meaning'
else
  bad link-only-comment-held "calls=$(cat "$REWRITE_CALLS") posts=$(cat "$MECH_POSTS") error=$(cat "$TMP/link-only.err")"
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
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" AGENT_REPLY_ONLY=yes \
  "$TMP/noise-board" comment add TEST-1 --text '<p><strong>Answer: The fourth distinct update is ready.</strong></p><p>Next: review the fourth update.</p>' >"$TMP/cap.out" 2>"$TMP/cap.err"
if [ ! -s "$MECH_POSTS" ] \
   && grep -qF 'daily cap reached (3 agent comments on this ticket today UTC)' "$TMP/cap.err" \
   && grep -qF 'daily cap reached' "$TMP/state/agent-board-poll/noise-test.log"; then
  ok daily-answer-comment-cap 'a reply-only Answer counts against the existing three-comment cap'
else
  bad daily-answer-comment-cap "posts=$(cat "$MECH_POSTS") error=$(cat "$TMP/cap.err")"
fi

# QA verdicts: the three-comment cap still holds for chatter, but a QA-kind
# Done:/Handoff:/Question: always posts, keeps its marker, and skips the
# server-side improve rewrite that drops the marker.
: > "$MECH_POSTS"
: > "$MECH_UPDATES"
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" AGENT_RUNNER_KIND=qa \
  "$TMP/noise-board" comment add TEST-1 --text '<p><strong>Question: Can the supervisor give QA the flagged test account?</strong></p><p>The search operators are hidden for the plain QA account.</p><p>Next: the supervisor decides.</p>' >"$TMP/qa-cap.out" 2>"$TMP/qa-cap.err"
if grep -qF 'comment add TEST-1' "$MECH_POSTS" \
   && grep -qF 'Question: Can the supervisor give QA' "$MECH_POSTS" \
   && ! grep -qF -- '--improve' "$MECH_POSTS" \
   && [ ! -s "$MECH_UPDATES" ] \
   && grep -qF 'comment cap bypassed on TEST-1: QA verdict always posts' "$TMP/state/agent-board-poll/noise-test.log"; then
  ok qa-verdict-bypasses-cap 'a QA Question: verdict posts with its marker after the three-comment cap'
else
  bad qa-verdict-bypasses-cap "posts=$(cat "$MECH_POSTS") updates=$(cat "$MECH_UPDATES") error=$(cat "$TMP/qa-cap.err")"
fi

: > "$MECH_POSTS"
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" AGENT_RUNNER_KIND=qa AGENT_REPLY_ONLY=yes \
  "$TMP/noise-board" comment add TEST-1 --text '<p><strong>Answer: The fifth distinct update is ready.</strong></p><p>Next: review the fifth update.</p>' >"$TMP/qa-answer.out" 2>"$TMP/qa-answer.err"
if [ ! -s "$MECH_POSTS" ] && grep -qF 'daily cap reached' "$TMP/qa-answer.err"; then
  ok qa-answer-still-capped 'a QA-kind Answer: is chatter and still counts against the cap'
else
  bad qa-answer-still-capped "posts=$(cat "$MECH_POSTS") error=$(cat "$TMP/qa-answer.err")"
fi

: > "$MECH_POSTS"
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" AGENT_RUNNER_KIND=worker \
  "$TMP/noise-board" comment add TEST-1 --text '<p><strong>Done: The worker shipped the sixth distinct update.</strong></p><p>Next: review the sixth update.</p>' >"$TMP/worker-done.out" 2>"$TMP/worker-done.err"
if [ ! -s "$MECH_POSTS" ] && grep -qF 'daily cap reached' "$TMP/worker-done.err"; then
  ok worker-done-still-capped 'a non-QA Done: still counts against the cap'
else
  bad worker-done-still-capped "posts=$(cat "$MECH_POSTS") error=$(cat "$TMP/worker-done.err")"
fi

: > "$MECH_POSTS"
: > "$MECH_UPDATES"
printf '{"comments":[{"id":61,"createdAt":"%s","agent":{"id":"agent-1","displayName":"Test Bot"},"text":"<p><strong>Done: QA PASS on production, the columns stayed visible.</strong></p><p>Next: nothing.</p>"}]}\n' "$now_iso" > "$TMP/mechanical-comments.json"
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" AGENT_RUNNER_KIND=qa \
  "$TMP/noise-board" comment add TEST-1 --text '<p><strong>Done: QA PASS on production, the columns stayed visible after reload.</strong></p><p>Next: nothing left.</p>' >"$TMP/qa-fresh.out" 2>"$TMP/qa-fresh.err"
if grep -qF 'Done: QA PASS on production' "$MECH_POSTS" && [ ! -s "$MECH_UPDATES" ]; then
  ok qa-verdict-posts-fresh 'a QA verdict posts a new comment instead of editing a near-duplicate'
else
  bad qa-verdict-posts-fresh "posts=$(cat "$MECH_POSTS") updates=$(cat "$MECH_UPDATES") error=$(cat "$TMP/qa-fresh.err")"
fi

: > "$MECH_POSTS"
printf '{"comments":[]}\n' > "$TMP/mechanical-comments.json"
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" AGENT_RUNNER_KIND=worker \
  "$TMP/noise-board" comment add TEST-1 --text '<p><strong>Decision: The worker keeps the release date.</strong></p><p>Next: review the date.</p>' >"$TMP/marked.out" 2>"$TMP/marked.err"
if grep -qF 'Decision: The worker keeps the release date.' "$MECH_POSTS" \
   && ! grep -qF -- '--improve' "$MECH_POSTS"; then
  ok marked-comment-skips-server-improve 'a marked comment keeps its marker and skips the server improve rewrite'
else
  bad marked-comment-skips-server-improve "posts=$(cat "$MECH_POSTS") error=$(cat "$TMP/marked.err")"
fi

: > "$MECH_POSTS"
held_done='<p><strong>Done: <a href="https://github.com/example/repo/pull/2">PR 2</a>.</strong></p><p>Next: nothing left.</p>'
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" AGENT_RUNNER_KIND=qa \
  "$TMP/noise-board" comment add TEST-1 --text "$held_done" >"$TMP/qa-held.out" 2>"$TMP/qa-held.err"
if grep -qF 'pull/2' "$MECH_POSTS" \
   && grep -qF 'QA verdict posted despite shape check' "$TMP/state/agent-board-poll/noise-test.log"; then
  ok qa-verdict-not-held 'a QA verdict that fails the shape check still posts and logs the reasons'
else
  bad qa-verdict-not-held "posts=$(cat "$MECH_POSTS") error=$(cat "$TMP/qa-held.err")"
fi

: > "$MECH_POSTS"
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" AGENT_RUNNER_KIND=worker \
  "$TMP/noise-board" comment add TEST-1 --text "$held_done" >"$TMP/worker-held.out" 2>"$TMP/worker-held.err"
if [ ! -s "$MECH_POSTS" ]; then
  ok worker-done-still-held 'a non-QA Done: that fails the shape check is still held'
else
  bad worker-done-still-held "posts=$(cat "$MECH_POSTS") error=$(cat "$TMP/worker-held.err")"
fi

: > "$MECH_POSTS"
owner_buried='<p><strong><span data-type="mention" data-id="6" data-label="Valentin Yeo">Valentin Yeo</span> Answer: The board loaded.</strong></p><p>Next: check the screenshot.</p>'
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
  AGENT_REPLY_ONLY=yes AGENT_OWNER_MENTION_REPLY=yes \
  "$TMP/noise-board" comment add TEST-1 --text "$owner_buried" >"$TMP/owner-cap.out" 2>"$TMP/owner-cap.err"
owner_shape=no
if python3 - "$MECH_POSTS" <<'PY'
import html, re, sys
post = open(sys.argv[1], encoding="utf-8").read()
start = post.find("<p>")
raise SystemExit(1 if start < 0 else 0)
PY
then
  if python3 - "$MECH_POSTS" <<'PY'
import html, re, sys
post = open(sys.argv[1], encoding="utf-8").read()
body = post[post.find("<p>"):]
plain = " ".join(html.unescape(re.sub(r"<[^>]+>", " ", body)).split())
ok = plain.startswith("Answer:") and ("data-label=\"name-6\"" in body or "data-label='name-6'" in body) and "The board loaded." in plain
raise SystemExit(0 if ok else 1)
PY
  then
    owner_shape=yes
  fi
fi
if [ "$(wc -l < "$MECH_POSTS")" -eq 1 ] \
   && [ "$owner_shape" = yes ] \
   && ! grep -qF 'redirected unmarked ticket comment to run activity' "$TMP/owner-cap.err" \
   && ! grep -qF 'daily cap reached' "$TMP/owner-cap.err"; then
  ok owner-answer-posts-at-cap 'an owner Answer posts for real in quiet mode even at the daily cap'
else
  bad owner-answer-posts-at-cap "posts=$(cat "$MECH_POSTS") error=$(cat "$TMP/owner-cap.err")"
fi

: > "$MECH_POSTS"
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
  "$TMP/noise-board" comment add TEST-1 --text '<p>Thanks, still looking at the board.</p>' >"$TMP/chatter.out" 2>"$TMP/chatter.err"
if [ ! -s "$MECH_POSTS" ] \
   && grep -qF 'run-activity: action Thanks, still looking at the board.' "$TMP/state/agent-board-poll/noise-test.log" \
   && grep -qF 'redirected unmarked ticket comment to run activity' "$TMP/chatter.err"; then
  ok quiet-chatter-stays-activity 'a non-owner chatter comment in quiet mode still goes to activity'
else
  bad quiet-chatter-stays-activity "posts=$(cat "$MECH_POSTS") error=$(cat "$TMP/chatter.err")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
