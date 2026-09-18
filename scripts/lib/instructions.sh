#!/usr/bin/env bash
# Queue-backed publication of maintainer instructions to the toolkit board.

INSTRUCTION_BOARD_ID="${INSTRUCTION_BOARD_ID:-5500}"
TICKET_FORMAT_CHECK="${TICKET_FORMAT_CHECK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/adapters/hypertask/plain-language/check-ticket.py}"
TASK_WRITER_PROMPT='Rewrite this ticket in the house format: title under 80 characters naming the change, then a bold outcome sentence, What went wrong, What changes as a numbered list, Done when. Keep all links and meaning.'
TASK_WRITER_REFUSAL_REASON=""

# board_section_or_first <project-json> <configured-section>
# Prints the live section name and whether it was an exact match or a fallback.
board_section_or_first() {
  PROJECT_JSON="$1" WANTED_SECTION="$2" python3 - <<'PYEOF'
import json
import os

raw = os.environ["PROJECT_JSON"]
start, end = raw.find("{"), raw.rfind("}")
if start < 0 or end <= start:
    raise SystemExit(1)
doc = json.loads(raw[start:end + 1])
project = doc.get("project") if isinstance(doc.get("project"), dict) else doc
sections = project.get("sections") or []

def value(item):
    if isinstance(item, dict):
        return str(item.get("section_title") or item.get("title") or item.get("name") or item.get("id") or "")
    return str(item or "")

names = [value(item) for item in sections if value(item)]
wanted = os.environ["WANTED_SECTION"]
for name in names:
    if name.casefold() == wanted.casefold():
        print(name)
        print("exact")
        raise SystemExit(0)
if names:
    print(names[0])
    print("fallback")
    raise SystemExit(0)
raise SystemExit(1)
PYEOF
}

# ticket_writer_rewrite <board-cli> <project> <raw> <title-file> <body-file> [done-when]
# Returns 1 when the writer itself is unavailable, and 2 when two drafts fail
# the structural gate. Callers may use their legacy formatter only for rc=1.
ticket_writer_rewrite() {
  local board_cli="$1" project="$2" raw="$3" title_file="$4" body_file="$5"
  local done_when="${6:-}" attempt prompt output reason err_file
  TASK_WRITER_REFUSAL_REASON=""
  err_file="$(mktemp "${TMPDIR:-/tmp}/task-writer.XXXXXX")"
  for attempt in 1 2; do
    prompt="$TASK_WRITER_PROMPT

Raw ticket text:
$raw"
    if [ "$attempt" -eq 2 ]; then
      prompt="$prompt

The previous draft failed the shape check. Shape rule: $reason. Fix every named part."
    fi
    if [ -n "${AGENT_AI_WRITER_FIXTURE:-}" ]; then
      if ! output="$(cat "$AGENT_AI_WRITER_FIXTURE" 2>"$err_file")"; then
        rm -f "$err_file"
        return 1
      fi
    elif ! output="$("$board_cli" --json ai write "$prompt" --project "$project" --mode task-writer 2>"$err_file")"; then
      rm -f "$err_file"
      return 1
    fi
    if ! OUTPUT="$output" python3 - "$title_file" "$body_file" <<'PYEOF'
import json
import os
import sys

raw = os.environ["OUTPUT"]
start, end = raw.find("{"), raw.rfind("}")
if start < 0 or end <= start:
    raise SystemExit(1)
doc = json.loads(raw[start:end + 1])
title = str(doc.get("title") or "").strip()
body = str(doc.get("html") or "").strip()
if doc.get("success") is False or not title or not body:
    raise SystemExit(1)
open(sys.argv[1], "w", encoding="utf-8").write(title)
open(sys.argv[2], "w", encoding="utf-8").write(body)
PYEOF
    then
      rm -f "$err_file"
      return 1
    fi
    if [ -n "$done_when" ]; then
      DONE_WHEN="$done_when" python3 - "$body_file" <<'PYEOF'
import html
import os
import re
import sys

path = sys.argv[1]
body = open(path, encoding="utf-8").read()
visible = re.sub(r"<[^>]+>", " ", body)
if not re.search(r"\bdone\s+when\b", visible, re.IGNORECASE):
    body += "<h2>Done when</h2><p>%s</p>" % html.escape(os.environ["DONE_WHEN"], quote=False)
    open(path, "w", encoding="utf-8").write(body)
PYEOF
    fi
    if reason="$(python3 "$TICKET_FORMAT_CHECK" "$(cat "$title_file")" "$body_file" 2>&1)"; then
      rm -f "$err_file"
      return 0
    fi
  done
  rm -f "$err_file"
  TASK_WRITER_REFUSAL_REASON="$(printf '%s' "$reason" | paste -sd ';' -)"
  return 2
}

