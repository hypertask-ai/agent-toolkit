#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/conf" "$TMP/comments"
printf 'token\n' > "$TMP/token"
printf '{"score":87}\n' > "$TMP/health.json"
printf 'key,/missing,example/repo,main\n' > "$TMP/repos.allow"
printf 'BOARD_ADAPTER="hypertask"\nAGENT_SLUG="dev-1"\n' > "$TMP/conf/dev-1.conf"
printf 'one\n' > "$TMP/mode"

python3 - "$TMP/tasks-one.json" "$TMP/tasks-two.json" <<'PYEOF'
import json, sys
base = [{"id":"b%d" % i,"ticketNumber":"TEST-%d" % i,"title":"queued","section":"Backlog","updatedAt":"2026-09-18T11:00:00Z"} for i in range(1, 10)]
base += [{"id":"stale","ticketNumber":"TEST-20","title":"stale review","section":"AI Review","updatedAt":"2026-09-16T08:00:00Z"}]
json.dump({"tasks":base}, open(sys.argv[1], "w"))
more = base + [{"id":"q%d" % i,"ticketNumber":"TEST-%d" % (30+i),"title":"qa queue","section":"QA","updatedAt":"2026-09-18T11:00:00Z"} for i in range(9)]
json.dump({"tasks":more}, open(sys.argv[2], "w"))
PYEOF

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
mode="$(cat "$FIXTURE/mode")"
cat "$FIXTURE/tasks-$mode.json"
printf '\n200'
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '[{"number":4,"url":"https://github.com/example/repo/pull/4","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2026-09-18T08:00:00Z"}]}]'
EOF
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'inactive\n'
exit 3
EOF
cat > "$TMP/bin/board" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-} ${2:-} ${3:-}" = "--json project show" ]; then
  printf '%s\n' '{"project":{"id":15,"ownerId":"owner-1","owner":{"id":"owner-1","displayName":"Valentin"},"sections":[{"section_title":"Inbox"},{"section_title":"Triage"}]}}'
  exit 0
fi
if [ "${1:-} ${2:-}" = "task create" ]; then
  count="$(cat "$FIXTURE/create-count" 2>/dev/null || printf 0)"
  count=$((count + 1))
  printf '%s\n' "$count" > "$FIXTURE/create-count"
  printf '%q ' "$@" >> "$FIXTURE/create-calls"
  printf '\n' >> "$FIXTURE/create-calls"
  printf '{"task":{"id":"bug-%s","ticketNumber":"TEST-%s","projectId":15,"uniqueIndex":%s}}\n' "$count" "$((100 + count))" "$((100 + count))"
  exit 0
fi
if [ "${1:-} ${2:-}" = "comment add" ]; then
  count="$(cat "$FIXTURE/comment-count" 2>/dev/null || printf 0)"
  count=$((count + 1))
  printf '%s\n' "$count" > "$FIXTURE/comment-count"
  printf '%s' "$3" > "$FIXTURE/comments/$count.ref"
  [ "${4:-}" = "--text" ] || exit 2
  printf '%s' "$5" > "$FIXTURE/comments/$count.html"
  exit 0
fi
printf 'unexpected board call\n' >&2
exit 2
EOF
chmod +x "$TMP/bin"/*

CONTRACT="$ROOT/scripts/agent-reply-contract"
"$CONTRACT" received --state-dir "$TMP/state" --slug dev-1 --event-id 15:1 --at 2026-09-18T10:00:00Z --board 15 --ticket TEST-1 --url https://app.hypertask.ai/detail/project-15/1 --kind question
"$CONTRACT" acknowledged --state-dir "$TMP/state" --slug dev-1 --event-id 15:1 --at 2026-09-18T10:00:30Z --estimate-minutes 30
"$CONTRACT" answered --state-dir "$TMP/state" --slug dev-1 --event-id 15:1 --at 2026-09-18T10:10:00Z
"$CONTRACT" received --state-dir "$TMP/state" --slug dev-1 --event-id 15:2 --at 2026-09-18T09:00:00Z --board 15 --ticket TEST-2 --url https://app.hypertask.ai/detail/project-15/2 --kind mention
printf '%s\n' '{"agent":"dev-1","state":"failed","at":"2026-09-18T09:30:00Z","detail":"runner failed"}' > "$TMP/state/dev-1.status"

run_health() {
  FIXTURE="$TMP" PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-health" tick \
    --state-dir "$TMP/state" --boards 15 --token-file "$TMP/token" \
    --board-cli "$TMP/bin/board" --repos-allow "$TMP/repos.allow" \
    --config-dir "$TMP/conf" --health-file "$TMP/health.json" \
    --now 2026-09-18T12:00:00Z
}
run_health
printf 'two\n' > "$TMP/mode"
run_health
run_health

if [ "$(cat "$TMP/create-count")" -eq 2 ] \
   && grep -q -- '--title Board\\ health' "$TMP/create-calls" \
   && grep -q -- '--labels Bug' "$TMP/create-calls" \
   && [ "$(cat "$TMP/comment-count")" -eq 2 ] \
   && [ "$(cat "$TMP/comments/1.ref")" = TEST-101 ] \
   && [ "$(cat "$TMP/comments/2.ref")" = TEST-101 ] \
   && head -1 "$TMP/comments/1.html" | grep -q '^<p><strong>Decision: Supervisor health score: 87\.</strong></p>$' \
   && grep -q 'Mentions or questions: 2\. Acked within one tick: 1\. Answered: 1\. Within estimate: 1\.' "$TMP/comments/1.html" \
   && grep -q 'TEST-2' "$TMP/comments/1.html" \
   && grep -q 'Backlog has 9 tickets' "$TMP/comments/1.html" \
   && grep -q 'AI Review over 24 hours' "$TMP/comments/1.html" \
   && grep -q 'example/repo#4' "$TMP/comments/1.html" \
   && grep -q 'Runner dev-1 error' "$TMP/comments/1.html" \
   && grep -q 'Timer for dev-1 is down' "$TMP/comments/1.html" \
   && grep -q 'QA has 9 tickets' "$TMP/comments/2.html" \
   && [ "$(grep -h -o 'name-owner-1' "$TMP/comments"/*.html | wc -l)" -eq 1 ] \
   && python3 "$ROOT/adapters/hypertask/plain-language/check-comment.py" < "$TMP/comments/1.html" \
   && python3 "$ROOT/adapters/hypertask/plain-language/check-comment.py" < "$TMP/comments/2.html"; then
  printf 'PASS %-36s %s\n' board-health-contract 'daily totals, one Bug per miss, pile-up alarms, dedupe, health score, and owner budget hold'
else
  printf 'FAIL %-36s %s\n' board-health-contract "creates=$(cat "$TMP/create-count" 2>/dev/null) comments=$(cat "$TMP/comment-count" 2>/dev/null)"
  for file in "$TMP/comments"/*.html; do [ -f "$file" ] && { printf '%s:\n' "$file"; cat "$file"; printf '\n'; }; done
  exit 1
fi
