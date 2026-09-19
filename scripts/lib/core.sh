#!/usr/bin/env bash
# core.sh: helpers shared by create-agent.sh and agent-board-poll.
#
# Core is board-agnostic. It knows about an agent identity, a skills index, a
# model CLI, a conf file and a state dir. Everything that talks to a specific
# tracker lives behind an adapter (adapters/<board>/adapter.sh). Core never
# names a tracker, a vendor or a host.
#
# Contract (same as the skills repo's TOOLS.md):
#   - every failure prints  ERROR: <what happened>. Do this next: <one step>
#     on stderr and exits non-zero
#   - --dry-run changes nothing but still validates
#   - secrets are written to 0600 files and referenced by path, never printed

# ---------- failure contract ----------
die() {
  # die <what happened> <what to do next>
  printf 'ERROR: %s. Do this next: %s\n' "$1" "$2" >&2
  exit 1
}

warn() { printf 'WARNING: %s\n' "$1" >&2; }

# ---------- slug ----------
core_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

# ---------- adapter loading ----------
# core_adapter_dir <adapter-name> : absolute path to that adapter's folder
core_adapter_dir() {
  printf '%s/adapters/%s' "$CORE_ROOT" "$1"
}

# core_load_adapter <adapter-name>
# Sources the adapter and checks it defines the whole contract, so a wrong
# --board fails here with our message instead of "command not found" later.
CORE_ADAPTER_FUNCTIONS="
adapter_id
adapter_config_dir_default
adapter_require_tools
adapter_supports_fleet_wiring
adapter_find_identity
adapter_create_identity
adapter_rotate_token_hint
adapter_extract_token
adapter_extract_identity_id
adapter_install_board_cli
adapter_list_candidates
adapter_latest_comment
adapter_mention_token
adapter_task_url
adapter_post_comment
adapter_move_task
adapter_fleet_wire
"

core_load_adapter() {
  local name="$1" dir
  dir="$(core_adapter_dir "$name")"
  [ -f "$dir/adapter.sh" ] || die \
    "no adapter named '$name' under $CORE_ROOT/adapters" \
    "pass one of: $(cd "$CORE_ROOT/adapters" 2>/dev/null && ls -1 | paste -sd '|' -)"
  # shellcheck disable=SC1090
  . "$dir/adapter.sh"
  local extension="$CORE_ROOT/scripts/lib/adapters/$name.sh"
  if [ -f "$extension" ]; then
    # shellcheck disable=SC1090
    . "$extension"
  fi
  local fn
  for fn in $CORE_ADAPTER_FUNCTIONS; do
    declare -F "$fn" >/dev/null 2>&1 || die \
      "adapter '$name' does not define $fn" \
      "implement $fn in $dir/adapter.sh, or copy the stub from adapters/linear/adapter.sh"
  done
  ADAPTER_NAME="$name"
}

# ---------- config dir ----------
# The adapter may keep its identities somewhere established; core falls back to
# its own generic location.
core_config_dir() {
  if [ -n "${AGENT_CONFIG_DIR:-}" ]; then
    printf '%s' "$AGENT_CONFIG_DIR"
  elif declare -F adapter_config_dir_default >/dev/null 2>&1 \
       && [ -n "$(adapter_config_dir_default)" ]; then
    adapter_config_dir_default
  else
    printf '%s/.config/agents' "$HOME"
  fi
}

