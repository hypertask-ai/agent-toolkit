#!/usr/bin/env bash
# create-agent.sh: provision a skills-driven agent identity.
#
# Board-agnostic core: name, slug, provider, mission, env file, state dir,
# a generic oneshot worker unit, and a chat test. Works with any repo.
#
# Dry-run is the default. Nothing is created, changed, or installed unless
# --yes is also passed.
#
# Never prints secrets. If you add board-specific wiring (an identity API,
# a webhook, a token) on top of this, write its secrets to 0600 files and
# reference them by path only, never print them.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# ---------- defaults ----------
NAME=""
KIND=""                # dev | qa | cli
PROVIDER="cursor"       # cursor | claude | codex
REPO=""
SKILLS_REPO="$HOME/projects/agent-skills"
MISSION_FILE=""
DRY_RUN="yes"
CONFIRM="no"
RESUME="no"

CONFIG_DIR="${AGENT_CONFIG_DIR:-$HOME/.config/agents}"
STATE_ROOT="${AGENT_STATE_ROOT:-$HOME/.local/state}"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

usage() {
  cat <<'EOF'
Usage: create-agent.sh --name "<Name>" --kind dev|qa|cli [options]

  --name NAME            Display name, e.g. "Cursor Dev 3"   (required)
  --kind dev|qa|cli       dev/qa run a worker; cli is env-only, no chat
  --provider cursor|claude|codex   default: cursor
  --repo PATH             repo the worker's cwd is set to (required for dev/qa)
  --skills-repo PATH       folder with INDEX.md          default: ~/projects/agent-skills
  --mission-file PATH      plain-text mission used verbatim instead of the template
  --resume                 finish an existing identity without replacing env values
  --yes                    actually do it
  --dry-run                print the plan, touch nothing    (default)
  -h, --help               this message
EOF
}

# ---------- args ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --kind) KIND="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --skills-repo) SKILLS_REPO="$2"; shift 2 ;;
    --mission-file) MISSION_FILE="$2"; shift 2 ;;
    --resume) RESUME="yes"; shift ;;
    --yes) CONFIRM="yes"; DRY_RUN="no"; shift ;;
    --dry-run) DRY_RUN="yes"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$NAME" ] || { echo "error: --name is required" >&2; exit 2; }
case "$KIND" in
  dev|qa|cli) ;;
  *) echo "error: --kind must be dev, qa, or cli" >&2; exit 2 ;;
esac
case "$PROVIDER" in
  cursor|claude|codex) ;;
  *) echo "error: --provider must be cursor, claude, or codex" >&2; exit 2 ;;
esac

# ---------- slug ----------
SLUG="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
if [ "$KIND" = "cli" ]; then
  DISPLAY_NAME="$NAME CLI"
else
  DISPLAY_NAME="$NAME"
fi

# An identity check is board-specific (it needs an API to ask "does this
# name already exist"). This template has none, so --resume here only
# controls whether local env values get overwritten (see write_missing_keys
# below). If you wire this into a real board, add a read-only existence
# check here, before any local file is touched, and exit with a message
# telling the caller to pass --resume instead of creating a duplicate.

if [ "$KIND" != "cli" ] && [ -z "$REPO" ]; then
  echo "error: --repo is required for --kind $KIND" >&2
  exit 2
fi
if [ -n "$REPO" ] && [ ! -d "$REPO" ]; then
  echo "error: --repo $REPO does not exist" >&2
  exit 2
fi
if [ -n "$MISSION_FILE" ] && [ ! -f "$MISSION_FILE" ]; then
  echo "error: --mission-file $MISSION_FILE does not exist" >&2
  exit 2
fi
INDEX_MD="$SKILLS_REPO/INDEX.md"
if [ ! -f "$INDEX_MD" ]; then
  echo "warning: $INDEX_MD not found: the mission points at a file that isn't there yet" >&2
