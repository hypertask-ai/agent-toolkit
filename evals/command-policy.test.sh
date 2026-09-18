#!/usr/bin/env bash
# Command policy checks use local board and command stubs, so no eval can spend.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/home/.config/agents" "$TMP/home/.claude/skills/pospeak" \
  "$TMP/home/.claude/skills/unslop" "$TMP/home/.claude/skills/i-have-adhd" \
  "$TMP/home/.codex" "$TMP/company" "$TMP/repo" "$TMP/bin"
printf '# company pack\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"
printf '{}\n' > "$TMP/home/.codex/auth.json"
printf 'global\n' > "$TMP/home/.claude/CLAUDE.md"
printf 'pospeak\n' > "$TMP/home/.claude/skills/pospeak/SKILL.md"
printf 'unslop\n' > "$TMP/home/.claude/skills/unslop/SKILL.md"
printf 'adhd\n' > "$TMP/home/.claude/skills/i-have-adhd/SKILL.md"

cat > "$TMP/board" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${BOARD_CAPTURE:-/dev/null}"
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
  *'/mcp/tasks?'*) cat "$BOARD_JSON"; printf '\n200' ;;
  *'/mcp/comments?'*)
    if [ -n "${COMMENT_JSON:-}" ]; then printf '%s\n200' "$COMMENT_JSON"; else printf '%s\n200' '{"comments":[]}'; fi
    ;;
  *) printf '%s\n200' '{}' ;;
esac
EOF
for command in model-only rung-one rung-two override-command; do
  cat > "$TMP/bin/$command" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$MODEL_CAPTURE"
EOF
done
cat > "$TMP/bin/failing-model" <<'EOF'
#!/usr/bin/env bash
echo 'provider unavailable' >&2
exit 7
EOF
cat > "$TMP/bin/timeout-stub" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
cat > "$TMP/bin/bwrap-stub" <<'EOF'
#!/usr/bin/env bash
hax=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "--ro-bind" ] && [ "${args[$((i + 2))]:-}" = "/opt/hax" ]; then
    hax="${args[$((i + 1))]}"
  fi
  if [ "${args[$i]}" = "--" ]; then
    exec "$hax" "${args[@]:$((i + 2))}"
  fi
done
exit 2
EOF
chmod +x "$TMP/board" "$TMP/bin/"*

write_board() {
  local ref="$1"
  cat > "$TMP/board.json" <<EOF
{"tasks":[{"id":"task-$ref","ticketNumber":"$ref","section":"Bugs","title":"Command policy test","description":"Exercise command routing","assignees":[{"agent":{"id":"agent-1"}}],"labels":[],"commentCount":0}]}
EOF
}

write_conf() {
  local state="$1" ladder="${2:-}"
  mkdir -p "$state/overrides"
  cat > "$TMP/home/.config/agents/test.conf" <<EOF
AGENT_ID="agent-1"
AGENT_NAME="Test Dev"
AGENT_KIND="dev"
AGENT_REPO="$TMP/repo"
BOARD_ADAPTER="hypertask"
BOARD_ID="1"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/board"
WATCH_SECTIONS="Bugs"
SKILLS_INDEX=""
MODEL_CLI="model-only --fixed"
LADDER="$ladder"
PR_REPO="example/repo"
TRIAGE="no"
RETRY_LIMIT="6"
MODEL_OVERRIDE_DIR="$state/overrides"
EOF
}

seed_failures() {
  local state="$1" ref="$2" count="$3" now
  mkdir -p "$state/agent-board-poll"
  now="$(date +%s)"
  : > "$state/agent-board-poll/test.attempts"
  for ((i=0; i<count; i++)); do
    printf 'task-%s %s old-rung failed\n' "$ref" "$now" >> "$state/agent-board-poll/test.attempts"
  done
}

run_poll() {
  local state="$1" capture="$2"; shift 2
  env HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
    XDG_STATE_HOME="$state" COMPANY_SKILLS_DIR="$TMP/company" \
    BOARD_JSON="$TMP/board.json" MODEL_CAPTURE="$capture" \
    BOARD_CAPTURE="${BOARD_CAPTURE:-$TMP/board-capture}" COMMENT_JSON="${COMMENT_JSON:-}" \
    REPLY_HAX_BIN="$TMP/bin/failing-model" REPLY_BWRAP_BIN="$TMP/bin/bwrap-stub" \
    REPLY_TIMEOUT_BIN="$TMP/bin/timeout-stub" REPLY_CODEX_AUTH="$TMP/home/.codex/auth.json" \
    PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" "$@" test
}

# An absent ladder cannot switch away from MODEL_CLI, even past the threshold.
state="$TMP/state-model"; capture="$TMP/capture-model"
write_board TEST-1
write_conf "$state"
seed_failures "$state" TEST-1 4
run_poll "$state" "$capture" --once >"$TMP/model.out" 2>"$TMP/model.err" || true
if grep -q '^model-only --fixed ' "$capture" \
   && ! grep -Eq '^(rung-one|rung-two|override-command) ' "$capture"; then
  ok no-ladder-model-only "four failures still run only MODEL_CLI"
else
  bad no-ladder-model-only "launch=$(cat "$capture" 2>/dev/null || true)"
fi

# Three failures select rung one; four failures select rung two.
state="$TMP/state-rung-two"; capture="$TMP/capture-rung-two"
write_board TEST-2
write_conf "$state" 'rung-one --first|rung-two --second'
seed_failures "$state" TEST-2 4
run_poll "$state" "$capture" --once >"$TMP/rung.out" 2>"$TMP/rung.err" || true
if grep -q '^rung-two --second ' "$capture" && ! grep -q '^rung-one ' "$capture"; then
  ok ladder-second-rung "four failures select the second configured command"
