#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH="$ROOT/scripts/agent-fleet-watch"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
CONF="$TMP/conf"
BIN="$TMP/bin"
mkdir -p "$STATE/run-records" "$CONF" "$BIN"
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

cat > "$BIN/board" <<'PYEOF'
#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
log = pathlib.Path(os.environ["BOARD_LOG"])
with log.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(args) + "\n")
if args[:2] == ["task", "create"]:
    counter = pathlib.Path(os.environ["BOARD_COUNTER"])
    value = int(counter.read_text() or "0") + 1 if counter.exists() else 1
    counter.write_text(str(value), encoding="utf-8")
    print(json.dumps({"task": {"ticketNumber": f"AGTE-{900 + value}"}}))
elif args[:2] == ["comment", "add"]:
    print(json.dumps({"comment": {"id": "comment-1"}}))
elif args[:2] == ["task", "move"]:
    print(json.dumps({"task": {"ticketNumber": args[2], "section": args[-1]}}))
else:
    raise SystemExit(2)
PYEOF
cat > "$BIN/gh" <<'PYEOF'
#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with pathlib.Path(os.environ["GH_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(args) + "\n")
mode = os.environ.get("GH_MODE", "stale")
if "/rate_limit" in args:
    remaining = 0 if mode == "exhausted" else 20
    print(json.dumps({"resources": {"core": {"remaining": remaining}}}))
elif any("/pulls?" in arg for arg in args):
    if mode == "recent":
        print('[{"merged_at":"2026-09-20T11:30:00Z"}]')
    else:
        print("[]")
else:
    raise SystemExit(2)
