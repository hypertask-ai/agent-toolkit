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
adapter_install_board_cli() {
  local slug="$1" token_file="$2" dest="$3"
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<EOF
#!/usr/bin/env bash
# $slug: the board CLI acting as this agent.
set -euo pipefail
TOKEN_FILE="$token_file"
[ -r "\$TOKEN_FILE" ] || {
  echo "ERROR: cannot read \$TOKEN_FILE. Do this next: capture the agent token into that file" >&2
  exit 1
}
exec hypertask --token "\$(cat "\$TOKEN_FILE")" "\$@"
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
# JSON {"id":..., "html":..., "author":...} or an empty line when there is none.
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
author = newest.get("user") or newest.get("author") or {}
print(json.dumps({
    "id": newest.get("id"),
    "html": newest.get("text") or newest.get("comment") or newest.get("html") or "",
    "author": (author.get("displayName") if isinstance(author, dict) else str(author)) or "",
}))
'
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

# ---------- writes (through the agent's own CLI) ----------
adapter_post_comment() {
  local board_cli="$1" ref="$2" html="$3"
  "$board_cli" comment add "$ref" --text "$html"
}

adapter_move_task() {
  local board_cli="$1" ref="$2" section="$3"
  "$board_cli" task move "$ref" --section "$section"
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
  local comments pr_json="" repo="${PR_REPO:-}"

  comments="$(_ht_get "$token_file" "/mcp/comments?task_id=${task_id}&project_id=${board_id}")"

  # The pull request is the other half of "finished", and GitHub is the only
  # place that knows whether it merged. No gh, no claim that it merged.
  if [ -n "$repo" ] && command -v gh >/dev/null 2>&1; then
    pr_json="$(gh pr list --repo "$repo" --state all --search "$ref" \
                 --json number,state,url,headRefName --limit 10 2>/dev/null || printf '[]')"
  fi

  printf '%s' "$comments" | \
  AGENT_ID="$agent_id" AGENT_NAME="$agent_name" REF="$ref" SECTION="$section" \
  REASON="$reason" PR_JSON="${pr_json:-[]}" HAVE_PR_VIEW="$([ -n "$pr_json" ] && echo yes || echo no)" \
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
    detail = "no pull request yet" if pr_known else "pull request state unknown, gh is unavailable"
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
  REF="$ref" gh pr list --repo "$PR_REPO" --state open --search "$ref" \
    --json headRefName,url --limit 10 2>/dev/null | python3 -c '
import json, os, sys
ref = os.environ["REF"].casefold()
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for row in rows:
    branch = row.get("headRefName") or ""
    if ref in branch.casefold() or ref in (row.get("url") or "").casefold():
        print(branch)
        break
'
}

adapter_workdir_checkout() {
  local source="$1" dir="$2" name="$3"
  local remote="${WORKDIR_REMOTE:-origin}" branch="${WORKDIR_BASE_BRANCH:-main}"
  local ref="${name##*-}" open_branch
  [ -d "$source/.git" ] || [ -f "$source/.git" ] || die \
    "$source is not a git checkout, so there is nothing to cut a worktree from" \
    "point AGENT_REPO at a git clone of the repo this agent changes"
  open_branch="$(_ht_open_branch_for "$ref")"
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
  local route_sh="$(dirname "$skills_index")/ticket-lifecycle/scripts/route.sh"
  local claim_sh="$(dirname "$skills_index")/ticket-lifecycle/scripts/claim-ticket.sh"
  cat <<EOF
You are $agent_name. You have one ticket, $ref, and this process ends when you do.

Ticket $url: $title

$description

Latest comment: ${latest:-none}

Why you have this ticket: ${why:-it came up next on the board}. If that says
this ticket already has a pull request, the working directory you are in is
already on that branch: push more commits to it and fix what is wrong. Opening
a second pull request for one ticket is the one mistake that wastes everybody.

Run \`$route_sh $ref\` first and follow the named skills, in the order it
names them. $skills_index is the fallback only if that prints NO_ROUTE.

Claim the ticket with \`$claim_sh $ref\` before you write any code. Never
assign userId 6: only Valentin assigns Valentin.

FINISH IT. The run counts for something only when the work is in a pull
request that can merge on its own: branch off the production branch, commit,
push, open the PR, and turn auto-merge on with
\`gh pr merge --auto --squash <number>\` in the same breath as opening it. A
PR sitting green with auto-merge off is work nobody gets. Then move the ticket
to the review lane the lifecycle skill names. Do not leave commits unpushed:
this working directory is thrown away when the process exits.

THREE COMMENTS, MAXIMUM, for this whole run. A ticket a human has to scroll is
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
