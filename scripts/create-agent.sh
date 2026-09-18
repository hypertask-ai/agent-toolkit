#!/usr/bin/env bash
# create-agent.sh: provision a skills-driven agent identity.
#
# Core is generic. An agent is a name, a mission, a skills index, a model CLI
# and a place to work. Anything that talks to a specific tracker lives behind
# an adapter in adapters/<name>/adapter.sh, and nothing here knows about a
# particular host, fleet or machine.
#
# Three wiring modes decide how work reaches the agent:
#   poll   (default) a timer runs one tick per minute; needs only the board CLI
#          and a model CLI on this machine
#   fleet  hand the agent to a long-lived worker runtime, allowed only where
#          the adapter says that runtime is installed
#   none   identity and skills index only; you trigger it yourself
#
# Dry-run is the default: nothing is created, changed or installed without
# --yes. Creating a real identity has its own hard stop on top of that.
#
# Never prints a token. Tokens land in 0600 files and are referenced by path.
#
# Examples:
#   create-agent.sh --name "CRO Bot" --board <adapter> --project <board id> \
#       --repo /home/me/projects/site --wiring poll --dry-run
#   create-agent.sh --name "Repo Bot" --board none --repo /home/me/projects/x --yes

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
CORE_ROOT="$(dirname "$(dirname "$SELF")")"
# shellcheck disable=SC1091
. "$CORE_ROOT/scripts/lib/core.sh"

# ---------- defaults ----------
NAME=""
KIND="worker"
BOARD="none"
BOARD_ID=""
REPO=""
SKILLS_REPO=""
# PR_REPO: the agent's own memory repo, org/name on GitHub, distinct from
# --repo above (a local working-directory path). Every agent needs one now
# (agent-board-poll refuses to tick without PR_REPO), so this flag creates it
# private from the skeleton in ../repo-skeleton when it does not exist yet,
# and always writes PR_REPO into the conf.
PR_REPO=""
# Checkouts to lay the standard agent layout into. --repo's checkout is added
# to this list below, so an agent's own repo is always synced.
SYNC_PROJECTS=""
SKILLS_INDEX=""
# The shared pack, cloned by install.sh. Override for a company that keeps
# its own somewhere else, or point it at nothing to provision a single-pack bot.
COMPANY_SKILLS_INDEX="${COMPANY_SKILLS_INDEX:-$HOME/projects/company-skills/INDEX.md}"
MISSION_FILE=""
WIRING="poll"
SECTIONS=""
PROVIDER="cursor"
MODEL_CLI=""
MODEL_CLI_SET="no"
MAX_CONCURRENT_RUNS="1"
CHAT_PAGE="yes"
QUIET="on"
ROLE="write"
DRY_RUN="yes"
CONFIRM="no"
RESUME="no"

BIN_DIR="${AGENT_BIN_DIR:-$HOME/.local/bin}"
SYSTEMD_USER_DIR="${AGENT_SYSTEMD_DIR:-$HOME/.config/systemd/user}"

