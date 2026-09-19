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
if [ -n "${FAKE_INSTALL_COPY_FILE:-}" ]; then
  mkdir -p "$AGENT_TEMPLATE_INSTALL_DIR/$(dirname "$FAKE_INSTALL_COPY_FILE")"
  cp "$(dirname "$0")/$FAKE_INSTALL_COPY_FILE" "$AGENT_TEMPLATE_INSTALL_DIR/$FAKE_INSTALL_COPY_FILE"
fi
mkdir -p "$AGENT_SYSTEMD_DIR"
printf '[Timer]\nOnBootSec=1m\n[Install]\nWantedBy=timers.target\n' > "$AGENT_SYSTEMD_DIR/fresh-update.timer"
printf '[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/bin/true\n[Install]\nWantedBy=default.target\n' > "$AGENT_SYSTEMD_DIR/fresh-update.service"
printf '%s\n' fresh-update.timer fresh-update.service agent-chat.service agent-board-poll@.timer >> "$AGENT_TEMPLATE_INSTALLED_UNITS_FILE"
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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -n "${AGENT_TEMPLATE_CORE_ROOT:-}" ]; then
  echo 'FAIL staged-core-root inherited installed tree'
  exit 1
fi
if [ "${EVAL_MODE:-green}" = red ]; then
  echo 'FAIL staged-release staged failure'
  echo '1 case(s) run, 1 failed'
  exit 1
fi
if [ -n "${EVAL_REJECT_FILE:-}" ] \
   && grep -qF "${EVAL_REJECT_TEXT:?}" "$ROOT/$EVAL_REJECT_FILE"; then
  echo 'FAIL staged-local-patch unsafe local patch'
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
  *"refs/tags/stable^{commit}"*) [ -z "${STABLE_REF:-}" ] || echo "$STABLE_REF" ;;
  *"show stable:VERSION"*) echo stable-version ;;
esac
exit 0
EOF
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$*" in
  '--user list-unit-files agent-board-poll@*.timer --state=enabled --no-legend --plain') printf '%s\n' 'agent-board-poll@.timer enabled' 'agent-board-poll@qa.timer enabled' 'agent-board-poll@worker.timer enabled'; exit 0 ;;
  '--user is-enabled agent-board-poll@.timer'|'--user is-enabled agent-board-poll@qa.timer'|'--user is-enabled agent-board-poll@worker.timer'|'--user is-enabled fresh-update.timer') exit 0 ;;
  '--user daemon-reload'|'--user enable fresh-update.service'|'--user start fresh-update.service'|'--user enable --now fresh-update.timer'|'--user enable agent-chat.service'|'--user start agent-chat.service'|'--user restart agent-chat.service'|'--user restart fresh-update.timer'|'--user restart agent-board-poll@qa.timer'|'--user restart agent-board-poll@worker.timer') exit 0 ;;
  '--user is-active fresh-update.service'|'--user is-active fresh-update.timer'|'--user is-active agent-chat.service') echo active; exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat > "$TMP/bin/update-board" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UPDATE_BOARD_LOG"
case "$*" in
  '--json project show '*) printf '%s\n' '{"sections":[{"title":"Backlog"},{"title":"Bugs"}]}' ;;
  'task list --project 15 --limit 100 --json') printf '%s\n' '{"tasks":[{"ticketNumber":"HEALTH-1","title":"Board health"}]}' ;;
  'comment add HEALTH-1 '*) printf '%s\n' '{"success":true}' ;;
  'task create --raw --project 5500 '*) printf '%s\n' '{"task":{"ticketNumber":"AGTE-999","projectId":5500,"uniqueIndex":999}}' ;;
  *) printf 'unexpected board command: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TEMPLATE/install.sh" "$TEMPLATE/scripts/sync-project.sh" \
  "$TEMPLATE/evals/run-evals.sh" "$TMP/bin/git" "$TMP/bin/systemctl" "$TMP/bin/update-board"

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
  HOME="$HOME_DIR" AGENT_SLUG="" AGENT_CONFIG_DIR="$CONF_DIR" AGENT_TEMPLATE_CONFIG_DIR="$CONF_DIR" \
    AGENT_TEMPLATE_HOST_CONFIG="$HOST_CONFIG" AGENT_TEMPLATE_REPO="$FAKE_REPO" \
    AGENT_SYSTEMD_DIR="$TMP/units" XDG_STATE_HOME="$TMP/state" \
    PATH="$TMP/bin:/usr/bin:/bin" GIT_LOG="$TMP/git.log" SYSTEMCTL_LOG="$TMP/systemctl.log" \
    UPDATE_BOARD_LOG="$TMP/update-board.log" WEBHOOK_LOG="$TMP/webhook.log" \
    AGENT_TEMPLATE_UPDATE_BOARD_CLI="$TMP/bin/update-board" \
    AGENT_TEMPLATE_UPDATE_HEALTH_BOARD=15 INSTALL_MARKER="$TMP/installed" \
    "$ROOT/scripts/agent-template" update "$@"
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

