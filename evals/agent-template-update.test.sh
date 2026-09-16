#!/usr/bin/env bash
# Update checks use an isolated HOME and stubs, so they cannot touch the host install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
CONF_DIR="$HOME_DIR/.config/hypertask-agents"
FAKE_REPO="$TMP/repo"
mkdir -p "$CONF_DIR" "$FAKE_REPO/.git" "$FAKE_REPO/templates/agent-skills/create-agent/scripts" \
  "$TMP/bin" "$TMP/units" "$TMP/state"

cat > "$FAKE_REPO/templates/agent-skills/create-agent/install.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAKE_REPO/templates/agent-skills/create-agent/scripts/sync-project.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAKE_REPO/templates/agent-skills/create-agent/scripts/migrate-provider-policy.py" <<'EOF'
#!/usr/bin/env python3
EOF
cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_REPO/templates/agent-skills/create-agent/install.sh" \
  "$FAKE_REPO/templates/agent-skills/create-agent/scripts/sync-project.sh" \
  "$TMP/bin/git" "$TMP/bin/systemctl"

cat > "$CONF_DIR/old-worker.conf" <<'EOF'
HT_AGENT_ID="agent-1"
HT_PROVIDER="claude"
HT_MODEL="sonnet"
HT_MISSION="Maintain the product"
HT_START_SECTIONS="Ready"
HT_PROJECT_ID="1"
EOF

set +e
HOME="$HOME_DIR" AGENT_CONFIG_DIR="$CONF_DIR" AGENT_TEMPLATE_CONFIG_DIR="$CONF_DIR" \
  AGENT_TEMPLATE_REPO="$FAKE_REPO" AGENT_SYSTEMD_DIR="$TMP/units" \
  XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
  "$ROOT/scripts/agent-template" update >"$TMP/update.out" 2>"$TMP/update.err"
status=$?
set -e

if [ "$status" -eq 0 ] && grep -q '^BOARD_ADAPTER="hypertask"$' "$CONF_DIR/old-worker.conf"; then
  printf 'PASS %-36s %s\n' update-old-schema-no-slug 'old-schema conf converts and update exits 0'
  printf '\n1 passed, 0 failed\n'
else
  printf 'FAIL %-36s status=%s output=%s error=%s\n' update-old-schema-no-slug "$status" \
    "$(cat "$TMP/update.out")" "$(cat "$TMP/update.err")"
  printf '\n0 passed, 1 failed\n'
  exit 1
fi
