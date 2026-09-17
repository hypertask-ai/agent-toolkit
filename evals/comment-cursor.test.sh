#!/usr/bin/env bash
# Board comment cursor checks use generated API pages and never call the board.
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
STATE_DIR="$TMP/state"
SLUG="test"
mkdir -p "$STATE_DIR"
warn() { printf '%s\n' "$*" >&2; }

_ht_get() {
  local path="$2" limit cursor
  case "$path" in
    *'/mcp/tasks?'*'status=Normal'*)
      printf '{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","section":"Done","title":"Question","description":"","assignees":[],"labels":[],"commentCount":%s,"updatedAt":"2026-01-01T00:00:00Z"}],"total":1}' "$TOTAL"
      ;;
    *'/mcp/tasks?'*)
      printf '{"tasks":[],"total":0}'
      ;;
    *'/mcp/comments?'*)
      limit="$(printf '%s' "$path" | sed -n 's/.*[?&]limit=\([0-9][0-9]*\).*/\1/p')"
      cursor="$(printf '%s' "$path" | sed -n 's/.*[?&]cursor=\([0-9][0-9]*\).*/\1/p')"
      TOTAL="$TOTAL" BASE="$BASE" LIMIT="${limit:-100}" CURSOR="$cursor" READS="$READS" python3 - <<'PY'
import json, os
base, total = int(os.environ["BASE"]), int(os.environ["TOTAL"])
ids = list(range(base + total, base, -1))
cursor = os.environ.get("CURSOR")
if cursor:
    try:
        ids = ids[ids.index(int(cursor)) + 1:]
    except ValueError:
        ids = []
page = ids[:int(os.environ["LIMIT"])]
with open(os.environ["READS"], "a", encoding="utf-8") as handle:
    handle.write("%d\n" % len(page))
comments = [{
    "id": value,
    "createdAt": "2026-01-01T00:%02d:00Z" % (value % 60),
    "agent": None,
    "creator": {"displayName": "Human"},
    "text": "<p><span data-label=\"agent-agent-1\">Test Bot</span> question %d?</p>" % value,
} for value in page]
next_cursor = str(page[-1]) if len(ids) > len(page) and page else None
print(json.dumps({"comments": comments, "nextCursor": next_cursor, "total": total}))
PY
      ;;
  esac
}

READS="$TMP/reads"
TOTAL=60
BASE=100
printf '100\n' > "$STATE_DIR/test.comment-cursor.1"
: > "$READS"
output="$(adapter_new_comments_on_owned token 1 agent-1 'Test Bot' 2>"$TMP/first.err")"
read_total="$(awk '{n += $1} END {print n + 0}' "$READS")"
if [ "$(cat "$STATE_DIR/test.comment-cursor.1")" = 160 ] \
   && [ "$read_total" -eq 60 ] \
   && printf '%s\n' "$output" | grep -q '"trigger": "reply_only"' \
   && [ ! -s "$TMP/first.err" ]; then
  ok sixty-comments-one-tick 'all 60 comments newer than the board cursor are read in one tick'
else
  bad sixty-comments-one-tick "cursor=$(cat "$STATE_DIR/test.comment-cursor.1") reads=$read_total output=$output warning=$(cat "$TMP/first.err")"
fi

TOTAL=501
BASE=0
printf '0\n' > "$STATE_DIR/test.comment-cursor.1"
: > "$READS"
adapter_new_comments_on_owned token 1 agent-1 'Test Bot' >/dev/null 2>"$TMP/cap.err"
warning_count="$(grep -c 'hit comment read ceiling 500 on board 1' "$TMP/cap.err" || true)"
read_total="$(awk '{n += $1} END {print n + 0}' "$READS")"
if [ "$read_total" -eq 500 ] && [ "$warning_count" -eq 1 ]; then
  ok cursor-ceiling-warning-once 'the 500-comment ceiling emits one warning for the tick'
else
  bad cursor-ceiling-warning-once "reads=$read_total warnings=$warning_count output=$(cat "$TMP/cap.err")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
