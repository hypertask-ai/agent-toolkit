#!/usr/bin/env bash
# Direct ticket URL resolution for the Hypertask runtime.

_hypertask_cached_project_prefix() {
  local cache="$1" base="$2" project_id="$3"
  [ -r "$cache" ] || return 1
  awk -F '\t' -v base="$base" -v project="$project_id" \
    '$1 == base && $2 == project { value = $3 } END { if (value != "") print value; else exit 1 }' \
    "$cache"
}

_hypertask_cache_project_prefix() {
  local cache="$1" base="$2" project_id="$3" prefix="$4" dir tmp cache_fd
  dir="$(dirname "$cache")"
  mkdir -p "$dir" 2>/dev/null || return 0
  chmod 700 "$dir" 2>/dev/null || true
  touch "$cache.lock" 2>/dev/null || return 0
  exec {cache_fd}>>"$cache.lock"
  if ! flock "$cache_fd"; then
    exec {cache_fd}>&-
    return 0
  fi
  if ! tmp="$(mktemp "$dir/.project-prefixes.XXXXXX")"; then
    flock -u "$cache_fd"
    exec {cache_fd}>&-
    return 0
  fi
  if [ -r "$cache" ]; then
    awk -F '\t' -v base="$base" -v project="$project_id" \
      '!( $1 == base && $2 == project )' "$cache" > "$tmp"
  fi
  printf '%s\t%s\t%s\n' "$base" "$project_id" "$prefix" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$cache"
  flock -u "$cache_fd"
  exec {cache_fd}>&-
}

adapter_ticket_ref() {
  local token_file="$1" ticket="$2" project_id number base cache prefix project_out
  if [[ ! "$ticket" =~ ^https://app\.hypertask\.ai/detail/project-([0-9]+)/([0-9]+)$ ]]; then
    printf '%s' "$ticket"
    return 0
  fi
  project_id="${BASH_REMATCH[1]}"
  number="${BASH_REMATCH[2]}"
  base="$(_ht_api_base)"
  cache="${HYPERTASK_PROJECT_PREFIX_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/agent-template/hypertask-project-prefixes.tsv}"

  if prefix="$(_hypertask_cached_project_prefix "$cache" "$base" "$project_id")"; then
    printf '%s-%s' "$prefix" "$number"
    return 0
  fi

  if [ -z "${BOARD_CLI:-}" ] || [ ! -x "$BOARD_CLI" ]; then
    printf 'ERROR: could not resolve %s because the board CLI is unavailable. Do this next: restore BOARD_CLI and retry\n' "$ticket" >&2
    return 1
  fi
  if ! project_out="$("$BOARD_CLI" --json project show "$project_id" 2>&1)"; then
    printf "ERROR: could not resolve %s because project %s was not found. Do this next: check the project id and this agent's board access\n" \
      "$ticket" "$project_id" >&2
    return 1
  fi
  if ! prefix="$(PROJECT_ID="$project_id" python3 -c '
import json, os, re, sys
raw = sys.stdin.read()
start, end = raw.find("{"), raw.rfind("}")
if start < 0 or end <= start:
    raise SystemExit(1)
doc = json.loads(raw[start:end + 1])
project = doc.get("project") if isinstance(doc.get("project"), dict) else doc
returned_id = project.get("id") or project.get("projectId") or project.get("project_id")
if returned_id is not None and str(returned_id) != os.environ["PROJECT_ID"]:
    raise SystemExit(1)
prefix = next((str(project.get(key) or "").strip() for key in (
    "ticketPrefix", "ticket_prefix", "taskPrefix", "task_prefix", "prefix", "key"
) if project.get(key)), "")
if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", prefix):
    raise SystemExit(1)
print(prefix.upper())
' <<< "$project_out")"; then
    printf 'ERROR: could not resolve %s because project %s has no valid ticket prefix. Do this next: check the project configuration\n' \
      "$ticket" "$project_id" >&2
    return 1
  fi

  _hypertask_cache_project_prefix "$cache" "$base" "$project_id" "$prefix"
  printf '%s-%s' "$prefix" "$number"
}
