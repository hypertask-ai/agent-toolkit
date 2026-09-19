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
TEMPLATE="$FAKE_REPO"
mkdir -p "$CONF_DIR" "$TEMPLATE/scripts" "$TEMPLATE/evals" "$TMP/bin" "$TMP/units" "$TMP/state"
printf 'test-version\n' > "$TEMPLATE/VERSION"
printf '%s\n' '- ACTION: set `BOARD_ID="15,5156,5500"` in `~/.config/hypertask-agents/product-bot.conf`.' > "$TEMPLATE/CHANGELOG.md"

cat > "$TEMPLATE/install.sh" <<'EOF'
#!/usr/bin/env bash
printf 'installed\n' > "$INSTALL_MARKER"
mkdir -p "$AGENT_SYSTEMD_DIR"
printf '[Timer]\nOnBootSec=1m\n[Install]\nWantedBy=timers.target\n' > "$AGENT_SYSTEMD_DIR/fresh-update.timer"
printf '[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/bin/true\n[Install]\nWantedBy=default.target\n' > "$AGENT_SYSTEMD_DIR/fresh-update.service"
printf '%s\n' fresh-update.timer fresh-update.service >> "$AGENT_TEMPLATE_INSTALLED_UNITS_FILE"
EOF
cat > "$TEMPLATE/scripts/sync-project.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TEMPLATE/scripts/migrate-provider-policy.py" <<'EOF'
#!/usr/bin/env python3
EOF
cp "$ROOT/scripts/migrate-quiet-mode.py" "$TEMPLATE/scripts/migrate-quiet-mode.py"
cat > "$TEMPLATE/evals/run-evals.sh" <<'EOF'
#!/usr/bin/env bash
if [ -n "${AGENT_TEMPLATE_CORE_ROOT:-}" ]; then
  echo 'FAIL staged-core-root inherited installed tree'
  exit 1
fi
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
  *"show stable:VERSION"*) echo stable-version ;;
esac
exit 0
EOF
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$*" in
  '--user is-enabled agent-board-poll@worker.timer') exit 0 ;;
  '--user daemon-reload'|'--user enable fresh-update.service'|'--user start fresh-update.service'|'--user enable --now fresh-update.timer') exit 0 ;;
  '--user is-active fresh-update.service'|'--user is-active fresh-update.timer') echo active; exit 0 ;;
  *) exit 1 ;;
esac
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
cat > "$CONF_DIR/current-worker.conf" <<'EOF'
AGENT_SLUG="current-worker"
BOARD_ADAPTER="hypertask"
EOF
cat > "$CONF_DIR/current-qa.conf" <<'EOF'
AGENT_SLUG="current-qa"
AGENT_KIND="qa"
BOARD_ADAPTER="hypertask"
WATCH_SECTIONS="AI Review"
EOF

run_update() {
  HOME="$HOME_DIR" AGENT_CONFIG_DIR="$CONF_DIR" AGENT_TEMPLATE_CONFIG_DIR="$CONF_DIR" \
    AGENT_TEMPLATE_HOST_CONFIG="$HOST_CONFIG" AGENT_TEMPLATE_REPO="$FAKE_REPO" \
    AGENT_SYSTEMD_DIR="$TMP/units" XDG_STATE_HOME="$TMP/state" \
    PATH="$TMP/bin:$PATH" GIT_LOG="$TMP/git.log" SYSTEMCTL_LOG="$TMP/systemctl.log" \
    INSTALL_MARKER="$TMP/installed" "$ROOT/scripts/agent-template" update "$@"
}

OLD_CORE="$TMP/old-installed"
mkdir -p "$OLD_CORE/scripts/lib"
cp "$ROOT/scripts/lib/core.sh" "$ROOT/scripts/lib/feedback.sh" "$OLD_CORE/scripts/lib/"
if AGENT_TEMPLATE_CORE_ROOT="$OLD_CORE" "$ROOT/scripts/agent-template" --help >/dev/null 2>&1; then
  ok staged-helper-bootstrap "a staged script escapes an older installed core that lacks its new library"
else
  bad staged-helper-bootstrap "the inherited old core hid a library present in the staged tree"
fi