# A passing timer update restarts chat and every enabled timer instance, never
# the bare poll template, then posts Board health.
SUCCESS_INSTALLED="$TMP/success-installed"
mkdir -p "$SUCCESS_INSTALLED"
printf 'old-version\n' > "$SUCCESS_INSTALLED/VERSION"
: > "$TMP/systemctl.log"
: > "$TMP/update-board.log"
set +e
AGENT_TEMPLATE_INSTALL_DIR="$SUCCESS_INSTALLED" run_update --timer >"$TMP/timer-green.out" 2>"$TMP/timer-green.err"
status=$?
set -e
if [ "$status" -eq 0 ] \
   && grep -q '^--user restart agent-chat.service$' "$TMP/systemctl.log" \
   && grep -q '^--user restart fresh-update.timer$' "$TMP/systemctl.log" \
   && grep -q '^--user restart agent-board-poll@qa.timer$' "$TMP/systemctl.log" \
   && grep -q '^--user restart agent-board-poll@worker.timer$' "$TMP/systemctl.log" \
   && ! grep -q '^--user restart agent-board-poll@\.timer$' "$TMP/systemctl.log" \
   && grep -q '^comment add HEALTH-1 .*Toolkit test-version passed evals and is now installed' "$TMP/update-board.log"; then
  ok timer-update-restarts-instances "green update restarts every poll instance, never the bare template, then posts Board health"
else
  bad timer-update-restarts-instances "status=$status output=$(cat "$TMP/timer-green.out") systemctl=$(cat "$TMP/systemctl.log") board=$(cat "$TMP/update-board.log")"
fi

# An unchanged commit still reconciles webhooks without running evals, install, restarts, or another post.
printf 'test-version\n' > "$SUCCESS_INSTALLED/VERSION"
printf 'version=test-version\ncommit=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\ninstalled_at=1\n' > "$TMP/state/agent-template/install-state"
mkdir -p "$SUCCESS_INSTALLED/scripts"
cat > "$SUCCESS_INSTALLED/scripts/agent-events" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WEBHOOK_LOG"
EOF
chmod +x "$SUCCESS_INSTALLED/scripts/agent-events"
rm -f "$TMP/installed"
: > "$TMP/systemctl.log"
: > "$TMP/update-board.log"
: > "$TMP/webhook.log"
set +e
AGENT_TEMPLATE_INSTALL_DIR="$SUCCESS_INSTALLED" EVAL_MODE=red run_update --timer >"$TMP/timer-same.out" 2>"$TMP/timer-same.err"
status=$?
set -e
if [ "$status" -eq 0 ] && [ ! -e "$TMP/installed" ] \
   && grep -q '^toolkit test-version at deadbee is already installed$' "$TMP/timer-same.out" \
   && [ "$(cat "$TMP/webhook.log")" = "reconcile-all" ] \
   && [ ! -s "$TMP/systemctl.log" ] && [ ! -s "$TMP/update-board.log" ]; then
  ok unchanged-commit-noop "an unchanged five-minute check still reconciles managed webhooks"
else
  bad unchanged-commit-noop "status=$status output=$(cat "$TMP/timer-same.out") systemctl=$(cat "$TMP/systemctl.log") board=$(cat "$TMP/update-board.log")"
fi

# A newer commit installs even when the author did not change VERSION.
printf 'version=test-version\ncommit=oldcommit\ninstalled_at=1\n' > "$TMP/state/agent-template/install-state"
rm -f "$TMP/installed"
: > "$TMP/systemctl.log"
: > "$TMP/update-board.log"
set +e
AGENT_TEMPLATE_INSTALL_DIR="$SUCCESS_INSTALLED" run_update --timer >"$TMP/timer-new-commit.out" 2>"$TMP/timer-new-commit.err"
status=$?
set -e
if [ "$status" -eq 0 ] && [ -e "$TMP/installed" ] \
   && grep -q '^== 2\. stage and evaluate test-version ==$' "$TMP/timer-new-commit.out" \
   && grep -q '^comment add HEALTH-1 .*Toolkit test-version passed evals and is now installed' "$TMP/update-board.log"; then
  ok same-version-new-commit "a newer latest-channel commit reaches the host without a version bump"
else
  bad same-version-new-commit "status=$status output=$(cat "$TMP/timer-new-commit.out") board=$(cat "$TMP/update-board.log")"
fi

