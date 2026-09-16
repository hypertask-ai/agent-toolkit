#!/usr/bin/env bash
# adapters/hypertask/adapter.sh
#
# Everything in this file talks to a Hypertask board. Core calls these
# functions and never learns what is behind them.
#
# Reads go over REST with the agent's bearer token (same endpoints the `ht`
# helper uses: Authorization: Bearer <token> against <api>/mcp/...). Writes go
# through the agent's own CLI wrapper so the board records the agent, not
# whoever happens to own the shell.

adapter_id() { printf 'hypertask'; }

# Where this tracker's identities already live on a machine.
adapter_config_dir_default() { printf '%s/.config/hypertask-agents' "$HOME"; }

adapter_require_tools() {
  command -v hypertask >/dev/null 2>&1 || die \
    "the hypertask CLI is not on PATH" \
    "install it (npm i -g @hypertask/hypertask_cli) and re-run"
  command -v curl >/dev/null 2>&1 || die "curl is not on PATH" "install curl"
  command -v python3 >/dev/null 2>&1 || die "python3 is not on PATH" "install python3"
}

# Fleet wiring means a long-lived worker runtime is actually running here, not
# merely that a unit file was copied in at some point. A machine can have the
# template and the worker script and still have no router, no webhook receiver
# and nothing running, which is exactly the dead end this check exists to stop.
# The proof is a live worker instance.
adapter_supports_fleet_wiring() {
  systemctl --user cat 'hypertask-agent-worker@.service' >/dev/null 2>&1 || return 1
  [ -n "$(systemctl --user list-units 'hypertask-agent-worker@*.service' \
            --state=active --no-legend --plain 2>/dev/null)" ]
}

# ---------- REST base ----------
_ht_api_base() {
  if [ -n "${BOARD_API_URL:-}" ]; then
    printf '%s' "$BOARD_API_URL"
  elif [ -r "$HOME/.hypertask/config.json" ]; then
    python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["apiUrl"])' \
      "$HOME/.hypertask/config.json" 2>/dev/null || printf 'https://app.hypertask.ai/api'
  else
    printf 'https://app.hypertask.ai/api'
  fi
}

# _ht_get <token-file> <path-with-query>
# `ht` has no -f, so a 404 or a bot-challenge page comes back as exit 0 with a
# junk body. Check the status code here instead of letting python choke on HTML.
_ht_get() {
  local token_file="$1" path="$2" base tok body status
  [ -r "$token_file" ] || die "cannot read the agent token file $token_file" \
    "check TOKEN_FILE in the conf, or capture the token again"
  tok="$(cat "$token_file")"
  base="$(_ht_api_base)"
  body="$(curl -sS -w $'\n%{http_code}' -H "Authorization: Bearer $tok" "${base}${path}" 2>/dev/null)" \
    || die "the board API call to ${base}${path} failed at the network level" \
           "check connectivity, then re-run"
  status="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if [ "$status" != "200" ]; then
    die "the board API returned HTTP $status for ${path}" \
        "if this is 401 the token is wrong or revoked; if it is 403 or an HTML body the host is rate limited, back off before retrying"
  fi
  printf '%s' "$body"
}

# ---------- identity ----------
# adapter_find_identity <display-name> <slug> : prints the id, or nothing.
# Read-only, and it runs before any local write so a duplicate name fails early.
adapter_find_identity() {
  hypertask agents list --json 2>/dev/null | python3 -c '
import json, re, sys
wanted_name = sys.argv[1].casefold()
wanted_slug = sys.argv[2]
doc = json.load(sys.stdin)
agents = doc if isinstance(doc, list) else doc.get("agents", [])
def slug(value):
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9]+", "-", value.casefold()))
for agent in agents:
    name = str(agent.get("display_name") or agent.get("name") or "")
    if name.casefold() == wanted_name or agent.get("slug") == wanted_slug or slug(name) == wanted_slug:
        print(agent.get("id", ""))
        break
' "$1" "$2"
}

# The exact command that mints a replacement token, for the error message when
# capture fails. It is a hint, never run automatically: rotating invalidates
# the token the agent is using right now.
adapter_rotate_token_hint() {
  printf 'hypertask agents rotate-token --id %s' "${1:-<agent_id>}"
}

# Prints the raw create output on stdout. The bearer token is in there and is
# shown exactly once, so the caller must persist it immediately.
adapter_create_identity() {
  local display_name="$1" board_id="$2" role="${3:-write}"
  hypertask agents create --name "$display_name" --project "$board_id" --role "$role"
}

# adapter_extract_token <file-holding-create-output>
# The documented response is
#   {"success":true,"agent":{"id":...,"display_name":...},"token":"<jwt>",...}
# but the CLI may print a human line around it, so pull the outermost JSON
# object out of the text first and then read the field by name. Never grep:
# a greedy match on "token" picks up the prose in `message`.
adapter_extract_token() {
  python3 - "$1" <<'PYEOF'
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
start, end = raw.find("{"), raw.rfind("}")
if start == -1 or end <= start:
    sys.exit(1)
try:
    doc = json.loads(raw[start:end + 1])
except json.JSONDecodeError:
    sys.exit(1)
candidates = [doc.get("token")]
agent = doc.get("agent")
if isinstance(agent, dict):
    candidates.append(agent.get("token"))
for key in ("bearer_token", "bearerToken", "agent_token", "agentToken"):
    candidates.append(doc.get(key))
for value in candidates:
    # A Hypertask agent token is a JWT: three dot-separated segments.
    if isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", value.strip()):
        sys.stdout.write(value.strip())
        sys.exit(0)
sys.exit(1)
PYEOF
}

adapter_extract_identity_id() {
  python3 - "$1" <<'PYEOF'
import json, sys
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
start, end = raw.find("{"), raw.rfind("}")
if start == -1 or end <= start:
    sys.exit(1)
try:
    doc = json.loads(raw[start:end + 1])
except json.JSONDecodeError:
    sys.exit(1)
agent = doc.get("agent") if isinstance(doc.get("agent"), dict) else doc
value = agent.get("id") or ""
if not value:
    sys.exit(1)
sys.stdout.write(str(value))
PYEOF
}

