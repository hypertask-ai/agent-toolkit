#!/usr/bin/env bash
# Answerer selection runs entirely against local board and GitHub stubs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

CONF_DIR="$TMP/home/.config/agents"
mkdir -p "$CONF_DIR" "$TMP/bin" "$TMP/company" "$TMP/repo" "$TMP/boards"
printf '# company pack\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"

cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " = *" comment add TEST-1 "* ]]; then
  printf '%s\n' "$*" >> "$BOARD_WRITE_LOG"
fi
exit 0
EOF
cat > "$TMP/bin/provider" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$AGENT_NAME" >> "$MODEL_RUN_LOG"
"$AGENT_BOARD_CLI" comment add TEST-1 --text '<p><strong>Decision: This is the selected answer.</strong></p><p>Next: continue.</p>'
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *'/mcp/tasks?'*) cat "$TASKS_JSON"; printf '\n200' ;;
  *'/mcp/comments?'*) cat "$COMMENTS_JSON"; printf '\n200' ;;
  *) printf '{}\n200' ;;
esac
EOF
chmod +x "$TMP/bin/"*

write_conf() {
  local slug="$1" id="$2" name="$3"
  cat > "$CONF_DIR/$slug.conf" <<EOF
AGENT_SLUG="$slug"
AGENT_ID="$id"
AGENT_NAME="$name"
AGENT_KIND="dev"
AGENT_REPO="$TMP/repo"
BOARD_ADAPTER="hypertask"
BOARD_ID="1"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/boards/$slug"
WATCH_SECTIONS="*"
SKILLS_INDEX=""
MODEL_CLI="provider"
PR_REPO="example/repo"
TRIAGE="no"
CLAIM_UNASSIGNED="no"
ANSWERER_FALLBACK="gamma"
EOF
}
write_conf alpha agent-a 'Alpha Bot'
write_conf beta agent-b 'Beta Bot'
write_conf gamma agent-c 'Gamma Bot'

run_agent() {
  local case_name="$1" slug="$2"
  HOME="$TMP/home" AGENT_CONFIG_DIR="$CONF_DIR" \
    XDG_STATE_HOME="$TMP/state/$case_name/$slug" COMPANY_SKILLS_DIR="$TMP/company" \
    TASKS_JSON="$TMP/tasks.json" COMMENTS_JSON="$TMP/comments.json" \
    BOARD_WRITE_LOG="$TMP/board-writes.log" MODEL_RUN_LOG="$TMP/model-runs.log" \
    PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once --dry-run --explain "$slug"
}

run_live() {
  local case_name="$1" slug="$2"
  HOME="$TMP/home" AGENT_CONFIG_DIR="$CONF_DIR" \
    XDG_STATE_HOME="$TMP/state/$case_name/$slug" COMPANY_SKILLS_DIR="$TMP/company" \
    TASKS_JSON="$TMP/tasks.json" COMMENTS_JSON="$TMP/comments.json" \
    BOARD_WRITE_LOG="$TMP/board-writes.log" MODEL_RUN_LOG="$TMP/model-runs.log" \
    PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once "$slug"
}

check_case() {
  local name="$1" expected="$2" expected_reason="$3" slug output reply_count=0 winner=""
  for slug in alpha beta gamma; do
    output="$(run_agent "$name" "$slug")"
    printf '%s\n' "$output" > "$TMP/$name-$slug.out"
    if printf '%s\n' "$output" | grep -q '^    reply-only:'; then
      reply_count=$((reply_count + 1))
      winner="$slug"
    fi
  done
  if [ "$reply_count" -eq 1 ] && [ "$winner" = "$expected" ] \
     && grep -qF "owns question 20 by $expected_reason" "$TMP/$name-$expected.out"; then
    ok "$name" "only $expected is reply-only by $expected_reason"
  else
    bad "$name" "reply-only count=$reply_count winner=${winner:-none}; outputs=$TMP/$name-*.out"
  fi
}

cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","section":"Review","title":"Owner question","description":"Choose one answerer","assignees":[{"agent":{"id":"agent-a","displayName":"Alpha Bot"}}],"labels":[],"commentCount":1,"updatedAt":"2026-09-17T10:00:00Z"}]}
EOF
cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":20,"createdAt":"2026-09-17T10:00:00Z","agent":null,"creator":{"displayName":"Owner"},"text":"<p>Beta Bot said this earlier. <span data-label=\"agent-agent-c\">Gamma Bot</span>, which option should we choose?</p>"}]}
EOF
check_case mention-beats-assignee gamma mention

cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","section":"Review","title":"Owner question","description":"Choose one answerer","assignees":[{"agent":{"id":"agent-a","displayName":"Alpha Bot"}}],"labels":[],"commentCount":2,"updatedAt":"2026-09-17T10:00:00Z"}]}
EOF
cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":10,"createdAt":"2026-09-17T09:00:00Z","agent":{"id":"agent-b","displayName":"Beta Bot"},"creator":{"displayName":"Owner"},"text":"<p>Done: Earlier work.</p>"},{"id":20,"createdAt":"2026-09-17T10:00:00Z","agent":null,"creator":{"displayName":"Owner"},"text":"<p>Can we change the result?</p>"}]}
EOF
check_case assignee-beats-history alpha assignee

cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","section":"Review","title":"Owner question","description":"Choose one answerer","assignees":[],"labels":[],"commentCount":3,"updatedAt":"2026-09-17T10:00:00Z"}]}
EOF
cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":8,"createdAt":"2026-09-17T08:00:00Z","agent":{"id":"agent-a","displayName":"Alpha Bot"},"creator":{"displayName":"Owner"},"text":"<p>Decision: Use the old route.</p>"},{"id":10,"createdAt":"2026-09-17T09:00:00Z","agent":{"id":"agent-b","displayName":"Beta Bot"},"creator":{"displayName":"Owner"},"text":"<p><strong>Done: The update shipped.</strong></p>"},{"id":20,"createdAt":"2026-09-17T10:00:00Z","agent":null,"creator":{"displayName":"Owner"},"text":"<p>What should happen next?</p>"}]}
EOF
check_case latest-marker-author beta 'last Done/Decision author'

cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","section":"Review","title":"Owner question","description":"Choose one answerer","assignees":[],"labels":[],"commentCount":1,"updatedAt":"2026-09-17T10:00:00Z"}]}
EOF
cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":20,"createdAt":"2026-09-17T10:00:00Z","agent":null,"creator":{"displayName":"Owner"},"text":"<p>Who should answer this?</p>"}]}
EOF
check_case configured-fallback gamma fallback

: > "$TMP/board-writes.log"
: > "$TMP/model-runs.log"
for slug in alpha beta gamma; do
  run_live one-live-reply "$slug" >/dev/null
done
if [ "$(wc -l < "$TMP/model-runs.log")" -eq 1 ] \
   && [ "$(cat "$TMP/model-runs.log")" = 'Gamma Bot' ] \
   && [ "$(wc -l < "$TMP/board-writes.log")" -eq 1 ]; then
  ok one-live-reply 'three polls produce one model answer and one stubbed board reply'
else
  bad one-live-reply "models=$(cat "$TMP/model-runs.log") writes=$(cat "$TMP/board-writes.log")"
fi

cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","section":"Review","title":"Answered question","description":"Do not answer twice","assignees":[],"labels":[],"commentCount":2,"updatedAt":"2026-09-17T10:01:00Z"}]}
EOF
cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":20,"createdAt":"2026-09-17T10:00:00Z","agent":null,"creator":{"displayName":"Owner"},"text":"<p>Who should answer this?</p>"},{"id":21,"createdAt":"2026-09-17T10:01:00Z","agent":{"id":"agent-a","displayName":"Alpha Bot"},"creator":{"displayName":"Owner"},"text":"<p>Decision: Alpha already answered.</p>"}]}
EOF
reply_count=0
for slug in alpha beta gamma; do
  output="$(run_agent already-answered "$slug")"
  printf '%s\n' "$output" > "$TMP/already-answered-$slug.out"
  if printf '%s\n' "$output" | grep -q '^    reply-only:'; then
    reply_count=$((reply_count + 1))
  fi
done
if [ "$reply_count" -eq 0 ] \
   && grep -qF 'alpha already commented after question 20' "$TMP/already-answered-beta.out"; then
  ok already-answered 'a later agent comment suppresses every second answer'
else
  bad already-answered "reply-only count=$reply_count; outputs=$TMP/already-answered-*.out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