else
  DOMAIN_WORDS="$(printf '%s' "$SLUG" | tr '-' '\n' | awk 'length($0) > 2 && $0 !~ /^(agent|assistant|bot|claude|cli|codex|cursor|dev|qa|worker)$/')"
  if [ -n "$DOMAIN_WORDS" ]; then
    DOMAIN_PATTERN="$(printf '%s\n' "$DOMAIN_WORDS" | paste -sd '|' -)"
    if ! grep -Eiq "$DOMAIN_PATTERN" "$INDEX_MD"; then
      echo "warning: $INDEX_MD has no match for domain words: $(printf '%s' "$DOMAIN_WORDS" | paste -sd ',' -)" >&2
      echo "warning: create the domain skill before running the chat test" >&2
    fi
  fi
fi

STATE_DIR="$STATE_ROOT/agent-$SLUG"
ENV_FILE="$CONFIG_DIR/$SLUG.env"
WRAPPER="$BIN_DIR/$SLUG"

echo "=== plan: $DISPLAY_NAME ($SLUG), kind=$KIND, provider=$PROVIDER ==="
[ "$DRY_RUN" = "yes" ] && echo "(dry run: no changes below are executed)"
[ "$RESUME" = "yes" ] && echo "(resume: existing env values are preserved, only missing keys are added)"
echo

STEP=0
plan() {
  STEP=$((STEP + 1))
  echo "[$STEP] $1"
}
run() {
  # run <description> -- <command...>
  local desc="$1"; shift
  [ "$1" = "--" ] && shift
  plan "$desc"
  echo "    + $*"
  if [ "$DRY_RUN" != "yes" ]; then
    "$@"
  fi
}
write_missing_keys() {
  # Create a config file, or append only assignments whose keys are absent.
  # This is what makes reruns (--resume) safe: an existing value is never
  # clobbered, only missing keys get added.
  local path="$1" content="$2"
  CONTENT="$content" python3 - "$path" <<'PYEOF'
import os,re,sys
path=sys.argv[1]; content=os.environ["CONTENT"]
blocks=[b for b in re.split(r"(?m)(?=^[A-Z][A-Z0-9_]*=)", content) if b]
existing=""
if os.path.exists(path):
    with open(path) as f:
        existing=f.read()
keys=set(re.findall(r"(?m)^([A-Z][A-Z0-9_]*)=", existing))
missing=[b for b in blocks if b.split("=",1)[0] not in keys]
if not os.path.exists(path):
    with open(path,"w") as f:
        f.write(content + "\n")
elif missing:
    with open(path,"a") as f:
        if existing and not existing.endswith("\n"):
            f.write("\n")
        f.write("".join(missing).rstrip("\n") + "\n")
os.chmod(path,0o600)
PYEOF
}

# ---------- mission text ----------
if [ -n "$MISSION_FILE" ]; then
  MISSION="$(cat "$MISSION_FILE"; printf x)"
  MISSION="${MISSION%x}"
elif [ "$KIND" = "qa" ]; then
  MISSION="You are $DISPLAY_NAME. You verify, you never fix. Read the literal absolute path $INDEX_MD first, then only the skill(s) it points you to for verification, and follow them exactly. Post which skill you used in your first comment. Corrections go into the skill file, not into chat."
else
  MISSION="You are $DISPLAY_NAME. Step one, before anything else: open the file at the literal absolute path $INDEX_MD (a tilde will not resolve in your home) and name the skill(s) whose trigger matches this task in your first comment or reply. Then follow the matched skill file(s) exactly, including their saved scripts. If no skill matches, say so and stop. Corrections go into the skill file, never into chat memory."
fi
DOMAIN_LABEL="${DOMAIN_WORDS:-${SLUG//-/ }}"
DOMAIN_LABEL="$(printf '%s' "$DOMAIN_LABEL" | tr '\n' ' ')"
CHAT_QUESTION="Describe how you would handle a representative $DOMAIN_LABEL task. Name the skill you would use and the evidence you would report."

echo "Mission (${#MISSION} chars):"
echo "  $MISSION"
echo

# ============================================================
# CORE: works for any provider, any repo
# ============================================================

run "make config dir 0700" -- mkdir -p "$CONFIG_DIR"
run "make state dir" -- mkdir -p "$STATE_DIR"

if [ "$KIND" = "cli" ]; then
  # env file only, no worker, cannot chat
  ENV_CONTENT="$(cat <<EOF
