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

CORE_ROOT="$ROOT"
# shellcheck disable=SC1090
. "$ROOT/scripts/lib/core.sh"
core_load_adapter hypertask

maintainer_prompt="$(MAINTAINER=on adapter_run_prompt "/company/INDEX.md" "Product Bot" "/bin/board" \
  "AGTE-68" "https://app.hypertask.ai/detail/project-5500/68" "Merge PR 7" \
  "Merge the green allowlisted pull request." "" "assigned instruction")"
regular_prompt="$(MAINTAINER=off adapter_run_prompt "/company/INDEX.md" "Developer" "/bin/board" \
  "TEST-1" "https://app.hypertask.ai/detail/project-1/1" "Fix the bug" \
  "Change the implementation." "" "new work")"
if printf '%s' "$maintainer_prompt" | grep -qF 'FINISH IT AS THE SETUP MAINTAINER' \
   && printf '%s' "$maintainer_prompt" | grep -qF 'Never merge a pull request by hand' \
   && printf '%s' "$maintainer_prompt" | grep -qF 'labelled `valentin-review`' \
   && ! printf '%s' "$maintainer_prompt" | grep -qF 'agent-template merge <pr-url>' \
   && printf '%s' "$maintainer_prompt" | grep -qF 'Do not create an implementation branch for a direct operation, delegate it, hand it to a developer' \
   && ! printf '%s' "$maintainer_prompt" | grep -qF 'branch off the production branch' \
   && printf '%s' "$regular_prompt" | grep -qF 'branch off the production branch' \
   && printf '%s' "$regular_prompt" | grep -qF 'The runner already won the claim' \
   && ! printf '%s' "$regular_prompt" | grep -qF 'claim-ticket.sh'; then
  ok maintainer-direct-action-prompt 'merge instructions execute in the maintainer run instead of entering developer PR workflow'
else
  bad maintainer-direct-action-prompt "maintainer=$maintainer_prompt regular=$regular_prompt"
fi

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

PROJECT_CALLS="$TMP/project-calls"
HYPERTASK_PROJECT_PREFIX_CACHE="$TMP/project-prefixes.tsv"
BOARD_CLI="$TMP/board"
export PROJECT_CALLS HYPERTASK_PROJECT_PREFIX_CACHE BOARD_CLI
cat > "$BOARD_CLI" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PROJECT_CALLS"
case "$*" in
  '--json project show 5500')
    printf '%s\n' '{"project":{"id":5500,"ticketPrefix":"AGTE","taskCount":250}}' ;;
  '--json project show 999') exit 1 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$BOARD_CLI"
resolved="$(adapter_ticket_ref "$TMP/token" 'https://app.hypertask.ai/detail/project-5500/150')"
cached="$(adapter_ticket_ref "$TMP/token" 'https://app.hypertask.ai/detail/project-5500/151')"
unchanged="$(adapter_ticket_ref "$TMP/token" 'AGTE-19')"
if [ "$resolved" = 'AGTE-150' ] && [ "$cached" = 'AGTE-151' ] \
   && [ "$unchanged" = 'AGTE-19' ] && [ "$(wc -l < "$PROJECT_CALLS")" -eq 1 ]; then
  ok ticket-url-to-ref 'a board over 100 tickets resolves from one cached project-prefix lookup'
else
  bad ticket-url-to-ref "resolved=$resolved cached=$cached unchanged=$unchanged calls=$(cat "$PROJECT_CALLS")"
fi

set +e
adapter_ticket_ref "$TMP/token" 'https://app.hypertask.ai/detail/project-999/7' \
  >"$TMP/unknown.out" 2>"$TMP/unknown.err"
status=$?
set -e
if [ "$status" -ne 0 ] && [ ! -s "$TMP/unknown.out" ] \
   && grep -qF 'project 999 was not found' "$TMP/unknown.err"; then
  ok ticket-url-unknown-project 'an unknown project fails with a clear project-specific error'
else
  bad ticket-url-unknown-project "status=$status output=$(cat "$TMP/unknown.out") error=$(cat "$TMP/unknown.err")"
fi

