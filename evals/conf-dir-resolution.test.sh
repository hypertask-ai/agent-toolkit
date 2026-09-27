#!/usr/bin/env bash
# Manager commands must find the adapter's config directory without env hints.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

slug="fallback"
CONF_DIR="$TMP/home/.config/hypertask-agents"
SHIM="$TMP/state/agent-identity-shims/$slug"
mkdir -p "$CONF_DIR" "$SHIM" "$TMP/bin" "$TMP/state"
cat > "$CONF_DIR/$slug.conf" <<EOF
AGENT_SLUG="$slug"
AGENT_NAME="Fallback Manager"
AGENT_KIND="worker"
AGENT_ID="agent-fallback"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/bin/board"
MODEL_CLI="provider"
MANAGER="on"
MAINTAINER="on"
EOF
printf 'token\n' > "$TMP/token"
cat > "$TMP/bin/board" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BOARD_LOG"
case "$*" in
  '--json project show 5500') printf '%s\n' '{"project":{"defaultSections":["Inbox"],"sections":[{"section_title":"Inbox"}]}}' ;;
  'project labels 5500') printf '%s\n' '{"labels":[{"name":"bug"},{"name":"adapter:hypertask"}]}' ;;
  task\ create*) printf '%s\n' '{"task":{"id":"task-101","ticketNumber":"AGTE-101","projectId":5500,"uniqueIndex":101}}' ;;
  'task assign AGTE-101 --self') printf '%s\n' '{}' ;;
esac
EOF
chmod +x "$TMP/bin/board"
: > "$TMP/board.log"

run_template() {
  env -u AGENT_CONFIG_DIR -u AGENT_SLUG \
    HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" BOARD_LOG="$TMP/board.log" \
    PATH="$SHIM:$TMP/bin:$PATH" "$ROOT/scripts/agent-template" "$@"
}

feedback="$(run_template feedback --as "$slug" --kind bug \
  --what 'Adapter config fallback regression' --got 'not found' --expected 'found')"
if printf '%s\n' "$feedback" | grep -qF 'Ticket: AGTE-101 https://app.hypertask.ai/detail/project-5500/101' \
   && grep -q '^task create --project 5500 ' "$TMP/board.log"; then
  ok feedback-adapter-conf-fallback 'feedback --as finds only the Hypertask default conf'
else
  bad feedback-adapter-conf-fallback "output=$feedback board=$(cat "$TMP/board.log")"
fi

instruction="$(run_template instruct "$slug" 'Review the adapter config fallback')"
instruction_file="$(find "$TMP/state/agent-board-poll/$slug-instructions" -name '*.json' -print -quit 2>/dev/null || true)"
marker="$(find "$TMP/state/agent-template/instruction-tickets" -name '*.json' -print -quit 2>/dev/null || true)"
if [[ "$instruction" == 'instruction filed: AGTE-101 '* ]] \
   && [ -z "$instruction_file" ] && [ -n "$marker" ] \
   && grep -q '^task assign AGTE-101 --self$' "$TMP/board.log"; then
  ok instruct-adapter-conf-fallback 'instruct finds the Hypertask conf and its agent board CLI'
else
  bad instruct-adapter-conf-fallback "output=$instruction file=${instruction_file:-none} marker=${marker:-missing}"
fi


mkdir -p "$CONF_DIR/Hypertask Product" "$CONF_DIR/Another Board" "$CONF_DIR/retired"
printf 'BOARD_ID="15"\n' > "$CONF_DIR/retired/retired-only.conf"
cp "$CONF_DIR/fallback.conf" "$CONF_DIR/Hypertask Product/fallback.conf"
printf 'BOARD_ID="5500,15"\n' > "$CONF_DIR/Another Board/multi.conf"
printf 'BOARD_ID="15"\n' > "$CONF_DIR/Hypertask Product/dev-1.conf"
# Source the same resolver that poll, create-agent and the manager use.
lookup="$(HOME="$TMP/home" AGENT_CONFIG_DIR="$CONF_DIR" CORE_ROOT="$ROOT" bash -c '
  . "$CORE_ROOT/scripts/lib/core.sh"
  core_find_conf fallback; printf "\n"; core_find_conf multi; printf "\n"
  core_find_conf dev-1
  if core_find_conf retired-only >/dev/null; then exit 1; fi