usage() { sed -n '2,25p' "$SELF" | sed 's/^# \{0,1\}//'; cat <<'EOF'

Options:
  --name NAME              display name                              (required)
  --kind dev|qa|worker|cli what the agent does; cli is an env-only identity
  --board NAME             adapter to use: see adapters/            (default none)
  --project ID             board id inside that adapter
  --repo PATH              absolute repo path the agent works in
  --pr-repo ORG/NAME       the agent's own memory repo on GitHub; created
                           private from the skeleton if it does not exist
  --sync-project PATH      lay the standard agent layout into an existing
                           checkout (.claude/skills/, AGENTS.md, board.yml,
                           the evals and the pr-title check). Repeatable.
                           Run automatically for --repo's checkout.
  --skills-repo PATH       folder holding INDEX.md
  --skills-index PATH      the index file itself, if it is not <skills-repo>/INDEX.md
  --mission-file PATH      plain-text mission, used verbatim
  --wiring poll|events|fleet|none how work reaches the agent        (default poll)
  --sections "A,B"         board columns the poll watches
  --provider cursor|pi     starter command to write                     (default cursor)
  --model-cli "CMD"        full command; overrides --provider
  --max-concurrent N       runs started per tick                    (default 1)
  --chat-page yes|no       enable the host chat lane               (default yes)
  --role ROLE              identity role on the board               (default write)
  --resume                 finish an existing identity, keep every existing value
  --yes                    actually do it
  --dry-run                print the plan, change nothing           (default)
  -h, --help               this message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --kind) KIND="$2"; shift 2 ;;
    --board) BOARD="$2"; shift 2 ;;
    --project|--board-id) BOARD_ID="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --pr-repo) PR_REPO="$2"; shift 2 ;;
    --sync-project) SYNC_PROJECTS="$SYNC_PROJECTS${SYNC_PROJECTS:+ }$2"; shift 2 ;;
    --skills-repo) SKILLS_REPO="$2"; shift 2 ;;
    # Repeatable, or one comma-separated list. Order matters: the shared
    # company pack first, this bot's own pack last.
    --skills-index) if [ -n "$SKILLS_INDEX" ]; then SKILLS_INDEX="$SKILLS_INDEX,$2"; else SKILLS_INDEX="$2"; fi; shift 2 ;;
    --mission-file) MISSION_FILE="$2"; shift 2 ;;
    --wiring) WIRING="$2"; shift 2 ;;
    --sections) SECTIONS="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --model-cli) MODEL_CLI="$2"; MODEL_CLI_SET="yes"; shift 2 ;;
    --max-concurrent) MAX_CONCURRENT_RUNS="$2"; shift 2 ;;
    --chat-page) CHAT_PAGE="$2"; shift 2 ;;
    --role) ROLE="$2"; shift 2 ;;
    --resume) RESUME="yes"; shift ;;
    --yes) CONFIRM="yes"; DRY_RUN="no"; shift ;;
    --dry-run) DRY_RUN="yes"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument $1" "run create-agent.sh --help for the accepted flags" ;;
  esac
done

if [ "$MODEL_CLI_SET" = "no" ]; then
  case "$PROVIDER" in
    cursor) MODEL_CLI="cursor-agent -p --output-format text --model cursor-grok-4.6-high-fast -f --trust" ;;
    pi) MODEL_CLI="pi --print --tools read,bash,edit,write --no-extensions --no-skills --provider zai --model glm-5.3-flash" ;;
    *) die "--provider must be cursor or pi, got '$PROVIDER'" \
         "pick one of those choices, or pass the complete command with --model-cli" ;;
  esac
fi
[ -n "$MODEL_CLI" ] || die "the model command is empty" \
  "pass --provider cursor|pi or --model-cli '<full command>'"