# A red staged suite refuses without invoking install and files one board ticket.
rm -f "$TMP/installed"
: > "$TMP/git.log"
: > "$TMP/update-board.log"
set +e
EVAL_MODE=red run_update --timer >"$TMP/red.out" 2>"$TMP/red.err"
status=$?
set -e
if [ "$status" -eq 0 ] && [ ! -e "$TMP/installed" ] \
   && grep -q '^update to test-version refused: 1 evals red$' "$TMP/red.out" \
   && [ "$(grep -c '^task create --raw --project 5500 ' "$TMP/update-board.log")" -eq 1 ]; then
  ok red-evals-refuse-swap "red staged evals keep the installed release and file one toolkit bug"
else
  bad red-evals-refuse-swap "status=$status installed=$([ -e "$TMP/installed" ] && echo yes || echo no) output=$(cat "$TMP/red.out") board=$(cat "$TMP/update-board.log")"
fi

set +e
EVAL_MODE=red run_update --timer >"$TMP/red-repeat.out" 2>"$TMP/red-repeat.err"
repeat_status=$?
set -e
if [ "$repeat_status" -eq 0 ] \
   && [ "$(grep -c '^task create --raw --project 5500 ' "$TMP/update-board.log")" -eq 1 ] \
   && grep -q '^eval failure ticket already filed for test-version at deadbee$' "$TMP/red-repeat.out"; then
  ok red-evals-ticket-deduplicated "the five-minute retry does not file another bug for the same commit"
else
  bad red-evals-ticket-deduplicated "status=$repeat_status output=$(cat "$TMP/red-repeat.out") board=$(cat "$TMP/update-board.log")"
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

# A local patch that breaks the incoming behavioural suite stays archived. The
# clean release installs instead of restoring code which silently removes a guard.
QUARANTINED="$TMP/quarantined-template"
mkdir -p "$QUARANTINED/scripts"
printf 'old-version\n' > "$QUARANTINED/VERSION"
printf 'release runner\n' > "$QUARANTINED/scripts/agent-board-poll"
(cd "$QUARANTINED" && sha256sum scripts/agent-board-poll > .manifest.sha256)
printf 'unsafe stale runner\n' > "$QUARANTINED/scripts/agent-board-poll"
printf 'incoming guarded runner\n' > "$TEMPLATE/scripts/agent-board-poll"
rm -f "$TMP/installed"
set +e
AGENT_TEMPLATE_INSTALL_DIR="$QUARANTINED" \
  FAKE_INSTALL_COPY_FILE="scripts/agent-board-poll" \
  EVAL_REJECT_FILE="scripts/agent-board-poll" EVAL_REJECT_TEXT="unsafe stale runner" \
  run_update >"$TMP/quarantined.out" 2>"$TMP/quarantined.err"
status=$?
set -e
if [ "$status" -eq 0 ] && [ -e "$TMP/installed" ] \
   && grep -qxF 'unsafe stale runner' "$QUARANTINED/local-patches/old-version/scripts/agent-board-poll" \
   && grep -qxF 'incoming guarded runner' "$QUARANTINED/scripts/agent-board-poll" \
   && grep -q 'local patches failed the incoming eval suite and remain archived without reapply' "$TMP/quarantined.out" \
   && ! grep -q 'local patch reapplied: scripts/agent-board-poll' "$TMP/quarantined.out"; then
  ok unsafe-local-patch-quarantined "a stale runner that removes a tested guard cannot replace the green release"
else
  bad unsafe-local-patch-quarantined "status=$status output=$(cat "$TMP/quarantined.out") installed=$(cat "$QUARANTINED/scripts/agent-board-poll")"
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
   && ! grep -q '^--user restart .*\.timer$' "$TMP/systemctl.log"; then
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

: > "$TMP/git.log"
set +e
HOME="$HOME_DIR" AGENT_TEMPLATE_HOST_CONFIG="$HOST_CONFIG" AGENT_TEMPLATE_REPO="$FAKE_REPO" \
  AGENT_TEMPLATE_INSTALL_STATE="$TMP/state/install-state" PATH="$TMP/bin:$PATH" GIT_LOG="$TMP/git.log" \
  STABLE_REF=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
  "$ROOT/scripts/agent-template" promote >"$TMP/promote-stable.out" 2>"$TMP/promote-stable.err"
status=$?
set -e
if [ "$status" -eq 0 ] \
   && grep -q '^promote skipped: stable already points to test-version ' "$TMP/promote-stable.out" \
   && ! grep -q 'tag -f stable' "$TMP/git.log"; then
  ok promote-skips-current-stable "five-minute checks do not reevaluate an already promoted release"
else
  bad promote-skips-current-stable "status=$status output=$(cat "$TMP/promote-stable.out") git=$(cat "$TMP/git.log")"
fi

if grep -q '^OnUnitActiveSec=5m$' "$ROOT/install.sh" \
   && ! grep -q '^OnCalendar=.*06:30' "$ROOT/install.sh"; then
  ok five-minute-update-timer "install writes a five-minute toolkit update schedule"
else
  bad five-minute-update-timer "install.sh does not contain the expected five-minute timer"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
