#!/usr/bin/env bash
# Direct ticket URL resolution and runner-specific lifecycle policy for Hypertask.

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

_hypertask_release_log() {
  local message="$1" path
  path="${LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-board-poll/${SLUG:-unknown}.log}"
  mkdir -p "$(dirname "$path")"
  printf '%s %s\n' "$(date -Is)" "$message" >> "$path"
}

_hypertask_release_section_file() {
  printf '%s/agent-board-poll/%s.release-sections' \
    "${XDG_STATE_HOME:-$HOME/.local/state}" "${SLUG:-unknown}"
}

_hypertask_validate_release_sections() {
  local board_ids="$1" configured="${OWNER_REVIEW_SECTION:-Review}"
  local board raw parsed target file temporary invalid="no"
  file="$(_hypertask_release_section_file)"
  mkdir -p "$(dirname "$file")"
  temporary="$file.$$"
  : > "$temporary"

  for board in $(printf '%s' "$board_ids" | tr ',' ' '); do
    [ -n "$board" ] || continue
    raw="$("$BOARD_CLI" --json section list --project "$board" 2>/dev/null || true)"
    parsed="$(RAW="$raw" python3 -c '
import json, os
raw = os.environ["RAW"]
try:
    doc = json.loads(raw)
except (TypeError, ValueError):
    start, end = raw.find("{"), raw.rfind("}")
    try:
        doc = json.loads(raw[start:end + 1]) if start >= 0 and end > start else None
    except (TypeError, ValueError):
        doc = None
if isinstance(doc, list):
    sections = doc
elif isinstance(doc, dict):
    container = doc.get("project") if isinstance(doc.get("project"), dict) else doc
    if "sections" not in container:
        raise SystemExit
    sections = container.get("sections") or []
else:
    raise SystemExit
print("__known__")
for item in sections:
    if isinstance(item, dict):
        name = item.get("name") or item.get("title") or item.get("section_title")
    else:
        name = item
    if name:
        print(str(name))
' 2>/dev/null || true)"
    if [ "$(printf '%s\n' "$parsed" | sed -n '1p')" != "__known__" ]; then
      _hypertask_release_log "PR release destination validation unavailable for board $board"
      printf '%s\t%s\n' "$board" "$configured" >> "$temporary"
      continue
    fi
    parsed="$(printf '%s\n' "$parsed" | sed '1d')"
    target=""
    if printf '%s\n' "$parsed" | awk -v wanted="$configured" 'BEGIN { IGNORECASE=1 } $0 == wanted { found=1 } END { exit !found }'; then
      target="$configured"
    elif [ "${configured,,}" = "review" ] \
         && printf '%s\n' "$parsed" | awk 'BEGIN { IGNORECASE=1 } $0 == "HT Manager Review" { found=1 } END { exit !found }'; then
      target="HT Manager Review"
      _hypertask_release_log "PR release destination \"$configured\" does not exist on board $board; using \"$target\""
    else
      invalid="yes"
      _hypertask_release_log "ERROR: PR release destination \"$configured\" does not exist on board $board"
      printf 'ERROR: PR release destination "%s" does not exist on board %s. Do this next: set OWNER_REVIEW_SECTION to a live manager lane\n' \
        "$configured" "$board" >&2
      continue
    fi
    printf '%s\t%s\n' "$board" "$target" >> "$temporary"
  done

  if [ "$invalid" = "yes" ]; then
    rm -f "$temporary"
    return 1
  fi
  mv "$temporary" "$file"
  printf '%s\n' "$$" > "$file.tick"
}

# The PR cache is the first board-gate dependency used on every runner tick.
# Validate there so the authenticated wrapper and run log already exist.
if declare -F _ht_pr_cache_rows >/dev/null 2>&1; then
  eval "$(declare -f _ht_pr_cache_rows | sed '1s/^_ht_pr_cache_rows /_hypertask_pr_cache_rows_base /')"
  _ht_pr_cache_rows() {
    local release_sections
    release_sections="$(_hypertask_release_section_file)"
    if [ ! -r "$release_sections.tick" ] || [ "$(cat "$release_sections.tick")" != "$$" ]; then
      _hypertask_validate_release_sections "${BOARD_ID:-}" || return 1
    fi
    _hypertask_pr_cache_rows_base "$@"
  }
fi

adapter_move_task() {
    local board_cli="$1" ref="$2" section="$3" actual="$3" task board="" file attempt
    local owner_section="${OWNER_REVIEW_SECTION:-Review}"
    if [ "${section,,}" = "${owner_section,,}" ]; then
      file="$(_hypertask_release_section_file)"
      task="$("$board_cli" --json task get "$ref" 2>/dev/null || true)"
      board="$(TASK="$task" python3 -c '
import json, os
raw = os.environ["TASK"]
start, end = raw.find("{"), raw.rfind("}")
try:
    doc = json.loads(raw[start:end + 1]) if start >= 0 and end > start else {}
    task = (doc.get("tasks") or [doc.get("task") or doc])[0]
    print(task.get("projectId") or task.get("boardId") or "")
except (IndexError, TypeError, ValueError):
    pass
' 2>/dev/null || true)"
      if [ -r "$file" ]; then
        if [ -n "$board" ]; then
          actual="$(awk -F '\t' -v board="$board" '$1 == board { print $2; exit }' "$file")"
        elif [ "$(wc -l < "$file")" -eq 1 ]; then
          actual="$(cut -f2- "$file")"
        fi
        [ -n "$actual" ] || actual="$section"
      fi
    fi

    for attempt in 1 2; do
      "$board_cli" task move "$ref" --section "$actual" && return 0
    done
    [ "${section,,}" = "${owner_section,,}" ] || return 1

    if ! adapter_unassign_task "$board_cli" "$ref" "${AGENT_ID:-}"; then
      _hypertask_release_log "PR release move failed for $ref and agent ${AGENT_ID:-unknown} could not be unassigned"
    fi
    if [ -n "${RELEASED_PRS:-}" ] && [ -n "${PR_REPO:-}" ] && [ -n "${PR_GATE_NUMBER:-}" ]; then
      mkdir -p "$(dirname "$RELEASED_PRS")"
      if ! awk -F '\t' -v repo="$PR_REPO" -v number="$PR_GATE_NUMBER" \
          '$1 == repo && $2 == number { found=1 } END { exit !found }' "$RELEASED_PRS" 2>/dev/null; then
        printf '%s\t%s\t%s\n' "$PR_REPO" "$PR_GATE_NUMBER" "$ref" >> "$RELEASED_PRS"
      fi
    fi
    [ -z "${BLOCKED:-}" ] || rm -f "$BLOCKED"
    _hypertask_release_log "PR release could not move $ref to $actual; agent unbound and verdict retained"
    if declare -F log >/dev/null 2>&1 && ! declare -F _hypertask_runner_log >/dev/null 2>&1; then
      eval "$(declare -f log | sed '1s/^log /_hypertask_runner_log /')"
      log() {
        if [ "$*" = "release of PR #${PR_GATE_NUMBER:-} failed; binding remains" ]; then
          _hypertask_runner_log "release of PR #${PR_GATE_NUMBER:-} stopped after the ticket move failed; agent unbound"
        else
          _hypertask_runner_log "$@"
        fi
      }
    fi
    return 1
}