# A one-line wrapper so every board write is attributed to the agent. The token
# is read from its 0600 file at call time; it is never baked into the wrapper,
# a command line, or a prompt.
#
# It also enforces the comment rules a run has to follow, instead of leaving
# them to the prompt alone: a model that has already decided the ticket
# needs no action posted the same "Nothing from you." comment three times in
# ten minutes (20:37, 20:44, 20:47) because nothing in the prompt can make it
# check what it already said. This checks for real: same first line already
# posted by this agent, or three comments already on this ticket, refuses
# the call instead of forwarding it, and says why on stderr and in this
# agent's own tick log, never on the ticket.
adapter_install_board_cli() {
  local slug="$1" token_file="$2" dest="$3" agent_name="${4:-}"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<EOF
#!/usr/bin/env bash
# $slug: the board CLI acting as this agent.
set -euo pipefail
TOKEN_FILE="$token_file"
AGENT_NAME="$agent_name"
RUN_LOG="\${XDG_STATE_HOME:-\$HOME/.local/state}/agent-board-poll/$slug.log"
POSTED="\${XDG_STATE_HOME:-\$HOME/.local/state}/agent-board-poll/$slug.posted-comments"
[ -r "\$TOKEN_FILE" ] || {
  echo "ERROR: cannot read \$TOKEN_FILE. Do this next: capture the agent token into that file" >&2
  exit 1
}
TOKEN="\$(cat "\$TOKEN_FILE")"

_comment_cap_note() {
  # \$1: the message. Stderr so the model sees it now, plus the agent's own
  # log so a human or the supervisor sees it later without opening the ticket.
  echo "\$1" >&2
  mkdir -p "\$(dirname "\$RUN_LOG")" 2>/dev/null || true
  printf '%s comment-cap: %s\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" "\$1" >> "\$RUN_LOG" 2>/dev/null || true
}

if [ "\${1:-}" = "comment" ] && [ "\${2:-}" = "add" ] && [ -n "\${3:-}" ]; then
  REF="\$3"
  TEXT=""
  args=("\$@")
  for ((i = 0; i < \${#args[@]}; i++)); do
    case "\${args[\$i]}" in
      --text|--body) TEXT="\${args[\$((i + 1))]:-}" ;;
    esac
  done
  if [ -n "\$TEXT" ]; then
    EXISTING="\$(hypertask --token "\$TOKEN" --json comment list "\$REF" 2>/dev/null || echo '{"comments":[]}')"
    VERDICT="\$(EXISTING="\$EXISTING" NEW_TEXT="\$TEXT" AGENT_NAME="\$AGENT_NAME" python3 -c '
import json, os, re

def first_line(html):
    # The bold lead, not the whole comment: "Nothing from you." said three
    # times with different filler after it is still the same reply. A
    # leading <strong>/<b> is the bold-lead convention every prompt in this
    # template uses; fall back to the first sentence when there is none.
    stripped = html.lstrip()
    lead = re.match(r"^\s*<(strong|b)[^>]*>(.*?)</\1>", stripped, re.IGNORECASE | re.DOTALL)
    if lead:
        text = re.sub(r"<[^>]+>", " ", lead.group(2))
    else:
        text = re.sub(r"<[^>]+>", " ", stripped)
        text = re.split(r"(?<=[.!?])\s", text, maxsplit=1)[0]
    return " ".join(text.split())[:80].strip().casefold()

def author_of(c):
    who = c.get("agent") or c.get("creator") or c.get("user") or {}
    if isinstance(who, dict):
        return str(who.get("displayName") or who.get("name") or "")
    return str(who)

try:
    comments = json.loads(os.environ["EXISTING"]).get("comments") or []
except json.JSONDecodeError:
    comments = []
agent_name = os.environ["AGENT_NAME"].strip().casefold()
new_first = first_line(os.environ["NEW_TEXT"])

mine = []
for c in comments:
    if agent_name and author_of(c).strip().casefold() != agent_name:
        continue
    text = c.get("text") or c.get("commentText") or c.get("comment") or c.get("html") or ""
    mine.append(first_line(text))

if new_first and new_first in mine:
    print("DUP")
elif len(mine) >= 3:
    print("CAP")
else:
    print("OK")
')"
    case "\$VERDICT" in
      DUP)
        _comment_cap_note "comment add refused on \$REF: this agent already has a comment starting the same way, not posting it again"
        exit 0 ;;
      CAP)
        _comment_cap_note "comment add refused on \$REF: cap reached (3 comments already on this ticket), ending this run's posting"
        exit 0 ;;
    esac
    # Posted for real: run it directly (not exec) so this script can look up
    # the id the board gave the new comment and hand it to core. Core writes
    # that id to this agent's seen-state after the run, so the next tick's
    # state key already matches this agent's own reply and the ticket is not
    # picked back up as if it were untouched. Without this, only the rank-3
    # "new work" path skipped an agent's own comment; a claimed-unfinished
    # ticket (rank 1) had no such guard and got reprocessed every tick.
    if OUT="\$(hypertask --token "\$TOKEN" "\$@")"; then
      RC=0
    else
      RC=\$?
    fi
    printf '%s\n' "\$OUT"
    if [ "\$RC" -eq 0 ]; then
      LISTED="\$(hypertask --token "\$TOKEN" --json comment list "\$REF" 2>/dev/null || echo '{"comments":[]}')"
      NEWID="\$(LISTED="\$LISTED" AGENT_NAME="\$AGENT_NAME" python3 -c '
import json, os

def author_of(c):
    who = c.get("agent") or c.get("creator") or c.get("user") or {}
    if isinstance(who, dict):
        return str(who.get("displayName") or who.get("name") or "")
    return str(who)

try:
    comments = json.loads(os.environ["LISTED"]).get("comments") or []
except json.JSONDecodeError:
    comments = []
agent_name = os.environ["AGENT_NAME"].strip().casefold()
mine = [c for c in comments if not agent_name or author_of(c).strip().casefold() == agent_name]
if mine:
    best = max(mine, key=lambda c: c.get("id") or 0)
    print(best.get("id") or "")
')"
      if [ -n "\$NEWID" ]; then
        mkdir -p "\$(dirname "\$POSTED")" 2>/dev/null || true
        printf '%s %s\n' "\$REF" "\$NEWID" >> "\$POSTED" 2>/dev/null || true
      fi
    fi
    exit "\$RC"
  fi
fi

exec hypertask --token "\$TOKEN" "\$@"
EOF
  chmod 755 "$dest"
}

# ---------- reads ----------
# adapter_list_candidates <token-file> <board-id> <sections-csv>
# One JSON object per line: id, ref, section, title, description, agent_ids,
# comment_count, url. agent_ids holds the AGENT ids on the ticket: an
# agent-assigned ticket still carries the owning user's numeric id at the top
# of each assignee record, with the agent's uuid nested under "agent".
# An agent may watch more than one board: BOARD_ID takes a comma-separated
# list, and every row says which board it came from, because the later reads
# for that ticket have to go back to the same one.
adapter_list_candidates() {
  local token_file="$1" board_id="$2" sections="$3" json one
  for one in $(printf '%s' "$board_id" | tr ',' ' '); do
    [ -n "$one" ] || continue
    json="$(_ht_get "$token_file" "/mcp/tasks?project_id=${one}&limit=100")"
  # The board reply is far too large for an environment variable, so it goes in
  # on stdin and the program goes in as one argv.
  printf '%s' "$json" | SECTIONS="$sections" BOARD_ID="$one" python3 -c '
import json, os, sys
# "*" means every column: an agent answering @mentions cannot know in advance
# which column the person asking was looking at.
raw = os.environ["SECTIONS"].strip()
wanted = [] if raw == "*" else [s.strip().casefold() for s in raw.split(",") if s.strip()]
board = os.environ["BOARD_ID"]
doc = json.load(sys.stdin)
for task in doc.get("tasks") or []:
    section = str(task.get("section") or "")
    if wanted and section.casefold() not in wanted:
        continue
    agent_ids = []
    assignees = task.get("assignees") or []
    for who in assignees:
        agent = who.get("agent") if isinstance(who, dict) else None
        if isinstance(agent, dict) and agent.get("id"):
            agent_ids.append(str(agent["id"]))
    # Labels decide whether a ticket is open season. A board carries them under
    # several shapes depending on how the task was created, so take the name
    # off whichever one is present and lowercase it once, here.
    labels = []
    for label in task.get("labels") or []:
        if isinstance(label, dict):
            name = label.get("name") or label.get("title") or label.get("label") or ""
        else:
            name = str(label)
        if name:
            labels.append(str(name).strip().casefold())
    ref = str(task.get("ticketNumber") or "")
    index = ref.rsplit("-", 1)[-1] if "-" in ref else str(task.get("id"))
    print(json.dumps({
        "id": task.get("id"),
        "ref": ref,
        "section": section,
        "title": task.get("title") or "",
        "description": task.get("description") or "",
        "agent_ids": agent_ids,
        # Anyone at all on the ticket, human or agent: a ticket with a name on
        # it belongs to whoever put it there, and is not free to pick up.
        "assignee_count": len(assignees),
        "labels": labels,
        "comment_count": task.get("commentCount") or 0,
        "board": board,
        "url": "https://app.hypertask.ai/detail/project-%s/%s" % (board, index),
    }))
'
  done
}

