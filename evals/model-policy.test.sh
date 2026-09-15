#!/usr/bin/env bash
# Provider routing checks use local board and model stubs, so no eval can spend.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/home/.config/agents" "$TMP/company" "$TMP/repo" "$TMP/bin"
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
  *'/mcp/tasks?'*) cat "$BOARD_JSON"; printf '\n200' ;;
  *'/mcp/comments?'*) printf '%s\n200' '{"comments":[]}' ;;
  *) printf '%s\n200' '{}' ;;
esac
EOF
for model_cli in cursor-agent claude hax; do
  cat > "$TMP/bin/$model_cli" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$MODEL_CAPTURE"
EOF
done
chmod +x "$TMP/board" "$TMP/bin/"*

write_board() {
  local ref="$1" labels="$2"
  cat > "$TMP/board.json" <<EOF
{"tasks":[{"id":"task-$ref","ticketNumber":"$ref","section":"Bugs","title":"Model policy test","description":"Exercise provider routing","assignees":[{"agent":{"id":"agent-1"}}],"labels":$labels,"commentCount":0}]}
EOF
}

write_conf() {
  local model_cli="$1" triage="$2" state="$3"
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
MODEL_CLI="$model_cli"
PR_REPO="example/repo"
TRIAGE="$triage"
MODEL_OVERRIDE_DIR="$state/overrides"
EOF
}

run_poll() {
  local state="$1" capture="$2"; shift 2
  env HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
    XDG_STATE_HOME="$state" COMPANY_SKILLS_DIR="$TMP/company" \
    MODEL_POLICY_CODEX_BIN_OVERRIDE=hax BOARD_JSON="$TMP/board.json" \
    MODEL_CAPTURE="$capture" PATH="$TMP/bin:$PATH" \
    "$ROOT/scripts/agent-board-poll" "$@" test
}

cursor_cli='cursor-agent -p --output-format text --model cursor-grok-4.6-high-fast -f --trust'

# install.sh sources core directly, without defining the runner's CORE_ROOT.
if env -u CORE_ROOT bash -c '. "$1"; [ "$MODEL_POLICY_HARD_OVERRIDE" = "codex:gpt-5.6-sol:high" ]' \
     _ "$ROOT/scripts/lib/core.sh"; then
  ok core-policy-self-location "core finds the shipped policy when sourced by install.sh"
else
  bad core-policy-self-location "core still depends on a caller-defined CORE_ROOT"
fi

# Hard triage visibly selects the first escalation without spending.
state="$TMP/state-hard-dry"; capture="$TMP/capture-hard-dry"
write_board TEST-1 '[{"name":"hard"}]'
write_conf "$cursor_cli" yes "$state"
dry_out="$(run_poll "$state" "$capture" --once --dry-run 2>"$TMP/hard-dry.err")"
if grep -qF 'would run on provider codex, model gpt-5.6-sol (effort high)' <<< "$dry_out"; then
  ok hard-cursor-switches-to-codex "dry run selects codex:gpt-5.6-sol:high"
else
  bad hard-cursor-switches-to-codex "dry run output: $dry_out"
fi

# The provider adapter invokes the hax stub with tools enabled and prompt last.
state="$TMP/state-hard-run"; capture="$TMP/capture-hard-run"
write_board TEST-2 '[{"name":"hard"}]'
write_conf "$cursor_cli" yes "$state"
run_poll "$state" "$capture" --once >"$TMP/hard-run.out" 2>"$TMP/hard-run.err" || true
if grep -qF 'hax --provider=codex --model=gpt-5.6-sol --effort=high --no-session -p This ticket is scored HARD.' "$capture" \
   && ! grep -qF -- '--raw' "$capture"; then
  ok codex-hax-adapter "stub receives high effort, no-session, tools, and the run prompt"
else
  bad codex-hax-adapter "launch=$(cat "$capture" 2>/dev/null || true)"
fi