instruction_conf_value() {
  python3 - "$1" "$2" <<'PYEOF'
import re
import shlex
import sys

path, wanted = sys.argv[1:]
value = ""
with open(path, encoding="utf-8") as handle:
    for raw in handle:
        match = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", raw.rstrip("\n"))
        if not match or match.group(1) != wanted:
            continue
        parsed = shlex.split(match.group(2), posix=True)
        value = parsed[0] if parsed else ""
print(value, end="")
PYEOF
}

instruction_file_is_queued() {
  python3 - "$1" <<'PYEOF'
import json
import sys

try:
    row = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(2)
raise SystemExit(0 if (row.get("status") or "queued") == "queued" else 1)
PYEOF
}

instruction_publish_file() { # instruction_publish_file <queue-json> <agent-conf>
  local queue_file="$1" conf="$2" adapter board_cli agent_id agent_name slug
  local work instruction_id marker_dir marker marker_fields ticket_ref ticket_url
  local project_out section section_result section_match configured_section create_out create_rc assign_out assign_rc writer_rc due priority
  local -a create_args

  [ -f "$queue_file" ] || {
    printf 'ERROR: queued instruction %s is missing. Do this next: recreate the instruction\n' "$queue_file" >&2
    return 1
  }
  [ -f "$conf" ] || {
    printf 'ERROR: no agent conf at %s. Do this next: restore the target agent conf and retry\n' "$conf" >&2
    return 1
  }
  adapter="$(instruction_conf_value "$conf" BOARD_ADAPTER)"
  board_cli="$(instruction_conf_value "$conf" BOARD_CLI)"
  agent_id="$(instruction_conf_value "$conf" AGENT_ID)"
  agent_name="$(instruction_conf_value "$conf" AGENT_NAME)"
  slug="$(instruction_conf_value "$conf" AGENT_SLUG)"
  [ -n "$slug" ] || slug="$(basename "$conf" .conf)"
  [ "$adapter" = "hypertask" ] || {
    printf 'ERROR: instruction target %s does not use Hypertask. Do this next: fix BOARD_ADAPTER and retry\n' "$slug" >&2
    return 1
  }
  [ -x "$board_cli" ] || {
    printf 'ERROR: instruction target %s has no executable board CLI at %s. Do this next: reinstall its board CLI and retry\n' "$slug" "$board_cli" >&2
    return 1
  }
  [ -n "$agent_id" ] && [ "$agent_id" != "6" ] || {
    printf 'ERROR: instruction target %s has no safe agent identity. Do this next: restore its agent id and retry\n' "$slug" >&2
    return 1
  }

  work="$(mktemp -d "${TMPDIR:-/tmp}/agent-instruction.XXXXXX")"
  if ! python3 - "$queue_file" "$work/title" "$work/body" "$work/raw" "$work/due" "$work/priority" > "$work/id" <<'PYEOF'
import datetime
import html
import json
import re
import sys

source, title_path, body_path, raw_path, due_path, priority_path = sys.argv[1:]
row = json.load(open(source, encoding="utf-8"))
instruction_id = str(row.get("id") or "")
instruction = str(row.get("instruction") or "")
ticket = str(row.get("ticket") or "")
if not re.fullmatch(r"[A-Za-z0-9._-]+", instruction_id):
    raise SystemExit("instruction id is missing or unsafe")
if not instruction.strip():
    raise SystemExit("instruction text is empty")
body = instruction.strip("\n")
first, _, rest = body.partition("\n")
if rest.strip() and len(first.strip()) <= 120 and not first.lstrip().startswith("<"):
    summary = first.strip()
    body = rest.strip("\n")
else:
    summary = " ".join(instruction.split())
    if len(summary) > 120:
        summary = summary[:117].rstrip() + "..."
parts = []
if body.lstrip().startswith("<"):
    parts.append(body)
else:
    parts.append("<p><strong>Instruction</strong></p>")
    for paragraph in re.split(r"\n[ \t]*\n", body):
        escaped = html.escape(paragraph, quote=False).replace("\n", "<br>")
        parts.append("<p>%s</p>" % escaped)
raw = instruction.strip()
if ticket:
    escaped_ticket = html.escape(ticket, quote=True)
    parts.append('<p><strong>Source ticket</strong>: <a href="%s">%s</a></p>' %
                 (escaped_ticket, html.escape(ticket, quote=False)))
    raw += "\n\nSource ticket: " + ticket
urgent = bool(re.search(r"\burgent\b", instruction, re.I))
due = str(row.get("due") or "")
if not due:
    try:
        created = datetime.datetime.fromisoformat(str(row.get("created") or "").replace("Z", "+00:00"))
    except ValueError:
        created = datetime.datetime.now(datetime.timezone.utc)
    due = (created + datetime.timedelta(hours=1 if urgent else 4)).isoformat()
priority = str(row.get("priority") or ("urgent" if urgent else ""))
open(title_path, "w", encoding="utf-8").write(summary)
open(body_path, "w", encoding="utf-8").write("".join(parts))
open(raw_path, "w", encoding="utf-8").write(raw)
open(due_path, "w", encoding="utf-8").write(due)
open(priority_path, "w", encoding="utf-8").write(priority)
print(instruction_id)
PYEOF
  then
    printf 'ERROR: queued instruction %s is invalid. Do this next: fix or remove that queue file\n' "$queue_file" >&2
    rm -rf "$work"
    return 1
  fi
  instruction_id="$(cat "$work/id")"
  cp "$work/title" "$work/title.original"
  cp "$work/body" "$work/body.original"
  if ticket_writer_rewrite "$board_cli" "$INSTRUCTION_BOARD_ID" "$(cat "$work/raw")" "$work/title" "$work/body"; then
    :
  else
    writer_rc=$?
    cp "$work/title.original" "$work/title"
    cp "$work/body.original" "$work/body"
    if [ "$writer_rc" -eq 1 ]; then
      printf 'Task Writer unavailable; using the original instruction ticket format.\n' >&2
    else
      printf 'WARNING: Task Writer rewrite failed two shape checks; using the original instruction unchanged.\n' >&2
    fi
  fi
  marker_dir="${INSTRUCTION_TICKET_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-template/instruction-tickets}"
  marker="$marker_dir/$slug-$instruction_id.json"
  mkdir -p "$marker_dir"
  chmod 700 "$marker_dir"

  if [ -f "$marker" ]; then
    if ! marker_fields="$(python3 - "$marker" <<'PYEOF'
import json
import sys

row = json.load(open(sys.argv[1], encoding="utf-8"))
ref = str(row.get("ticket_ref") or "")
url = str(row.get("ticket_url") or "")
if not ref or not url:
    raise SystemExit(1)
print(ref)
print(url)
PYEOF
)"; then
      printf 'ERROR: instruction ticket marker %s is invalid. Do this next: repair the marker and retry\n' "$marker" >&2
      rm -rf "$work"
      return 1
    fi
    { IFS= read -r ticket_ref; IFS= read -r ticket_url; } <<< "$marker_fields"
  else
    if project_out="$("$board_cli" --json project show "$INSTRUCTION_BOARD_ID" 2>&1)"; then
      :
    else
      create_rc=$?
      printf '%s\n' "$project_out" >&2
      rm -rf "$work"
      return "$create_rc"
    fi
    configured_section="${FEEDBACK_BOARD_SECTION:-Backlog}"
    if ! section_result="$(board_section_or_first "$project_out" "$configured_section")"; then
      printf 'ERROR: board %s has no sections. Do this next: add an intake section and retry\n' "$INSTRUCTION_BOARD_ID" >&2
      rm -rf "$work"
      return 1
    fi
    section="$(printf '%s\n' "$section_result" | sed -n '1p')"
    section_match="$(printf '%s\n' "$section_result" | sed -n '2p')"
    if [ "$section_match" = fallback ]; then
      printf 'Instruction board section "%s" was not found; using first section "%s".\n' "$configured_section" "$section" >&2
    fi

    due="$(cat "$work/due")"
    priority="$(cat "$work/priority")"
    create_args=(task create --project "$INSTRUCTION_BOARD_ID" --section "$section"
      --title "$(cat "$work/title")" --description "$(cat "$work/body")" --due "$due")
    [ -z "$priority" ] || create_args+=(--priority "$priority")
    create_args+=(--json)
    if create_out="$("$board_cli" "${create_args[@]}" 2>&1)"; then
      create_rc=0
    else
      create_rc=$?
    fi
    if [ "$create_rc" -ne 0 ]; then
      printf '%s\n' "$create_out" >&2
      rm -rf "$work"
      return "$create_rc"
    fi
    if ! CREATE_OUT="$create_out" INSTRUCTION_ID="$instruction_id" \
      AGENT_ID="$agent_id" AGENT_NAME="$agent_name" BOARD_ID="$INSTRUCTION_BOARD_ID" \
      python3 - "$marker.new" <<'PYEOF'