# adapter_latest_comment <token-file> <task-id> <board-id>
# JSON {"id":..., "html":..., "author":..., "agent_id":...} or an empty line
# when there is none.
#
# A comment's real actor is the "agent" field, not "creator": every comment
# posted through an agent's own board CLI still carries the account owner as
# creator, because the token is scoped under that account. "agent" is null
# only for a comment a person typed themselves, so author here is the agent's
# name when one posted it, the creator's name otherwise, and agent_id is set
# only in the first case.
adapter_latest_comment() {
  local token_file="$1" task_id="$2" board_id="$3" json
  json="$(_ht_get "$token_file" "/mcp/comments?task_id=${task_id}&project_id=${board_id}")"
  printf '%s' "$json" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
comments = doc.get("comments") or []
if not comments:
    print("")
    sys.exit(0)
def key(comment):
    return (comment.get("createdAt") or "", comment.get("id") or 0)
newest = max(comments, key=key)
agent = newest.get("agent") if isinstance(newest.get("agent"), dict) else None
creator = newest.get("creator") if isinstance(newest.get("creator"), dict) else {}
author = (agent or creator).get("displayName") or ""
print(json.dumps({
    "id": newest.get("id"),
    "html": newest.get("text") or newest.get("commentText") or newest.get("html") or "",
    "author": author,
    "agent_id": (agent or {}).get("id") or "",
}))
'
}

# _ht_owned_row <token-file> <task-id> <row-json> <board-id> <agent-id>
# Given a candidate row (already known to be assigned to this agent, or to
# have at least one comment) and its task id, prints the same row with
# "trigger": "new_comment" added when its newest comment is a human's and
# this agent owns the ticket, or nothing at all. One comments read.
#
# Ownership here is assigned, or having posted the most recent agent comment
# before this one: the "claimed by a comment, never assigned" case a plain
# Q&A agent needs, since it has no claim step of its own. A ticket only ever
# claimed in words no comment carries (rare, and unusual for this board's own
# claim-ticket.sh, which assigns) is outside this check's reach.
_ht_owned_row() {
  local token_file="$1" task_id="$2" row="$3" board_id="$4" agent_id="$5" comments
  comments="$(_ht_get "$token_file" "/mcp/comments?task_id=${task_id}&project_id=${board_id}" 2>/dev/null)" || return 0
  ROW="$row" CJ="$comments" AID="$agent_id" python3 -c '
import json, os, sys
row = json.loads(os.environ["ROW"])
doc = json.loads(os.environ["CJ"])
aid = os.environ["AID"]
comments = doc.get("comments") or []
if not comments:
    sys.exit(0)
comments.sort(key=lambda c: (c.get("createdAt") or "", c.get("id") or 0))
newest = comments[-1]
# A comment posted by any agent, this one or another, is not new work for a
# human-reply trigger: the thread already has the last word from an agent.
if isinstance(newest.get("agent"), dict):
    sys.exit(0)
assigned = aid in (row.get("agent_ids") or [])
last_agent = None
for c in reversed(comments[:-1]):
    a = c.get("agent")
    if isinstance(a, dict):
        last_agent = a
        break
claimed = bool(last_agent) and str(last_agent.get("id") or "") == aid
if not (assigned or claimed):
    sys.exit(0)
row["trigger"] = "new_comment"
print(json.dumps(row))
'
}

# adapter_new_comments_on_owned <token-file> <board-id> <agent-id> <agent-name>
# Optional: core calls this only if it is defined (declare -F), the same way
# it calls adapter_pick_rank. Prints one row per ticket, same shape as
# adapter_list_candidates plus "trigger": "new_comment", for every ticket this
# agent owns whose newest comment is a human's -- in any section, not only
# WATCH_SECTIONS, because a ticket this agent claimed can move to a review
# column the poll never watches, and a reply there would otherwise be
# invisible. Bounded by OWNED_COMMENT_READ_CAP (default 40) comments reads
# PER BOARD per tick, assigned tickets checked first, and within the
# comment-only ones, most recently updated first: an agent with more owned
# tickets than the cap allows still surfaces a fresh human reply the same
# tick it lands, instead of a reply on whichever ticket happens to sort
# first getting starved forever behind an always-checked-first stale one.
adapter_new_comments_on_owned() {
  local token_file="$1" board_id="$2" agent_id="$3" agent_name="$4"
  local one json rows cand cand_id reads cap="${OWNED_COMMENT_READ_CAP:-40}"
  for one in $(printf '%s' "$board_id" | tr ',' ' '); do
    [ -n "$one" ] || continue
    # Each board gets its own budget of $cap reads: a board with more owned
    # tickets than the cap must not spend the next board's allowance too,
    # which is how a warning could once fire "on board 5156" without this
    # function ever having looked at board 5156 at all.
    reads=0
    json="$(_ht_get "$token_file" "/mcp/tasks?project_id=${one}&limit=100")"
    rows="$(printf '%s' "$json" | BOARD="$one" AID="$agent_id" python3 -c '
import json, os, sys
board = os.environ["BOARD"]
aid = os.environ["AID"]
doc = json.load(sys.stdin)
assigned_rows, commented_rows = [], []
for task in doc.get("tasks") or []:
    section = str(task.get("section") or "")
    if section.casefold() in ("done", "archive", "shipped"):
        continue
    agent_ids = []
    assignees = task.get("assignees") or []
    for who in assignees:
        a = who.get("agent") if isinstance(who, dict) else None
        if isinstance(a, dict) and a.get("id"):
            agent_ids.append(str(a["id"]))
    labels = []
    for label in task.get("labels") or []:
        if isinstance(label, dict):
            name = label.get("name") or label.get("title") or label.get("label") or ""
        else:
            name = str(label)
        if name:
            labels.append(str(name).strip().casefold())
    ref = str(task.get("ticketNumber") or "")
    index = ref.rsplit("-", 1)[-1] if "-" in ref else str(task.get("id"))
    row = {
        "id": task.get("id"), "ref": ref, "section": section,
        "title": task.get("title") or "", "description": task.get("description") or "",
        "agent_ids": agent_ids, "assignee_count": len(assignees), "labels": labels,
        "comment_count": task.get("commentCount") or 0, "board": board,
        "url": "https://app.hypertask.ai/detail/project-%s/%s" % (board, index),
    }
    if aid in agent_ids:
        assigned_rows.append(row)
    elif row["comment_count"] > 0:
        commented_rows.append((task.get("updatedAt") or "", row))
# Assigned tickets first (this agent owns the outcome outright), then the
# merely-commented-on ones newest-activity-first, so a cap that has to skip
# some skips the stalest, not whichever loaded first from the API.
commented_rows.sort(key=lambda pair: pair[0], reverse=True)
for row in assigned_rows + [row for _, row in commented_rows]:
    print(json.dumps(row))
')"
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      if [ "$reads" -ge "$cap" ]; then
        warn "adapter_new_comments_on_owned: hit OWNED_COMMENT_READ_CAP=$cap on board $one, the rest wait for the next tick"
        break
      fi
      reads=$((reads + 1))
      cand_id="$(ROW="$cand" python3 -c 'import json,os;print(json.loads(os.environ["ROW"])["id"])')"
      _ht_owned_row "$token_file" "$cand_id" "$cand" "$one" "$agent_id"
    done <<< "$rows"
  done
}