')"
if [ "$lookup" = "$(printf '%s\n%s\n%s' "$CONF_DIR/Hypertask Product/fallback.conf" "$CONF_DIR/Another Board/multi.conf" "$CONF_DIR/Hypertask Product/dev-1.conf")" ]; then
  ok folder-slug-lookup 'board folders win over flat files; multi-board agents use their slug'
else
  bad folder-slug-lookup "lookup=$lookup"
fi

if PYTHONPATH="$ROOT/scripts" python3 - "$CONF_DIR" <<'PYEOF'
from pathlib import Path
from config_files import config_files
import sys
root = Path(sys.argv[1])
rows = {path.stem: path for path in config_files(root)}
assert rows["fallback"] == root / "Hypertask Product/fallback.conf"
assert rows["multi"] == root / "Another Board/multi.conf"
assert rows["dev-1"] == root / "Hypertask Product/dev-1.conf"
assert "retired-only" not in rows
PYEOF
then
  ok python-folder-discovery 'status and event scanners share slug-first folder discovery'
else
  bad python-folder-discovery 'Python config file enumeration failed'
fi

cat > "$TMP/bin/hypertask" <<'CLI'
#!/usr/bin/env bash
case " $* " in
  *' --json project show 15 '*) printf '%s\n' '{"project":{"title":"Hypertask Product"}}' ;;
  *' agents list '*) printf '%s\n' '{"agents":[]}' ;;
esac
CLI
chmod +x "$TMP/bin/hypertask"
mkdir -p "$TMP/repo"
: > "$TMP/INDEX.md"
create_plan="$(HOME="$TMP/home" AGENT_CONFIG_DIR="$CONF_DIR" PATH="$TMP/bin:$PATH" \
  COMPANY_SKILLS_INDEX= "$ROOT/scripts/create-agent.sh" --name 'New Bot' \
  --board hypertask --project 15,5500 --repo "$TMP/repo" --pr-repo org/repo \
  --skills-index "$TMP/INDEX.md" --dry-run 2>&1)"
if [[ "$create_plan" == *"$CONF_DIR/Hypertask Product/new-bot.conf"* ]] && [ ! -e "$CONF_DIR/Hypertask Product/new-bot.conf" ]; then
  ok board-folder-create 'first board title is used for a new multi-board agent'
else
  bad board-folder-create "plan=$create_plan"
fi
if HOME="$TMP/home" AGENT_CONFIG_DIR="$CONF_DIR" PATH="$TMP/bin:$PATH" \
  COMPANY_SKILLS_INDEX= "$ROOT/scripts/create-agent.sh" --name 'Dev 1' \
  --board hypertask --project 15 --repo "$TMP/repo" --pr-repo org/repo \
  --skills-index "$TMP/INDEX.md" --dry-run > "$TMP/duplicate.out" 2>&1; then
  bad duplicate-folder-slug 'create accepted an existing slug in a board folder'
else
  ok duplicate-folder-slug 'create rejects an existing slug in any board folder'
fi

MIGRATION_DIR="$TMP/migration"
mkdir -p "$MIGRATION_DIR"
for slug in dev-1 dev-2 qa-1; do printf 'BOARD_ID="15"\n' > "$MIGRATION_DIR/$slug.conf"; done
printf 'BOARD_ID="2101"\n' > "$MIGRATION_DIR/support.conf"
install_plan="$(HOME="$TMP/home" AGENT_CONFIG_DIR="$MIGRATION_DIR" \
  "$ROOT/install.sh" --dry-run --no-host-notes 2>&1)"
if [ "$(printf '%s\n' "$install_plan" | grep -c '^would move .* into Hypertask Product$')" -eq 3 ] \
   && [ -f "$MIGRATION_DIR/support.conf" ] && [ -f "$MIGRATION_DIR/dev-1.conf" ]; then
  ok migration-limited 'install plans only the three Product agents and dry-run changes nothing'
else
  bad migration-limited "plan=$install_plan"
fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