# core_find_conf <slug>
# The conf lives in core's own config dir, or in the place a given adapter
# already keeps its identities. Core does not know those places by name: it
# asks every installed adapter, in a subshell, and takes the first hit.
core_find_conf() {
  local slug="$1" dir candidate adapter
  for dir in "${AGENT_CONFIG_DIR:-}" "$HOME/.config/agents"; do
    [ -n "$dir" ] || continue
    [ -f "$dir/$slug.conf" ] && { printf '%s/%s.conf' "$dir" "$slug"; return 0; }
  done
  for adapter in "$CORE_ROOT"/adapters/*/adapter.sh; do
    [ -f "$adapter" ] || continue
    candidate="$(
      # shellcheck disable=SC1090
      . "$adapter" 2>/dev/null
      declare -F adapter_config_dir_default >/dev/null 2>&1 && adapter_config_dir_default
    )" || continue
    [ -n "$candidate" ] || continue
    [ -f "$candidate/$slug.conf" ] && { printf '%s/%s.conf' "$candidate" "$slug"; return 0; }
  done
  return 1
}

# Logs, state keys and lock files for every agent this core runs.
core_state_dir() {
  printf '%s/%s' "${XDG_STATE_HOME:-$HOME/.local/state}" "${CORE_STATE_NAME:-agent-runs}"
}

# ---------- conf files ----------
# Write a KEY=value file without clobbering values that are already there.
core_write_missing_keys() {
  local path="$1" content="$2"
  CONTENT="$content" python3 - "$path" <<'PYEOF'
import os, re, sys
path = sys.argv[1]
content = os.environ["CONTENT"]
blocks = [b for b in re.split(r"(?m)(?=^[A-Z][A-Z0-9_]*=)", content) if b]
existing = ""
if os.path.exists(path):
    with open(path) as fh:
        existing = fh.read()
keys = set(re.findall(r"(?m)^([A-Z][A-Z0-9_]*)=", existing))
missing = [b for b in blocks if b.split("=", 1)[0] not in keys]
if not os.path.exists(path):
    with open(path, "w") as fh:
        fh.write(content.rstrip("\n") + "\n")
elif missing:
    with open(path, "a") as fh:
        if existing and not existing.endswith("\n"):
            fh.write("\n")
        fh.write("".join(missing).rstrip("\n") + "\n")
os.chmod(path, 0o600)
PYEOF
}

# core_read_conf <path> : source a KEY=value conf, refusing anything else
core_read_conf() {
  local path="$1"
  [ -f "$path" ] || die "no conf at $path" \
    "run create-agent.sh for this agent, or pass the right slug"
  if grep -qvE '^\s*(#.*)?$|^[A-Z][A-Z0-9_]*=' "$path"; then
    die "conf $path has a line that is not KEY=value or a comment" \
        "remove it; the conf is sourced by the runner and must stay declarative"
  fi
  # shellcheck disable=SC1090
  . "$path"
}

# core_enable_agent_identity <slug> <token-file> <board-cli>
# Every child process gets aliases which enter through the agent's wrapper.
# The original PATH is restored inside each alias so the wrapper can reach the
# native CLI without resolving back to the alias.
core_enable_agent_identity() {
  local slug="$1" token_file="$2" board_cli="$3" shim_dir
  if [ -z "${AGENT_ORIGINAL_PATH+x}" ]; then
    AGENT_ORIGINAL_PATH="$PATH"
    export AGENT_ORIGINAL_PATH
  fi
  shim_dir="$("$CORE_ROOT/scripts/agent-identity-shim" "$slug" "$token_file" "$board_cli")" || return 1
  AGENT_SLUG="$slug"
  HYPERTASK_TOKEN_FILE="$token_file"
  AGENT_IDENTITY_PATH="$shim_dir:$AGENT_ORIGINAL_PATH"
  export AGENT_SLUG HYPERTASK_TOKEN_FILE AGENT_IDENTITY_PATH
}

# core_guard_token_wrappers <bin-dir> [<dry-run: yes|no>]
# The identity shim only catches a bare `hypertask`/`ht`/`htbot` call made by
# a provider process that runs with the shim first on PATH (AGTE-13: Product
# Bot posted an unmarked, unstripped owner mention through ~/.local/bin/htbot,
# a hand-made wrapper that called the board API directly and never went
# through a shimmed run). A wrapper like that sits right next to the real
# board CLIs in <bin-dir>, so that is what this scans: any executable there
# that embeds a managed agent's TOKEN_FILE path but is not that agent's own
# BOARD_CLI. It is rewritten to exec the agent's BOARD_CLI (which carries the
# marker check and owner-mention stripping) with a timestamped backup kept
# next to it. A target this cannot safely rewrite as a script -- unreadable,
# unwritable, or not text -- gets a loud warning instead of a silent skip;
# dry-run reports the same findings and changes nothing.
core_guard_token_wrappers() {
  local bin_dir="$1" dry_run="${2:-no}" dir conf found_confs
  [ -d "$bin_dir" ] || return 0

  local confs
  confs="$(mktemp)"
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    for conf in "$dir"/*.conf; do
      [ -f "$conf" ] || continue
      (
        # shellcheck disable=SC1090
        . "$conf" 2>/dev/null
        [ -n "${AGENT_SLUG:-}" ] && [ -n "${TOKEN_FILE:-}" ] || exit 0
        printf '%s\t%s\t%s\n' "$AGENT_SLUG" "$TOKEN_FILE" "${BOARD_CLI:-}"
      ) >> "$confs"
    done
  done < <(core_conf_dirs)

  found_confs="no"
  [ -s "$confs" ] && found_confs="yes"
  if [ "$found_confs" = "no" ]; then
    rm -f "$confs"
    return 0
  fi

  local entry resolved_entry resolved_board line slug token_file board_cli backup
  for entry in "$bin_dir"/*; do
    [ -f "$entry" ] && [ -x "$entry" ] || continue
    resolved_entry="$(readlink -f "$entry" 2>/dev/null || printf '%s' "$entry")"
    while IFS=$'\t' read -r slug token_file board_cli; do
      [ -n "$slug" ] || continue
      if [ -n "$board_cli" ]; then
        resolved_board="$(readlink -f "$board_cli" 2>/dev/null || printf '%s' "$board_cli")"
        [ "$resolved_entry" = "$resolved_board" ] && continue
      fi
      grep -qF -- "$token_file" "$entry" 2>/dev/null || continue

      if [ "$dry_run" = "yes" ]; then
        warn "$entry embeds $slug's token file outside the identity shim. Do this next: run install.sh (not --dry-run) so it is rewritten to exec $board_cli"
        continue
      fi
      if [ -z "$board_cli" ] || [ ! -w "$entry" ] || ! head -c2 "$entry" 2>/dev/null | grep -q '^#!'; then
        warn "$entry embeds $slug's token file outside the identity shim and could not be rewritten. Do this next: remove it or point it at the BOARD_CLI for $slug by hand"
        continue
      fi
      backup="$entry.bak-$(date -u +%Y%m%dT%H%M%SZ)"
      cp -a "$entry" "$backup"
      cat > "$entry" <<EOF
#!/usr/bin/env bash
# $entry: rewritten by install.sh (AGTE-13). This used to reach the board API
# directly, outside the identity shim, so the marker check and owner-mention
# stripping never ran for it. It now defers to $slug's own board CLI.
set -euo pipefail
exec "$board_cli" "\$@"
EOF
      chmod 755 "$entry"
      warn "rewrote $entry to exec $board_cli: it embedded $slug's token file outside the identity shim (backup: $backup)"
    done < "$confs"
  done
  rm -f "$confs"
}

# ---------- command ladder ----------
# Commands are opaque policy owned by the conf. Core only selects an ordered
# rung; it never identifies, validates or rewrites a provider, model or harness.
# It does check that the rung's executable exists on this host (AGTE-4): a
# ladder rung naming a binary this host lacks must not be run at all, so
# core_ladder_command prints "" for that rung and the caller falls back to
# the agent's own MODEL_CLI instead of failing the run with exit=127.
core_ladder_count() {
  [ -n "${1:-}" ] || { printf '0'; return 0; }
  LADDER_VALUE="$1" python3 -c 'import os; print(len(os.environ["LADDER_VALUE"].split("|")))'
}

# core_ladder_command <ladder> <one-based-rung> : print one full command, or
# "" if that rung is empty or its executable is not on PATH.
core_ladder_command() {
  local ladder="$1" rung="$2" command argv0
  command="$(LADDER_VALUE="$ladder" LADDER_RUNG="$rung" python3 <<'PYEOF'
import os
commands = os.environ["LADDER_VALUE"].split("|") if os.environ["LADDER_VALUE"] else []
try:
    rung = int(os.environ["LADDER_RUNG"])
except ValueError:
    rung = 0
print(commands[rung - 1].strip() if 0 < rung <= len(commands) else "", end="")
PYEOF
)"
  if [ -n "$command" ]; then
    read -r argv0 _ <<< "$command"
    if ! command -v "$argv0" >/dev/null 2>&1; then
      echo "WARNING: ladder rung $rung command '$argv0' is not on this host's PATH; falling back to the agent's configured MODEL_CLI" >&2
      command=""
    fi
  fi
  printf '%s' "$command"
}

# core_command_available <full-command>: the command is routable only when its
# executable exists. Provider fallback uses this before launch, so a configured
# subscription that is not installed cannot consume or fail a run.
core_command_available() {
  local command="$1" argv0
  read -r argv0 _ <<< "$command"
  [ -n "$argv0" ] && command -v "$argv0" >/dev/null 2>&1
}

# core_command_provider <full-command>: identify the provider only from command
# syntax that names it. Unknown wrappers stay unknown rather than guessing.
core_command_provider() {
  MODEL_COMMAND="$1" python3 <<'PYEOF'
import os
import shlex
from pathlib import Path

try:
    argv = shlex.split(os.environ["MODEL_COMMAND"])
except ValueError:
    argv = []
provider = ""
if argv:
    executable = Path(argv[0]).name
    if executable == "cursor-agent":
        provider = "cursor"
    elif executable == "codex":
        provider = "codex"
    elif executable == "claude":
        provider = "claude"
    elif executable in {"hax", "pi"}:
        for index, value in enumerate(argv):
            if value == "--provider" and index + 1 < len(argv):
                provider = argv[index + 1]
                break
            if value.startswith("--provider="):
                provider = value.split("=", 1)[1]
                break
print(provider.lower())
PYEOF
}

# core_provider_quota_error <stderr-file>: match subscription exhaustion, not
# generic process failures or ordinary HTTP rate limiting.
core_provider_quota_error() {
  QUOTA_ERROR_FILE="$1" python3 <<'PYEOF'
import os
import re

try:
    text = open(os.environ["QUOTA_ERROR_FILE"], encoding="utf-8", errors="replace").read()
except OSError:
    text = ""
patterns = (
    r"\binsufficient_quota\b",
    r"\b(?:usage|spending|monthly|weekly|token|credit) limit (?:has been )?(?:reached|exceeded)\b",
    r"\b(?:reached|exceeded) (?:your|the) (?:usage|spending|monthly|weekly|token|credit) limit\b",
    r"\bquota (?:has been )?(?:exhausted|reached|exceeded)\b",
    r"\b(?:exhausted|reached) (?:your|the) quota\b",
    r"\b(?:out of|no) (?:tokens|credits)(?: remaining)?\b",
    r"\bno (?:premium |fast )?requests remaining\b",
    r"\bcredit balance (?:is )?(?:too low|exhausted)\b",
)
raise SystemExit(0 if any(re.search(pattern, text, re.I) for pattern in patterns) else 1)
PYEOF
}

# core_provider_quota_reset <stderr-file>: print "<epoch>\t<UTC ISO time>"
# when the provider reports an absolute or relative reset. No guessed reset is
# safer than making the runner promise a time the subscription did not provide.
core_provider_quota_reset() {
  QUOTA_ERROR_FILE="$1" python3 <<'PYEOF'
import datetime as dt
import os
import re

try:
    text = open(os.environ["QUOTA_ERROR_FILE"], encoding="utf-8", errors="replace").read()
except OSError:
    text = ""
now = dt.datetime.now(dt.timezone.utc)
reset = None
absolute = re.search(
    r"(?:reset(?:s|ting)?|available again)(?:\s+(?:at|on))?[:\s]+"
    r"(\d{4}-\d{2}-\d{2}[T ][0-9]{2}:[0-9]{2}(?::[0-9]{2})?(?:Z|[+-][0-9]{2}:?[0-9]{2})?)",
    text,
    re.I,
)
if absolute:
    value = absolute.group(1).replace(" ", "T")
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    if re.search(r"[+-][0-9]{4}$", value):
        value = value[:-5] + value[-5:-2] + ":" + value[-2:]
    try:
        reset = dt.datetime.fromisoformat(value)
        if reset.tzinfo is None:
            reset = reset.replace(tzinfo=dt.timezone.utc)
        reset = reset.astimezone(dt.timezone.utc)
    except ValueError:
        reset = None
if reset is None:
    unix = re.search(r'"?(?:reset_at|resetAt|reset_epoch)"?\s*[:=]\s*"?(\d{10})', text, re.I)
    if unix:
        reset = dt.datetime.fromtimestamp(int(unix.group(1)), dt.timezone.utc)
if reset is None:
    relative = re.search(
        r"(?:reset(?:s)?|try again|available again)\s+in\s+"
        r"(?:(\d+)\s*(?:h|hour|hours))?\s*(?:(\d+)\s*(?:m|min|minute|minutes))?",
        text,
        re.I,
    )
    if relative and (relative.group(1) or relative.group(2)):
        reset = now + dt.timedelta(hours=int(relative.group(1) or 0), minutes=int(relative.group(2) or 0))
if reset is not None:
    print(f"{int(reset.timestamp())}\t{reset.isoformat().replace('+00:00', 'Z')}")
PYEOF
}

# ---------- secrets ----------
# core_save_secret <path> <value-on-stdin>
# Writes 0600, verifies it landed, never echoes the value.
core_save_secret() {
  local path="$1" dir
  dir="$(dirname "$path")"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  ( umask 077; cat > "$path" )
  chmod 600 "$path"
  [ -s "$path" ] || die "wrote an empty secret file at $path" \
    "delete it and capture the value again"
  local mode
  mode="$(stat -c '%a' "$path")"
  [ "$mode" = "600" ] || die "secret file $path has mode $mode, not 600" \
    "run chmod 600 $path"
}

core_require_abs() {
  case "$1" in
    /*) : ;;
    *) die "$2 must be an absolute path, got '$1'" \
          "pass the full path starting with /" ;;
  esac
}

# ---------- skill packs ----------
# SKILLS_INDEX is a LIST, not one path: the company pack first, then this
# bot's own pack. Every bot in a company does the same things to a board and
# builds different things on top, so the shared half lives in one repo every
# bot reads, and the bot pack only carries what is its own. An agent reads
# them in order, and the first pack wins a name collision, which is why the
# company pack goes first.
#
# Comma-separated, like WATCH_SECTIONS and EXCLUDE_LABELS. One path is still
# a valid list of one, so every conf written before this change keeps working.

# core_skill_indexes <value> : print one absolute index path per line.
core_skill_indexes() {
  # `read` returns false on the final line when it has no trailing newline, so
  # the loop has to keep going while the variable still holds something, or the
  # last pack in the list is silently dropped.
  printf '%s\n' "$1" | tr ',' '\n' | while IFS= read -r one || [ -n "$one" ]; do
    one="$(printf '%s' "$one" | tr -d '[:space:]')"
    [ -n "$one" ] && printf '%s\n' "$one"
  done
}

# core_check_skill_indexes <value> <key name> : every entry absolute and real.
core_check_skill_indexes() {
  local value="$1" key="$2" found=0 one
  while IFS= read -r one; do
    [ -n "$one" ] || continue
    found=1
    core_require_abs "$one" "$key"
    [ -f "$one" ] || die "the skills index $one does not exist" \
      "point $key at a real index file; an agent with no skills has nothing to follow"
  done <<EOF
$(core_skill_indexes "$value")
EOF
  [ "$found" = "1" ] || die "$key is empty" \
    "set $key to one or more absolute index paths, comma-separated, company pack first"
}

# core_skill_index_at <value> <first|last> : one entry, without piping into
# head or tail. Under `set -o pipefail` the writer gets SIGPIPE the moment head
# closes the pipe, and the whole script dies with 141 before it prints a word.
core_skill_index_at() {
  local which="$2" one out=""
  while IFS= read -r one; do
    [ -n "$one" ] || continue
    if [ "$which" = "first" ]; then
      printf '%s' "$one"
      return 0
    fi
    out="$one"
  done <<EOF
$(core_skill_indexes "$1")
EOF
  printf '%s' "$out"
}

# core_skill_index_sentence <value> : the phrase a prompt uses for the list.
core_skill_index_sentence() {
  local value="$1" n one out=""
  n=0
  while IFS= read -r one; do
    [ -n "$one" ] || continue
    n=$((n + 1))
    if [ -z "$out" ]; then out="$one"; else out="$out, then $one"; fi
  done <<EOF
$(core_skill_indexes "$value")
EOF
  if [ "$n" -gt 1 ]; then
    printf '%s (the company pack first, then your own)' "$out"
  else
    printf '%s' "$out"
  fi
}

# ---------- a working directory per run ----------
# Some agents change code, and two runs sharing one checkout overwrite each
# other's edits. WORKDIR_MODE=per-run gives each run its own directory under
# WORKDIR_ROOT, thrown away when the run ends.
#
# Core owns the option, the location, and the removal. It does not know how to
# make a checkout, because that depends on the version control the board's
# projects use, so the adapter supplies it: define adapter_workdir_checkout
# <source> <dir> <name> to fill the directory, and optionally
# adapter_workdir_remove <source> <dir> to release it before core deletes it.
# An adapter that defines neither still works: the directory is made empty.

# core_workdir_create <source> <root> <name> : prints the directory it made
core_workdir_create() {
  local source="$1" root="$2" name="$3" dir
  [ -n "$root" ] || die "WORKDIR_ROOT is empty but WORKDIR_MODE is per-run" \
    "set WORKDIR_ROOT= in the conf to a directory this user can write"
  core_require_abs "$root" "WORKDIR_ROOT"
  dir="$root/$name"
  mkdir -p "$root"
  # A directory left behind by a killed run is stale, never a resume point.
  # Unless the adapter refuses to let it go, in which case it holds the only
  # copy of some work: step around it rather than deadlocking every future run
  # on this ticket.
  if [ -e "$dir" ]; then
    core_workdir_remove "$source" "$dir"
    if [ -e "$dir" ]; then
      dir="$root/$name-$(date +%s)"
      warn "the old directory for $name was kept, so this run works in $dir"
    fi
  fi
  if declare -F adapter_workdir_checkout >/dev/null 2>&1; then
    adapter_workdir_checkout "$source" "$dir" "$name" >&2 || return 1
  else
    mkdir -p "$dir"
  fi
  [ -d "$dir" ] || die "the checkout for $name did not create $dir" \
    "check adapter_workdir_checkout in the adapter for this board"
  printf '%s' "$dir"
}

# ---------- shared poll units ----------
core_record_installed_unit() {
  [ -n "${AGENT_TEMPLATE_INSTALLED_UNITS_FILE:-}" ] || return 0
  printf '%s\n' "$1" >> "$AGENT_TEMPLATE_INSTALLED_UNITS_FILE"
}

# core_write_poll_units <systemd-user-dir> <bin-dir> : the agent-board-poll@
# service+timer pair, written once and shared by every slug (%i is the slug).
# The single source of truth for both install.sh (refresh on every host) and
# create-agent.sh (first agent on a host with no units yet). Two copies of
# this heredoc drifting apart is exactly how the missing-PATH bug happened:
# a ticket run as a systemd unit does not inherit the interactive shell's
# PATH, so `hypertask` (installed under ~/.local/bin or ~/.npm-global/bin)
# was invisible to every tick until an agent hand-patched a per-slug
# drop-in. Fixed at the source so no slug ever needs one again.
core_write_poll_units() {
  local systemd_dir="$1" bin_dir="$2" service timer
  service="$systemd_dir/agent-board-poll@.service"
  timer="$systemd_dir/agent-board-poll@.timer"
  mkdir -p "$systemd_dir"
  cat > "$service" <<EOF
[Unit]
Description=One work tick for agent %i

[Service]
# Type=oneshot, so systemd itself refuses to start a second tick while one is
# still running. That is the concurrency guard: no daemon, no queue, no lock
# file to go stale. One process per ticket, and the board holds the state.
Type=oneshot
# A systemd user unit does not inherit the shell's PATH, so name every
# directory a board CLI or model CLI can live in explicitly.
Environment=PATH=%h/.local/bin:%h/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
Environment=HOME=%h
Environment=AGENT_SLUG=%i
ExecStartPre=$bin_dir/agent-template build reconcile
ExecStart=$bin_dir/agent-board-poll-tick %i
EOF
  cat > "$timer" <<EOF
[Unit]
Description=Poll the board for agent %i

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=5s
Unit=agent-board-poll@%i.service

[Install]
WantedBy=timers.target
EOF
  core_record_installed_unit "$(basename "$service")"
  core_record_installed_unit "$(basename "$timer")"
}

core_write_reconcile_units() {
  local systemd_dir="$1" bin_dir="$2"
  mkdir -p "$systemd_dir"
  cat > "$systemd_dir/agent-board-reconcile.service" <<EOF
[Unit]
Description=Reconcile agent runs with board columns
After=network-online.target

[Service]
Type=oneshot
Environment=HOME=%h
Environment=PATH=%h/.local/bin:%h/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$bin_dir/agent-board-reconcile
EOF
  cat > "$systemd_dir/agent-board-reconcile.timer" <<EOF
[Unit]
Description=Reconcile agent board state every five minutes

[Timer]
OnBootSec=5m
OnUnitActiveSec=5m
AccuracySec=30s
Unit=agent-board-reconcile.service

[Install]
WantedBy=timers.target
EOF
  core_record_installed_unit agent-board-reconcile.service
  core_record_installed_unit agent-board-reconcile.timer
}

# Events mode keeps the same poll service as a five-minute safety net. The
# event receiver starts exact-ticket ticks between safety scans.
core_write_event_timer_dropin() {
  local systemd_dir="$1" slug="$2" dir
  dir="$systemd_dir/agent-board-poll@$slug.timer.d"
  mkdir -p "$dir"
  cat > "$dir/events.conf" <<EOF
[Timer]
OnUnitActiveSec=
OnUnitActiveSec=5m
EOF
}

core_remove_event_timer_dropin() {
  local systemd_dir="$1" slug="$2" dir
  dir="$systemd_dir/agent-board-poll@$slug.timer.d"
  rm -f "$dir/events.conf"
  rmdir "$dir" 2>/dev/null || true
}

# core_workdir_remove <source> <dir>
# The adapter gets the last word. If it refuses, the directory stays: it knows
# what is in there, and losing an agent's only copy of its work to a tidy-up is
# worse than leaving a directory behind for someone to look at.
core_workdir_remove() {
  local source="$1" dir="$2"
  [ -n "$dir" ] || return 0
  case "$dir" in /*) : ;; *) return 0 ;; esac
  if declare -F adapter_workdir_remove >/dev/null 2>&1; then
    if ! adapter_workdir_remove "$source" "$dir" >&2; then
      warn "keeping $dir: the adapter says there is work in it that exists nowhere else"
      return 0
    fi
  fi
  rm -rf "$dir"
}

# ---------- where skills come from (3.11.0) ----------
# Three sources, in the order a run reads them:
#
#   1. the company pack, shared by every agent in the company. A Claude Code
#      plugin when one is installed, the clone otherwise.
#   2. .claude/skills/ inside the repo the run works in. Project skills live in
#      the repo they serve, so a run can never read rules for code it is not
#      editing, and a skill change ships in the same PR as the code change.
#   3. anything extra the conf names in SKILLS_INDEX. Optional since 3.11.0:
#      1 and 2 are found without being told.
#
# Both 1 and 2 carry a VERSION file, and the runner logs both at the start of
# every run. A bot behaving oddly is usually a bot reading an old pack, and
# that line is how you tell.

COMPANY_PACK_NAME="${COMPANY_PACK_NAME:-company-skills}"
COMPANY_PACK_CLONE="${COMPANY_PACK_CLONE:-$HOME/projects/company-skills}"

# core_company_pack : absolute path to the company pack root, or empty when
# neither the plugin nor the clone is on this host.
core_company_pack() {
  local dir
  # An explicit override wins: a test host, or a session pinning a worktree.
  if [ -n "${COMPANY_SKILLS_DIR:-}" ] && [ -f "$COMPANY_SKILLS_DIR/INDEX.md" ]; then
    printf '%s' "$COMPANY_SKILLS_DIR"
    return 0
  fi
  # The installed plugin. The cache keeps one directory per version, so take
  # the most recently written rather than trying to sort version strings in
  # shell. `ls -t` on the glob, newest first.
  for dir in $(ls -1dt "$HOME/.claude/plugins/cache/$COMPANY_PACK_NAME/$COMPANY_PACK_NAME"/*/ 2>/dev/null); do
    dir="${dir%/}"
    [ -f "$dir/INDEX.md" ] || continue
    printf '%s' "$dir"
    return 0
  done
  # The clone, still the fallback on any host where the plugin is not installed.
  if [ -f "$COMPANY_PACK_CLONE/INDEX.md" ]; then
    printf '%s' "$COMPANY_PACK_CLONE"
    return 0
  fi
  printf ''
}