# The marker an @mention of this agent leaves in stored comment HTML:
#   <span data-type="mention" class="mention" data-id="<Name>"
#         data-label="agent-<uuid>">Name</span>
# A user mention uses data-label="name-<userId>" instead, so matching on
# "agent-<uuid>" cannot collide with a person.
adapter_mention_token() { printf 'agent-%s' "$1"; }

adapter_task_url() {
  local board_id="$1" ref="$2"
  printf 'https://app.hypertask.ai/detail/project-%s/%s' "$board_id" "${ref##*-}"
}

# ---------- triage ----------
# Everything the scorer needs about one ticket, as one JSON object on stdout.
# Core does not know what a QA comment looks like or where a pull request
# lives; this does, because both are this board's business.
#
# adapter_triage_input <token-file> <board-id> <ref> <task-id> <title> <description>
adapter_triage_input() {
  local token_file="$1" board_id="$2" ref="$3" task_id="$4" title="$5" description="$6"
  local comments pr_json="[]" repo="${PR_REPO:-}"

  comments="$(_ht_get "$token_file" "/mcp/comments?task_id=${task_id}&project_id=${board_id}")" \
    || comments='{"comments":[]}'

  # A pull request that closed without merging is the quietest failed attempt
  # there is: nothing is written on the ticket when somebody gives up on a
  # branch. No gh, no claim either way.
  if [ -n "$repo" ] && command -v gh >/dev/null 2>&1; then
    pr_json="$(gh pr list --repo "$repo" --state all --search "$ref" \
                 --json number,state,url,headRefName --limit 10 2>/dev/null || printf '[]')"
  fi

  printf '%s' "$comments" | \
  REF="$ref" TITLE="$title" DESCRIPTION="$description" PR_JSON="${pr_json:-[]}" python3 -c '
import json, os, re, sys

def text_of(comment):
    return comment.get("text") or comment.get("comment") or comment.get("html") or ""

doc = json.load(sys.stdin)
comments = [text_of(c) for c in (doc.get("comments") or [])]

ref = os.environ["REF"]
prs = json.loads(os.environ["PR_JSON"]) or []
prs = [p for p in prs if ref.casefold() in
       (str(p.get("headRefName") or "") + " " + str(p.get("url") or "")).casefold()]
merged = any(str(p.get("state") or "").upper() == "MERGED" for p in prs)
closed_unmerged = (not merged) and any(
    str(p.get("state") or "").upper() == "CLOSED" for p in prs)

print(json.dumps({
    "ref": ref,
    "title": os.environ["TITLE"],
    "description": os.environ["DESCRIPTION"],
    "comments": comments,
    "closed_unmerged_pr": closed_unmerged,
}))
'
}

# ---------- writes (through the agent's own CLI) ----------
adapter_post_comment() {
  local board_cli="$1" ref="$2" html="$3"
  "$board_cli" comment add "$ref" --text "$html"
}

adapter_move_task() {
  local board_cli="$1" ref="$2" section="$3"
  "$board_cli" task move "$ref" --section "$section"
}

# adapter_add_label <board-cli> <token-file> <board-id> <ref> <label>
# Adds one label and keeps the rest. Three things this board makes you do:
#
#  - `task update --labels` SETS the list, so the ticket's current labels have
#    to go back in with the new one or Bug, CLI and the rest are wiped.
#  - a label that does not exist on the project is an error, not an implicit
#    create, so it is created first when it is missing.
#  - name resolution is fuzzy ("hard" would happily match "intensity:hard"),
#    so everything here is resolved to label UUIDs before the write.
adapter_add_label() {
  local board_cli="$1" token_file="$2" board_id="$3" ref="$4" label="$5"
  local labels_json label_id task_json current ids

  labels_json="$(_ht_get "$token_file" "/mcp/projects/${board_id}/labels")" || return 1
  label_id="$(LJ="$labels_json" WANT="$label" python3 -c '
import json, os
want = os.environ["WANT"].strip().casefold()
for row in json.loads(os.environ["LJ"]).get("labels") or []:
    if str(row.get("name") or "").strip().casefold() == want:
        print(row.get("id") or "")
        break')"

  if [ -z "$label_id" ]; then
    "$board_cli" labels create --project "$board_id" --name "$label" >/dev/null 2>&1 || return 1
    labels_json="$(_ht_get "$token_file" "/mcp/projects/${board_id}/labels")" || return 1
    label_id="$(LJ="$labels_json" WANT="$label" python3 -c '
import json, os
want = os.environ["WANT"].strip().casefold()
for row in json.loads(os.environ["LJ"]).get("labels") or []:
    if str(row.get("name") or "").strip().casefold() == want:
        print(row.get("id") or "")
        break')"
    [ -n "$label_id" ] || return 1
  fi

  task_json="$(_ht_get "$token_file" "/mcp/tasks?ticket_number=${ref}")" || return 1
  ids="$(TJ="$task_json" NEW="$label_id" python3 -c '
import json, os, sys
tasks = json.loads(os.environ["TJ"]).get("tasks") or []
if not tasks:
    sys.exit(1)
ids = []
for row in tasks[0].get("labels") or []:
    got = row.get("id") if isinstance(row, dict) else None
    if got and got not in ids:
        ids.append(str(got))
new = os.environ["NEW"]
if new in ids:
    sys.exit(2)          # already there; nothing to write
ids.append(new)
print(",".join(ids))')" || {
    # exit 2 is "the ticket already carries this label", which is a success.
    [ "$?" = "2" ] && return 0
    return 1
  }
  [ -n "$ids" ] || return 1

  "$board_cli" task update "$ref" --labels "$ids" >/dev/null 2>&1 || return 1
}

