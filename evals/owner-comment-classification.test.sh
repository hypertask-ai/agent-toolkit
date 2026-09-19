#!/usr/bin/env bash
# Owner comment pickup checks run against local board and model stubs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/config" "$TMP/bin" "$TMP/repo" "$TMP/company" "$TMP/state"
printf '# company skills\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"

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
prompt="${!#}"
[[ "$prompt" = *'Description: Ship the requested change'* ]]
[[ "$prompt" = *'Full comment thread:'*'Do not build this yet.'* ]]
[[ "$prompt" = *'Newest owner comment: Do not build this yet.'* ]]
printf 'classifier\n' >> "$MOCK_MODEL_LOG"
printf '%s\n' "$MOCK_CLASSIFICATION"
EOF
cat > "$TMP/bin/model" <<'EOF'
#!/usr/bin/env bash
printf 'work\n' >> "$MOCK_MODEL_LOG"
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
  *' task assign '*)
    printf 'assign TEST-1 agent-dev\n' >> "$MOCK_BOARD_LOG"
    ;;
  *' task unassign '*)
    printf 'unassign TEST-1 agent-dev\n' >> "$MOCK_BOARD_LOG"
    python3 - "$MOCK_TASKS" <<'PYEOF'
import json, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
doc["tasks"][0]["assignees"] = []
json.dump(doc, open(path, "w", encoding="utf-8"))
PYEOF
    ;;
  *' task move '*)
    section=""
    argv=("$@")
    for ((i = 0; i < ${#argv[@]}; i++)); do
      [ "${argv[$i]}" != "--section" ] || section="${argv[$((i + 1))]:-}"
    done
    printf 'move TEST-1 %s\n' "$section" >> "$MOCK_BOARD_LOG"
    ;;
  *' comment add '*)
    text=""
    argv=("$@")
    for ((i = 0; i < ${#argv[@]}; i++)); do
      [ "${argv[$i]}" != "--text" ] || text="${argv[$((i + 1))]:-}"
    done
    printf 'comment TEST-1 %s\n' "$text" >> "$MOCK_BOARD_LOG"
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
BOARD_CLI="$TMP/board"
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
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","projectId":15,"section":"Backlog","title":"Build it","description":"Ship the requested change","assignees":[{"agent":{"id":"agent-dev","displayName":"Dev"}}],"labels":[],"commentCount":1,"updatedAt":"2026-09-19T08:02:00Z"}]}
EOF
cat > "$TMP/comments.json" <<'EOF'
{"comments":[{"id":90,"createdAt":"2026-09-19T08:02:00Z","agent":null,"creator":{"id":6,"displayName":"Valentin"},"text":"<p>Do not build this yet.</p>"}]}
EOF
: > "$TMP/board.log"
: > "$TMP/model.log"

HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state" \
  COMPANY_SKILLS_DIR="$TMP/company" PATH="$TMP/bin:$PATH" MOCK_CLASSIFICATION=hold \
  MOCK_TASKS="$TMP/tasks.json" MOCK_COMMENTS="$TMP/comments.json" \
  MOCK_BOARD_LOG="$TMP/board.log" MOCK_MODEL_LOG="$TMP/model.log" \
  "$ROOT/scripts/agent-board-poll" --once dev > "$TMP/out" 2>&1

if [ "$(cat "$TMP/model.log")" = classifier ] \
   && grep -qxF 'unassign TEST-1 agent-dev' "$TMP/board.log" \
   && grep -qxF 'move TEST-1 Review' "$TMP/board.log" \
   && grep -qF '<strong>Decision: I read your comment as a hold.</strong>' "$TMP/board.log" \
   && ! grep -q '^assign ' "$TMP/board.log" \
   && ! grep -q '^work$' "$TMP/model.log"; then
  echo 'PASS owner-hold-before-claim              assigned agent unassigns, moves to Review, acknowledges, and does not run'
else
  echo "FAIL owner-hold-before-claim              board=$(cat "$TMP/board.log") model=$(cat "$TMP/model.log") output=$(cat "$TMP/out")"
  exit 1
fi