AGENT_NAME="$DISPLAY_NAME"
AGENT_SLUG="$SLUG"
AGENT_KIND="cli"
AGENT_PROVIDER="$PROVIDER"
AGENT_MISSION="$MISSION"
EOF
)"
  plan "create $ENV_FILE (0600), or add only missing keys; env-only identity, cannot chat"
  echo "    + preserve existing values in $ENV_FILE; add missing keys only"
  if [ "$DRY_RUN" != "yes" ]; then
    umask 077
    write_missing_keys "$ENV_FILE" "$ENV_CONTENT"
  fi
  echo
  echo "Note: a CLI identity has no worker. It shows up in logs and commit"
  echo "trails under its own name; there is no chat test to run for it."
else
  ENV_CONTENT="$(cat <<EOF
AGENT_NAME="$DISPLAY_NAME"
AGENT_SLUG="$SLUG"
AGENT_KIND="$KIND"
AGENT_PROVIDER="$PROVIDER"
AGENT_REPO="$REPO"
AGENT_SKILLS_INDEX="$INDEX_MD"
EOF
)"
  plan "create $ENV_FILE (0600), or add only missing keys"
  echo "    + preserve existing values in $ENV_FILE; add missing keys only"
  if [ "$DRY_RUN" != "yes" ]; then
    umask 077
    write_missing_keys "$ENV_FILE" "$ENV_CONTENT"
  fi

  # generic per-repo trigger wrapper + a oneshot systemd unit
  case "$PROVIDER" in
    claude) PROVIDER_CMD='claude -p "$PROMPT"' ;;
    cursor) PROVIDER_CMD='cursor-agent -p "$PROMPT"' ;;
    codex)  PROVIDER_CMD='codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT"' ;;
  esac
  printf -v MISSION_SHELL '%q' "$MISSION"
  WRAPPER_CONTENT="$(cat <<EOF
#!/usr/bin/env bash
# $SLUG: generic trigger wrapper. Usage: $SLUG run "<task text>"
set -euo pipefail
cd "$REPO"
MISSION=$MISSION_SHELL
TASK="\${2:-\$1}"
PROMPT="\$MISSION

Task: \$TASK"
$PROVIDER_CMD
EOF
)"
  plan "write $WRAPPER (0755): manual/cron trigger, cwd=$REPO"
  echo "    + printf '%s\n' \"\$WRAPPER_CONTENT\" > $WRAPPER && chmod 755 $WRAPPER"
  if [ "$DRY_RUN" != "yes" ]; then
    printf '%s\n' "$WRAPPER_CONTENT" > "$WRAPPER"
    chmod 755 "$WRAPPER"
  fi

  UNIT_PATH="$SYSTEMD_USER_DIR/agent-worker-$SLUG.service"
  UNIT_CONTENT="$(cat <<EOF
[Unit]
Description=$DISPLAY_NAME: one run of the skills-driven worker

[Service]
Type=oneshot
WorkingDirectory=$REPO
ExecStart=$WRAPPER run "\${TASK}"
EOF
)"
  plan "write generic oneshot unit $UNIT_PATH (one process per event)"
  echo "    + printf '%s\n' \"\$UNIT_CONTENT\" > $UNIT_PATH"
  if [ "$DRY_RUN" != "yes" ]; then
    mkdir -p "$SYSTEMD_USER_DIR"
    printf '%s\n' "$UNIT_CONTENT" > "$UNIT_PATH"
    systemctl --user daemon-reload
  fi

  # Chat test: ask about the domain and quote the reply exactly.
  plan "chat test: send the mission + a domain question to the $PROVIDER CLI"
  echo "    + $WRAPPER run \"$CHAT_QUESTION\""
  if [ "$DRY_RUN" != "yes" ]; then
    CHAT_REPLY="$("$WRAPPER" run "$CHAT_QUESTION")"
    printf 'Chat test reply (verbatim):\n%s\n' "$CHAT_REPLY"
  fi
fi

echo
echo "=== Check before you say done ==="
cat <<EOF
  [ ] a matching domain skill exists in $SKILLS_REPO/INDEX.md
  [ ] chat test asked a domain question and its reply is quoted verbatim
  [ ] $ENV_FILE is 0600
EOF

echo
if [ "$DRY_RUN" = "yes" ]; then
  echo "Dry run only. Re-run with --yes to actually create $DISPLAY_NAME."
fi
