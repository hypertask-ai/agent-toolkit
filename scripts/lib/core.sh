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

# ---------- model policy ----------
# One shipped file defines the ladder for this runner and the supervisor.
CORE_POLICY_ROOT="$(dirname "$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")")"
MODEL_POLICY_FILE="${MODEL_POLICY_FILE:-$CORE_POLICY_ROOT/core/model-policy.conf}"
[ -r "$MODEL_POLICY_FILE" ] || die "model policy is missing at $MODEL_POLICY_FILE" \
  "install the complete create-agent template, including core/model-policy.conf"
# shellcheck disable=SC1090
. "$MODEL_POLICY_FILE"
[ -z "${MODEL_POLICY_CODEX_BIN_OVERRIDE:-}" ] || MODEL_POLICY_CODEX_BIN="$MODEL_POLICY_CODEX_BIN_OVERRIDE"

core_model_provider() {
  local argv=()
  read -r -a argv <<< "$1"
  case "$(basename "${argv[0]:-}")" in
    cursor-agent) printf 'cursor-agent' ;;
    hax|codex) printf 'codex' ;;
    claude) printf 'claude' ;;
    *) printf '' ;;
  esac
}

core_model_option() {
  local cli="$1" option="$2" argv=() i
  read -r -a argv <<< "$cli"
  for i in "${!argv[@]}"; do
    case "${argv[$i]}" in
      "$option") printf '%s' "${argv[$((i + 1))]:-}"; return 0 ;;
      "$option="*) printf '%s' "${argv[$i]#*=}"; return 0 ;;
    esac
  done
  printf ''
}

core_model_count() {
  local argv=() item count=0
  read -r -a argv <<< "$1"
  for item in "${argv[@]}"; do
    case "$item" in --model|--model=*) count=$((count + 1)) ;; esac
  done
  printf '%s' "$count"
}

core_list_has() {
  case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac
}

core_model_allowed() {
  case "$1" in
    cursor-agent) core_list_has "$MODEL_POLICY_CURSOR_AGENT_MODELS" "$2" ;;
    codex) core_list_has "$MODEL_POLICY_CODEX_MODELS" "$2" ;;
    claude) core_list_has "$MODEL_POLICY_CLAUDE_MODELS" "$2" ;;
    *) return 1 ;;
  esac
}

core_effort_allowed() {
  case "$1:$2" in
    cursor-agent:|claude:|claude:high|codex:high|codex:xhigh) return 0 ;;
    *) return 1 ;;
  esac
}

core_model_default() {
  case "$1" in
    cursor-agent) printf '%s' "$MODEL_POLICY_CURSOR_AGENT_DEFAULT" ;;
    codex) printf '%s' "$MODEL_POLICY_CODEX_DEFAULT" ;;
    claude) printf '%s' "$MODEL_POLICY_CLAUDE_DEFAULT" ;;
  esac
}

core_effort_default() {
  case "$1" in
    codex|claude) printf 'high' ;;
    *) printf '' ;;
  esac
}

core_model_cli() {
  local provider="$1" model="$2" effort="${3:-}"
  [ -n "$effort" ] || effort="$(core_effort_default "$provider")"
  case "$provider" in
    cursor-agent)
      printf 'cursor-agent -p --output-format text --model %s -f --trust' "$model"
      ;;
    codex)
      printf '%s --provider=codex --model=%s --effort=%s --no-session' \
        "$MODEL_POLICY_CODEX_BIN" "$model" "$effort"
      [ "$effort" = "xhigh" ] && printf ' --raw'
      printf ' -p'
      ;;
    claude)
      printf 'claude -p --model %s --effort %s' "$model" "$effort"
      ;;
  esac
}

# core_model_resolve <conf-cli> <provider:model[:effort]|bare-model|empty> <source>
# Sets CORE_MODEL_{CLI,PROVIDER,MODEL,EFFORT,NOTICE}. Invalid input falls back
# to the validated conf default and is reported by the caller as one line.
core_model_resolve() {
  local conf_cli="$1" selection="$2" source="$3"
  local conf_provider conf_model conf_effort provider model effort fallback_model fallback_effort rest
  CORE_MODEL_CLI="$conf_cli"
  CORE_MODEL_PROVIDER="$(core_model_provider "$conf_cli")"
  CORE_MODEL_MODEL="$(core_model_option "$conf_cli" --model)"
  CORE_MODEL_EFFORT="$(core_model_option "$conf_cli" --effort)"
  CORE_MODEL_NOTICE=""

  conf_provider="$CORE_MODEL_PROVIDER"
  conf_model="$CORE_MODEL_MODEL"
  conf_effort="$CORE_MODEL_EFFORT"
  if [ -z "$conf_provider" ]; then
    conf_provider="cursor-agent"
    conf_model="$(core_model_default "$conf_provider")"
    conf_effort=""
    CORE_MODEL_NOTICE="model policy rejected 'unknown:${CORE_MODEL_MODEL:-<empty>}' from $source; falling back to '$conf_provider:$conf_model'."
    CORE_MODEL_CLI="$(core_model_cli "$conf_provider" "$conf_model" "$conf_effort")"
    CORE_MODEL_PROVIDER="$conf_provider"
    CORE_MODEL_MODEL="$conf_model"
    CORE_MODEL_EFFORT="$conf_effort"
  elif [ "$(core_model_count "$conf_cli")" -ne 1 ] \
       || ! core_model_allowed "$conf_provider" "$conf_model" \
       || ! core_effort_allowed "$conf_provider" "$conf_effort"; then
    fallback_model="$(core_model_default "$conf_provider")"
    fallback_effort="$(core_effort_default "$conf_provider")"
    CORE_MODEL_NOTICE="model policy rejected '$conf_provider:${conf_model:-<empty>}' from $source; falling back to '$conf_provider:$fallback_model'."
    CORE_MODEL_CLI="$(core_model_cli "$conf_provider" "$fallback_model" "$fallback_effort")"
    CORE_MODEL_MODEL="$fallback_model"
    CORE_MODEL_EFFORT="$fallback_effort"
    conf_model="$fallback_model"
    conf_effort="$fallback_effort"
  fi

  [ -n "$selection" ] || return 0
  case "$selection" in
    *:*)
      provider="${selection%%:*}"
      rest="${selection#*:}"
      model="${rest%%:*}"
      if [ "$rest" = "$model" ]; then effort="$(core_effort_default "$provider")"; else effort="${rest#*:}"; fi
      case "$effort" in *:*) provider="" ;; esac
      ;;
    *) provider="$conf_provider"; model="$selection"; effort="$conf_effort" ;;
  esac
  if [ -z "$provider" ] || ! core_model_allowed "$provider" "$model" \
     || ! core_effort_allowed "$provider" "$effort"; then
    CORE_MODEL_NOTICE="model policy rejected '${provider:-unknown}:${model:-<empty>}' from $source; falling back to '$conf_provider:$conf_model'."
    return 0
  fi

  CORE_MODEL_PROVIDER="$provider"
  CORE_MODEL_MODEL="$model"
  CORE_MODEL_EFFORT="$effort"
  CORE_MODEL_CLI="$(core_model_cli "$provider" "$model" "$effort")"
  CORE_MODEL_NOTICE=""
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
ExecStart=$bin_dir/agent-board-poll --once %i
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
