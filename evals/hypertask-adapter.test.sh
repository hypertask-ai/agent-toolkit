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

PRS="$TMP/prs.json"
TASKS="$TMP/tasks.jsonl"
python3 - "$PRS" "$TASKS" <<'PYEOF'
import json, sys
prs = []
with open(sys.argv[2], "w", encoding="utf-8") as tasks:
    for number in range(1, 51):
        ref = "LOAD-%d" % number
        body = "x" * 8_200
        if number <= 48:
            body += " " + ref
        prs.append({"number": number, "state": "OPEN", "title": "Load test", "body": body,
                    "headRefName": "work-%d" % number})
        tasks.write(json.dumps({"id": "task-%d" % number, "ref": ref, "board": "1",
                                "assigned": True}) + "\n")
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(prs, handle)
PYEOF
set +e
output="$(_ht_tasks_with_pr "$PRS" "$TASKS" 2>"$TMP/prs.err")"
status=$?
set -e
refs="$(printf '%s\n' "$output" | python3 -c 'import json,sys; print(" ".join(json.loads(line)["ref"] for line in sys.stdin if line.strip()))')"
expected="$(python3 -c 'print(" ".join("LOAD-%d" % number for number in range(1, 49)))')"
if [ "$status" -eq 0 ] && [ "$(wc -c < "$PRS")" -ge 400000 ] && [ "$refs" = "$expected" ]; then
  ok eligibility-large-prs-json 'a 400 KB PR list is loaded once and matches 50 task rows'
else
  bad eligibility-large-prs-json "status=$status refs=$refs error=$(cat "$TMP/prs.err")"
fi

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
