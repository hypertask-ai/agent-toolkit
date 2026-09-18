#!/usr/bin/env bash
# QA section checks use isolated config and command stubs; no board is contacted.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/home" "$TMP/config" "$TMP/bin" "$TMP/repo-default" \
  "$TMP/repo-explicit" "$TMP/repo-runner" "$TMP/state" "$TMP/company"
printf '# QA skills\n' > "$TMP/INDEX.md"
printf '# company skills\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"

create_qa() {
  HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" AGENT_BIN_DIR="$TMP/bin" \
    AGENT_SYSTEMD_DIR="$TMP/units" COMPANY_SKILLS_INDEX= \
    "$ROOT/scripts/create-agent.sh" "$@" --kind qa --board none --wiring none \
      --skills-index "$TMP/INDEX.md" --yes >/dev/null
}
create_qa --name 'QA 1' --repo "$TMP/repo-default"
create_qa --name 'QA 2' --repo "$TMP/repo-explicit" --sections 'AI Review'

if grep -q '^WATCH_SECTIONS="AI Review,QA"$' "$TMP/config/qa-1.conf" \
   && grep -q '^WATCH_SECTIONS="AI Review,QA"$' "$TMP/config/qa-2.conf"; then
  ok qa-create-sections "new QA confs include QA with default and explicit sections"
else
  bad qa-create-sections "default=$(sed -n 's/^WATCH_SECTIONS=//p' "$TMP/config/qa-1.conf") explicit=$(sed -n 's/^WATCH_SECTIONS=//p' "$TMP/config/qa-2.conf")"
fi

printf 'token\n' > "$TMP/token"
cat > "$TMP/board" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *'/mcp/tasks?'*) cat "$TASKS_JSON"; printf '\n200' ;;
  *'/mcp/comments?'*) printf '%s\n200' '{"comments":[]}' ;;
  *) printf '%s\n200' '{}' ;;
esac
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *' project show '*) printf '%s\n' '{"project":{"id":5500,"ownerId":6,"sections":[{"name":"Bugs"},{"name":"QA"},{"name":"Done"},{"name":"HT Manager Review"}]}}' ;;
  *) printf '{}\n' ;;
esac
EOF
chmod +x "$TMP/board" "$TMP/bin/curl" "$TMP/bin/gh" "$TMP/bin/hypertask"
cat > "$TMP/tasks.json" <<'EOF'
{"tasks":[{"id":"task-26","ticketNumber":"AGTE-26","section":"QA","title":"Verify the fix","description":"Ready for QA","assignees":[{"agent":{"id":"agent-qa"}}],"labels":[],"commentCount":0}]}
EOF
cat > "$TMP/config/qa-runner.conf" <<EOF
AGENT_ID="agent-qa"
AGENT_NAME="QA Runner"
AGENT_KIND="qa"
AGENT_REPO="$TMP/repo-runner"
AGENT_SLUG="qa-runner"
BOARD_ADAPTER="hypertask"
BOARD_ID="5500"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/board"
WATCH_SECTIONS="AI Review,QA"
SKILLS_INDEX=""
MODEL_CLI="provider"
PR_REPO="example/repo"
TRIAGE="no"
CLAIM_UNASSIGNED="no"
FLEET_PROGRESS_SUPERVISOR="off"
EOF

output="$(HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config" XDG_STATE_HOME="$TMP/state" \
  COMPANY_SKILLS_DIR="$TMP/company" TASKS_JSON="$TMP/tasks.json" PATH="$TMP/bin:$PATH" \
  "$ROOT/scripts/agent-board-poll" --once --dry-run qa-runner)"
if printf '%s\n' "$output" | grep -q '^would pick up AGTE-26 '; then
  ok qa-column-ticket-eligible "an assigned ticket in QA is eligible for the QA agent"
else
  bad qa-column-ticket-eligible "output=$output"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