PYEOF
cat > "$BIN/systemctl" <<'PYEOF'
#!/usr/bin/env python3
import json, os, pathlib, sys
with pathlib.Path(os.environ["SYSTEMCTL_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(sys.argv[1:]) + "\n")
PYEOF
chmod +x "$BIN/board" "$BIN/gh" "$BIN/systemctl"
printf 'fixture-token\n' > "$TMP/token"
: > "$TMP/board.log"
: > "$TMP/gh.log"
: > "$TMP/systemctl.log"

cat > "$CONF/product-bot.conf" <<EOF
AGENT_SLUG="product-bot"
AGENT_KIND="answer"
AGENT_ID="product-agent"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$BIN/board"
WATCH_SECTIONS="*"
CLAIM_UNASSIGNED="no"
PR_REPO="example/work"
EOF
for slug in dev-1 dev-2; do
  cat > "$CONF/$slug.conf" <<EOF
AGENT_SLUG="$slug"
AGENT_KIND="dev"
AGENT_ID="agent-$slug"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$BIN/board"
WATCH_SECTIONS="Bugs,In Progress"
CLAIM_UNASSIGNED="yes"
PR_REPO="example/work"
EOF
done
cat > "$CONF/dev-3.conf" <<EOF
AGENT_SLUG="dev-3"
AGENT_KIND="dev"
AGENT_ID="agent-dev-3"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$BIN/board"
WATCH_SECTIONS="Bugs,In Progress"
CLAIM_UNASSIGNED="no"
PR_REPO="example/work"
EOF
cat > "$TMP/tasks.jsonl" <<'EOF'
{"id":101,"ref":"TEST-101","board":"15","section":"Bugs","title":"Waiting work","assignee_count":0,"agent_ids":[]}
EOF
cat > "$TMP/assigned-tasks.jsonl" <<'EOF'
{"id":102,"ref":"TEST-102","board":"15","section":"Bugs","title":"Assigned work","assignee_count":1,"agent_ids":["another-agent"]}
EOF
: > "$TMP/empty-tasks.jsonl"
for slug in dev-1 dev-2 dev-3; do
  cat > "$STATE/$slug.progress.json" <<EOF
{"schema_version":1,"runner":"$slug","last_completed_run":{"ticket":"TEST-1","at":"2026-09-20T08:00:00Z"}}
EOF
done
cat > "$STATE/dev-1.log" <<'EOF'
2026-09-20T09:00:00+00:00 run FAILED tick exit=2
2026-09-20T10:00:00+00:00 run FAILED tick exit=2
2026-09-20T11:00:00+00:00 run FAILED tick exit=2
EOF
: > "$STATE/dev-2.log"
: > "$STATE/dev-3.log"
cat > "$STATE/run-records/dev-2-TEST-2.json" <<'EOF'
{"status":"running","run_kind":"ticket","started_at":"2026-09-20T10:50:00Z"}
EOF
touch -d '2026-09-20 11:50:00 UTC' "$STATE/run-records/dev-2-TEST-2.json"
cat > "$STATE/dev-1.blocked" <<'EOF'
{"pr":77,"ticket":"TEST-77","state":"red","since":"2026-09-20T10:00:00Z"}
EOF
cat > "$STATE/dev-2.blocked" <<'EOF'
{"pr":77,"ticket":"TEST-77","state":"red","since":"2026-09-20T10:00:00Z"}
EOF
cat > "$STATE/fleet-watch-state.json" <<'EOF'
{"schema_version":1,"rules":{},"manual_since":{"dev-3":"2026-09-20T09:00:00Z"}}
EOF

watch() {
  local tasks="$1" mode="$2" disk="$3"
  HOME="$TMP/home" PATH="$BIN:$PATH" BOARD_LOG="$TMP/board.log" \
    BOARD_COUNTER="$TMP/board-counter" GH_LOG="$TMP/gh.log" GH_MODE="$mode" \
    SYSTEMCTL_LOG="$TMP/systemctl.log" FLEET_WATCH_TASKS_FILE="$tasks" \
    "$WATCH" --config-dir "$CONF" --state-dir "$STATE" \
      --now 2026-09-20T12:00:00Z --disk-pct "$disk"
}

watch "$TMP/tasks.jsonl" stale 86 >/dev/null
for rule in R1 R2 R3 R4 R5 R7; do
  if RULE="$rule" STATE="$STATE" python3 - <<'PYEOF'
import json, os
health = json.load(open(os.path.join(os.environ["STATE"], "fleet-health.json")))
row = next(item for item in health["breaches"] if item["rule"] == os.environ["RULE"])
assert row["detail"] and row["since"]
state = json.load(open(os.path.join(os.environ["STATE"], "fleet-watch-state.json")))
assert state["rules"][os.environ["RULE"]]["ticket"].startswith("AGTE-")
PYEOF
  then
    ok "fleet-watch-$rule" "$rule raises one Review alarm with durable state"
  else
    bad "fleet-watch-$rule" "$rule did not produce its breach and alarm state"
  fi
done

if STATE="$STATE" BOARD="$TMP/board.log" GHLOG="$TMP/gh.log" \
   SYSLOG="$TMP/systemctl.log" python3 - <<'PYEOF'
import json, os
health = json.load(open(os.path.join(os.environ["STATE"], "fleet-health.json")))
assert health["ok"] is False
assert health["metrics"]["merges_3h"] == {"15": 0}
assert health["metrics"]["live_runs"]["dev-1"] == 0
assert health["metrics"]["live_runs"]["dev-2"] == 1
assert health["metrics"]["failed_ticks"]["dev-1"] == 3
assert health["metrics"]["disk_pct"] == 86
assert health["metrics"]["github_remaining"] == 20
assert [(row["agent"], row["action"], row["status"]) for row in health["actions"]] == [
    ("dev-1", "start", "started")]
state = json.load(open(os.path.join(os.environ["STATE"], "fleet-watch-state.json")))
assert state["rules"]["R2"]["actions"] == health["actions"]
board = [json.loads(line) for line in open(os.environ["BOARD"])]
creates = [row for row in board if row[:2] == ["task", "create"]]
comments = [row for row in board if row[:2] == ["comment", "add"]]
assert len(creates) == len(comments) == 6
for create in creates:
    assert create[create.index("--project") + 1] == "5500"
    assert create[create.index("--section") + 1] == "Review"
    assert create[create.index("--priority") + 1] == "high"
    assert create[create.index("--labels") + 1] == "manager-only"
    body = create[create.index("--description") + 1]
    assert "Fleet watch manager report" in body
    assert "Action:" not in body
    assert "Merge the next" not in body
    assert "assign its eligible ticket" not in body
    assert "release the other agents" not in body
r2 = next(row for row in creates if row[row.index("--title") + 1].startswith("R2:"))
r2_body = r2[r2.index("--description") + 1]
assert "started an immediate poll for agent dev-1" in r2_body
assert "agent dev-2" not in r2_body
for comment in comments:
    body = comment[comment.index("--text") + 1]
    assert body.startswith("<p><strong>R")
    assert "Fleet watch manager report" in body and "</strong></p><p>Observed: " in body
    assert "<p>Acceptance: The manager reviewed this report.</p>" in body
calls = [json.loads(line) for line in open(os.environ["GHLOG"])]
assert len(calls) == 2
starts = [json.loads(line) for line in open(os.environ["SYSLOG"])]
assert starts == [
    ["--user", "--no-block", "start", "agent-board-poll@dev-1.service"],
]
log = open(os.path.join(os.environ["STATE"], "fleet-watch.log")).read().splitlines()
assert "actions=dev-1:start-started" in log[-1]
PYEOF
then
  ok fleet-watch-contract 'health metrics, alarm shape, and two-call GitHub budget are enforced'
else
  bad fleet-watch-contract 'the first fleet snapshot or alarm contract was wrong'
fi

before="$(wc -l < "$TMP/board.log")"
watch "$TMP/tasks.jsonl" stale 86 >/dev/null
after="$(wc -l < "$TMP/board.log")"
if [ "$before" -eq "$after" ]; then
  ok fleet-watch-dedupe 'all six active rules add no second alarm inside six hours'
else
  bad fleet-watch-dedupe "active rules wrote again: $before/$after board calls"
fi

: > "$TMP/systemctl.log"
touch -d '2026-09-20 11:30:00 UTC' "$STATE/run-records/dev-2-TEST-2.json"
watch "$TMP/tasks.jsonl" stale 86 >/dev/null
if STATE="$STATE" SYSLOG="$TMP/systemctl.log" python3 - <<'PYEOF'
import json, os
health = json.load(open(os.path.join(os.environ["STATE"], "fleet-health.json")))
assert health["metrics"]["live_runs"]["dev-2"] == 0
assert [row["agent"] for row in health["actions"]] == ["dev-1", "dev-2"]
starts = [json.loads(line)[-1] for line in open(os.environ["SYSLOG"])]
assert starts == ["agent-board-poll@dev-1.service", "agent-board-poll@dev-2.service"]
PYEOF
then
  ok fleet-watch-stale-live-run 'a running record older than its stall limit remains eligible for R2'
else
  bad fleet-watch-stale-live-run 'a stale running record incorrectly counted as active'
fi

printf '%s\n' '2026-09-20T11:30:00+00:00 tick finished: 0 eligible, 0 started' >> "$STATE/dev-1.log"
rm -f "$STATE/dev-1.blocked" "$STATE/dev-2.blocked"
: > "$TMP/systemctl.log"
watch "$TMP/empty-tasks.jsonl" recent 20 >/dev/null
moves="$(python3 -c 'import json,sys; print(sum(json.loads(line)[:2] == ["task","move"] for line in open(sys.argv[1])))' "$TMP/board.log")"
if [ "$moves" -eq 6 ]; then
  ok fleet-watch-clear 'recovered rules move all six active alarms to Done'
else
  bad fleet-watch-clear "expected 6 Done moves, got $moves"
fi
if [ ! -s "$TMP/systemctl.log" ]; then
  ok fleet-watch-no-eligible-work 'R2 starts no poll when eligible work is absent'
else
  bad fleet-watch-no-eligible-work "R2 started a poll without eligible work: $(cat "$TMP/systemctl.log")"
fi

: > "$TMP/gh.log"
watch "$TMP/empty-tasks.jsonl" exhausted 20 >/dev/null
rate_board="$(wc -l < "$TMP/board.log")"
rate_calls="$(wc -l < "$TMP/gh.log")"
if STATE="$STATE" python3 - <<'PYEOF'
import json, os
health = json.load(open(os.path.join(os.environ["STATE"], "fleet-health.json")))
assert [row["rule"] for row in health["breaches"]] == ["R6"]
assert health["metrics"]["github_remaining"] == 0
assert health["metrics"]["merges_3h"] == {"15": None}
assert "GitHub rules skipped: rate limit exhausted" in open(os.path.join(os.environ["STATE"], "fleet-watch.log")).read().splitlines()[-1]
PYEOF
then
  ok fleet-watch-rate-limit 'remaining zero raises R6 and skips every repository merge call'
else
  bad fleet-watch-rate-limit 'rate exhaustion did not skip GitHub-dependent rules cleanly'
fi
if [ "$rate_calls" -ne 1 ]; then
  bad fleet-watch-rate-budget "rate exhaustion made $rate_calls GitHub calls"
else
  ok fleet-watch-rate-budget 'an exhausted limit stops after the one rate-limit call'
fi

watch "$TMP/empty-tasks.jsonl" exhausted 20 >/dev/null
if [ "$(wc -l < "$TMP/board.log")" -eq "$rate_board" ]; then
  ok fleet-watch-r6-dedupe 'R6 adds no second alarm inside six hours'
else
  bad fleet-watch-r6-dedupe 'R6 wrote a duplicate alarm'
fi

watch "$TMP/empty-tasks.jsonl" recent 20 >/dev/null
if STATE="$STATE" python3 - <<'PYEOF'
import json, os
health = json.load(open(os.path.join(os.environ["STATE"], "fleet-health.json")))
assert health["ok"] is True and health["breaches"] == []
assert health["metrics"]["merges_3h"] == {"15": 1}
lines = open(os.path.join(os.environ["STATE"], "fleet-watch.log")).read().splitlines()
assert len(lines) == 7
assert lines[-1].endswith("ok=true breaches=none")
PYEOF
then
  ok fleet-watch-healthy 'a healthy pass writes ok=true and exactly one log line'
else
  bad fleet-watch-healthy 'the healthy snapshot or one-line log contract was wrong'
fi

sed -i 's/^CLAIM_UNASSIGNED="yes"$/CLAIM_UNASSIGNED="no"/' "$CONF/dev-1.conf" "$CONF/dev-2.conf"
touch -d '2026-09-20T11:00:00Z' "$CONF/dev-1.conf" "$CONF/dev-2.conf" "$CONF/dev-3.conf"
STATE="$STATE" python3 - <<'PYEOF'
import json, os
path = os.path.join(os.environ["STATE"], "fleet-watch-state.json")
state = json.load(open(path))
state["freeze_since"] = "2026-09-20T11:29:00Z"
json.dump(state, open(path, "w"))
PYEOF
watch "$TMP/assigned-tasks.jsonl" recent 20 >/dev/null
if STATE="$STATE" python3 - <<'PYEOF'
import json, os
state_dir = os.environ["STATE"]
health = json.load(open(os.path.join(state_dir, "fleet-health.json")))
state = json.load(open(os.path.join(state_dir, "fleet-watch-state.json")))
assert not any(row["rule"] == "R8" for row in health["breaches"])
assert "freeze_since" not in state
PYEOF
then
  ok fleet-watch-nonempty-intake 'assigned intake work prevents the empty-intake freeze alarm'
else
  bad fleet-watch-nonempty-intake 'assigned intake work was incorrectly treated as empty intake'
fi
STATE="$STATE" python3 - <<'PYEOF'
import json, os
path = os.path.join(os.environ["STATE"], "fleet-watch-state.json")
state = json.load(open(path))
state["freeze_since"] = "2026-09-20T11:29:00Z"
json.dump(state, open(path, "w"))
PYEOF
freeze_board_before="$(wc -l < "$TMP/board.log")"
watch "$TMP/empty-tasks.jsonl" recent 20 >/dev/null
if STATE="$STATE" BOARD="$TMP/board.log" BEFORE="$freeze_board_before" python3 - <<'PYEOF'
import json, os
health = json.load(open(os.path.join(os.environ["STATE"], "fleet-health.json")))
assert [row["rule"] for row in health["breaches"]] == ["R8"]
row = health["breaches"][0]
assert row["since"] == "2026-09-20T11:29:00Z"
assert "longer than 30 minutes" in row["detail"] and "empty intake" in row["detail"]
state = json.load(open(os.path.join(os.environ["STATE"], "fleet-watch-state.json")))
assert state["rules"]["R8"]["ticket"].startswith("AGTE-")
board = [json.loads(line) for line in open(os.environ["BOARD"])]
new = board[int(os.environ["BEFORE"]):]
creates = [call for call in new if call[:2] == ["task", "create"]]
comments = [call for call in new if call[:2] == ["comment", "add"]]
assert len(creates) == len(comments) == 1
assert creates[0][creates[0].index("--title") + 1] == "R8: Fleet watch alarm"
PYEOF
then
  ok fleet-watch-empty-intake-freeze 'a fleet-wide 31-minute manual freeze raises R8 with no intake waiting'
else
  bad fleet-watch-empty-intake-freeze 'the empty-intake fleet freeze did not raise exactly one alarm'
fi

sed -i 's/^CLAIM_UNASSIGNED="no"$/CLAIM_UNASSIGNED="yes"/' "$CONF/dev-1.conf"
watch "$TMP/empty-tasks.jsonl" recent 20 >/dev/null
if STATE="$STATE" python3 - <<'PYEOF'
import json, os
state = json.load(open(os.path.join(os.environ["STATE"], "fleet-watch-state.json")))
assert "freeze_since" not in state
assert state["rules"]["R8"]["active"] is False
PYEOF
then
  ok fleet-watch-freeze-clears 'leaving fleet-wide manual mode clears R8 and its timer'
else
  bad fleet-watch-freeze-clears 'R8 stayed active after one runner returned to auto mode'
fi

SKIP_CONF="$TMP/skip-conf"
SKIP_STATE="$TMP/skip-state"
mkdir -p "$SKIP_CONF" "$SKIP_STATE/run-records"
cat > "$SKIP_CONF/product-bot.conf" <<EOF
AGENT_SLUG="product-bot"
AGENT_KIND="answer"
AGENT_ID="product-agent"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$BIN/board"
WATCH_SECTIONS="*"
CLAIM_UNASSIGNED="no"
PR_REPO="example/work"
EOF
cat > "$SKIP_CONF/readable-dev.conf" <<EOF
AGENT_SLUG="readable-dev"
AGENT_KIND="dev"
AGENT_ID="agent-readable"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$BIN/board"
WATCH_SECTIONS="Bugs"
CLAIM_UNASSIGNED="yes"
PR_REPO="example/work"
EOF
cat > "$SKIP_CONF/support-bot.conf" <<EOF
AGENT_SLUG="support-bot"
AGENT_KIND="answer"
AGENT_ID="support-agent"
BOARD_ADAPTER="hypertask"
BOARD_ID="2101"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$BIN/board"
WATCH_SECTIONS="*"
CLAIM_UNASSIGNED="no"
PR_REPO="example/support"
EOF
cat > "$SKIP_STATE/readable-dev.progress.json" <<'EOF'
{"schema_version":1,"runner":"readable-dev","last_completed_run":{"ticket":"TEST-201","at":"2026-09-20T11:30:00Z"}}
EOF
: > "$SKIP_STATE/readable-dev.log"
cat > "$BIN/curl" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys
url = sys.argv[-1]
forbidden = os.environ.get("CURL_MODE") == "forbidden" or "project_id=2101" in url
if forbidden:
    print(json.dumps({"error": "forbidden"}))
    print("403")
else:
    print(json.dumps({"tasks": [{"id": 201, "ticketNumber": "TEST-201", "projectId": 15,
                                  "section": "Bugs", "title": "Readable work",
                                  "assignees": [{"agent": {"id": "agent-readable"}}]}]}))
    print("200")
PYEOF
cat > "$BIN/hypertask" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN/curl" "$BIN/hypertask"
set +e
HOME="$TMP/home" PATH="$BIN:$PATH" BOARD_LOG="$TMP/board.log" \
  BOARD_COUNTER="$TMP/board-counter" GH_LOG="$TMP/gh.log" GH_MODE=recent \
  FLEET_WATCH_INTAKE_JSON='{"15":["Bugs"],"2101":["Support"]}' \
  "$WATCH" --config-dir "$SKIP_CONF" --state-dir "$SKIP_STATE" \
    --now 2026-09-20T12:00:00Z --disk-pct 20 > "$TMP/skip.out" 2>&1
skip_status=$?
set -e
if [ "$skip_status" -eq 0 ] && STATE="$SKIP_STATE" python3 - <<'PYEOF'
import json, os
state = os.environ["STATE"]
health = json.load(open(os.path.join(state, "fleet-health.json")))
assert health["ok"] is True and health["breaches"] == []
assert health["metrics"]["merges_3h"] == {"15": 1}
assert len(health["skipped_boards"]) == 1
assert health["skipped_boards"][0]["board"] == "2101"
assert "HTTP 403" in health["skipped_boards"][0]["reason"]
lines = open(os.path.join(state, "fleet-watch.log")).read().splitlines()
assert len(lines) == 1 and "skipped board 2101:" in lines[0] and "HTTP 403" in lines[0]
PYEOF
then
  ok fleet-watch-skip-board 'one forbidden board is recorded while readable boards are evaluated successfully'
else
  bad fleet-watch-skip-board "partial board failure did not preserve the healthy board: $(cat "$TMP/skip.out")"
fi

ALL_SKIPPED_STATE="$TMP/all-skipped-state"
mkdir -p "$ALL_SKIPPED_STATE/run-records"
set +e
HOME="$TMP/home" PATH="$BIN:$PATH" BOARD_LOG="$TMP/board.log" \
  BOARD_COUNTER="$TMP/board-counter" GH_LOG="$TMP/gh.log" GH_MODE=recent CURL_MODE=forbidden \
  FLEET_WATCH_INTAKE_JSON='{"15":["Bugs"],"2101":["Support"]}' \
  "$WATCH" --config-dir "$SKIP_CONF" --state-dir "$ALL_SKIPPED_STATE" \
    --now 2026-09-20T12:00:00Z --disk-pct 20 > "$TMP/all-skipped.out" 2>&1
all_skipped_status=$?
set -e
if [ "$all_skipped_status" -ne 0 ] && STATE="$ALL_SKIPPED_STATE" python3 - <<'PYEOF'
import json, os
health = json.load(open(os.path.join(os.environ["STATE"], "fleet-health.json")))
assert health["ok"] is False
assert health["metrics"]["merges_3h"] == {}
assert [row["board"] for row in health["skipped_boards"]] == ["15", "2101"]
PYEOF
then
  ok fleet-watch-no-readable-boards 'the watch fails only when every configured board is unreadable'
else
  bad fleet-watch-no-readable-boards 'the watch did not fail after every board read failed'
fi

if grep -qF 'OnBootSec=5min' "$ROOT/install.sh" \
   && grep -qF 'OnUnitActiveSec=15min' "$ROOT/install.sh" \
   && grep -qF 'ExecStart=$BIN/agent-fleet-watch' "$ROOT/install.sh" \
   && grep -qF 'enable --now agent-fleet-watch.timer' "$ROOT/install.sh" \
   && ! grep -Eq 'Telegram|toast|hax|codex|MODEL_CLI' "$WATCH"; then
  ok fleet-watch-install 'install links the watcher and enables its model-free 15-minute timer'
else
  bad fleet-watch-install 'the install timer or no-notifier/no-model contract is missing'
fi

printf '\n%d fleet-watch check(s), %d failed\n' "$((pass + fail))" "$fail"
[ "$fail" -eq 0 ]
