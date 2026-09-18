#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CONTRACT="$ROOT/scripts/agent-reply-contract"

"$CONTRACT" received --state-dir "$TMP" --slug dev-1 --event-id 15:71 \
  --at 2026-09-18T10:00:00Z --board 15 --ticket TEST-7 \
  --url https://app.hypertask.ai/detail/project-15/7 --kind mention
"$CONTRACT" acknowledged --state-dir "$TMP" --slug dev-1 --event-id 15:71 \
  --at 2026-09-18T10:00:30Z --estimate-minutes 30
"$CONTRACT" answered --state-dir "$TMP" --slug dev-1 --event-id 15:71 \
  --at 2026-09-18T10:12:00Z
# Replayed poll events are idempotent.
"$CONTRACT" received --state-dir "$TMP" --slug dev-1 --event-id 15:71 \
  --at 2026-09-18T10:00:00Z --board 15 --ticket TEST-7 \
  --url https://app.hypertask.ai/detail/project-15/7 --kind mention

if python3 - "$TMP/dev-1.reply-contract.json" <<'PYEOF'
import json, sys
row = json.load(open(sys.argv[1]))
assert row["schema_version"] == 1 and row["agent"] == "dev-1"
assert len(row["interactions"]) == 1
item = row["interactions"][0]
assert item["received"] == "2026-09-18T10:00:00Z"
assert item["acknowledged"] == item["estimate_given"] == "2026-09-18T10:00:30Z"
assert item["estimate_due"] == "2026-09-18T10:30:30Z"
assert item["answered"] == "2026-09-18T10:12:00Z"
assert item["kind"] == "mention" and item["ticket"] == "TEST-7"
PYEOF
then
  printf 'PASS %-36s %s\n' reply-lifecycle-ledger 'received, acknowledged, estimate, and answer are durable per agent'
else
  printf 'FAIL %-36s %s\n' reply-lifecycle-ledger 'reply ledger did not preserve the lifecycle'
  exit 1
fi