else
  bad ladder-second-rung "launch=$(cat "$capture" 2>/dev/null || true)"
fi

# AGTE-4: a ladder rung naming a binary this host does not have must not run
# it (and must not crash the tick) -- the run falls back to MODEL_CLI instead.
state="$TMP/state-rung-missing"; capture="$TMP/capture-rung-missing"
write_board TEST-4
write_conf "$state" 'rung-one --first|absent-command --second'
seed_failures "$state" TEST-4 4
run_poll "$state" "$capture" --once >"$TMP/missing.out" 2>"$TMP/missing.err" || true
if grep -q '^model-only --fixed ' "$capture" \
   && ! grep -Eq '^(rung-one|absent-command) ' "$capture"; then
  ok ladder-missing-binary "missing rung binary falls back to MODEL_CLI, not exit=127"
else
  bad ladder-missing-binary "launch=$(cat "$capture" 2>/dev/null || true); err=$(cat "$TMP/missing.err" 2>/dev/null || true)"
fi

# A ticket override is a full command and wins verbatim.
state="$TMP/state-override"; capture="$TMP/capture-override"
write_board TEST-3
write_conf "$state" 'rung-one --first|rung-two --second'
printf 'override-command --exact value\n' > "$state/overrides/TEST-3"
run_poll "$state" "$capture" --once >"$TMP/override.out" 2>"$TMP/override.err" || true
if grep -q '^override-command --exact value ' "$capture" \
   && ! grep -Eq '^(model-only|rung-one|rung-two) ' "$capture"; then
  ok override-full-command "override file is executed as the complete command"
else
  bad override-full-command "launch=$(cat "$capture" 2>/dev/null || true)"
fi

# A failed mention writes host status only but still spends the ticket cooldown.
state="$TMP/state-failure"; capture="$TMP/capture-failure"; board_capture="$TMP/board-failure"
write_board TEST-4
write_conf "$state"
sed -i 's#^MODEL_CLI=.*#MODEL_CLI="failing-model"#' "$TMP/home/.config/agents/test.conf"
seed_failures "$state" TEST-4 0
COMMENT_JSON='{"comments":[{"id":99,"createdAt":"2026-09-16T00:00:00Z","text":"<p><span data-label=\"agent-agent-1\">@Test Dev</span> please retry</p>","creator":{"displayName":"Valentin"}}]}'
BOARD_CAPTURE="$board_capture" COMMENT_JSON="$COMMENT_JSON" \
  run_poll "$state" "$capture" --once >"$TMP/failure.out" 2>"$TMP/failure.err" || true
BOARD_CAPTURE="$board_capture" COMMENT_JSON="$COMMENT_JSON" \
  run_poll "$state" "$capture" --once --dry-run >"$TMP/failure-next.out" 2>>"$TMP/failure.err" || true
status_file="$state/agent-board-poll/test.status"
if [ -f "$status_file" ] \
   && python3 -c 'import json,sys; row=json.load(open(sys.argv[1])); assert row["state"] == "failed" and row["ticket"] == "TEST-4"' "$status_file" \
   && ! grep -q 'comment add' "$board_capture" 2>/dev/null \
   && ! grep -q '^task-TEST-4:99$' "$state/agent-board-poll/test.seen" \
   && grep -q 'no new human or other-agent comment bypasses the 1800s ticket cooldown' "$TMP/failure-next.out" \
   && ! grep -q 'would pick up TEST-4' "$TMP/failure-next.out"; then
  ok failed-mention-obeys-cooldown "failure posts nothing and cannot rerun the same mention for 30 minutes"
else
  bad failed-mention-obeys-cooldown "status=$(cat "$status_file" 2>/dev/null || true) board=$(cat "$board_capture" 2>/dev/null || true) next=$(cat "$TMP/failure-next.out")"
fi

# Migration preserves the old cursor policy and leaves a custom pi conf alone.
migrate="$TMP/migrate"
mkdir -p "$migrate"
cat > "$migrate/cursor.conf" <<'EOF'
MODEL_CLI="cursor-agent -p --output-format text --model cursor-grok-4.6-high-fast -f --trust"
EOF
cat > "$migrate/pi.conf" <<'EOF'
MODEL_CLI="pi --print --tools read,bash,edit,write --no-extensions --no-skills --provider zai --model glm-5.3-flash"
EOF
HOME="$TMP/home" python3 "$ROOT/scripts/migrate-provider-policy.py" \
  --version 3.16.0 "$migrate" > "$TMP/migrate.out"
if grep -q '^LADDER=.*/hax --provider=codex.*|.*/hax --provider=codex.*|.*/hax --provider=codex.*--model=gpt-5.6-sol' "$migrate/cursor.conf" \
   && grep -q '^RESEARCH_CLI=.*/hax --provider=codex.*--effort=xhigh' "$migrate/cursor.conf" \
   && grep -q '^TRIAGE_HARD_CLI=.*/hax --provider=codex.*--effort=high' "$migrate/cursor.conf" \
   && [ -f "$migrate/cursor.conf.bak-3.16.0" ] \
   && cmp -s "$migrate/pi.conf" <(printf '%s\n' 'MODEL_CLI="pi --print --tools read,bash,edit,write --no-extensions --no-skills --provider zai --model glm-5.3-flash"') \
   && [ ! -e "$migrate/pi.conf.bak-3.16.0" ]; then
  ok migration-selective "cursor gets explicit policy; pi remains byte-for-byte unchanged"
else
  bad migration-selective "output=$(cat "$TMP/migrate.out"); cursor=$(cat "$migrate/cursor.conf"); pi=$(cat "$migrate/pi.conf")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
