#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-34s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-34s %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/bin" "$TMP/home/.config/hypertask" "$TMP/home/.config/agents" "$TMP/company" "$TMP/repo"
printf '{"token":"owner-token"}\n' > "$TMP/home/.config/hypertask/config.json"
printf '# company pack\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'agent-token\n' > "$TMP/token"

cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
token=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "--token" ]; then token="${args[$((i + 1))]:-}"; fi
done
if [ -z "$token" ]; then token="owner-token"; fi
if [[ " $* " = *" comment add "* ]]; then touch "$BOARD_POSTED"; fi
printf '%s\n' "$token"
EOF
for name in ht htbot; do
  cat > "$TMP/bin/$name" <<'EOF'
#!/usr/bin/env bash
exec hypertask "$@"
EOF
done
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *'/mcp/tasks?'*) cat "$BOARD_JSON"; printf '\n200' ;;
  *'/mcp/comments?'*) printf '{"comments":[]}\n200' ;;
  *) printf '{}\n200' ;;
esac
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
cat > "$TMP/bin/provider" <<'EOF'
#!/usr/bin/env bash
command -v hypertask > "$RESOLVED_CAPTURE"
command -v ht >> "$RESOLVED_CAPTURE"
command -v htbot >> "$RESOLVED_CAPTURE"
hypertask --json status > "$TOKEN_CAPTURE"
EOF
chmod +x "$TMP/bin/"*

CORE_ROOT="$ROOT"
PATH="$TMP/bin:$PATH"
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/core.sh"
core_load_adapter hypertask
adapter_install_board_cli test "$TMP/token" "$TMP/board" "Test Agent"

cat > "$TMP/board.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","section":"Bugs","title":"Identity test","description":"Verify the provider identity boundary","assignees":[{"agent":{"id":"agent-1"}}],"labels":[],"commentCount":0}]}
EOF
cat > "$TMP/home/.config/agents/test.conf" <<EOF
AGENT_ID="agent-1"
AGENT_NAME="Test Agent"
AGENT_KIND="dev"
AGENT_REPO="$TMP/repo"
AGENT_SLUG="test"
BOARD_ADAPTER="hypertask"
BOARD_ID="1"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/board"
WATCH_SECTIONS="Bugs"
SKILLS_INDEX=""
MODEL_CLI="provider"
PR_REPO="example/repo"
TRIAGE="no"
EOF

run_poll() {
  env HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
    XDG_RUNTIME_DIR= XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
    BOARD_JSON="$TMP/board.json" BOARD_POSTED="$TMP/posted" \
    RESOLVED_CAPTURE="$TMP/resolved" TOKEN_CAPTURE="$TMP/received-token" \
    PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once test
}

if run_poll > "$TMP/run.out" 2> "$TMP/run.err" \
   && [ "$(sed -n '1p' "$TMP/resolved")" = "$TMP/state/agent-identity-shims/test/hypertask" ] \
   && [ "$(sed -n '2p' "$TMP/resolved")" = "$TMP/state/agent-identity-shims/test/ht" ] \
   && [ "$(sed -n '3p' "$TMP/resolved")" = "$TMP/state/agent-identity-shims/test/htbot" ]; then
  ok identity-shim-first-on-path "hypertask, ht, and htbot resolve inside the agent shim"
else
  bad identity-shim-first-on-path "resolved paths: $(paste -sd, "$TMP/resolved" 2>/dev/null || true)"
fi

if cmp -s "$TMP/received-token" <(printf 'agent-token\n'); then
  ok identity-shim-agent-token "a bare board command receives the agent token"
else
  bad identity-shim-agent-token "a bare board command did not receive the agent token"
fi

rm -f "$TMP/token" "$TMP/posted"
if run_poll > "$TMP/missing.out" 2> "$TMP/missing.err"; then
  missing_rc=0
else
  missing_rc=$?
fi
if [ "$missing_rc" -ne 0 ] \
   && grep -qF 'no agent token for test' "$TMP/missing.err" \
   && grep -qF 'no agent token for test' "$TMP/state/agent-board-poll/test.log" \
   && [ ! -e "$TMP/posted" ]; then
  ok identity-shim-missing-token "the run fails loudly before any board write"
else
  bad identity-shim-missing-token "missing token exit=$missing_rc or the run reached a board write"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
