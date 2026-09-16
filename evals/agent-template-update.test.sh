#!/usr/bin/env bash
# Update checks use isolated homes and stubs, so they cannot touch the host install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

HOME_DIR="$TMP/home"
CONF_DIR="$HOME_DIR/.config/hypertask-agents"
HOST_CONFIG="$HOME_DIR/.config/agent-template/config"
FAKE_REPO="$TMP/repo"
TEMPLATE="$FAKE_REPO/templates/agent-skills/create-agent"
mkdir -p "$CONF_DIR" "$TEMPLATE/scripts" "$TEMPLATE/evals" "$TMP/bin" "$TMP/units" "$TMP/state"
printf 'test-version\n' > "$TEMPLATE/VERSION"

cat > "$TEMPLATE/install.sh" <<'EOF'
#!/usr/bin/env bash
printf 'installed\n' > "$INSTALL_MARKER"
EOF
cat > "$TEMPLATE/scripts/sync-project.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TEMPLATE/scripts/migrate-provider-policy.py" <<'EOF'
#!/usr/bin/env python3
EOF
cat > "$TEMPLATE/evals/run-evals.sh" <<'EOF'
#!/usr/bin/env bash
if [ "${EVAL_MODE:-green}" = red ]; then
  echo 'FAIL staged-release staged failure'
  echo '1 case(s) run, 1 failed'
  exit 1
fi
echo '1 case(s) run, 0 failed'
EOF
cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_LOG"
case "$*" in
  *"rev-parse --short HEAD"*) echo deadbee ;;
  *"rev-parse HEAD"*) echo deadbeefdeadbeefdeadbeefdeadbeefdeadbeef ;;
  *"show stable:templates/agent-skills/create-agent/VERSION"*) echo stable-version ;;
esac
exit 0
EOF
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TEMPLATE/install.sh" "$TEMPLATE/scripts/sync-project.sh" \
  "$TEMPLATE/evals/run-evals.sh" "$TMP/bin/git" "$TMP/bin/systemctl"

cat > "$CONF_DIR/old-worker.conf" <<'EOF'
HT_AGENT_ID="agent-1"
HT_PROVIDER="claude"
HT_MODEL="sonnet"
HT_MISSION="Maintain the product"
HT_START_SECTIONS="Ready"
HT_PROJECT_ID="1"
EOF

run_update() {
  HOME="$HOME_DIR" AGENT_CONFIG_DIR="$CONF_DIR" AGENT_TEMPLATE_CONFIG_DIR="$CONF_DIR" \
    AGENT_TEMPLATE_HOST_CONFIG="$HOST_CONFIG" AGENT_TEMPLATE_REPO="$FAKE_REPO" \
    AGENT_SYSTEMD_DIR="$TMP/units" XDG_STATE_HOME="$TMP/state" \
    PATH="$TMP/bin:$PATH" GIT_LOG="$TMP/git.log" INSTALL_MARKER="$TMP/installed" \
    "$ROOT/scripts/agent-template" update "$@"
}

# Stable is the default and selects only the stable tag.
: > "$TMP/git.log"
set +e
run_update >"$TMP/stable.out" 2>"$TMP/stable.err"
status=$?
set -e
if [ "$status" -eq 0 ] \
   && grep -q '^BOARD_ADAPTER="hypertask"$' "$CONF_DIR/old-worker.conf" \
   && grep -q 'checkout --detach stable' "$TMP/git.log" \
   && ! grep -q 'checkout --detach origin/main' "$TMP/git.log"; then
  ok stable-host-stays-on-tag "stable update checks out stable, never main"
else
  bad stable-host-stays-on-tag "status=$status output=$(cat "$TMP/stable.out") git=$(cat "$TMP/git.log")"
fi

# A red staged suite refuses without invoking install and exits successfully.
rm -f "$TMP/installed"
: > "$TMP/git.log"
set +e
EVAL_MODE=red run_update >"$TMP/red.out" 2>"$TMP/red.err"
status=$?
set -e
if [ "$status" -eq 0 ] && [ ! -e "$TMP/installed" ] \
   && grep -q '^update to test-version refused: 1 evals red$' "$TMP/red.out"; then
  ok red-evals-refuse-swap "red staged evals leave the installed release alone"
else
  bad red-evals-refuse-swap "status=$status installed=$([ -e "$TMP/installed" ] && echo yes || echo no) output=$(cat "$TMP/red.out")"
fi

# A changed installed file is archived and blocks the swap by default.
INSTALLED="$TMP/installed-template"
mkdir -p "$INSTALLED/scripts"
printf 'old-version\n' > "$INSTALLED/VERSION"
printf 'release copy\n' > "$INSTALLED/scripts/custom"
(cd "$INSTALLED" && sha256sum scripts/custom > .manifest.sha256)
printf 'host edit\n' > "$INSTALLED/scripts/custom"
rm -f "$TMP/installed"
set +e
AGENT_TEMPLATE_INSTALL_DIR="$INSTALLED" run_update >"$TMP/patch.out" 2>"$TMP/patch.err"
status=$?
set -e
if [ "$status" -eq 0 ] && [ ! -e "$TMP/installed" ] \
   && grep -q '^host edit$' "$INSTALLED/local-patches/old-version/scripts/custom" \
   && grep -q 'update refused: local changes would be replaced' "$TMP/patch.out"; then
  ok local-patch-refuses-swap "host edit is archived and the swap is refused"
else
  bad local-patch-refuses-swap "status=$status output=$(cat "$TMP/patch.out")"
fi

# Promotion cannot move stable until this exact install is 24 hours old.
mkdir -p "$(dirname "$HOST_CONFIG")"
printf 'CHANNEL=latest\nMAINTAINER=yes\n' > "$HOST_CONFIG"
printf 'version=test-version\ncommit=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\ninstalled_at=%s\n' "$(date +%s)" > "$TMP/state/install-state"
: > "$TMP/git.log"
set +e
HOME="$HOME_DIR" AGENT_TEMPLATE_HOST_CONFIG="$HOST_CONFIG" AGENT_TEMPLATE_REPO="$FAKE_REPO" \
  AGENT_TEMPLATE_INSTALL_STATE="$TMP/state/install-state" PATH="$TMP/bin:$PATH" GIT_LOG="$TMP/git.log" \
  "$ROOT/scripts/agent-template" promote >"$TMP/promote.out" 2>"$TMP/promote.err"
status=$?
set -e
if [ "$status" -eq 0 ] && grep -q 'promote refused: installed test-version has run for .* less than 24h' "$TMP/promote.out" \
   && ! grep -q 'tag -f stable' "$TMP/git.log"; then
  ok promote-refuses-under-24h "stable tag is untouched during the observation window"
else
  bad promote-refuses-under-24h "status=$status output=$(cat "$TMP/promote.out") git=$(cat "$TMP/git.log")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
