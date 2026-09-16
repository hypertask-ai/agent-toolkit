#!/usr/bin/env bash
# Owned-reply checks use local command stubs and never call the board or GitHub.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
MODEL_CLI="true"
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
  printf 'PASS %-36s %s\n' watch-all-owned-human-reply 'WATCH_SECTIONS=* yields one eligible owned reply'
  printf '\n1 passed, 0 failed\n'
else
  printf 'FAIL %-36s output=%s\n' watch-all-owned-human-reply "$output"
  printf '\n0 passed, 1 failed\n'
  exit 1
fi