printf 'token\n' > "$TMP/token"
RUN_OPEN_PAYLOAD="$TMP/run-open-payload"
_ht_run_post() { printf '%s' "$3" > "$RUN_OPEN_PAYLOAD"; printf '404\n{}'; }
run_id="$(AGENT_RUN_AGENT=dev-1 AGENT_RUN_PROVIDER=codex AGENT_RUN_MODEL=gpt-test \
  AGENT_RUN_STARTED_AT=2026-01-01T00:00:00Z AGENT_RUN_LOG_LINK=file:///tmp/run.log \
  adapter_run_open "$TMP/token" task-1 "$TMP/run.log" on)"
AGENT_RUN_AGENT=dev-1 AGENT_RUN_PROVIDER=codex AGENT_RUN_MODEL=gpt-test AGENT_RUN_STARTED_AT=2026-01-01T00:00:00Z \
AGENT_RUN_STARTED_EPOCH="$(date +%s)" AGENT_RUN_OUTCOME=running \
AGENT_RUN_LOG_LINK=file:///tmp/run.log \
  adapter_run_activity "$TMP/token" "$run_id" "$TMP/run.log" action 'started TEST-1'
adapter_run_stop "$TMP/token" "$run_id" "$TMP/run.log" completed
if [ "$run_id" = local ] \
   && grep -qF 'opened local-only run for task task-1 graft=on' "$TMP/run.log" \
   && grep -q 'action started TEST-1 agent=dev-1 provider=codex model=gpt-test started=2026-01-01T00:00:00Z duration=[0-9]\+s outcome=running log=file:///tmp/run.log' "$TMP/run.log" \
   && grep -qF 'closed run local with status completed' "$TMP/run.log" \
   && RUN_OPEN_PAYLOAD="$RUN_OPEN_PAYLOAD" python3 -c 'import json,os; assert json.load(open(os.environ["RUN_OPEN_PAYLOAD"])) == {"taskId":"task-1","source":"runtime","graft":"on","agent":"dev-1","provider":"codex","model":"gpt-test","startedAt":"2026-01-01T00:00:00Z","logUrl":"file:///tmp/run.log"}'; then
  ok run-api-404-local-only 'a missing runs route keeps graft, open, activity, and close in the local record'
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
AGENT_RUN_AGENT=dev-1 AGENT_RUN_PROVIDER=cursor AGENT_RUN_MODEL=gpt-test AGENT_RUN_STARTED_AT=2026-01-01T00:00:00Z \
AGENT_RUN_STARTED_EPOCH="$(date +%s)" AGENT_RUN_OUTCOME=running \
AGENT_RUN_LOG_LINK=https://app.hypertask.ai/agents/runs/run-1 \
QUIET=on COMMENT_REWRITE_CLI="$TMP/rewrite-model" \
  adapter_run_activity "$TMP/token" run-1 "$TMP/response.log" response "$technical"
if [ ! -s "$REWRITE_CALLS" ] \
   && grep -qF "$technical" "$TMP/response.log" \
   && grep -qF 'comment contains a file path' "$TMP/response.log" \
   && PAYLOAD="$RUN_PAYLOAD" python3 - <<'PYEOF'
import json, os
with open(os.environ["PAYLOAD"], encoding="utf-8") as handle:
    payload = json.load(handle)
assert payload["type"] == "action"
assert payload["text"] == "Question held: did not pass the plain-language shape check"
assert payload["agent"] == "dev-1" and payload["provider"] == "cursor" and payload["model"] == "gpt-test"
assert payload["startedAt"] == "2026-01-01T00:00:00Z"
assert payload["durationSeconds"] >= 0 and payload["outcome"] == "running"
assert payload["logUrl"] == "https://app.hypertask.ai/agents/runs/run-1"
PYEOF
then
  ok response-uses-comment-gate 'an invalid quiet response is held unchanged without a rewrite call'
else
  bad response-uses-comment-gate "calls=$(cat "$REWRITE_CALLS") payload=$(cat "$RUN_PAYLOAD") log=$(cat "$TMP/response.log")"
fi