import datetime
import json
import os
import sys

raw = os.environ["CREATE_OUT"]
start, end = raw.find("{"), raw.rfind("}")
if start < 0 or end <= start:
    raise SystemExit("ticket creation returned no JSON")
doc = json.loads(raw[start:end + 1])
task = doc.get("task") if isinstance(doc.get("task"), dict) else doc
ref = str(task.get("ticketNumber") or "")
index = str(task.get("uniqueIndex") or (ref.rsplit("-", 1)[-1] if "-" in ref else ""))
project = str(task.get("projectId") or task.get("boardId") or os.environ["BOARD_ID"])
if not ref or not index:
    raise SystemExit("ticket creation returned no ticket id")
row = {
    "instruction_id": os.environ["INSTRUCTION_ID"],
    "ticket_id": str(task.get("id") or ref),
    "ticket_ref": ref,
    "ticket_url": "https://app.hypertask.ai/detail/project-%s/%s" % (project, index),
    "assignee_id": os.environ["AGENT_ID"],
    "assignee": os.environ["AGENT_NAME"],
    "created": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(row, handle, indent=2)
    handle.write("\n")
os.chmod(sys.argv[1], 0o600)
PYEOF
    then
      printf 'ERROR: ticket creation succeeded but its id could not be recorded. Do this next: inspect the API output before retrying: %s\n' "$create_out" >&2
      rm -f "$marker.new"
      rm -rf "$work"
      return 1
    fi
    mv "$marker.new" "$marker"
    ticket_ref="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ticket_ref"])' "$marker")"
    ticket_url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ticket_url"])' "$marker")"
  fi

  if assign_out="$("$board_cli" task assign "$ticket_ref" --self 2>&1)"; then
    assign_rc=0
  else
    assign_rc=$?
  fi
  if [ "$assign_rc" -ne 0 ]; then
    printf '%s\n' "$assign_out" >&2
    rm -rf "$work"
    return "$assign_rc"
  fi

  rm -f "$queue_file"
  rm -rf "$work"
  printf 'instruction filed: %s %s\n' "$ticket_ref" "$ticket_url"
}
