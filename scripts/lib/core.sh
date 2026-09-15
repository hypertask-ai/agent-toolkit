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
  if [ -e "$dir" ]; then core_workdir_remove "$source" "$dir"; fi
  if declare -F adapter_workdir_checkout >/dev/null 2>&1; then
    adapter_workdir_checkout "$source" "$dir" "$name" >&2 || return 1
  else
    mkdir -p "$dir"
  fi
  [ -d "$dir" ] || die "the checkout for $name did not create $dir" \
    "check adapter_workdir_checkout in the adapter for this board"
  printf '%s' "$dir"
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
