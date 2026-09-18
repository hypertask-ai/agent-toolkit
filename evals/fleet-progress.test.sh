#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/evals/fixtures/fleet-progress"
PROGRESS="$ROOT/scripts/agent-progress"
CHECK_COMMENT="$ROOT/adapters/hypertask/plain-language/check-comment.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

STATE="$TMP/state/agent-board-poll"
CONF="$TMP/conf"
mkdir -p "$STATE" "$CONF" "$TMP/bin"
cp "$FIXTURES"/*.json "$STATE/"
for fixture in "$STATE"/*.json; do
  slug="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runner"])' "$fixture")"
  mv "$fixture" "$STATE/$slug.progress.json"
done

cat > "$TMP/bin/board" <<'EOF'
#!/usr/bin/env python3
import json, os, pathlib, sys
log = pathlib.Path(os.environ["BOARD_LOG"])
with log.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(sys.argv[1:]) + "\n")
args = sys.argv[1:]
if args[:2] == ["task", "create"]:
    print(json.dumps({"task": {"id": "bug-1", "ticketNumber": "AGTE-99"}}))
elif args[:2] == ["comment", "add"]:
    counter = pathlib.Path(os.environ["BOARD_COUNTER"])
    value = int(counter.read_text() or "0") + 1 if counter.exists() else 1
    counter.write_text(str(value), encoding="utf-8")
    print(json.dumps({"comment": {"id": f"comment-{value}", "text": args[-1]}}))
elif args[:2] == ["comment", "update"]:
    print(json.dumps({"comment": {"id": args[2], "text": args[-1]}}))
else:
    raise SystemExit(2)
EOF
cat > "$TMP/bin/notifier" <<'EOF'
#!/usr/bin/env bash
[ "$#" -eq 1 ] || exit 2
case "$1" in *$'\n'*) exit 3 ;; esac
printf '%s\n' "$1" >> "$NOTIFIER_LOG"
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env python3
import json, os, pathlib, sys
with pathlib.Path(os.environ["TELEGRAM_CURL_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(sys.argv[1:]) + "\n")
EOF
chmod +x "$TMP/bin/board" "$TMP/bin/notifier" "$TMP/bin/curl"
: > "$TMP/board.log"
: > "$TMP/notifier.log"

cat > "$CONF/product-bot.conf" <<EOF
AGENT_SLUG="product-bot"
AGENT_NAME="Product Bot"
AGENT_KIND="worker"
AGENT_ID="agent-product"
BOARD_ADAPTER="hypertask"
BOARD_ID="15,5500"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/bin/board"
MODEL_CLI="model"
MAINTAINER="on"
EOF
cat > "$CONF/dev-1.conf" <<EOF
AGENT_SLUG="dev-1"
AGENT_NAME="Dev 1"
AGENT_KIND="dev"
AGENT_ID="agent-dev-1"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/bin/board"
MODEL_CLI="model"
CLAIM_UNASSIGNED="yes"
EOF
printf 'token\n' > "$TMP/token"

supervise() {
  HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" AGENT_CONFIG_DIR="$CONF" \
    BOARD_LOG="$TMP/board.log" BOARD_COUNTER="$TMP/board-counter" \
    NOTIFIER_LOG="$TMP/notifier.log" FLEET_TELEGRAM_NOTIFIER="$TMP/bin/notifier" \
    "$PROGRESS" supervise --state-dir "$STATE" --board-cli "$TMP/bin/board" \
      --manager-cli "$ROOT/scripts/agent-template" --manager-slug product-bot \
      --toolkit-ticket AGTE-37 --now 2026-09-18T12:00:00Z
}

first="$(supervise)"
if FIRST="$first" STATE="$STATE" BOARD_LOG="$TMP/board.log" NOTIFIER_LOG="$TMP/notifier.log" CONF="$CONF" \
  python3 - <<'PYEOF'
import json, os
from pathlib import Path
state = json.load(open(Path(os.environ["STATE"]) / "fleet-stalls.json"))
entries = state["stalls"]
assert len(entries) == 4
assert {row["rule"] for row in entries.values()} == {
    "wait-over-two-hours", "eligible-without-completion", "repeated-failure", "unit-without-result"
}
wait = next(row for row in entries.values() if row["rule"] == "wait-over-two-hours")
assert wait["runner"] == "dev-1" and wait["manual_at"] == "2026-09-18T12:00:00Z"
assert wait["owner_notified_at"] == "2026-09-18T12:00:00Z"
assert wait["bug_ticket"] == "AGTE-99" and wait["bug_filed_at"] == "2026-09-18T12:00:00Z"
assert "PR 633" in wait["reason"] and "30 hours" in wait["reason"]
assert all(row.get("comment_id") and row.get("notified_at") for row in entries.values())
board = [json.loads(line) for line in open(os.environ["BOARD_LOG"])]
assert len([row for row in board if row[:2] == ["task", "create"]]) == 1
create = next(row for row in board if row[:2] == ["task", "create"])
assert create[create.index("--project") + 1] == "5500"
assert "PR #633" in create[create.index("--title") + 1]
assert len([row for row in board if row[:2] == ["comment", "add"]]) == 4
assert not [row for row in board if row[:2] == ["comment", "update"]]
notifications = Path(os.environ["NOTIFIER_LOG"]).read_text().splitlines()
assert len(notifications) == 5
assert sum(line.startswith("[fleet manual]") for line in notifications) == 1
assert all("\n" not in line for line in notifications)
assert 'CLAIM_UNASSIGNED="no"' in (Path(os.environ["CONF"]) / "dev-1.conf").read_text()
assert list(Path(os.environ["CONF"]).glob("dev-1.conf.bak-*"))
for path in Path(os.environ["STATE"]).glob("*.progress.json"):
    progress = json.load(open(path))
    assert progress["stall"]["stalled_since"]
    assert "\n" not in progress["stall"]["reason"]
assert "4 runner file(s), 4 active stall(s)" in os.environ["FIRST"]
PYEOF
then
  ok four-fixture-rules 'all rules detect, including dev-1 PR 633 after 30 hours'
else
  bad four-fixture-rules 'fixture detection or escalation state was wrong'
fi

if python3 - "$TMP/board.log" "$CHECK_COMMENT" <<'PYEOF'
import json, subprocess, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
for row in rows:
    if row[:2] != ["comment", "add"]:
        continue
    result = subprocess.run([sys.executable, sys.argv[2]], input=row[-1], text=True,
                            capture_output=True)
    assert result.returncode == 0, result.stdout
    assert row[-1].startswith("<p><strong>Decision:")
PYEOF
then
  ok decision-comment-shape 'every stall uses the phone-friendly Decision HTML shape'
else
  bad decision-comment-shape 'a generated Decision comment failed the outbound gate'
fi

before_board="$(wc -l < "$TMP/board.log")"
before_notify="$(wc -l < "$TMP/notifier.log")"
supervise >/dev/null
after_board="$(wc -l < "$TMP/board.log")"
after_notify="$(wc -l < "$TMP/notifier.log")"
if [ "$before_board" -eq "$after_board" ] && [ "$before_notify" -eq "$after_notify" ] \
   && [ "$(grep -c 'mode manual --runner dev-1' "$TMP/state/agent-board-poll/manager-actions.log")" -eq 1 ]; then
  ok dedupe-and-owner-once 'unchanged stalls add no comment, Telegram line, or manual escalation'
else
  bad dedupe-and-owner-once "board=$before_board/$after_board notify=$before_notify/$after_notify"
fi

python3 - "$STATE/dev-2.progress.json" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
row = json.load(open(path))
row["eligible_work"]["count"] = 3
temporary = path + ".new"
json.dump(row, open(temporary, "w"), indent=2)
os.replace(temporary, path)
PYEOF
supervise >/dev/null
adds="$(python3 -c 'import json,sys; print(sum(json.loads(line)[:2] == ["comment","add"] for line in open(sys.argv[1])))' "$TMP/board.log")"
updates="$(python3 -c 'import json,sys; print(sum(json.loads(line)[:2] == ["comment","update"] for line in open(sys.argv[1])))' "$TMP/board.log")"
if [ "$adds" -eq 4 ] && [ "$updates" -eq 1 ] && [ "$(wc -l < "$TMP/notifier.log")" -eq 5 ]; then
  ok edit-in-place 'a changed reason updates its stored comment without another notification'
else
  bad edit-in-place "adds=$adds updates=$updates notifications=$(wc -l < "$TMP/notifier.log")"
fi

CONTRACT="$TMP/contract"
mkdir -p "$CONTRACT"
"$PROGRESS" event --state-dir "$CONTRACT" --slug runner --event completed-run \
  --ticket HTPR-8 --ticket-url https://app.hypertask.ai/detail/project-15/8 --now 2026-09-18T09:00:00Z
"$PROGRESS" event --state-dir "$CONTRACT" --slug runner --event pr-opened --pr 9 \
  --pr-url https://github.com/example/repo/pull/9 --ticket HTPR-9 --now 2026-09-18T09:15:00Z
"$PROGRESS" event --state-dir "$CONTRACT" --slug runner --event merge --pr 7 \
  --pr-url https://github.com/example/repo/pull/7 --ticket HTPR-7 \
  --occurred-at 2026-09-18T09:30:00Z --now 2026-09-18T09:31:00Z
for at in 09:40 09:45 09:50; do
  "$PROGRESS" event --state-dir "$CONTRACT" --slug runner --event failure \
    --ticket HTPR-10 --ticket-url https://app.hypertask.ai/detail/project-15/10 \
    --detail 'provider returned 500' --now "2026-09-18T${at}:00Z"
done
"$PROGRESS" event --state-dir "$CONTRACT" --slug runner --event unit --kind instruction \
  --unit-id instruction-1 --unit advisor-runner-1 --status completed --produced-result yes \
  --now 2026-09-18T09:55:00Z
"$PROGRESS" tick --state-dir "$CONTRACT" --slug runner --eligible-count 1 \
  --eligible-ticket HTPR-10 --eligible-url https://app.hypertask.ai/detail/project-15/10 \
  --wait-state awaiting-merge --wait-since 2026-09-18T09:00:00Z --wait-ticket HTPR-9 \
  --wait-pr 9 --wait-pr-url https://github.com/example/repo/pull/9 --now 2026-09-18T10:00:00Z
"$PROGRESS" tick --state-dir "$CONTRACT" --slug runner --preserve-work-state \
  --now 2026-09-18T10:01:00Z
if python3 - "$CONTRACT/runner.progress.json" <<'PYEOF'
import json, sys
row = json.load(open(sys.argv[1]))
assert row["schema_version"] == 1 and row["runner"] == "runner"
assert row["last_completed_run"]["ticket"] == "HTPR-8"
assert row["last_pr_opened"]["number"] == 9
assert row["last_merge"]["number"] == 7
assert row["wait"]["state"] == "awaiting-merge" and row["wait"]["since"]
assert row["eligible_work"]["count"] == 1 and row["eligible_work"]["since"]
assert row["repeated_attempt"]["count"] == 3 and row["repeated_attempt"]["failure_signature"]
assert row["units"][0]["produced_result"] is True
PYEOF
then
  ok progress-json-contract 'tick snapshot carries run, PR, merge, wait, eligible, attempt, and unit fields'
else
  bad progress-json-contract 'the published snapshot omitted a required field'
fi

TELEGRAM_STATE="$TMP/telegram-state"
mkdir -p "$TELEGRAM_STATE"
cp "$FIXTURES/repeated-failure.json" "$TELEGRAM_STATE/dev-3.progress.json"
cat > "$TMP/telegram.env" <<'EOF'
TELEGRAM_HYPERTASK_BOT_TOKEN="fixture-token"
TELEGRAM_HYPERTASK_CHAT_ID="fixture-chat"
EOF
: > "$TMP/telegram-curl.log"
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" AGENT_CONFIG_DIR="$CONF" \
  BOARD_LOG="$TMP/board.log" BOARD_COUNTER="$TMP/board-counter" \
  TELEGRAM_CURL_LOG="$TMP/telegram-curl.log" FLEET_TELEGRAM_ENV="$TMP/telegram.env" \
  PATH="$TMP/bin:$PATH" "$PROGRESS" supervise --state-dir "$TELEGRAM_STATE" \
    --board-cli "$TMP/bin/board" --manager-cli "$ROOT/scripts/agent-template" \
    --manager-slug product-bot --toolkit-ticket AGTE-37 --now 2026-09-18T12:00:00Z >/dev/null
if python3 - "$TMP/telegram-curl.log" <<'PYEOF'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert len(rows) == 1
args = rows[0]
assert any("api.telegram.org/botfixture-token/sendMessage" in value for value in args)
message = args[args.index("--data-urlencode") + 1]
assert message.startswith("text=[fleet stall]") and "\n" not in message
PYEOF
then
  ok existing-telegram-notifier 'default path sends one line through the established Telegram transport'
else
  bad existing-telegram-notifier 'the established Telegram transport did not receive one line'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