CLAIM_SLEEP="$TMP/claim-sleep"
CLAIM_READS="$TMP/claim-reads"
: > "$CLAIM_SLEEP"
printf '0\n' > "$CLAIM_READS"
set +e
claim_result="$(
  unset ADAPTER_CLAIM_TEST_JITTER_SECONDS ADAPTER_CLAIM_TEST_SETTLE_SECONDS
  sleep() { printf '%s\n' "$1" >> "$CLAIM_SLEEP"; }
  adapter_assign_task() { return 0; }
  _ht_get() {
    local count
    count="$(cat "$CLAIM_READS")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$CLAIM_READS"
    if [ "$count" -eq 1 ]; then
      printf '%s\n' '{"tasks":[{"ticketNumber":"TEST-1","projectId":15,"assignees":[]}]}'
    else
      printf '%s\n' '{"tasks":[{"ticketNumber":"TEST-1","projectId":15,"assignees":[{"agent":{"id":"agent-a","displayName":"Agent A"}}]}]}'
    fi
  }
  adapter_claim "$TMP/token" unused 15 TEST-1 agent-a
)"
claim_status=$?
set -e
first_sleep="$(sed -n '1p' "$CLAIM_SLEEP")"
second_sleep="$(sed -n '2p' "$CLAIM_SLEEP")"
if [ "$claim_status" -eq 0 ] && [ "$claim_result" = held ] \
   && [[ "$first_sleep" =~ ^[1-5]$ ]] && [ "$second_sleep" = 2 ]; then
  ok claim-jitter-and-settle 'an uncontended claim waits 1-5 seconds before its read and 2 seconds after assignment'
else
  bad claim-jitter-and-settle "status=$claim_status result=$claim_result sleeps=$(paste -sd, "$CLAIM_SLEEP")"
fi

CLAIM_ASSIGNED="$TMP/claim-assigned"
set +e
claim_result="$(
  sleep() { :; }
  adapter_assign_task() { touch "$CLAIM_ASSIGNED"; }
  _ht_get() {
    printf '%s\n' '{"tasks":[{"ticketNumber":"TEST-1","projectId":15,"assignees":[{"agent":{"id":"agent-b","displayName":"Agent B"}}]}]}'
  }
  ADAPTER_CLAIM_TEST_JITTER_SECONDS=0 ADAPTER_CLAIM_TEST_SETTLE_SECONDS=0 \
    adapter_claim "$TMP/token" unused 15 TEST-1 agent-a
)"
claim_status=$?
set -e
if [ "$claim_status" -eq 0 ] && [ "$claim_result" = $'backoff\talready claimed by Agent B' ] \
   && [ ! -e "$CLAIM_ASSIGNED" ]; then
  ok claim-reread-before-assign 'a foreign agent arriving after the first guard makes the claim back off before assignment'
else
  bad claim-reread-before-assign "status=$claim_status result=$claim_result assigned=$([ -e "$CLAIM_ASSIGNED" ] && echo yes || echo no)"
fi

STOP_PAYLOAD="$TMP/stop-payload"
RUN_PAYLOAD="$STOP_PAYLOAD"
AGENT_RUN_AGENT=dev-1 AGENT_RUN_PROVIDER=cursor AGENT_RUN_MODEL=gpt-test AGENT_RUN_STARTED_AT=2026-01-01T00:00:00Z \
AGENT_RUN_STARTED_EPOCH="$(date +%s)" AGENT_RUN_OUTCOME=failed \
AGENT_RUN_LOG_LINK=https://app.hypertask.ai/agents/runs/run-1 \
  adapter_run_stop "$TMP/token" run-1 "$TMP/stop.log" failed
if STOP_PAYLOAD="$STOP_PAYLOAD" python3 - <<'PYEOF'
import json, os
payload = json.load(open(os.environ["STOP_PAYLOAD"]))
assert payload["status"] == payload["outcome"] == "failed"
assert payload["agent"] == "dev-1" and payload["provider"] == "cursor" and payload["model"] == "gpt-test"
assert payload["startedAt"] == "2026-01-01T00:00:00Z"
assert payload["durationSeconds"] >= 0
assert payload["logUrl"].endswith("/run-1")
PYEOF
then
  ok run-stop-context 'run close carries agent, model, timing, outcome, and log link'
else
  bad run-stop-context "payload=$(cat "$STOP_PAYLOAD")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