# ---------- one ticket until live ----------
# adapter_pr_gate <token-file> <board-ids> <agent-id> <agent-name> <slug> <cache-dir>
# Prints one JSON object for the oldest pull request this agent still owes, or
# nothing when every attributed pull request is live. Attribution is the
# configured branch prefix (default agent/<slug>-) plus ticket references in a
# PR title/body/branch that name a ticket assigned to or claimed by this agent.
#
# LIVE is merged + the base contains the merge commit + the newest Production
# deployment created after the merge succeeded and contains that commit. Repos
# with no deployment records use merged + contained as the documented fallback.
adapter_pr_gate() (
  local token_file="$1" board_ids="$2" agent_id="$3" agent_name="$4" slug="$5" cache_dir="$6"
  local repo="${PR_REPO:-}" prefix="${PR_BRANCH_PREFIX:-agent/$slug-}"
  local tmp prs tasks one rows ref task_id assigned comments claimed_refs candidates pr number live
  [ -n "$repo" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  mkdir -p "$cache_dir"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  if ! gh pr list --repo "$repo" --state open --limit 1000 \
      --json number,state,url,title,body,headRefName,createdAt > "$tmp/open.json" \
     || ! gh pr list --repo "$repo" --state merged --limit 100 \
      --json number,state,url,title,body,headRefName,createdAt > "$tmp/merged.json"; then
    printf 'ERROR: cannot list pull requests in %s for the one-ticket-until-live gate\n' "$repo" >&2
    return 1
  fi
  python3 - "$tmp/open.json" "$tmp/merged.json" <<'PYEOF' > "$tmp/prs.json"
import json, sys
seen, rows = set(), []
for path in sys.argv[1:]:
    for row in json.load(open(path)):
        if row.get("number") in seen:
            continue
        seen.add(row.get("number"))
        rows.append(row)
print(json.dumps(rows))
PYEOF

  : > "$tmp/tasks.jsonl"
  for one in $(printf '%s' "$board_ids" | tr ',' ' '); do
    [ -n "$one" ] || continue
    tasks="$(_ht_get "$token_file" "/mcp/tasks?project_id=${one}&limit=100")" || return 1
    printf '%s' "$tasks" | BOARD="$one" AID="$agent_id" python3 -c '
import json, os, sys
for task in json.load(sys.stdin).get("tasks") or []:
    ref = str(task.get("ticketNumber") or "")
    if not ref:
        continue
    aids = []
    for who in task.get("assignees") or []:
        agent = who.get("agent") if isinstance(who, dict) else None
        if isinstance(agent, dict) and agent.get("id"):
            aids.append(str(agent["id"]))
    print(json.dumps({"ref": ref, "id": task.get("id"), "board": os.environ["BOARD"],
                      "assigned": os.environ["AID"] in aids}))
' >> "$tmp/tasks.jsonl"
  done

  # Assigned tickets are claims. For ticket references appearing on a possible
  # PR but not currently assigned, use the same evidence as adapter_pick_rank:
  # this agent authored a comment containing "claim".
  awk 'NF' "$tmp/tasks.jsonl" | while IFS= read -r rows; do
    ref="$(ROW="$rows" python3 -c 'import json,os;print(json.loads(os.environ["ROW"])["ref"])')"
    if ! REFS="$ref" PRS="$(cat "$tmp/prs.json")" python3 -c '
import json, os, re, sys
ref = os.environ["REFS"]
pattern = re.compile(r"(?<![0-9A-Za-z])" + re.escape(ref) + r"(?![0-9A-Za-z])", re.I)
for pr in json.loads(os.environ["PRS"]):
    if str(pr.get("state") or "").upper() not in ("OPEN", "MERGED"):
        continue
    if pattern.search(" ".join(str(pr.get(k) or "") for k in ("title", "body", "headRefName"))):
        sys.exit(0)
sys.exit(1)
'; then
      continue
    fi
    assigned="$(ROW="$rows" python3 -c 'import json,os;print("yes" if json.loads(os.environ["ROW"])["assigned"] else "no")')"
    if [ "$assigned" = "yes" ]; then
      printf '%s\n' "$ref" >> "$tmp/claimed"
      continue
    fi
    task_id="$(ROW="$rows" python3 -c 'import json,os;print(json.loads(os.environ["ROW"])["id"])')"
    one="$(ROW="$rows" python3 -c 'import json,os;print(json.loads(os.environ["ROW"])["board"])')"
    comments="$(_ht_get "$token_file" "/mcp/comments?task_id=${task_id}&project_id=${one}")" || continue
    if printf '%s' "$comments" | AID="$agent_id" ANAME="$agent_name" python3 -c '
import json, os, re, sys
want_id, want_name = os.environ["AID"], os.environ["ANAME"].strip().casefold()
for comment in json.load(sys.stdin).get("comments") or []:
    agent = comment.get("agent") if isinstance(comment.get("agent"), dict) else None
    author = agent or comment.get("user") or comment.get("author") or {}
    if isinstance(author, dict):
        mine = str(author.get("id") or "") == want_id or str(author.get("displayName") or author.get("display_name") or author.get("name") or "").strip().casefold() == want_name
    else:
        mine = str(author).strip().casefold() == want_name
    text = comment.get("text") or comment.get("comment") or comment.get("commentText") or comment.get("html") or ""
    if mine and re.search(r"\bclaim", re.sub(r"<[^>]+>", " ", text), re.I):
        sys.exit(0)
sys.exit(1)
'; then
      printf '%s\n' "$ref" >> "$tmp/claimed"
    fi
  done
  claimed_refs="$(sort -u "$tmp/claimed" 2>/dev/null | paste -sd, - || true)"

  CLAIMED="$claimed_refs" PREFIX="$prefix" python3 - "$tmp/prs.json" <<'PYEOF' > "$tmp/candidates.jsonl"
import json, os, re, sys
claimed = {x.casefold() for x in os.environ.get("CLAIMED", "").split(",") if x}
prefix = os.environ["PREFIX"].casefold()
with open(sys.argv[1]) as handle:
    prs = json.load(handle)
for pr in sorted(prs, key=lambda row: row.get("createdAt") or ""):
    if str(pr.get("state") or "").upper() not in ("OPEN", "MERGED"):
        continue
    haystack = " ".join(str(pr.get(k) or "") for k in ("title", "body", "headRefName"))
    refs = re.findall(r"(?<![0-9A-Za-z])([A-Z][A-Z0-9]{1,10}-[0-9]+)(?![0-9A-Za-z])", haystack, re.I)
    if str(pr.get("headRefName") or "").casefold().startswith(prefix) or any(r.casefold() in claimed for r in refs):
        pr["ticket"] = refs[0].upper() if refs else "PR-%s" % pr["number"]
        print(json.dumps(pr))
PYEOF

  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    number="$(ROW="$pr" python3 -c 'import json,os;print(json.loads(os.environ["ROW"])["number"])')"
    live="$(_ht_pr_live_state "$repo" "$number" "$cache_dir")" || return 1
    if LIVE="$live" python3 -c 'import json,os,sys;sys.exit(0 if json.loads(os.environ["LIVE"])["live"] else 1)'; then
      continue
    fi
    _ht_pr_work_state "$repo" "$pr" "$live"
    return 0
  done < "$tmp/candidates.jsonl"
)

# _ht_pr_live_state <repo> <number> <cache-dir>: one JSON answer, cached 60s.
_ht_pr_live_state() {
  local repo="$1" number="$2" cache_dir="$3" cache
  local now mtime view state base merge merged_at compare deployments deployment dep_id dep_sha dep_at statuses dep_state deploy_contains base_contains_deploy
  mkdir -p "$cache_dir"
  cache="$cache_dir/$number.json"
  now="$(date +%s)"
  if [ -f "$cache" ]; then
    mtime="$(stat -c %Y "$cache" 2>/dev/null || printf 0)"
    if [ "$((now - mtime))" -lt 60 ]; then cat "$cache"; return 0; fi
  fi
  view="$(gh pr view "$number" --repo "$repo" --json state,baseRefName,mergedAt,mergeCommit 2>/dev/null)" || return 1
  state="$(printf '%s' "$view" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("state") or "")')"
  if [ "$state" != "MERGED" ]; then
    printf '{"live":false,"state":"open","definition":"GitHub Production deployments"}\n' | tee "$cache"
    return 0
  fi
  base="$(printf '%s' "$view" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("baseRefName") or "")')"
  merge="$(printf '%s' "$view" | python3 -c 'import json,sys;d=json.load(sys.stdin);print((d.get("mergeCommit") or {}).get("oid") or "")')"
  merged_at="$(printf '%s' "$view" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("mergedAt") or "")')"
  [ -n "$base" ] && [ -n "$merge" ] && [ -n "$merged_at" ] || return 1
  compare="$(gh api "repos/$repo/compare/$merge...$base" 2>/dev/null)" || return 1
  if ! printf '%s' "$compare" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if d.get("status") in ("ahead","identical") else 1)'; then
    printf '{"live":false,"state":"merged-base-missing","definition":"GitHub Production deployments"}\n' | tee "$cache"
    return 0
  fi

  deployments="$(gh api "repos/$repo/deployments?per_page=100" 2>/dev/null)" || return 1
  if [ "$(printf '%s' "$deployments" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')" = "0" ]; then
    printf '{"live":true,"state":"live","definition":"fallback: merged and base contains merge commit (no deployment records)"}\n' | tee "$cache"
    return 0
  fi
  deployment="$(printf '%s' "$deployments" | MERGED_AT="$merged_at" python3 -c '
import json, os, sys
rows = [r for r in json.load(sys.stdin) if str(r.get("environment") or "").casefold() == "production"]
rows.sort(key=lambda r: r.get("created_at") or "", reverse=True)
print(json.dumps(rows[0]) if rows else "")
')"
  if [ -z "$deployment" ]; then
    printf '{"live":false,"state":"merged-undeployed","definition":"GitHub Production deployments"}\n' | tee "$cache"
    return 0
  fi
  dep_id="$(printf '%s' "$deployment" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("id") or "")')"
  dep_sha="$(printf '%s' "$deployment" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("sha") or d.get("ref") or "")')"
  dep_at="$(printf '%s' "$deployment" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("created_at") or "")')"
  statuses="$(gh api "repos/$repo/deployments/$dep_id/statuses?per_page=1" 2>/dev/null)" || return 1
  dep_state="$(printf '%s' "$statuses" | python3 -c 'import json,sys;d=json.load(sys.stdin);print((d[0] if d else {}).get("state") or "")')"
  deploy_contains="no"
  base_contains_deploy="no"
  if [ -n "$dep_sha" ]; then
    compare="$(gh api "repos/$repo/compare/$merge...$dep_sha" 2>/dev/null)" || return 1
    if printf '%s' "$compare" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if d.get("status") in ("ahead","identical") else 1)'; then
      deploy_contains="yes"
    fi
    compare="$(gh api "repos/$repo/compare/$dep_sha...$base" 2>/dev/null)" || return 1
    if printf '%s' "$compare" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if d.get("status") in ("ahead","identical") else 1)'; then
      base_contains_deploy="yes"
    fi
  fi
  if MERGED_AT="$merged_at" DEP_AT="$dep_at" DEP_STATE="$dep_state" CONTAINS="$deploy_contains" ON_BASE="$base_contains_deploy" python3 -c '