# A Cursor Claude id in conf is rejected once and falls back to Grok.
state="$TMP/state-conf"; capture="$TMP/capture-conf"
write_board TEST-3 '[]'
write_conf 'cursor-agent -p --output-format text --model claude-opus-5-thinking-high -f --trust' no "$state"
run_poll "$state" "$capture" --once >"$TMP/conf.out" 2>"$TMP/conf.err" || true
if [ "$(grep -c "model policy rejected 'cursor-agent:claude-opus-5-thinking-high' from conf" "$TMP/conf.err" || true)" -eq 1 ] \
   && grep -qF -- 'cursor-agent -p --output-format text --model cursor-grok-4.6-high-fast' "$capture" \
   && ! grep -qF -- '--model claude-' "$capture"; then
  ok cursor-claude-conf-rejected "one error; launch falls back to Cursor Grok"
else
  bad cursor-claude-conf-rejected "stderr=$(cat "$TMP/conf.err"); launch=$(cat "$capture" 2>/dev/null || true)"
fi

# A Cursor-qualified Claude override is rejected and logged.
state="$TMP/state-override"; capture="$TMP/capture-override"
write_board TEST-4 '[]'
write_conf "$cursor_cli" no "$state"
printf 'cursor-agent:claude-opus-5-thinking-high\n' > "$state/overrides/TEST-4"
run_poll "$state" "$capture" --once >"$TMP/override.out" 2>"$TMP/override.err" || true
log="$state/agent-board-poll/test.log"
if grep -qF "model policy rejected 'cursor-agent:claude-opus-5-thinking-high' from override" "$TMP/override.err" \
   && grep -qF "model policy rejected 'cursor-agent:claude-opus-5-thinking-high' from override" "$log" \
   && grep -qF -- '--model cursor-grok-4.6-high-fast' "$capture" \
   && ! grep -qF -- '--model claude-' "$capture"; then
  ok cursor-claude-override-rejected "rejected, logged, and launch stays on Grok"
else
  bad cursor-claude-override-rejected "stderr=$(cat "$TMP/override.err"); launch=$(cat "$capture" 2>/dev/null || true)"
fi

# Claude override is blocked before two Codex failures.
state="$TMP/state-claude-early"; capture="$TMP/capture-claude-early"
write_board TEST-5 '[]'
write_conf "$cursor_cli" no "$state"
printf 'claude:opus:high\n' > "$state/overrides/TEST-5"
run_poll "$state" "$capture" --once >"$TMP/claude-early.out" 2>"$TMP/claude-early.err" || true
if grep -qF 'Claude requires two failed Codex attempts' "$TMP/claude-early.err" \
   && grep -qF 'cursor-agent ' "$capture" \
   && ! grep -qF 'claude ' "$capture"; then
  ok claude-override-gated "falls back to conf default before two Codex failures"
else
  bad claude-override-gated "stderr=$(cat "$TMP/claude-early.err"); launch=$(cat "$capture" 2>/dev/null || true)"
fi

# Exactly two failed Codex attempts unlock Claude Opus.
state="$TMP/state-claude-final"; capture="$TMP/capture-claude-final"
write_board TEST-6 '[]'
write_conf "$cursor_cli" no "$state"
printf 'claude:opus:high\n' > "$state/overrides/TEST-6"
mkdir -p "$state/agent-board-poll"
now="$(date +%s)"
printf 'task-TEST-6 %s codex failed\ntask-TEST-6 %s codex failed\n' "$now" "$now" > "$state/agent-board-poll/test.attempts"
run_poll "$state" "$capture" --once >"$TMP/claude-final.out" 2>"$TMP/claude-final.err" || true
if grep -qF 'claude -p --model opus --effort high' "$capture"; then
  ok claude-after-two-codex-failures "claude:opus:high is the final machine rung"
else
  bad claude-after-two-codex-failures "stderr=$(cat "$TMP/claude-final.err"); launch=$(cat "$capture" 2>/dev/null || true)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
