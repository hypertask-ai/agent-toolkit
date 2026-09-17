#!/usr/bin/env bash
# Hypertask adapter checks use local JSON fixtures and never call the board.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

# shellcheck disable=SC1090
. "$ROOT/adapters/hypertask/adapter.sh"
COMMENTS="$TMP/comments.json"
_ht_get() { cat "$COMMENTS"; }

python3 - "$COMMENTS" <<'PYEOF'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"comments": [
        {"id": 1, "createdAt": "2026-01-01T00:00:00Z", "agent": {"id": "agent-1"}, "text": "claimed"},
        {"id": 2, "createdAt": "2026-01-01T00:01:00Z", "agent": None, "text": "x" * 300_000},
    ]}, handle)
PYEOF
row='{"id":"task-1","ref":"TEST-1","agent_ids":[]}'
set +e
output="$(_ht_owned_row "$TMP/token" task-1 "$row" 1 agent-1 2>"$TMP/large.err")"
status=$?
set -e
if [ "$status" -eq 0 ] && printf '%s' "$output" | grep -q '"trigger": "new_comment"'; then
  ok owned-row-large-json 'a 300 KB comments response produces an eligible row'
else
  bad owned-row-large-json "status=$status error=$(cat "$TMP/large.err")"
fi

printf '{not json' > "$COMMENTS"
set +e
_ht_owned_row "$TMP/token" task-1 "$row" 1 agent-1 >"$TMP/bad.out" 2>"$TMP/bad.err"
status=$?
set -e
if [ "$status" -ne 0 ] && grep -q '^ERROR:' "$TMP/bad.err"; then
  ok owned-row-parse-error 'a malformed response fails with a loud error'
else
  bad owned-row-parse-error "status=$status error=$(cat "$TMP/bad.err")"
fi

printf '%s\n' '{"tasks":[{"id":"task-19","ticketNumber":"AGTE-19","section":"Inbox","title":"URL conversion","uniqueIndex":19}]}' > "$COMMENTS"
resolved="$(adapter_ticket_ref "$TMP/token" 'https://app.hypertask.ai/detail/project-5500/19')"
unchanged="$(adapter_ticket_ref "$TMP/token" 'AGTE-19')"
if [ "$resolved" = 'AGTE-19' ] && [ "$unchanged" = 'AGTE-19' ]; then
  ok ticket-url-to-ref 'ticket URLs reuse normalized adapter rows to produce PREFIX-NNN'
else
  bad ticket-url-to-ref "resolved=$resolved unchanged=$unchanged"
fi

printf 'token\n' > "$TMP/token"
_ht_run_post() { printf '404\n{}'; }
run_id="$(adapter_run_open "$TMP/token" task-1 "$TMP/run.log")"
adapter_run_activity "$TMP/token" "$run_id" "$TMP/run.log" action 'started TEST-1'
adapter_run_stop "$TMP/token" "$run_id" "$TMP/run.log" completed
if [ "$run_id" = local ] \
   && grep -qF 'opened local-only run for task task-1' "$TMP/run.log" \
   && grep -qF 'action started TEST-1' "$TMP/run.log" \
   && grep -qF 'closed run local with status completed' "$TMP/run.log"; then
  ok run-api-404-local-only 'a missing runs route keeps open, activity, and close in the local log'
else
  bad run-api-404-local-only "id=$run_id log=$(cat "$TMP/run.log")"
fi

cat > "$TMP/rewrite-model" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >> "$REWRITE_CALLS"
printf '%s' "$REWRITE_OUTPUT"
EOF
chmod +x "$TMP/rewrite-model"
REWRITE_CALLS="$TMP/rewrite-calls"
REWRITE_OUTPUT='<p><strong>Question: Should this change ship today?</strong></p>'
RUN_PAYLOAD="$TMP/response-payload"
export REWRITE_CALLS REWRITE_OUTPUT RUN_PAYLOAD
: > "$REWRITE_CALLS"
_ht_run_post() {
  printf '%s' "$3" > "$RUN_PAYLOAD"
  printf '201\n{}'
}
technical='<p>Question: Should runThing() in src/app.ts ship?</p>'
QUIET=on COMMENT_REWRITE_CLI="$TMP/rewrite-model" \
  adapter_run_activity "$TMP/token" run-1 "$TMP/response.log" response "$technical"
if [ "$(wc -l < "$REWRITE_CALLS")" -eq 1 ] \
   && PAYLOAD="$RUN_PAYLOAD" EXPECTED="$REWRITE_OUTPUT" python3 - <<'PYEOF'
import json, os
with open(os.environ["PAYLOAD"], encoding="utf-8") as handle:
    payload = json.load(handle)
assert payload == {"type": "response", "text": os.environ["EXPECTED"]}
assert "Question:" in payload["text"]
PYEOF
then
  ok response-uses-comment-gate 'a quiet response keeps its prefix and posts the shared gate rewrite'
else
  bad response-uses-comment-gate "calls=$(cat "$REWRITE_CALLS") payload=$(cat "$RUN_PAYLOAD")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