import datetime, os, sys
def stamp(value): return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
sys.exit(0 if os.environ["DEP_STATE"] == "success" and os.environ["CONTAINS"] == "yes" and os.environ["ON_BASE"] == "yes" and stamp(os.environ["DEP_AT"]) > stamp(os.environ["MERGED_AT"]) else 1)
'; then
    printf '{"live":true,"state":"live","definition":"merged, base contains merge commit, newest Production deployment on that base after merge succeeded and contains merge commit"}\n' | tee "$cache"
  else
    printf '{"live":false,"state":"merged-undeployed","definition":"GitHub Production deployments"}\n' | tee "$cache"
  fi
}

# Add current checks, failed-run logs, and review feedback to an owed PR.
_ht_pr_work_state() {
  local repo="$1" pr="$2" live="$3" number view checks reviews inline feedback action wait_state head run_ids run_id logs
  number="$(ROW="$pr" python3 -c 'import json,os;print(json.loads(os.environ["ROW"])["number"])')"
  view="$(gh pr view "$number" --repo "$repo" --json state,url,title,body,headRefName,headRefOid,baseRefName,createdAt,statusCheckRollup,reviews,comments 2>/dev/null)" || return 1
  state="$(printf '%s' "$view" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("state") or "")')"
  if [ "$state" = "MERGED" ]; then
    PR="$pr" LIVE="$live" python3 -c '
import json, os
pr, live = json.loads(os.environ["PR"]), json.loads(os.environ["LIVE"])
print(json.dumps({"action":"wait", "state":live["state"], "definition":live["definition"],
                  "number":pr["number"], "url":pr["url"], "ticket":pr["ticket"],
                  "title":pr["title"], "branch":pr["headRefName"], "since":pr["createdAt"]}))
'
    return 0
  fi
  inline="$(gh api "repos/$repo/pulls/$number/comments?per_page=100" 2>/dev/null || printf '[]')"
  feedback="$(VIEW="$view" INLINE="$inline" python3 -c '
import json, os
view, inline = json.loads(os.environ["VIEW"]), json.loads(os.environ["INLINE"])
failed, pending, review = [], [], []
for check in view.get("statusCheckRollup") or []:
    name = check.get("name") or check.get("context") or "unnamed check"
    status = str(check.get("status") or "").upper()
    conclusion = str(check.get("conclusion") or "").upper()
    if status != "COMPLETED" or not conclusion:
        pending.append(name)
    elif conclusion not in ("SUCCESS", "NEUTRAL", "SKIPPED"):
        failed.append({"name": name, "conclusion": conclusion, "url": check.get("detailsUrl") or ""})
for item in (view.get("reviews") or []) + (view.get("comments") or []) + inline:
    body = str(item.get("body") or "").strip()
    state = str(item.get("state") or "")
    author = item.get("author") or item.get("user") or {}
    if isinstance(author, dict): author = author.get("login") or author.get("name") or "reviewer"
    if body and ("CONCERNS" in body.upper() or state.upper() == "CHANGES_REQUESTED"):
        review.append({"author": str(author), "state": state, "body": body})
print(json.dumps({"failed": failed, "pending": pending, "review": review}))
')"
  head="$(printf '%s' "$view" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("headRefOid") or "")')"
  run_ids="$(printf '%s' "$feedback" | python3 -c '
import json, re, sys
for check in json.load(sys.stdin)["failed"]:
    match = re.search(r"/actions/runs/([0-9]+)", check.get("url") or "")
    if match: print(match.group(1))
' | sort -u)"
  logs=""
  for run_id in $run_ids; do
    logs="$logs$(gh run view "$run_id" --repo "$repo" --log-failed 2>&1 | tail -c 12000 || true)"
  done
  action="$(printf '%s' "$feedback" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("fix" if d["failed"] or d["review"] else "wait")')"
  wait_state="$(printf '%s' "$feedback" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("checks-pending" if d["pending"] else "awaiting-merge")')"
  PR="$pr" VIEW="$view" LIVE="$live" FEEDBACK="$feedback" LOGS="$logs" ACTION="$action" WAIT_STATE="$wait_state" python3 -c '
import json, os
pr, view = json.loads(os.environ["PR"]), json.loads(os.environ["VIEW"])
live, feedback = json.loads(os.environ["LIVE"]), json.loads(os.environ["FEEDBACK"])
parts = []
if feedback["failed"]:
    parts.append("Failing checks (exact names):\n" + "\n".join("- %s [%s] %s" % (c["name"], c["conclusion"], c["url"]) for c in feedback["failed"]))
if feedback["review"]:
    parts.append("Review feedback (verbatim):\n" + "\n\n".join("[%s %s]\n%s" % (r["author"], r["state"], r["body"]) for r in feedback["review"]))
if os.environ["LOGS"].strip():
    parts.append("Failing check logs:\n" + os.environ["LOGS"].strip())
print(json.dumps({"action":os.environ["ACTION"],
                  "state":"red" if os.environ["ACTION"] == "fix" else os.environ["WAIT_STATE"],
                  "definition":live["definition"], "number":pr["number"], "url":pr["url"],
                  "ticket":pr["ticket"], "title":view.get("title") or pr["title"],
                  "branch":view.get("headRefName") or pr["headRefName"],
                  "base":view.get("baseRefName") or "main", "since":pr["createdAt"],
                  "feedback":"\n\n".join(parts), "pending":feedback["pending"]}))
'
}