# Stable is the default and selects only the stable tag.
mkdir -p "$TEMPLATE/evals/__pycache__"
printf 'stale cache\n' > "$TEMPLATE/evals/__pycache__/case.pyc"
: > "$TMP/git.log"
set +e
run_update >"$TMP/stable.out" 2>"$TMP/stable.err"
status=$?
set -e
if [ "$status" -eq 0 ] \
   && grep -q '^BOARD_ADAPTER="hypertask"$' "$CONF_DIR/old-worker.conf" \
   && grep -q '^GRAFT="off"$' "$CONF_DIR/old-worker.conf" \
   && grep -q '^GRAFT="off"$' "$CONF_DIR/current-worker.conf" \
   && grep -q '^WATCH_SECTIONS="AI Review,QA"$' "$CONF_DIR/current-qa.conf" \
   && compgen -G "$CONF_DIR/current-qa.conf.bak-*" >/dev/null \
   && grep -q 'ACTION: set `BOARD_ID="15,5156,5500"` in `~/.config/hypertask-agents/product-bot.conf`\.' "$TMP/stable.out" \
   && grep -q 'cache cleaned: evals/__pycache__' "$TMP/stable.out" \
   && [ ! -e "$TEMPLATE/evals/__pycache__" ] \
   && grep -q 'checkout --detach stable' "$TMP/git.log" \
   && ! grep -q 'checkout --detach origin/main' "$TMP/git.log"; then
  ok stable-host-stays-on-tag "stable update checks out stable, prints the host action, and never follows main"
else
  bad stable-host-stays-on-tag "status=$status output=$(cat "$TMP/stable.out") git=$(cat "$TMP/git.log")"
fi

# Every concrete timer and service written by install is activated and reported once.
if grep -q '^--user enable --now fresh-update.timer$' "$TMP/systemctl.log" \
   && grep -q '^--user enable fresh-update.service$' "$TMP/systemctl.log" \
   && grep -q '^--user start fresh-update.service$' "$TMP/systemctl.log" \
   && [ "$(grep -c '^  fresh-update.timer: active$' "$TMP/stable.out")" -eq 1 ] \
   && [ "$(grep -c '^  fresh-update.service: active$' "$TMP/stable.out")" -eq 1 ]; then
  ok installed-units-active "fresh timer and service are active and each has one state line after update"
else
  bad installed-units-active "output=$(cat "$TMP/stable.out") systemctl=$(cat "$TMP/systemctl.log")"
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

# A changed installed file is archived, installed, and reapplied automatically.
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
if [ "$status" -eq 0 ] && [ -e "$TMP/installed" ] \
   && grep -q '^host edit$' "$INSTALLED/local-patches/old-version/scripts/custom" \
   && grep -q '^host edit$' "$INSTALLED/scripts/custom" \
   && grep -q 'local patch reapplied: scripts/custom' "$TMP/patch.out"; then
  ok local-patch-reapplied "host edit is archived, reported, and restored after install"
else
  bad local-patch-reapplied "status=$status output=$(cat "$TMP/patch.out")"
fi

# A host edit already present byte-for-byte upstream is no longer a conflict.
MATCHED="$TMP/matched-template"
mkdir -p "$MATCHED/scripts"
printf 'old-version\n' > "$MATCHED/VERSION"
printf 'release copy\n' > "$MATCHED/scripts/agent-board-poll"
(cd "$MATCHED" && sha256sum scripts/agent-board-poll > .manifest.sha256)
printf 'upstream fix\n' > "$MATCHED/scripts/agent-board-poll"
printf 'upstream fix\n' > "$TEMPLATE/scripts/agent-board-poll"
rm -f "$TMP/installed"
set +e
AGENT_TEMPLATE_INSTALL_DIR="$MATCHED" run_update >"$TMP/matched.out" 2>"$TMP/matched.err"
status=$?
set -e
if [ "$status" -eq 0 ] && [ -e "$TMP/installed" ] \
   && [ ! -e "$MATCHED/local-patches/old-version/scripts/agent-board-poll" ] \
   && grep -q 'no local patches found' "$TMP/matched.out"; then
  ok upstreamed-patch-installs "an installed hand patch identical to the incoming release installs cleanly"
else
  bad upstreamed-patch-installs "status=$status output=$(cat "$TMP/matched.out")"
fi

# --keep-timers may reload changed units but never restarts an enabled timer.
mkdir -p "$TMP/units/agent-board-poll@worker.service.d"
printf '[Service]\nEnvironment=PATH=/tmp/bin\n' > "$TMP/units/agent-board-poll@worker.service.d/path.conf"
: > "$TMP/systemctl.log"
set +e
run_update --keep-timers >"$TMP/keep-timers.out" 2>"$TMP/keep-timers.err"
status=$?
set -e
if [ "$status" -eq 0 ] \
   && grep -q 'kept timer states unchanged (--keep-timers)' "$TMP/keep-timers.out" \
   && grep -q '^--user daemon-reload$' "$TMP/systemctl.log" \
   && ! grep -q '^--user restart ' "$TMP/systemctl.log"; then
  ok keep-timers-preserves-state "changed units reload without starting a stopped timer"
else
  bad keep-timers-preserves-state "status=$status output=$(cat "$TMP/keep-timers.out") systemctl=$(cat "$TMP/systemctl.log")"
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
