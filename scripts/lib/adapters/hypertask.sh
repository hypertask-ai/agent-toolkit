#!/usr/bin/env bash
# Direct ticket URL resolution for the Hypertask runtime.

# The runner historically treats 75 as an optional rate-limit skip. PR ownership
# must fail closed whenever GitHub cannot provide a complete answer.
_hypertask_base_pr_gate() (
  # shellcheck disable=SC1091
  . "$CORE_ROOT/adapters/hypertask/adapter.sh"
  adapter_pr_gate "$@"
)

_hypertask_checked_pr_gate() {
  local rc
  _hypertask_base_pr_gate "$@" && return 0
  rc=$?
  [ "$rc" -ne 75 ] || return 1
  return "$rc"
}

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

# Keep the board adapter's full ownership lookup, then apply the pickup policy
# here so runtime policy can evolve without coupling core to Hypertask.
adapter_pr_gate() (
  local slug="$5" opened_prs="${8:-}" state_dir rows rc monitor root
  root="${CORE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
  state_dir="$(dirname "${opened_prs:-${6%/*}/none}")"
  monitor="$state_dir/$slug.monitored-prs.json"
  if rows="$(CORE_ROOT="$root" _hypertask_checked_pr_gate "$@")"; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  mkdir -p "$state_dir"
  ROWS="$rows" NOW="${PR_GATE_NOW:-}" MONITOR="$monitor" python3 - <<'PYEOF'
import datetime
import json
import os

rows = [json.loads(line) for line in os.environ["ROWS"].splitlines() if line.strip()]
try:
    now = datetime.datetime.fromisoformat(os.environ.get("NOW", "").replace("Z", "+00:00"))
except ValueError:
    now = datetime.datetime.now(datetime.timezone.utc)
if now.tzinfo is None:
    now = now.replace(tzinfo=datetime.timezone.utc)


def age(row):
    try:
        value = datetime.datetime.fromisoformat(str(row.get("since") or "").replace("Z", "+00:00"))
        if value.tzinfo is None:
            value = value.replace(tzinfo=datetime.timezone.utc)
        return (now - value).total_seconds()
    except ValueError:
        return 0


for row in rows:
    stale = row.get("state") in {"red", "pending"} and age(row) >= 2 * 60 * 60
    if stale:
        row["action"] = "observe"
        row["pickup_slot"] = False
        row["unfixable"] = True

open_slots = [row for row in rows
              if row.get("pickup_slot") is True
              and row.get("state") in {"red", "pending", "awaiting-review"}]
gates = [row for row in rows if not row.get("unfixable")]
if len(open_slots) < 2:
    gates = [row for row in gates if row.get("state") != "awaiting-review"]

# Prefer repairable failures when multiple open PRs fill the available slots.
gates.sort(key=lambda row: (row.get("action") != "fix", str(row.get("since") or "")))
path = os.environ["MONITOR"]
temporary = path + ".new"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(rows, handle, sort_keys=True)
    handle.write("\n")
os.replace(temporary, path)
for row in gates:
    print(json.dumps(row, sort_keys=True))
PYEOF
)

# Print the live owner-review destination for one board. An unreadable section
# list keeps the configured value so a temporary board outage does not stop all work.
adapter_resolve_release_section() {
  local board_cli="$1" board="$2" configured="$3" raw resolved rc
  if ! raw="$("$board_cli" --json section list --project "$board" 2>/dev/null)"; then
    printf 'PR release destination validation unavailable for board %s; using configured destination "%s"\n' \
      "$board" "$configured" >&2
    printf '%s' "$configured"
    return 0
  fi
  if resolved="$(RAW="$raw" WANTED="$configured" python3 -c '
import json, os
raw = os.environ["RAW"]
try:
    doc = json.loads(raw)
except (TypeError, ValueError):
    raise SystemExit(2)
if isinstance(doc, list):
    sections = doc
elif isinstance(doc, dict):
    container = doc.get("project") if isinstance(doc.get("project"), dict) else doc
    if "sections" not in container:
        raise SystemExit(2)
    sections = container.get("sections") or []
else:
    raise SystemExit(2)
names = []
for item in sections:
    if isinstance(item, dict):
        name = item.get("name") or item.get("title") or item.get("section_title")
    else:
        name = item
    if name:
        names.append(str(name))
wanted = os.environ["WANTED"]
match = next((name for name in names if name.casefold() == wanted.casefold()), None)
if match:
    print(match)
    raise SystemExit
if wanted.casefold() == "review":
    manager = next((name for name in names if name.casefold() == "ht manager review"), None)
    if manager:
        print(manager)
        raise SystemExit
raise SystemExit(1)
' 2>/dev/null)"; then
    printf '%s' "$resolved"
    return 0
  else
    rc=$?
  fi
  case "$rc" in
    2)
      printf 'PR release destination validation unavailable for board %s; using configured destination "%s"\n' \
        "$board" "$configured" >&2
      printf '%s' "$configured"
      return 0 ;;
    *) return 1 ;;
  esac
}