# core_pack_version <dir> : the pack's VERSION, or "unversioned".
core_pack_version() {
  local v=""
  [ -n "${1:-}" ] && [ -f "$1/VERSION" ] && v="$(head -n1 "$1/VERSION" | tr -d '[:space:]')"
  printf '%s' "${v:-unversioned}"
}

# core_repo_skills <checkout> : absolute path to the repo's skills dir, or
# empty when that repo has not been synced yet.
core_repo_skills() {
  [ -n "${1:-}" ] || { printf ''; return 0; }
  [ -f "$1/.claude/skills/INDEX.md" ] || { printf ''; return 0; }
  printf '%s/.claude/skills' "$1"
}

# core_conf_dirs : every directory an agent conf can live in on this host, one
# per line, deduplicated. The same set core_find_conf searches, exposed so a
# caller can walk every conf rather than look one up by slug.
core_conf_dirs() {
  local dir adapter candidate seen=""
  for dir in "${AGENT_CONFIG_DIR:-}" "$HOME/.config/agents"; do
    [ -n "$dir" ] || continue
    case " $seen " in *" $dir "*) continue ;; esac
    seen="$seen $dir"
    [ -d "$dir" ] && printf '%s\n' "$dir"
  done
  for adapter in "$CORE_ROOT"/adapters/*/adapter.sh; do
    [ -f "$adapter" ] || continue
    candidate="$(
      # shellcheck disable=SC1090
      . "$adapter" 2>/dev/null
      declare -F adapter_config_dir_default >/dev/null 2>&1 && adapter_config_dir_default
    )" || continue
    [ -n "$candidate" ] || continue
    case " $seen " in *" $candidate "*) continue ;; esac
    seen="$seen $candidate"
    [ -d "$candidate" ] && printf '%s\n' "$candidate"
  done
}