# ---------- which ticket comes next ----------
# An agent that starts a second ticket while its first one is still open leaves
# the first one half done and nobody watching it. The board already knows which
# ticket that is, so this is a query, not a lock file: a ticket this agent
# claimed, not Done, with no merged pull request, is still its job.
#
# Rank, lowest first:
#   1  a ticket this agent claimed and has not finished. Nothing else runs
#      while one of these exists.
#   2  a ticket this agent worked that QA sent back. Fixing a rejection beats
#      starting something new.
#   3  a new ticket.
#   0  skip, with a reason.
#
# adapter_pick_rank <token-file> <board-id> <agent-id> <agent-name> <ref> \
#                   <task-id> <section> <reason>
# prints "<rank> <one line saying why>"
adapter_pick_rank() {
  local token_file="$1" board_id="$2" agent_id="$3" agent_name="$4" ref="$5"
  local task_id="$6" section="$7" reason="$8"
  local comments pr_json="" repo="${PR_REPO:-}" pr_known="no"

  comments="$(_ht_get "$token_file" "/mcp/comments?task_id=${task_id}&project_id=${board_id}")"

  # PR_REPO is required (agent-board-poll refuses to tick without it), so the
  # only question here is whether gh could answer. gh missing or the call
  # failing is a real fault, loud on purpose so the supervisor's log check
  # catches it; only a successful call may claim a pull request state. Either
  # way a ticket this agent still owes falls through to "not finished" below,
  # and the run itself discovers the truth.
  if command -v gh >/dev/null 2>&1; then
    if pr_json="$(gh pr list --repo "$repo" --state all --search "$ref" \
                 --json number,state,url,headRefName --limit 10 2>&1)"; then
      pr_known="yes"
    else
      printf 'ERROR: gh pr list failed for %s in %s: %s\n' "$ref" "$repo" "$pr_json" >&2
      pr_json=""
    fi
  else
    printf 'ERROR: PR_REPO=%s is set but gh is not on PATH, so %s cannot learn its pull request state\n' \
      "$repo" "$ref" >&2
  fi

  printf '%s' "$comments" | \
  AGENT_ID="$agent_id" AGENT_NAME="$agent_name" REF="$ref" SECTION="$section" \
  REASON="$reason" PR_JSON="${pr_json:-[]}" HAVE_PR_VIEW="$pr_known" \
  python3 -c '
import json, os, re, sys

def text_of(comment):
    raw = comment.get("text") or comment.get("comment") or comment.get("html") or ""
    return re.sub(r"<[^>]+>", " ", raw)

def author_of(comment):
    who = comment.get("user") or comment.get("author") or {}
    if isinstance(who, dict):
        return str(who.get("displayName") or who.get("display_name") or who.get("name") or "")
    return str(who)

agent_name = os.environ["AGENT_NAME"].strip().casefold()
ref = os.environ["REF"]
section = os.environ["SECTION"].strip().casefold()
reason = os.environ["REASON"]
comments = (json.load(sys.stdin).get("comments") or [])
comments.sort(key=lambda c: (c.get("createdAt") or "", c.get("id") or 0))

mine = [c for c in comments if author_of(c).strip().casefold() == agent_name]
# "Claimed." is what claim-ticket.sh writes; assignment is the other half and
# the runner has already told us whether this agent is on the ticket.
claimed = reason.startswith("assigned") or any(
    "claim" in text_of(c).casefold() for c in mine)
worked = bool(mine) or claimed

# A QA verdict is the newest comment from somebody else that fails this ticket.
qa_fail = False
for comment in reversed(comments):
    body = text_of(comment).casefold()
    if author_of(comment).strip().casefold() == agent_name:
        continue
    if "qa" in body and re.search(r"\bfail(ed|s|ing)?\b", body):
        qa_fail = True
        break
    if re.search(r"\bqa\s*(verdict|result)?\s*[:\-]?\s*pass\b", body):
        break

done = section in {"done", "archive", "shipped"}

prs = json.loads(os.environ["PR_JSON"]) or []
# gh --search is a full-text search, so keep only the pull requests that
# actually name this ticket in the branch or the title.
prs = [p for p in prs if ref.casefold() in
       (str(p.get("headRefName") or "") + " " + str(p.get("url") or "")).casefold()]
merged = any(str(p.get("state") or "").upper() == "MERGED" for p in prs)
open_pr = [p for p in prs if str(p.get("state") or "").upper() == "OPEN"]
pr_known = os.environ["HAVE_PR_VIEW"] == "yes"

if done:
    print("0 %s is %s, nothing left to do" % (ref, section))
elif qa_fail and worked:
    print("2 %s was sent back by QA on work this agent did, so it comes before any new ticket" % ref)
elif claimed and merged:
    print("3 %s was claimed by this agent but its pull request is merged, so it no longer holds the agent" % ref)
elif claimed and open_pr:
    print("1 %s is claimed by this agent and its pull request %s is still open, so this agent owes it a fix"
          % (ref, open_pr[0].get("url")))
elif claimed and not merged:
    detail = "no pull request yet" if pr_known else "pull request state unknown, gh failed, see the tick log"
    print("1 %s is claimed by this agent and is not finished (%s)" % (ref, detail))
else:
    print("3 %s is new work (%s)" % (ref, reason))
'
}