[ -n "$NAME" ] || die "--name is missing" "pass --name \"<Display Name>\""
case "$KIND" in dev|qa|worker|cli) ;; *) die "--kind must be dev, qa, worker or cli, got '$KIND'" "pick one of those four" ;; esac
case "$WIRING" in poll|events|fleet|none) ;; *) die "--wiring must be poll, events, fleet or none, got '$WIRING'" "use poll unless this host has a public HTTPS event route" ;; esac
case "$CHAT_PAGE" in yes|no) ;; *) die "--chat-page must be yes or no" "pass --chat-page yes or --chat-page no" ;; esac
if [ "$KIND" = "cli" ] || [ "$BOARD" = "none" ]; then CHAT_PAGE="no"; fi
CHAT="off"
[ "$CHAT_PAGE" = "yes" ] && CHAT="on"
if [ -n "$PR_REPO" ]; then
  case "$PR_REPO" in
    */*) ;;
    *) die "--pr-repo must be org/name, got '$PR_REPO'" "pass the GitHub org and repo name, e.g. hypertask-ai/product-bot" ;;
  esac
fi

core_load_adapter "$BOARD"
adapter_require_tools

SLUG="$(core_slug "$NAME")"
DISPLAY_NAME="$NAME"
if [ "$KIND" = "cli" ]; then DISPLAY_NAME="$NAME CLI"; fi

# --resume means "keep every existing value": a flag left off this call is
# not "unset", it is "use whatever the conf already has". Read those back
# (not sourced, so an unrelated key in the existing conf cannot shadow a
# variable this script itself uses) before the flags below get validated,
# so resuming an identity that was provisioned repo-less on purpose (an
# answer/Q&A kind with no code to work in, like Product Bot) does not force
# a --repo it never needed, and resuming one that already has a skills
# index does not force --skills-index/--skills-repo again either.
EXISTING_CONF="$(core_config_dir)/$SLUG.conf"
if [ "$RESUME" = "yes" ] && [ -f "$EXISTING_CONF" ]; then
  [ -n "$REPO" ] || REPO="$(sed -n 's/^AGENT_REPO="\(.*\)"$/\1/p' "$EXISTING_CONF" | tail -1)"
  [ -n "$SKILLS_INDEX" ] || SKILLS_INDEX="$(sed -n 's/^SKILLS_INDEX="\(.*\)"$/\1/p' "$EXISTING_CONF" | tail -1)"
  [ -n "$BOARD_ID" ] || BOARD_ID="$(sed -n 's/^BOARD_ID="\(.*\)"$/\1/p' "$EXISTING_CONF" | tail -1)"
fi

if [ -n "$REPO" ]; then core_require_abs "$REPO" "--repo"; fi
if [ -n "$REPO" ] && [ ! -d "$REPO" ]; then
  die "--repo $REPO does not exist" "create the checkout first, or pass the right path"
fi
if [ "$KIND" != "cli" ] && [ -z "$REPO" ] \
   && ! ([ "$RESUME" = "yes" ] && [ -f "$EXISTING_CONF" ]); then
  die "--repo is missing and --kind $KIND needs somewhere to work" \
      "pass --repo /absolute/path/to/the/repo"
fi

# ---------- skills index ----------
if [ -z "$SKILLS_INDEX" ]; then
  [ -n "$SKILLS_REPO" ] || die "neither --skills-index nor --skills-repo was given" \
    "point the agent at a skills index: an agent with no skills has nothing to follow"
  SKILLS_INDEX="$SKILLS_REPO/INDEX.md"
  # Two packs: the company pack every bot reads first, then this bot's own.
  # Prepended only when it is actually on this host and is not already the
  # pack we just picked, so a machine without it still provisions.
  if [ -f "$COMPANY_SKILLS_INDEX" ] && [ "$COMPANY_SKILLS_INDEX" != "$SKILLS_INDEX" ]; then
    SKILLS_INDEX="$COMPANY_SKILLS_INDEX,$SKILLS_INDEX"
  fi
fi
SKILLS_INDEX_PRIMARY="$(core_skill_index_at "$SKILLS_INDEX" first)"
SKILLS_INDEX_LAST="$(core_skill_index_at "$SKILLS_INDEX" last)"
for one in $(core_skill_indexes "$SKILLS_INDEX"); do
  core_require_abs "$one" "--skills-index"
  [ -f "$one" ] || warn "$one does not exist yet: create it before the first run"
done
# The domain check looks at the BOT pack, the last one in the list: the
# company pack is generic by definition and would match nothing.
if [ -f "$SKILLS_INDEX_LAST" ]; then
  DOMAIN_WORDS="$(printf '%s' "$SLUG" | tr '-' '\n' | awk 'length($0) > 2 && $0 !~ /^(agent|assistant|bot|claude|cli|codex|cursor|dev|qa|worker)$/')"
  if [ -n "$DOMAIN_WORDS" ]; then
    DOMAIN_PATTERN="$(printf '%s\n' "$DOMAIN_WORDS" | paste -sd '|' -)"
    if ! grep -Eiq "$DOMAIN_PATTERN" "$SKILLS_INDEX_LAST"; then
      warn "$SKILLS_INDEX_LAST has no match for domain words: $(printf '%s' "$DOMAIN_WORDS" | paste -sd ',' -): create the domain skill before running the chat test"
    fi
  fi
fi

# ---------- wiring gate ----------
if [ "$WIRING" = "fleet" ] && ! adapter_supports_fleet_wiring; then
  die "fleet wiring was asked for, but this machine has no worker runtime for the '$BOARD' adapter" \
      "re-run with --wiring poll, which needs only the board CLI and a model CLI on this machine"
fi
if [ "$BOARD" = "none" ] && { [ "$WIRING" = "poll" ] || [ "$WIRING" = "events" ]; }; then
  WIRING="none"
  warn "no board adapter, so there is nothing to poll: wiring set to none"
fi

# ---------- paths ----------
CONFIG_DIR="$(core_config_dir)"
CONF_FILE="$CONFIG_DIR/$SLUG.conf"
TOKEN_FILE="$CONFIG_DIR/credentials/$SLUG-agent-token"
BOARD_CLI="$BIN_DIR/$SLUG-board"
if [ -z "$SECTIONS" ]; then
  [ "$KIND" = "qa" ] && SECTIONS="AI Review,QA" || SECTIONS="In Progress,Backlog"
elif [ "$KIND" = "qa" ] && [ "$SECTIONS" != "*" ] \
   && ! printf '%s\n' "$SECTIONS" | tr ',' '\n' | grep -Eiq '^[[:space:]]*QA[[:space:]]*$'; then
  SECTIONS="$SECTIONS,QA"
fi

# ---------- mission ----------
if [ -n "$MISSION_FILE" ]; then
  [ -f "$MISSION_FILE" ] || die "--mission-file $MISSION_FILE does not exist" "pass a file that is there"
  MISSION="$(cat "$MISSION_FILE")"
elif [ "$KIND" = "qa" ]; then
  MISSION="You are $DISPLAY_NAME. You verify, you never fix. Read the literal absolute path $SKILLS_INDEX first, then only the skills it points you to, and follow them exactly. Record the skill you used in the run log, not a ticket comment. Corrections go into the skill file, not into chat, committed in the same run, never a pull request. A fact (a number, a name, a date, a path) goes into a doc or the ticket, never into a skill; a rule (always or never do X) goes into the skill file. A session looking after you reads MAINTAINER.md next to this conf."
else
  MISSION="You are $DISPLAY_NAME. Step one, before anything else: open the file at the literal absolute path $SKILLS_INDEX and record the skill whose trigger matches this task in the run log, not a ticket comment. Then follow that skill exactly, including its scripts. If no skill matches, say so and stop. Corrections go into the skill file, never into chat memory, committed in the same run, never a pull request. A fact (a number, a name, a date, a path) goes into a doc or the ticket, never into a skill; a rule (always or never do X) goes into the skill file. Unsure which: would it still be true for a different customer? Yes is a rule, no is a fact. A session looking after you reads MAINTAINER.md next to this conf."
fi

# ---------- existing identity ----------
AGENT_ID=""
IDENTITY_EXISTS="no"
if [ "$BOARD" != "none" ]; then
  [ -n "$BOARD_ID" ] || die "--project is missing and the '$BOARD' adapter needs a board id" \
    "pass --project <id>"
  AGENT_ID="$(adapter_find_identity "$DISPLAY_NAME" "$SLUG" || true)"
  if [ -n "$AGENT_ID" ]; then
    IDENTITY_EXISTS="yes"
    [ "$RESUME" = "yes" ] || die \
      "an identity named $DISPLAY_NAME already exists on this board" \
      "re-run with --resume to finish the missing steps without touching what is already there"
    echo "identity exists ($AGENT_ID): --resume keeps every existing value and adds only what is missing"
  fi
fi

# ---------- plan ----------
echo "=== plan: $DISPLAY_NAME ($SLUG) ==="
echo "  kind      $KIND"
echo "  board     $BOARD${BOARD_ID:+ (id $BOARD_ID)}"
echo "  wiring    $WIRING"
echo "  repo      ${REPO:-none}"
echo "  pr-repo   ${PR_REPO:-none (agent-board-poll will refuse to tick without one)}"
echo "  skills    $SKILLS_INDEX"
echo "            (read in order: company pack first, bot pack last)"
echo "  model CLI $MODEL_CLI"
if [ "$CHAT" = "on" ]; then
  echo "  chat      on (https://app.hypertask.ai/agents/chat?agent=$SLUG)"
else
  echo "  chat      off"
fi
echo "  conf      $CONF_FILE"
echo "  token     $TOKEN_FILE (0600, never printed)"
if [ "$DRY_RUN" = "yes" ]; then echo "  (dry run: nothing below is executed)"; fi
echo

step() { printf '[%s] %s\n' "$1" "$2"; }

# ---------- 1. identity and token ----------
if [ "$BOARD" != "none" ] && [ "$IDENTITY_EXISTS" = "no" ]; then
  step 1 "create the identity on the $BOARD board (this makes a real account)"
  echo "    hard stop: this step does not run without --yes"
  if [ "$DRY_RUN" != "yes" ] && [ "$CONFIRM" = "yes" ]; then
    # The token is printed exactly once, by this call. Capture it straight to a
    # 0600 file; never let it reach stdout, a log, or a shell variable that
    # something else might echo.
    CREATE_OUT="$(mktemp)"
    chmod 600 "$CREATE_OUT"
    trap 'rm -f "$CREATE_OUT"' EXIT
    ( umask 077; adapter_create_identity "$DISPLAY_NAME" "$BOARD_ID" "$ROLE" > "$CREATE_OUT" ) \
      || die "the create call failed; its output is in $CREATE_OUT" \
             "read that file, fix the cause, and re-run with --resume"
    AGENT_ID="$(adapter_extract_identity_id "$CREATE_OUT" || true)"
    TOKEN_TMP="$(mktemp)"
    chmod 600 "$TOKEN_TMP"
    if ! adapter_extract_token "$CREATE_OUT" > "$TOKEN_TMP"; then
      rm -f "$TOKEN_TMP" "$CREATE_OUT"
      die "token not captured" \
          "run \`$(adapter_rotate_token_hint "${AGENT_ID:-<agent_id>}")\` with the owner's go-ahead and save the token to $TOKEN_FILE"
    fi
    # Redirection, not a pipe: a pipe would run the checks in a subshell and a
    # failed check there could not stop this script.
    core_save_secret "$TOKEN_FILE" < "$TOKEN_TMP"
    rm -f "$TOKEN_TMP" "$CREATE_OUT"
    trap - EXIT
    [ -n "$AGENT_ID" ] || die "the identity was created but its id could not be read" \
      "look the id up on the board and put it in AGENT_ID= in $CONF_FILE"
    echo "    identity $AGENT_ID created; token saved to $TOKEN_FILE ($(stat -c '%a' "$TOKEN_FILE"), $(stat -c '%s' "$TOKEN_FILE") bytes)"
  else
    echo "    + adapter_create_identity \"$DISPLAY_NAME\" \"$BOARD_ID\" \"$ROLE\""
    echo "    + token parsed from that reply and written to $TOKEN_FILE, 0600, never echoed"
  fi
elif [ "$BOARD" != "none" ]; then
  step 1 "identity $AGENT_ID already exists; its token stays where it is"
  if [ "$DRY_RUN" != "yes" ] && [ ! -s "$TOKEN_FILE" ]; then
    warn "no token at $TOKEN_FILE: the poll runner cannot read the board without it"
    echo "    fix: run \`$(adapter_rotate_token_hint "$AGENT_ID")\` with the owner's go-ahead and save the reply's token to $TOKEN_FILE"
  fi
else
  step 1 "no board adapter: no identity to create"
fi

# ---------- 2. board CLI wrapper ----------
if [ "$BOARD" != "none" ]; then
  step 2 "install the board CLI wrapper at $BOARD_CLI (reads the token file at call time)"
  if [ "$DRY_RUN" != "yes" ]; then
    adapter_install_board_cli "$SLUG" "$TOKEN_FILE" "$BOARD_CLI" "$DISPLAY_NAME" "$AGENT_ID" "$BOARD_ID" "$QUIET"
  fi
fi

# ---------- 2b. this agent's own memory repo ----------
# Every agent needs PR_REPO now (agent-board-poll refuses to tick without
# it). This step is idempotent: an existing repo is left exactly as it is,
# and enabling auto-merge is best-effort, because GitHub refuses
# allow_auto_merge on a private repo under a plan that does not carry it
# (true for the private repos this creates). That refusal must never fail
# the run: the supervisor's pr-hygiene check merges a green PR by hand when
# auto-merge could not be turned on.
if [ -n "$PR_REPO" ]; then
  step 2b "this agent's own memory repo: $PR_REPO (its output, reports and scripts land here as PRs)"
  if [ "$DRY_RUN" != "yes" ]; then
    if gh repo view "$PR_REPO" >/dev/null 2>&1; then
      echo "    $PR_REPO already exists, left as is"
    else
      SKELETON_DIR="$CORE_ROOT/repo-skeleton"
      [ -d "$SKELETON_DIR" ] || die "no skeleton at $SKELETON_DIR" \
        "the create-agent template is missing repo-skeleton/; reinstall the template"
      STAGE="$(mktemp -d)"
      cp -a "$SKELETON_DIR/." "$STAGE/"
      BOARD_DESC="$BOARD${BOARD_ID:+ (project $BOARD_ID)}"
      AGENT_NAME_SUB="$DISPLAY_NAME" AGENT_SLUG_SUB="$SLUG" BOARD_ADAPTER_SUB="$BOARD" \
      BOARD_ID_SUB="$BOARD_ID" BOARD_DESC_SUB="$BOARD_DESC" STAGE="$STAGE" python3 - <<'PYEOF'
import os
stage = os.environ["STAGE"]
subs = {
    "__AGENT_NAME__": os.environ["AGENT_NAME_SUB"],
    "__AGENT_SLUG__": os.environ["AGENT_SLUG_SUB"],
    "__BOARD_ADAPTER__": os.environ["BOARD_ADAPTER_SUB"],
    "__BOARD_ID__": os.environ["BOARD_ID_SUB"],
    "__BOARD_DESC__": os.environ["BOARD_DESC_SUB"],
}
for name in ("README.md", "board.yml", "CHANGELOG.md"):
    path = os.path.join(stage, name)
    if not os.path.isfile(path):
        continue
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    for token, value in subs.items():
        text = text.replace(token, value)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
PYEOF
      ( cd "$STAGE" && git init -q -b main \
          && git add -A \
          && git -c user.name="create-agent" -c user.email="create-agent@localhost" \
               commit -q -m "$DISPLAY_NAME: repo created from the create-agent skeleton" ) \
        || { rm -rf "$STAGE"; die "could not stage the skeleton repo" "check git is installed and working"; }
      if ! gh repo create "$PR_REPO" --private --source="$STAGE" --remote=origin --push >/dev/null; then
        rm -rf "$STAGE"
        die "gh repo create $PR_REPO failed" \
            "check \`gh auth status\` and that this token can create repos in that org"
      fi
      rm -rf "$STAGE"
      echo "    created $PR_REPO (private) from the skeleton"
    fi
    # gh repo edit --enable-auto-merge exits 0 even when GitHub silently
    # refuses the setting (a private repo on a plan that does not carry
    # auto-merge, true for hypertask-ai's private repos). Read the setting
    # back instead of trusting the edit call's exit code.
    gh repo edit "$PR_REPO" --enable-auto-merge >/dev/null 2>&1 || true
    if [ "$(gh api "repos/$PR_REPO" --jq '.allow_auto_merge' 2>/dev/null)" = "true" ]; then
      echo "    auto-merge enabled on $PR_REPO"
    else
      echo "    auto-merge unavailable on private repo, supervisor merges green PRs"
    fi
  else
    echo "    + create $PR_REPO (private, from repo-skeleton/) if it does not already exist"
    echo "    + gh repo edit $PR_REPO --enable-auto-merge (best effort, may be refused on a private repo)"
  fi
fi

# ---------- 2c. the standard layout in every project this agent touches ------
# An agent reads .claude/skills/INDEX.md out of the checkout it is working in,
# so a repo with no such file gives it nothing to follow. Lay the layout down
# here rather than waiting for somebody to remember. Idempotent, and a file the
# project has edited is never overwritten.
[ -n "$REPO" ] && SYNC_PROJECTS="$SYNC_PROJECTS${SYNC_PROJECTS:+ }$REPO"
if [ -n "$SYNC_PROJECTS" ]; then
  step 2c "the standard agent layout in: $SYNC_PROJECTS"
  SYNC_SH="$CORE_ROOT/scripts/sync-project.sh"
  [ -x "$SYNC_SH" ] || die "no sync-project.sh at $SYNC_SH" \
    "the create-agent template is missing scripts/sync-project.sh; reinstall the template"
  for project in $SYNC_PROJECTS; do
    if [ "$DRY_RUN" = "yes" ]; then
      AGENT_SLUG="$SLUG" BOARD_ADAPTER="$BOARD" BOARD_ID="$BOARD_ID" \
        bash "$SYNC_SH" "$project" --dry-run 2>&1 | sed 's/^/    /' || true
    else
      AGENT_SLUG="$SLUG" BOARD_ADAPTER="$BOARD" BOARD_ID="$BOARD_ID" \
        bash "$SYNC_SH" "$project" 2>&1 | sed 's/^/    /'
    fi
  done
fi

# ---------- 3. conf ----------
step 3 "write $CONF_FILE (0600; existing values are kept, only missing keys are added)"
CONF_CONTENT="$(cat <<EOF
AGENT_NAME="$DISPLAY_NAME"
AGENT_SLUG="$SLUG"
AGENT_KIND="$KIND"
AGENT_ID="${AGENT_ID:-}"
AGENT_REPO="$REPO"
AGENT_MISSION="$MISSION"
BOARD_ADAPTER="$BOARD"
BOARD_ID="$BOARD_ID"
TOKEN_FILE="$TOKEN_FILE"
BOARD_CLI="$BOARD_CLI"
WATCH_SECTIONS="$SECTIONS"
SKILLS_INDEX="$SKILLS_INDEX"
MODEL_CLI="$MODEL_CLI"
MAX_CONCURRENT_RUNS="$MAX_CONCURRENT_RUNS"
WIRING="$WIRING"
CHAT="$CHAT"
ROOM_DAILY_TURN_BUDGET="20"
QUIET="$QUIET"
ANSWERER_FALLBACK=""
MANAGER="off"
MAINTAINER="off"
GRAFT="off"
EOF
)"
# PR_REPO only when given: an empty PR_REPO="" written to a conf that has
# none yet would satisfy core_write_missing_keys and still leave the runner's
# required-key check failing on an empty value, silently hiding the real
# "run create-agent --pr-repo" fix behind a key that already exists.
if [ -n "$PR_REPO" ]; then
  CONF_CONTENT="$CONF_CONTENT
PR_REPO=\"$PR_REPO\""
fi
if [ "$DRY_RUN" != "yes" ]; then
  mkdir -p "$CONFIG_DIR"
  core_write_missing_keys "$CONF_FILE" "$CONF_CONTENT"
  # One shared copy next to every bot's conf in this config dir: whoever
  # looks after any of them starts from the same page.
  cp -a "$CORE_ROOT/MAINTAINER.md" "$CONFIG_DIR/MAINTAINER.md" 2>/dev/null || true
fi

# ---------- 4. wiring ----------
case "$WIRING" in
  poll|events)
    if [ "$WIRING" = "events" ]; then
      step 4 "install event wiring and start the hourly poll safety net"
    else
      step 4 "install the poll units and start the timer"
    fi
    SERVICE="$SYSTEMD_USER_DIR/agent-board-poll@.service"
    TIMER="$SYSTEMD_USER_DIR/agent-board-poll@.timer"
    if [ "$WIRING" = "events" ]; then
      echo "    agent-events.service + $TIMER (hourly safety net)"
    else
      echo "    $SERVICE (Type=oneshot) + $TIMER (every 60s)"
    fi
    echo "    systemctl --user enable --now agent-board-poll@$SLUG.timer"
    if [ "$DRY_RUN" != "yes" ]; then
      core_write_poll_units "$SYSTEMD_USER_DIR" "$BIN_DIR"
      if [ "$WIRING" = "events" ]; then
        core_write_event_timer_dropin "$SYSTEMD_USER_DIR" "$SLUG"
      else
        core_remove_event_timer_dropin "$SYSTEMD_USER_DIR" "$SLUG"
      fi
      systemctl --user daemon-reload
      systemctl --user enable --now "agent-board-poll@$SLUG.timer"
      systemctl --user list-timers "agent-board-poll@$SLUG.timer" --no-pager || true
    fi
    ;;
  fleet)
    step 4 "hand the agent to the worker runtime installed on this machine"
    if [ "$DRY_RUN" != "yes" ]; then
      adapter_fleet_wire "$SLUG"
    else
      echo "    + adapter_fleet_wire $SLUG"
    fi
    ;;
  none)
    step 4 "no wiring: trigger this agent yourself, from cron, CI, or by hand"
    echo "    agent-board-poll --once $SLUG   # if you later add a board"
    ;;
esac

# ---------- 5. acceptance ----------
echo
echo "Ticket comments have exactly five kinds: Question: asks a human and ends with a question mark; Answer: replies to a direct owner question or mention; Decision: states a fact the owner must know; Handoff: names the receiving agent and explains what shipped; Done: explains what shipped and includes the PR link. Reply-only runs default to Answer and may end with Decision needed: only when the owner must choose. In quiet mode, an Answer to the owner's direct mention keeps a mention to the owner even after the daily owner-mention allowance was used. Handoff and Done cannot be only a link. Everything else is run activity."
echo
echo "=== check before you say done ==="
cat <<EOF
  [ ] $CONF_FILE is 0600 and names the right board, sections and skills index
  [ ] every index in $SKILLS_INDEX exists, and the bot pack ($SKILLS_INDEX_LAST) has a skill whose trigger matches this agent's work
  [ ] PR_REPO is set in $CONF_FILE, either from --pr-repo above or added by hand: agent-board-poll refuses to tick without it
EOF
if [ "$BOARD" != "none" ]; then
  cat <<EOF
  [ ] $TOKEN_FILE is non-empty and 0600, and was never printed
  [ ] $BOARD_CLI runs as the agent, not as you
EOF
fi
if [ "$WIRING" = "poll" ] || [ "$WIRING" = "events" ]; then
  cat <<EOF
  [ ] agent-board-poll --once --dry-run $SLUG lists the tickets you expect
  [ ] agent-board-poll --once $SLUG posts a reply on a test ticket as the agent
  [ ] agent-board-poll@$SLUG.timer is active${WIRING:+ ($WIRING mode)}
EOF
fi
if [ "$CHAT_PAGE" = "yes" ]; then
  echo "  [ ] agent-chat.service is active"
  echo "  [ ] https://app.hypertask.ai/agents/chat?agent=$SLUG answers, and the reply is quoted verbatim"
fi

echo
if [ "$DRY_RUN" = "yes" ]; then
  echo "Dry run only. Re-run with --yes to create $DISPLAY_NAME."
fi