# ---------- a working directory per run ----------
# Core decides there should be one and where it goes; the checkout itself is
# here, because "a checkout" on this board's projects means a git worktree cut
# from the branch that deploys. Detached, so the run names its own branch when
# it has something to push, and so two runs never contend for one branch name.
# The directory name ends in the ticket reference, which is how this finds the
# branch a previous run already pushed for the same ticket. A ticket with an
# open pull request resumes on that branch: cutting from the base branch again
# is how one ticket ends up with two pull requests.
_ht_open_branch_for() {
  local ref="$1"
  [ -n "${PR_REPO:-}" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  # REF has to be exported: an assignment prefix would only reach gh, not the
  # python3 on the other side of the pipe.
  export REF="$ref"
  gh pr list --repo "$PR_REPO" --state open --search "$ref" \
    --json headRefName,url --limit 10 2>/dev/null | python3 -c '
import json, os, sys
ref = os.environ["REF"].casefold()
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
# The ref has to appear as a whole word. A substring match puts ticket 6459 on
# the branch of ticket 16459, worse than opening a second pull request.
import re
pattern = re.compile(r"(?<![0-9a-z])" + re.escape(ref) + r"(?![0-9a-z])")
for row in rows:
    branch = row.get("headRefName") or ""
    if pattern.search(branch.casefold()):
        print(branch)
        break
'
}

adapter_workdir_checkout() {
  local source="$1" dir="$2" name="$3"
  local remote="${WORKDIR_REMOTE:-origin}" branch="${WORKDIR_BASE_BRANCH:-main}"
  # The ref is a shape, PREFIX-NUMBER, not "whatever follows the last dash":
  # the workdir name starts with the agent slug, which has dashes of its own.
  local ref open_branch
  ref="$(printf '%s' "$name" | grep -oE '[A-Z][A-Z0-9]*-[0-9]+$' || true)"
  [ -d "$source/.git" ] || [ -f "$source/.git" ] || die \
    "$source is not a git checkout, so there is nothing to cut a worktree from" \
    "point AGENT_REPO at a git clone of the repo this agent changes"
  open_branch=""
  [ -n "$ref" ] && open_branch="$(_ht_open_branch_for "$ref")"
  if [ -n "$open_branch" ]; then
    if git -C "$source" fetch --quiet "$remote" "$open_branch" 2>/dev/null; then
      branch="$open_branch"
      printf 'resuming %s on its open pull request branch %s\n' "$ref" "$branch" >&2
    fi
  fi
  git -C "$source" fetch --quiet "$remote" "$branch" || die \
    "could not fetch $remote/$branch in $source" \
    "check the remote name in WORKDIR_REMOTE and that this machine can reach it"
  git -C "$source" worktree add --detach "$dir" "$remote/$branch" >/dev/null || die \
    "could not create a worktree for $name at $dir" \
    "run git -C $source worktree prune, then try again"
}

# Refuses, by returning non-zero, when the only copy of some work is in here:
# uncommitted changes, or commits no remote has. A run that built something and
# failed to push it leaves evidence, not a hole.
adapter_workdir_remove() {
  local source="$1" dir="$2"
  if [ -d "$dir" ]; then
    if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
      printf 'the worktree %s has uncommitted changes, keeping it\n' "$dir" >&2
      return 1
    fi
    # Commits reachable from HEAD that no remote-tracking ref holds.
    if [ -n "$(git -C "$dir" log --oneline HEAD --not --remotes 2>/dev/null | head -1)" ]; then
      printf 'the worktree %s holds commits no remote has, keeping it\n' "$dir" >&2
      return 1
    fi
  fi
  git -C "$source" worktree remove --force "$dir" >/dev/null 2>&1 || true
  git -C "$source" worktree prune >/dev/null 2>&1 || true
  return 0
}

# ---------- the prompt one ticket gets ----------
# The generic prompt in core says "read the index and follow what matches".
# This board's agents have a router that answers that question deterministically
# before any model judgment, a claim step that has to happen before code is
# written, and a rule about whose name goes on a comment. All three are
# specific to this tracker, so they live here.
#
# adapter_run_prompt <skills-index> <agent-name> <board-cli> <ref> <url> <title>
#                    <description> <latest-comment>
adapter_run_prompt() {
  local skills_index="$1" agent_name="$2" board_cli="$3" ref="$4" url="$5"
  local title="$6" description="$7" latest="$8" why="${9:-}"
  # $skills_index is now a readable phrase naming every pack, so the lifecycle
  # scripts are looked up under the FIRST pack (the company one), which is
  # where ticket-lifecycle lives. The runner exports it.
  local primary="${SKILLS_INDEX_PRIMARY:-$skills_index}"
  local route_sh="$(dirname "$primary")/ticket-lifecycle/scripts/route.sh"
  local claim_sh="$(dirname "$primary")/ticket-lifecycle/scripts/claim-ticket.sh"
  cat <<EOF
You are $agent_name. You have one ticket, $ref, and this process ends when you do.

Ticket $url: $title

$description

Latest comment: ${latest:-none}

Why you have this ticket: ${why:-it came up next on the board}. If that says
this ticket already has a pull request, the working directory you are in is
already on that branch, at a detached head: check the branch out by name first
(\`git checkout -B <branch> --track ${WORKDIR_REMOTE:-origin}/<branch>\`), then push more commits
to it and fix what is wrong. Opening a second pull request for one ticket is
the one mistake that wastes everybody.

Run \`$route_sh $ref\` first and follow the named skills, in the order it
names them. It resolves a skill against both packs, so the paths it prints are
real. The indexes are the fallback only if it prints NO_ROUTE: read
$skills_index, in that order, company pack before your own.

Claim the ticket with \`$claim_sh $ref\` before you write any code. Never
assign userId 6: only Valentin assigns Valentin.

FINISH IT. The run counts for something only when the work is in a pull
request that can merge on its own: branch off the production branch, commit,
push, open the PR, and turn auto-merge on with
\`gh pr merge --auto --squash <number>\` in the same breath as opening it. A
PR sitting green with auto-merge off is work nobody gets. GitHub refuses that
command on a private repo whose plan does not carry auto-merge; when it is
refused, do not retry it and do not fail the run over it: leave the PR open,
say so in your result comment, and move the ticket to the review lane anyway.
Checks turning green on a PR that could not get auto-merge is what the
supervisor's pr-hygiene check looks for; it merges those by hand. Then move
the ticket to the review lane the lifecycle skill names. Do not leave commits
unpushed: this working directory is thrown away when the process exits.

${AGENT_ADVISOR_GUIDANCE:+$AGENT_ADVISOR_GUIDANCE

}THREE COMMENTS, MAXIMUM, for this whole run. A ticket a human has to scroll is
a ticket nobody reads.

1. One claim comment, which is also the only place you list the skills you are
   about to follow. Do not post the route and the claim separately: take the
   ROUTE: line from $route_sh and pass it to $claim_sh with --skills, or post
   the single merged comment yourself and skip the script's own.
2. One result comment at the end: the pull request link, or what stopped you
   and why. The cost line goes in this comment, not a comment of its own. A
   gates ledger goes in this comment too, or is kept up to date in place with
   \`$board_cli comment update <id>\`, never appended as a new comment each pass.
3. A reply, only if somebody asks you something.

Anything else you want to say belongs in the pull request body or the run log.
Write as $agent_name, in HTML block tags, with
\`$board_cli comment add $ref --text '<p>...</p>'\`. Never write in Valentin's
name. A run that ends with nothing on the ticket is a run nobody can see, so
the result comment is not optional, including when you are blocked.

Do not ask for permission and do not stop halfway.

If a human corrects your output at any point, whether they edit your comment,
fail your QA, reject your pull request or simply say that is wrong, stop and
run \`agent-template feedback --what '<one sentence>' --got <the bad output>
--expected '<what should have happened>'\` before you carry on. A correction
that lives only in this run is gone the moment this process exits.

When a correction lands on your work, also edit the skill file in this
repo's skills folder in the same run and commit it, message
\`skill: <what changed> (from $ref)\`. Do not open a pull request for a skill
edit; the evals check on push is the gate. A fact (a number, a name, a date,
a path) goes into a doc or the ticket, never into a skill; a rule (always or
never do X) goes into the skill file. If you are unsure which: would it still
be true for a different customer? Yes is a rule, no is a fact.
EOF
}

# adapter_failure_comment <board-cli> <ref> <stderr-text>
# A run that died is written on the ticket, where a human already looks, not
# only in a log on one machine. The ticket is not moved: where it sits is the
# board's record of how far it got.
adapter_failure_comment() {
  local board_cli="$1" ref="$2" detail="$3" html
  html="$(DETAIL="$detail" python3 -c '
import html, os
detail = os.environ["DETAIL"].strip()[:300] or "no output on stderr"
print("<p><strong>Run failed: %s</strong></p>" % html.escape(detail))')"
  "$board_cli" comment add "$ref" --text "$html" >/dev/null 2>&1 || return 1
}

# ---------- fleet wiring (this tracker only, and only where it exists) ----------
adapter_fleet_wire() {
  local slug="$1"
  adapter_supports_fleet_wiring || die \
    "this machine has no agent worker runtime, so fleet wiring has nothing to attach to" \
    "re-run with --wiring poll, which needs only the board CLI and a model CLI"
  cat <<EOF
Fleet wiring for $slug is handed to the worker runtime already installed here.
It owns the webhook receiver, the router entry and the per-agent units; this
template does not copy another agent's drop-ins, because those are specific to
the machine that already runs them.

Next: follow the runtime's own provisioning docs for $slug, then come back and
run the acceptance check.
EOF
}
