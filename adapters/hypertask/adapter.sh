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

_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAIN_LANGUAGE_DIR="${PLAIN_LANGUAGE_DIR:-$_ADAPTER_DIR/plain-language}"
PLAIN_LANGUAGE_CHECK="${PLAIN_LANGUAGE_CHECK:-$PLAIN_LANGUAGE_DIR/check-comment.py}"
POSPEAK_SKILL="${POSPEAK_SKILL:-$PLAIN_LANGUAGE_DIR/pospeak.md}"
TICKET_FORMAT_RULE="${TICKET_FORMAT_RULE:-$PLAIN_LANGUAGE_DIR/ticket-format.md}"
UNSLOP_SKILL="${UNSLOP_SKILL:-$PLAIN_LANGUAGE_DIR/unslop.md}"
ADHD_SKILL="${ADHD_SKILL:-$PLAIN_LANGUAGE_DIR/i-have-adhd.md}"
TICKET_LINK_FORMATTER="${TICKET_LINK_FORMATTER:-$_ADAPTER_DIR/../../scripts/ticket_links.py}"
# shellcheck source=plain-language/outbound-text-gate.sh
. "$PLAIN_LANGUAGE_DIR/outbound-text-gate.sh"

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

# Run telemetry must never make ticket work fail. The runs API is deployed
# independently, so 404 means this run remains local and its activity stays in
# the runner log until the app route is available.
_adapter_run_log() {
  local log_file="$1" message="$2"
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
  printf '%s run-activity: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$message" >> "$log_file" 2>/dev/null || true
}

# _ht_run_post <token-file> <path> <json>: prints "<status>\n<body>".
_ht_run_post() {
  local token_file="$1" path="$2" payload="$3" base tok reply status body
  [ -r "$token_file" ] || { printf '000\n'; return 0; }
  tok="$(cat "$token_file")"
  base="$(_ht_api_base)"
  reply="$(curl -sS -w $'\n%{http_code}' -X POST \
    -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    --data "$payload" "${base}${path}" 2>/dev/null)" || { printf '000\n'; return 0; }
  status="${reply##*$'\n'}"
  body="${reply%$'\n'*}"
  printf '%s\n%s' "$status" "$body"
}

# adapter_run_open <token-file> <task-id> <run-log> <graft on|off>
# Prints the app run id, or "local" when registration is unavailable.
adapter_run_open() {
  local token_file="$1" task_id="$2" log_file="$3" graft="$4" payload reply status body run_id
  payload="$(TASK_ID="$task_id" GRAFT="$graft" python3 -c '
import json, os
value = os.environ["TASK_ID"]
row = {"taskId": int(value) if value.isdigit() else value, "source": "runtime", "graft": os.environ["GRAFT"]}
for env, key in (("AGENT_RUN_AGENT", "agent"), ("AGENT_RUN_MODEL", "model"),
                 ("AGENT_RUN_PROVIDER", "provider"), ("AGENT_RUN_STARTED_AT", "startedAt"),
                 ("AGENT_RUN_LOG_LINK", "logUrl")):
    if os.environ.get(env):
        row[key] = os.environ[env]
print(json.dumps(row))')"
  reply="$(_ht_run_post "$token_file" '/mcp/agents/runs' "$payload")"
  status="${reply%%$'\n'*}"
  body="${reply#*$'\n'}"
  if [[ "$status" = 2* ]]; then
    run_id="$(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("run") if isinstance(d.get("run"),dict) else d; print(r.get("id") or r.get("runId") or "")' 2>/dev/null || true)"
    if [ -n "$run_id" ]; then
      _adapter_run_log "$log_file" "opened run $run_id for task $task_id graft=$graft"
      printf '%s' "$run_id"
      return 0
    fi
  fi
  if [ "$status" = "404" ]; then
    _adapter_run_log "$log_file" "runs API unavailable (HTTP 404); opened local-only run for task $task_id graft=$graft"
  else
    _adapter_run_log "$log_file" "run registration failed (HTTP $status); opened local-only run for task $task_id graft=$graft"
  fi
  printf 'local'
}

_outbound_gate_activity() {
  local gate_type="$1" gate_message="$2"
  adapter_run_activity "$token_file" "$run_id" "$log_file" "$gate_type" "$gate_message"
}

_outbound_gate_note() {
  _adapter_run_log "$log_file" "$1"
}

# adapter_run_activity <token-file> <run-id> <run-log> <type> <message>
adapter_run_activity() {
  local token_file="$1" run_id="$2" log_file="$3" type="$4" message="$5" payload reply status
  local TEXT="$message" RUN_LOG="$log_file" now started duration
  if [ "$type" = "response" ]; then
    _outbound_text_gate "$message" || return 0
    message="$TEXT"
  fi
  now="$(date +%s)"
  started="${AGENT_RUN_STARTED_EPOCH:-$now}"
  [[ "$started" =~ ^[0-9]+$ ]] || started="$now"
  duration=$((now - started)); [ "$duration" -ge 0 ] || duration=0
  _adapter_run_log "$log_file" "$type $message agent=${AGENT_RUN_AGENT:-unknown} provider=${AGENT_RUN_PROVIDER:-unknown} model=${AGENT_RUN_MODEL:-unknown} started=${AGENT_RUN_STARTED_AT:-unknown} duration=${duration}s outcome=${AGENT_RUN_OUTCOME:-running} log=${AGENT_RUN_LOG_LINK:-unavailable}"
  [ -n "$run_id" ] && [ "$run_id" != "local" ] || return 0
  payload="$(ACTIVITY_TYPE="$type" MESSAGE="$message" NOW="$(date +%s)" python3 -c '
import json, os
try:
    duration = max(0, int(os.environ["NOW"]) - int(os.environ.get("AGENT_RUN_STARTED_EPOCH") or os.environ["NOW"]))
except ValueError:
    duration = 0
print(json.dumps({"type": os.environ["ACTIVITY_TYPE"], "text": os.environ["MESSAGE"],
                  "agent": os.environ.get("AGENT_RUN_AGENT", "unknown"),
                  "provider": os.environ.get("AGENT_RUN_PROVIDER", "unknown"),
                  "model": os.environ.get("AGENT_RUN_MODEL", "unknown"),
                  "startedAt": os.environ.get("AGENT_RUN_STARTED_AT", ""),
                  "durationSeconds": duration,
                  "outcome": os.environ.get("AGENT_RUN_OUTCOME", "running"),
                  "logUrl": os.environ.get("AGENT_RUN_LOG_LINK", "")}))')"
  reply="$(_ht_run_post "$token_file" "/mcp/agents/runs/$run_id/activities" "$payload")"
  status="${reply%%$'\n'*}"
  [[ "$status" = 2* ]] || _adapter_run_log "$log_file" "activity delivery failed (HTTP $status); kept locally: $message"
  return 0
}

# adapter_run_stop <token-file> <run-id> <run-log> <status>
adapter_run_stop() {
  local token_file="$1" run_id="$2" log_file="$3" run_status="$4" payload reply status
  _adapter_run_log "$log_file" "closed run ${run_id:-local} with status $run_status"
  [ -n "$run_id" ] && [ "$run_id" != "local" ] || return 0
  payload="$(RUN_STATUS="$run_status" NOW="$(date +%s)" python3 -c '
import json, os
try:
    duration = max(0, int(os.environ["NOW"]) - int(os.environ.get("AGENT_RUN_STARTED_EPOCH") or os.environ["NOW"]))
except ValueError:
    duration = 0
print(json.dumps({"status": os.environ["RUN_STATUS"], "outcome": os.environ["RUN_STATUS"],
                  "agent": os.environ.get("AGENT_RUN_AGENT", "unknown"),
                  "provider": os.environ.get("AGENT_RUN_PROVIDER", "unknown"),
                  "model": os.environ.get("AGENT_RUN_MODEL", "unknown"),
                  "startedAt": os.environ.get("AGENT_RUN_STARTED_AT", ""),
                  "durationSeconds": duration,
                  "logUrl": os.environ.get("AGENT_RUN_LOG_LINK", "")}))')"
  reply="$(_ht_run_post "$token_file" "/mcp/agents/runs/$run_id/stop" "$payload")"
  status="${reply%%$'\n'*}"
  [[ "$status" = 2* ]] || _adapter_run_log "$log_file" "run close failed (HTTP $status); local close remains authoritative"
  return 0
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
# them to the prompt alone. A near-duplicate add updates the agent's recent
# comment in place, and a fourth comment on the same UTC day is refused. Both
# --text and --file calls pass through these checks, so scheduled tools cannot
# bypass the wrapper used by model runs.
adapter_install_board_cli() {
  local slug="$1" token_file="$2" dest="$3" agent_name="${4:-}"
  local agent_id="${5:-}" board_ids="${6:-}" quiet="${7:-on}"
  local plain_language_dir native_cli native_path
  plain_language_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/plain-language" && pwd)"
  mkdir -p "$(dirname "$dest")"
  native_cli="hypertask"
  native_path="$(command -v hypertask 2>/dev/null || true)"
  if [ -n "$native_path" ] && [ "$(readlink -f "$native_path")" = "$(readlink -m "$dest")" ]; then
    if [ ! -x "$dest.native" ]; then
      cp "$native_path" "$dest.native"
      chmod 755 "$dest.native"
    fi
    native_cli="$dest.native"
  fi
  cat > "$dest" <<EOF
#!/usr/bin/env bash
# $slug: the board CLI acting as this agent.
set -euo pipefail
HYPERTASK_NATIVE="$native_cli"
if [ "\$HYPERTASK_NATIVE" != hypertask ]; then
  hypertask() { "\$HYPERTASK_NATIVE" "\$@"; }
fi
TOKEN_FILE="$token_file"
AGENT_NAME="$agent_name"
AGENT_ID="$agent_id"
BOARD_IDS="$board_ids"
QUIET="$quiet"
VERBATIM="\${AGENT_COMMENT_VERBATIM:-no}"
REPLY_TO_COMMENT_ID="\${AGENT_REPLY_TO_COMMENT_ID:-}"
OWNER_MENTION_REPLY="no"
if [ "\${AGENT_REPLY_ONLY:-no}" = "yes" ] && [ "\${AGENT_OWNER_MENTION_REPLY:-no}" = "yes" ]; then
  OWNER_MENTION_REPLY="yes"
fi
RUN_LOG="\${XDG_STATE_HOME:-\$HOME/.local/state}/agent-board-poll/$slug.log"
POSTED="\${XDG_STATE_HOME:-\$HOME/.local/state}/agent-board-poll/$slug.posted-comments"
MOVED="\${XDG_STATE_HOME:-\$HOME/.local/state}/agent-board-poll/$slug.moved-tickets"
OWNER_MENTIONS="\${XDG_STATE_HOME:-\$HOME/.local/state}/agent-board-poll/$slug.owner-mentions"
PLAIN_LANGUAGE_DIR="$plain_language_dir"
PLAIN_LANGUAGE_CHECK="\$PLAIN_LANGUAGE_DIR/check-comment.py"
OUTBOUND_TEXT_GATE="\$PLAIN_LANGUAGE_DIR/outbound-text-gate.sh"
POSPEAK_SKILL="\${AGENT_POSPEAK_SKILL:-\$PLAIN_LANGUAGE_DIR/pospeak.md}"
TICKET_FORMAT_RULE="\${AGENT_TICKET_FORMAT_RULE:-\$PLAIN_LANGUAGE_DIR/ticket-format.md}"
UNSLOP_SKILL="\${AGENT_UNSLOP_SKILL:-\$PLAIN_LANGUAGE_DIR/unslop.md}"
ADHD_SKILL="\${AGENT_ADHD_SKILL:-\$PLAIN_LANGUAGE_DIR/i-have-adhd.md}"
TICKET_LINK_FORMATTER="$plain_language_dir/../../../scripts/ticket_links.py"
BOARD_API_URL="\${BOARD_API_URL:-$(_ht_api_base)}"
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

_board_owner_ids() {
  local ids="" board project owner_id
  for board in \$(printf '%s' "\$BOARD_IDS" | tr ',' ' '); do
    project="\$(hypertask --token "\$TOKEN" --json project show "\$board" 2>/dev/null || true)"
    owner_id="\$(PROJECT="\$project" python3 -c '
import json, os
try:
    doc = json.loads(os.environ["PROJECT"])
except json.JSONDecodeError:
    doc = {}
project = doc.get("project") if isinstance(doc.get("project"), dict) else doc
print(project.get("ownerId") or (project.get("owner") or {}).get("id") or "")
')"
    [ -z "\$owner_id" ] || ids="\${ids}\${ids:+,}\$owner_id"
  done
  printf '%s' "\$ids"
}

_run_activity() {
  local type="\$1" message="\$2" payload status TEXT="\$2" now started duration
  if [ "\$type" = "response" ]; then
    _outbound_text_gate "\$message" || return 0
    message="\$TEXT"
  fi
  mkdir -p "\$(dirname "\$RUN_LOG")" 2>/dev/null || true
  now="\$(date +%s)"
  started="\${AGENT_RUN_STARTED_EPOCH:-\$now}"
  [[ "\$started" =~ ^[0-9]+$ ]] || started="\$now"
  duration=\$((now - started)); [ "\$duration" -ge 0 ] || duration=0
  printf '%s run-activity: %s %s agent=%s provider=%s model=%s started=%s duration=%ss outcome=%s log=%s\n' \
    "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" "\$type" "\$message" \
    "\${AGENT_RUN_AGENT:-unknown}" "\${AGENT_RUN_PROVIDER:-unknown}" "\${AGENT_RUN_MODEL:-unknown}" \
    "\${AGENT_RUN_STARTED_AT:-unknown}" "\$duration" "\${AGENT_RUN_OUTCOME:-running}" \
    "\${AGENT_RUN_LOG_LINK:-unavailable}" >> "\$RUN_LOG" 2>/dev/null || true
  [ -n "\${AGENT_RUN_ID:-}" ] && [ "\$AGENT_RUN_ID" != "local" ] && [ -n "\${AGENT_RUN_API_BASE:-}" ] || return 0
  payload="\$(ACTIVITY_TYPE="\$type" MESSAGE="\$message" NOW="\$(date +%s)" python3 -c '
import json, os
try:
    duration = max(0, int(os.environ["NOW"]) - int(os.environ.get("AGENT_RUN_STARTED_EPOCH") or os.environ["NOW"]))
except ValueError:
    duration = 0
print(json.dumps({"type": os.environ["ACTIVITY_TYPE"], "text": os.environ["MESSAGE"],
                  "agent": os.environ.get("AGENT_RUN_AGENT", "unknown"),
                  "provider": os.environ.get("AGENT_RUN_PROVIDER", "unknown"),
                  "model": os.environ.get("AGENT_RUN_MODEL", "unknown"),
                  "startedAt": os.environ.get("AGENT_RUN_STARTED_AT", ""),
                  "durationSeconds": duration,
                  "outcome": os.environ.get("AGENT_RUN_OUTCOME", "running"),
                  "logUrl": os.environ.get("AGENT_RUN_LOG_LINK", "")}))')"
  status="\$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer \$TOKEN" -H 'Content-Type: application/json' \
    --data "\$payload" "\$AGENT_RUN_API_BASE/mcp/agents/runs/\$AGENT_RUN_ID/activities" 2>/dev/null || printf 000)"
  case "\$status" in 2*) : ;; *) _comment_cap_note "run activity delivery failed (HTTP \$status), kept locally" ;; esac
}

_outbound_gate_activity() { _run_activity "\$@"; }
_outbound_gate_note() { _comment_cap_note "\$@"; }
# shellcheck source=/dev/null
. "\$OUTBOUND_TEXT_GATE"

# Task creation has no server-side writer flag, so rewrite both fields first.
# --raw is deliberately wrapper-only and is removed before the real CLI call.
if { [ "\${1:-}" = "task" ] || [ "\${1:-}" = "tasks" ]; } \
   && [ "\${2:-}" = "create" ]; then
  RAW=no
  TITLE=""
  DESCRIPTION=""
  DESCRIPTION_FILE=""
  PROJECT=""
  HAS_DESCRIPTION=no
  args=("\$@")
  for ((i = 2; i < \${#args[@]}; i++)); do
    case "\${args[\$i]}" in
      --raw) RAW=yes ;;
      --title) TITLE="\${args[\$((i + 1))]:-}"; i=\$((i + 1)) ;;
      --description) DESCRIPTION="\${args[\$((i + 1))]:-}"; HAS_DESCRIPTION=yes; i=\$((i + 1)) ;;
      --description-file) DESCRIPTION_FILE="\${args[\$((i + 1))]:-}"; HAS_DESCRIPTION=yes; i=\$((i + 1)) ;;
      --project) PROJECT="\${args[\$((i + 1))]:-}"; i=\$((i + 1)) ;;
    esac
  done
  if [ -n "\$DESCRIPTION_FILE" ] && [ -r "\$DESCRIPTION_FILE" ]; then
    DESCRIPTION="\$(cat "\$DESCRIPTION_FILE")"
  fi
  WRITTEN_TITLE="\$TITLE"
  WRITTEN_DESCRIPTION="\$DESCRIPTION"
  REWRITTEN=no
  if [ "\$RAW" != "yes" ] && [ -n "\$TITLE" ] && [ -n "\$PROJECT" ]; then
    PROMPT="\$TITLE

\$DESCRIPTION"
    if [ -n "\${AGENT_AI_WRITER_FIXTURE:-}" ]; then
      WRITER_OUTPUT="\$(cat "\$AGENT_AI_WRITER_FIXTURE" 2>/dev/null)" || WRITER_OUTPUT=""
    else
      WRITER_OUTPUT="\$(hypertask --token "\$TOKEN" --json ai write "\$PROMPT" --project "\$PROJECT" --mode task-writer 2>/dev/null)" || WRITER_OUTPUT=""
    fi
    WRITTEN="\$(WRITER_OUTPUT="\$WRITER_OUTPUT" python3 -c '
import json, os
raw = os.environ["WRITER_OUTPUT"]
start, end = raw.find("{"), raw.rfind("}")
try:
    doc = json.loads(raw[start:end + 1]) if start >= 0 and end > start else {}
except json.JSONDecodeError:
    doc = {}
title = str(doc.get("title") or "").strip()
body = str(doc.get("html") or "").strip()
if doc.get("success") is True and title and body:
    print(title)
    print(body, end="")
' 2>/dev/null || true)"
    if [ -n "\$WRITTEN" ] && [[ "\$WRITTEN" == *\$'\n'* ]]; then
      WRITTEN_TITLE="\${WRITTEN%%\$'\n'*}"
      WRITTEN_DESCRIPTION="\${WRITTEN#*\$'\n'}"
      REWRITTEN=yes
    else
      _comment_cap_note "WARNING: Hypertask AI writer failed; posting the original task text"
    fi
  fi
  POST_ARGS=()
  for ((i = 0; i < \${#args[@]}; i++)); do
    case "\${args[\$i]}" in
      --raw) ;;
      --title)
        POST_ARGS+=(--title "\$WRITTEN_TITLE")
        i=\$((i + 1)) ;;
      --description|--description-file)
        POST_ARGS+=(--description "\$WRITTEN_DESCRIPTION")
        i=\$((i + 1)) ;;
      --markdown)
        [ "\$REWRITTEN" = yes ] || POST_ARGS+=(--markdown) ;;
      *) POST_ARGS+=("\${args[\$i]}") ;;
    esac
  done
  if [ "\$REWRITTEN" = yes ] && [ "\$HAS_DESCRIPTION" = no ]; then
    POST_ARGS+=(--description "\$WRITTEN_DESCRIPTION")
  fi
  exec "\$HYPERTASK_NATIVE" --token "\$TOKEN" "\${POST_ARGS[@]}"
fi

_strip_owner_mentions() {
  local text="\$1" owner_ids="\$2"
  TEXT="\$text" OWNER_IDS="\$owner_ids" python3 -c '
import os, re
text = os.environ["TEXT"]
owners = {value for value in os.environ["OWNER_IDS"].split(",") if value}
pattern = re.compile(r"<span\\b(?=[^>]*data-label\\s*=\\s*[\"\\x27]?name-([A-Za-z0-9_-]+))[^>]*>(.*?)</span>", re.I | re.S)
def replace(match):
    return match.group(2) if not owners or match.group(1) in owners else match.group(0)
print(pattern.sub(replace, text), end="")
'
}

# QA moves are fail-closed around the two tickets the product owner reserves:
# a valentin label or a direct board-owner assignment. Agent-linked assignee
# rows carry their creator at the top level, so only a row without an agent
# counts as a direct human assignment.
if [ "\${AGENT_QA_MOVE:-no}" = "yes" ] && [ "\${1:-}" = "task" ] \
   && [ "\${2:-}" = "move" ] && [ -n "\${3:-}" ]; then
  REF="\$3"
  TASK="\$(hypertask --token "\$TOKEN" --json task get "\$REF" 2>/dev/null || true)"
  PROJECT_ID="\$(TASK="\$TASK" python3 -c '
import json, os
try:
    doc = json.loads(os.environ["TASK"])
    task = (doc.get("tasks") or [doc.get("task") or doc])[0]
    print(task.get("projectId") or task.get("boardId") or "")
except (IndexError, json.JSONDecodeError, TypeError):
    pass
')"
  PROJECT=""
  [ -z "\$PROJECT_ID" ] || PROJECT="\$(hypertask --token "\$TOKEN" --json project show "\$PROJECT_ID" 2>/dev/null || true)"
  PROTECTION="\$(TASK="\$TASK" PROJECT="\$PROJECT" python3 -c '
import json, os
try:
    doc = json.loads(os.environ["TASK"])
    task = (doc.get("tasks") or [doc.get("task") or doc])[0]
    project_doc = json.loads(os.environ["PROJECT"])
    project = project_doc.get("project") if isinstance(project_doc.get("project"), dict) else project_doc
except (IndexError, json.JSONDecodeError, TypeError):
    print("unverified")
    raise SystemExit
owner = str(project.get("ownerId") or (project.get("owner") or {}).get("id") or "")
if not owner:
    print("unverified")
    raise SystemExit
labels = set()
for label in task.get("labels") or []:
    name = (label.get("name") or label.get("title") or label.get("label") or "") if isinstance(label, dict) else str(label)
    if name:
        labels.add(str(name).strip().casefold())
if "valentin" in labels:
    print("label valentin")
    raise SystemExit
for who in task.get("assignees") or []:
    if not isinstance(who, dict) or isinstance(who.get("agent"), dict):
        continue
    if str(who.get("id") or who.get("userId") or "") == owner:
        print("board owner assignment")
        raise SystemExit
print("ok")
')"
  if [ "\$PROTECTION" != "ok" ]; then
    _comment_cap_note "QA move skipped on \$REF: \$PROTECTION"
    exit 0
  fi
  if OUT="\$(hypertask --token "\$TOKEN" "\$@")"; then RC=0; else RC=\$?; fi
  printf '%s\n' "\$OUT"
  if [ "\$RC" -eq 0 ]; then
    SECTION=""
    args=("\$@")
    for ((i = 0; i < \${#args[@]}; i++)); do
      [ "\${args[\$i]}" = "--section" ] && SECTION="\${args[\$((i + 1))]:-}"
    done
    mkdir -p "\$(dirname "\$MOVED")" 2>/dev/null || true
    printf '%s\t%s\n' "\$REF" "\$SECTION" >> "\$MOVED" 2>/dev/null || true
  fi
  exit "\$RC"
fi
# Older CLIs have no --improve path, so obtain the rewritten HTML explicitly.
_write_comment_with_ai() {
  local original="\$1" ref="\$2" plain marker prompt output rewritten
  plain="\$(_plain_comment "\$original")"
  case "\$plain" in
    Answer:*|Question:*|Decision:*|Handoff:*|Done:*) marker="\${plain%%:*}:" ;;
    *) marker="" ;;
  esac
  prompt="Rewrite this ticket comment for a product owner in plain language. Keep the leading marker exactly when one is present. Keep every @mention and HTML mention span exactly. Keep every link and the original meaning. Return one concise HTML comment only.

Original comment:
\$original"
  if [ -n "\${AGENT_AI_WRITER_FIXTURE:-}" ]; then
    output="\$(cat "\$AGENT_AI_WRITER_FIXTURE" 2>/dev/null)" || output=""
  else
    output="\$(hypertask --token "\$TOKEN" --json ai write "\$prompt" --task "\$ref" --mode write-with-ai 2>/dev/null)" || output=""
  fi
  rewritten="\$(OUTPUT="\$output" python3 -c '
import json, os
raw = os.environ["OUTPUT"]
start, end = raw.find("{"), raw.rfind("}")
try:
    doc = json.loads(raw[start:end + 1]) if start >= 0 and end > start else {}
except json.JSONDecodeError:
    doc = {}
if doc.get("success") is True:
    print(str(doc.get("html") or "").strip(), end="")
' 2>/dev/null || true)"
  if [ -n "\$rewritten" ] && ORIGINAL="\$original" REWRITTEN="\$rewritten" MARKER="\$marker" python3 -c '
import html, os, re, sys
original = os.environ["ORIGINAL"]
rewritten = os.environ["REWRITTEN"]
marker = os.environ["MARKER"]
def plain(value):
    return " ".join(html.unescape(re.sub(r"<[^>]+>", " ", value)).split())
if marker and not plain(rewritten).casefold().startswith(marker.casefold()):
    raise SystemExit(1)
spans = re.findall(r"<span\\b(?=[^>]*data-label\\s*=\\s*[\"\x27]?name-[A-Za-z0-9_-]+)[^>]*>.*?</span>", original, re.I | re.S)
mentions = re.findall(r"(?<![A-Za-z0-9_])@[A-Za-z0-9_.-]+", plain(original))
if any(value not in rewritten for value in spans) or any(value not in plain(rewritten) for value in mentions):
    raise SystemExit(1)
'; then
    TEXT="\$rewritten"
  else
    TEXT="\$original"
    _comment_cap_note "WARNING: Hypertask AI writer failed on \$ref; posting the original comment"
  fi
}

# An update has no ticket reference, so it cannot safely spend a per-ticket
# allowance. Owner mentions must be added in a new comment where the wrapper
# can identify the ticket and enforce its 24-hour ledger.
if [ "\${1:-}" = "comment" ] && [ "\${2:-}" = "update" ] && [ -n "\${3:-}" ]; then
  TEXT=""
  FILE=""
  args=("\$@")
  for ((i = 0; i < \${#args[@]}; i++)); do
    case "\${args[\$i]}" in
      --text|--body) TEXT="\${args[\$((i + 1))]:-}" ;;
      --file) FILE="\${args[\$((i + 1))]:-}" ;;
    esac
  done
  if [ -z "\$TEXT" ] && [ -n "\$FILE" ] && [ -r "\$FILE" ]; then
    TEXT="\$(cat "\$FILE")"
  fi
  if [ -n "\$TEXT" ]; then
    ORIGINAL_TEXT="\$TEXT"
    OWNER_IDS="\$(_board_owner_ids)"
    if [ "\$QUIET" = "on" ]; then
      TEXT="\$(_strip_owner_mentions "\$TEXT" "\$OWNER_IDS")"
      if [ "\$TEXT" != "\$ORIGINAL_TEXT" ]; then
        _comment_cap_note "quiet mode: stripped board-owner mention from comment update"
      fi
    fi
    _outbound_text_gate "\$TEXT" || exit 0
    if [ "\$TEXT" != "\$ORIGINAL_TEXT" ]; then
      exec "\$HYPERTASK_NATIVE" --token "\$TOKEN" comment update "\$3" --text "\$TEXT"
    fi
    if TEXT="\$TEXT" OWNER_IDS="\$OWNER_IDS" python3 -c '
import os, re, sys
mentions = set(re.findall(r"data-label\s*=\s*[^>]*?name-([A-Za-z0-9_-]+)", os.environ["TEXT"], re.I))
owners = {value for value in os.environ["OWNER_IDS"].split(",") if value}
sys.exit(0 if (mentions & owners) or (mentions and not owners) else 1)
'; then
      _comment_cap_note "owner-mention budget: comment update refused because an owner mention must use a ticket-addressed comment add"
      exit 0
    fi
  fi
fi

if [ "\${1:-}" = "comment" ] && [ "\${2:-}" = "add" ] && [ -n "\${3:-}" ]; then
  REF="\$3"
  TEXT=""
  FILE=""
  RAW=no
  USE_IMPROVE=no
  POSTED_ID=""
  args=("\$@")
  for ((i = 0; i < \${#args[@]}; i++)); do
    case "\${args[\$i]}" in
      --text|--body) TEXT="\${args[\$((i + 1))]:-}" ;;
      --file) FILE="\${args[\$((i + 1))]:-}" ;;
      --raw) RAW=yes ;;
    esac
  done
  if [ -z "\$TEXT" ] && [ -n "\$FILE" ] && [ -r "\$FILE" ]; then
    TEXT="\$(cat "\$FILE")"
  fi
  if [ -n "\$TEXT" ]; then
    ORIGINAL_TEXT="\$TEXT"
    OWNER_IDS="\$(_board_owner_ids)"
    if [ "\$QUIET" = "on" ] && [ "\$VERBATIM" != "yes" ] && [ "\$OWNER_MENTION_REPLY" != "yes" ]; then
      TEXT="\$(_strip_owner_mentions "\$TEXT" "\$OWNER_IDS")"
      if [ "\$TEXT" != "\$ORIGINAL_TEXT" ]; then
        _comment_cap_note "quiet mode: stripped board-owner mention from comment on \$REF"
      fi
    fi
    if [ "\$RAW" != yes ]; then
      USE_IMPROVE=yes
      _outbound_text_gate "\$TEXT" "\$VERBATIM" || exit 0
    fi
    mkdir -p "\$(dirname "\$OWNER_MENTIONS")" 2>/dev/null || true
    touch "\$OWNER_MENTIONS"
    exec 9>>"\$OWNER_MENTIONS.lock"
    flock 9
    OWNER_IDS="\$(_board_owner_ids)"
    EXISTING="\$(hypertask --token "\$TOKEN" --json comment list "\$REF" 2>/dev/null || echo '{"comments":[]}')"
    VERDICT="\$(EXISTING="\$EXISTING" NEW_TEXT="\$TEXT" AGENT_NAME="\$AGENT_NAME" \
      AGENT_ID="\$AGENT_ID" OWNER_IDS="\$OWNER_IDS" REF="\$REF" \
      OWNER_MENTIONS="\$OWNER_MENTIONS" OWNER_MENTION_REPLY="\$OWNER_MENTION_REPLY" \
      NOW="\$(date +%s)" python3 -c '
import datetime, html, json, os, re

def signature(value):
    text = html.unescape(re.sub(r"<[^>]+>", " ", value))
    return " ".join(text.split()).casefold()[:40]

def author_of(c):
    who = c.get("agent") or c.get("creator") or c.get("user") or {}
    if isinstance(who, dict):
        return str(who.get("displayName") or who.get("name") or "")
    return str(who)

def is_mine(c):
    agent = c.get("agent") if isinstance(c.get("agent"), dict) else {}
    agent_id = str(agent.get("id") or "")
    return (agent_id and agent_id == os.environ["AGENT_ID"]) or (
        not agent_id and author_of(c).strip().casefold() == agent_name)

def mention_ids(text):
    return set(re.findall(r"data-label\s*=\s*[^>]*?name-([A-Za-z0-9_-]+)", text, re.I))

def created_at(c):
    value = str(c.get("createdAt") or "")
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(datetime.timezone.utc)
    except ValueError:
        return None

try:
    comments = json.loads(os.environ["EXISTING"]).get("comments") or []
except json.JSONDecodeError:
    comments = []
agent_name = os.environ["AGENT_NAME"].strip().casefold()
owner_ids = {value for value in os.environ["OWNER_IDS"].split(",") if value}
new_text = os.environ["NEW_TEXT"]
new_mentions = mention_ids(new_text)
new_owner_mention = bool(new_mentions & owner_ids)
owner_mention_reply = os.environ["OWNER_MENTION_REPLY"] == "yes"
now = int(os.environ["NOW"])
now_at = datetime.datetime.fromtimestamp(now, datetime.timezone.utc)
new_signature = signature(new_text)
recent_duplicate = None
today_count = 0
recent_owner_mention = False
for c in comments:
    if not is_mine(c):
        continue
    text = c.get("text") or c.get("commentText") or c.get("comment") or c.get("html") or ""
    when = created_at(c)
    if when and when.date() == now_at.date():
        today_count += 1
    age = now - when.timestamp() if when else 86401
    if 0 <= age < 86400:
        if mention_ids(text) & owner_ids:
            recent_owner_mention = True
        if new_signature and signature(text) == new_signature and c.get("id") is not None:
            candidate = (when, str(c.get("id")))
            if recent_duplicate is None or candidate > recent_duplicate:
                recent_duplicate = candidate

try:
    with open(os.environ["OWNER_MENTIONS"], encoding="utf-8") as handle:
        for line in handle:
            ref, at = (line.rstrip("\n").split("\t") + ["", ""])[:2]
            if ref == os.environ["REF"] and now - int(at) < 86400:
                recent_owner_mention = True
except (OSError, ValueError):
    pass

if new_mentions and not owner_ids:
    print("OWNER_UNKNOWN")
elif new_owner_mention and recent_owner_mention and not owner_mention_reply:
    print("OWNER")
elif recent_duplicate:
    print("UPDATE:" + recent_duplicate[1])
elif today_count >= 3:
    print("CAP")
elif new_owner_mention:
    print("OK_OWNER")
else:
    print("OK")
')"
    if [ "\$VERBATIM" = "yes" ] && [[ "\$VERDICT" = UPDATE:* ]]; then
      VERDICT="OK"
    fi
    case "\$VERDICT" in
      OWNER)
        _comment_cap_note "owner-mention budget: comment add refused on \$REF because this agent already @mentioned the board owner in the last 24 hours"
        exit 0 ;;
      OWNER_UNKNOWN)
        _comment_cap_note "owner-mention budget: comment add refused on \$REF because the board owner could not be verified"
        exit 0 ;;
      UPDATE:*)
        UPDATE_ID="\${VERDICT#UPDATE:}"
        if OUT="\$(hypertask --token "\$TOKEN" comment update "\$UPDATE_ID" --text "\$TEXT")"; then
          _comment_cap_note "comment dedupe on \$REF: updated near-identical comment \$UPDATE_ID instead of posting a new one"
          mkdir -p "\$(dirname "\$POSTED")" 2>/dev/null || true
          printf '%s %s\n' "\$REF" "\$UPDATE_ID" >> "\$POSTED" 2>/dev/null || true
          printf '%s\n' "\$OUT"
          exit 0
        else
          RC=\$?
          printf '%s\n' "\$OUT"
          exit "\$RC"
        fi ;;
      CAP)
        _comment_cap_note "comment add refused on \$REF: daily cap reached (3 agent comments on this ticket today UTC)"
        exit 0 ;;
    esac
    # Posted for real: run it directly (not exec) so this script can look up
    # the id the board gave the new comment and hand it to core. Core writes
    # that id to this agent's seen-state after the run, so the next tick's
    # state key already matches this agent's own reply and the ticket is not
    # picked back up as if it were untouched. Without this, only the rank-3
    # "new work" path skipped an agent's own comment; a claimed-unfinished
    # ticket (rank 1) had no such guard and got reprocessed every tick.
    POST_ARGS=()
    for ((i = 0; i < \${#args[@]}; i++)); do
      case "\${args[\$i]}" in
        --raw|--improve) ;;
        --improve-command) i=\$((i + 1)) ;;
        --text|--body|--file)
          POST_ARGS+=(--text "\$TEXT")
          i=\$((i + 1)) ;;
        *) POST_ARGS+=("\${args[\$i]}") ;;
      esac
    done
    FALLBACK_ARGS=("\${POST_ARGS[@]}")
    if [ -n "\$REPLY_TO_COMMENT_ID" ]; then
      if [ "\$USE_IMPROVE" = yes ]; then
        _write_comment_with_ai "\$TEXT" "\$REF"
        _outbound_text_gate "\$TEXT" "\$VERBATIM" || exit 0
        for ((i = 0; i < \${#FALLBACK_ARGS[@]}; i++)); do
          if [ "\${FALLBACK_ARGS[\$i]}" = "--text" ]; then
            FALLBACK_ARGS[\$((i + 1))]="\$TEXT"
          fi
        done
      fi
      PAYLOAD="\$(REF="\$REF" TEXT="\$TEXT" REPLY_TO_COMMENT_ID="\$REPLY_TO_COMMENT_ID" python3 -c '
import json, os
reply_id = os.environ["REPLY_TO_COMMENT_ID"]
if reply_id.isdigit():
    reply_id = int(reply_id)
print(json.dumps({"ticket_number": os.environ["REF"], "text": os.environ["TEXT"],
                  "reply_to_comment_id": reply_id}))')"
      if REPLY="\$(curl -sS -w '\n%{http_code}' -X POST \
        -H "Authorization: Bearer \$TOKEN" -H 'Content-Type: application/json' \
        --data "\$PAYLOAD" "\${BOARD_API_URL%/}/mcp/comments" 2>/dev/null)"; then
        STATUS="\${REPLY##*\$'\n'}"
        OUT="\${REPLY%\$'\n'*}"
      else
        STATUS=000
        OUT=""
      fi
      if [[ "\$STATUS" = 2* ]]; then
        RC=0
        POSTED_ID="\$(REPLY_BODY="\$OUT" python3 -c '
import json, os
try:
    row = json.loads(os.environ["REPLY_BODY"])
except json.JSONDecodeError:
    row = {}
comment = row.get("comment") if isinstance(row.get("comment"), dict) else row
print(comment.get("id") or "")' 2>/dev/null || true)"
      else
        _comment_cap_note "reply-stamped comment API failed on \$REF (HTTP \$STATUS); falling back to CLI without reply stamp"
        if OUT="\$(hypertask --token "\$TOKEN" "\${FALLBACK_ARGS[@]}")"; then
          RC=0
        else
          RC=\$?
        fi
      fi
    elif [ "\$USE_IMPROVE" = yes ]; then
      POST_ARGS+=(--improve --improve-command improve-readability)
      IMPROVE_ERR="\$(mktemp "\${TMPDIR:-/tmp}/agent-comment-improve.XXXXXX")"
      if OUT="\$(hypertask --token "\$TOKEN" "\${POST_ARGS[@]}" 2>"\$IMPROVE_ERR")"; then
        RC=0
      else
        RC=\$?
        cat "\$IMPROVE_ERR" >&2
        if grep -qiE '(unknown|unrecognized|invalid).*(option|argument).*--improve|--improve.*(unknown|unrecognized|invalid)' "\$IMPROVE_ERR"; then
          _write_comment_with_ai "\$TEXT" "\$REF"
          _outbound_text_gate "\$TEXT" "\$VERBATIM" || { rm -f "\$IMPROVE_ERR"; exit 0; }
          for ((i = 0; i < \${#FALLBACK_ARGS[@]}; i++)); do
            if [ "\${FALLBACK_ARGS[\$i]}" = "--text" ]; then
              FALLBACK_ARGS[\$((i + 1))]="\$TEXT"
            fi
          done
          if OUT="\$(hypertask --token "\$TOKEN" "\${FALLBACK_ARGS[@]}")"; then
            RC=0
          else
            RC=\$?
          fi
        elif grep -qiE '(ai|writer|improv).*(fail|error|empty|unavailable)|(fail|error|empty|unavailable).*(ai|writer|improv)' "\$IMPROVE_ERR"; then
          _comment_cap_note "WARNING: Hypertask AI writer failed on \$REF; posting the original comment"
          if OUT="\$(hypertask --token "\$TOKEN" "\${FALLBACK_ARGS[@]}")"; then
            RC=0
          else
            RC=\$?
          fi
        fi
      fi
      rm -f "\$IMPROVE_ERR"
    elif OUT="\$(hypertask --token "\$TOKEN" "\${FALLBACK_ARGS[@]}")"; then
      RC=0
    else
      RC=\$?
    fi
    printf '%s\n' "\$OUT"
    if [ "\$RC" -eq 0 ]; then
      if [ "\$VERDICT" = "OK_OWNER" ]; then
        REF="\$REF" AT="\$(date +%s)" python3 - "\$OWNER_MENTIONS" <<'PYEOF'
import os, sys
path = sys.argv[1]
ref = os.environ["REF"]
with open(path, encoding="utf-8") as handle:
    rows = [line for line in handle if line.split("\t", 1)[0] != ref]
rows.append("%s\t%s\n" % (ref, os.environ["AT"]))
temporary = path + ".new"
with open(temporary, "w", encoding="utf-8") as handle:
    handle.writelines(rows)
os.replace(temporary, path)
PYEOF
      fi
      NEWID="\$POSTED_ID"
      if [ -z "\$NEWID" ]; then
        LISTED="\$(hypertask --token "\$TOKEN" --json comment list "\$REF" 2>/dev/null || echo '{"comments":[]}')"
        NEWID="\$(LISTED="\$LISTED" AGENT_NAME="\$AGENT_NAME" AGENT_ID="\$AGENT_ID" python3 -c '
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
agent_id = os.environ["AGENT_ID"]
def is_mine(c):
    agent = c.get("agent") if isinstance(c.get("agent"), dict) else {}
    found = str(agent.get("id") or "")
    return (found and found == agent_id) or (not found and author_of(c).strip().casefold() == agent_name)
mine = [c for c in comments if is_mine(c)]
if mine:
    best = max(mine, key=lambda c: c.get("id") or 0)
    print(best.get("id") or "")
')"
      fi
      if [ -n "\$NEWID" ]; then
        mkdir -p "\$(dirname "\$POSTED")" 2>/dev/null || true
        printf '%s %s\n' "\$REF" "\$NEWID" >> "\$POSTED" 2>/dev/null || true
      fi
    fi
    exit "\$RC"
  fi
fi

exec "\$HYPERTASK_NATIVE" --token "\$TOKEN" "\$@"
EOF
  chmod 755 "$dest"
}

# ---------- reads ----------
# Normalize one task-list response to the candidate JSONL core consumes.
_ht_candidate_rows() {
  local sections="$1" board="$2"
  SECTIONS="$sections" BOARD_ID="$board" python3 -c '
import json, os, sys
raw = os.environ["SECTIONS"].strip()
wanted = [] if raw == "*" else [s.strip().casefold() for s in raw.split(",") if s.strip()]
board = os.environ["BOARD_ID"]
for task in json.load(sys.stdin).get("tasks") or []:
    section = str(task.get("section") or "")
    if wanted and section.casefold() not in wanted:
        continue
    agent_ids = []
    human_assignee_ids = []
    assignees = task.get("assignees") or []
    for who in assignees:
        agent = who.get("agent") if isinstance(who, dict) else None
        if isinstance(agent, dict) and agent.get("id"):
            agent_ids.append(str(agent["id"]))
        elif isinstance(who, dict):
            human_id = who.get("id") or who.get("userId")
            if human_id is not None:
                human_assignee_ids.append(str(human_id))
    # Labels decide whether a ticket is open season. A board carries them under
    # several shapes depending on how the task was created, so take the name
    # off whichever one is present and lowercase it once, here.
    labels = []
    for label in task.get("labels") or []:
        name = ((label.get("name") or label.get("title") or label.get("label") or "")
                if isinstance(label, dict) else str(label))
        if name:
            labels.append(str(name).strip().casefold())
    priority = task.get("priority") or ""
    if isinstance(priority, dict):
        priority = priority.get("name") or priority.get("title") or ""
    ref = str(task.get("ticketNumber") or "")
    index = ref.rsplit("-", 1)[-1] if "-" in ref else str(task.get("id"))
    actual_board = str(task.get("projectId") or board)
    print(json.dumps({
        "id": task.get("id"),
        "ref": ref,
        "section": section,
        "title": task.get("title") or "",
        "description": task.get("description") or "",
        "priority": str(priority),
        "dueDate": task.get("dueDate") or "",
        "updated_at": task.get("updatedAt") or "",
        "section_entered_at": (task.get("sectionEnteredAt") or task.get("sectionChangedAt")
                               or task.get("sectionUpdatedAt") or task.get("movedAt") or ""),
        "agent_ids": agent_ids,
        "human_assignee_ids": human_assignee_ids,
        # Anyone at all on the ticket, human or agent: a ticket with a name on
        # it belongs to whoever put it there, and is not free to pick up.
        "assignee_count": len(assignees),
        "labels": labels,
        "comment_count": task.get("commentCount") or 0,
        "board": actual_board,
        "url": "https://app.hypertask.ai/detail/project-%s/%s" % (actual_board, index),
    }))
'
}

# adapter_list_candidates <token-file> <board-id> <sections-csv>
# Full paginated list, retained for URL resolution and explicit full scans.
adapter_list_candidates() {
  local token_file="$1" board_id="$2" sections="$3" one offset path json returned
  for one in $(printf '%s' "$board_id" | tr ',' ' '); do
    [ -n "$one" ] || continue
    offset=0
    while :; do
      path="/mcp/tasks?project_id=${one}&limit=100"
      [ "$offset" -eq 0 ] || path="$path&offset=$offset"
      json="$(_ht_get "$token_file" "$path")"
      printf '%s' "$json" | _ht_candidate_rows "$sections" "$one"
      returned="$(printf '%s' "$json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("tasks") or []))')"
      [ "$returned" -eq 100 ] || break
      offset=$((offset + returned))
    done
  done
}

# adapter_list_tick_candidates <token-file> <board-id> <sections-csv> <ticket-or-empty> <target-board-or-empty>
# Ordinary ticks rank only rows newer than their last successful list. A full
# safety scan is allowed once an hour. Event ticks query exactly one ticket.
adapter_list_tick_candidates() {
  local token_file="$1" board_id="$2" sections="$3" ticket="${4:-}" target_board="${5:-}"
  local one offset path json returned cursor_file full_file pending_file cutoff full now latest rows merged
  if [ -n "$ticket" ]; then
    json="$(_ht_get "$token_file" "/mcp/tasks?ticket_number=${ticket}")"
    for one in $(printf '%s' "${target_board:-$board_id}" | tr ',' ' '); do
      case ",$board_id," in *",$one,"*) : ;; *) continue ;; esac
      printf '%s' "$json" | _ht_candidate_rows "*" "$one" | REF="$ticket" BOARD="$one" python3 -c '
import json, os, sys
for line in sys.stdin:
    row = json.loads(line)
    if str(row.get("ref") or "").casefold() == os.environ["REF"].casefold() and str(row.get("board")) == os.environ["BOARD"]:
        print(json.dumps(row))
        break
'
    done
    return 0
  fi

  now="$(date +%s)"
  for one in $(printf '%s' "$board_id" | tr ',' ' '); do
    [ -n "$one" ] || continue
    cursor_file="$STATE_DIR/$SLUG.updated-cursor.$one"
    full_file="$STATE_DIR/$SLUG.full-rescan.$one"
    cutoff=""; [ -r "$cursor_file" ] && read -r cutoff < "$cursor_file" || true
    full="no"
    if [ ! -r "$full_file" ] || [ "$((now - $(cat "$full_file" 2>/dev/null || printf 0)))" -ge 3600 ]; then
      full="yes"
    fi
    rows=""; latest="$cutoff"; offset=0
    while :; do
      path="/mcp/tasks?project_id=${one}&limit=100"
      [ "$offset" -eq 0 ] || path="$path&offset=$offset"
      json="$(_ht_get "$token_file" "$path")"
      page="$(printf '%s' "$json" | _ht_candidate_rows "$sections" "$one")"
      [ -z "$page" ] || rows="${rows}${rows:+$'\n'}${page}"
      page_latest="$(printf '%s\n' "$page" | python3 -c 'import json,sys; values=[json.loads(x).get("updated_at") or "" for x in sys.stdin if x.strip()]; print(max(values or [""]))')"
      [[ "$page_latest" > "$latest" ]] && latest="$page_latest"
      returned="$(printf '%s' "$json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("tasks") or []))')"
      [ "$returned" -eq 100 ] || break
      offset=$((offset + returned))
    done
    pending_file="$STATE_DIR/$SLUG.ranking-pending.$one.jsonl"
    merged="$(printf '%s\n' "$rows" | CUTOFF="$cutoff" FULL="$full" PENDING="$pending_file" python3 -c '
import json, os, sys
rows, order = {}, []
def keep(row):
    key = str(row.get("id") or "")
    if not key or key in rows:
        return
    rows[key] = row
    order.append(key)
for line in sys.stdin:
    if not line.strip():
        continue
    row = json.loads(line)
    updated = str(row.get("updated_at") or "")
    if os.environ["FULL"] == "yes" or not os.environ["CUTOFF"] or not updated or updated > os.environ["CUTOFF"]:
        keep(row)
try:
    with open(os.environ["PENDING"], encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                keep(json.loads(line))
except OSError:
    pass
for key in order:
    print(json.dumps(rows[key]))
')"
    printf '%s\n' "$merged"
    if [ "${DRY_RUN:-no}" != "yes" ]; then
      printf '%s\n' "$merged" | sed '/^$/d' > "$pending_file.new"
      mv "$pending_file.new" "$pending_file"
      [ -z "$latest" ] || { printf '%s\n' "$latest" > "$cursor_file.new"; mv "$cursor_file.new" "$cursor_file"; }
      [ "$full" = "no" ] || { printf '%s\n' "$now" > "$full_file.new"; mv "$full_file.new" "$full_file"; }
    fi
  done
}


# Persist the final de-duplicated candidate set, including owned-comment rows
# outside WATCH_SECTIONS, before ranking can hit its time boundary.
adapter_persist_tick_candidates() {
  [ "${DRY_RUN:-no}" != "yes" ] || { cat >/dev/null; return 0; }
  STATE="$STATE_DIR" SLUG_VALUE="$SLUG" python3 -c '
import json, os, sys
from pathlib import Path
state = Path(os.environ["STATE"])
slug = os.environ["SLUG_VALUE"]
by_board = {}
for line in sys.stdin:
    if not line.strip():
        continue
    row = json.loads(line)
    by_board.setdefault(str(row.get("board") or ""), []).append(row)
for board, incoming in by_board.items():
    if not board:
        continue
    path = state / (slug + ".ranking-pending." + board + ".jsonl")
    rows, order = {}, []
    for row in incoming:
        key = str(row.get("id") or "")
        if key and key not in rows:
            rows[key] = row; order.append(key)
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            row = json.loads(line)
            key = str(row.get("id") or "")
            if key and key not in rows:
                rows[key] = row; order.append(key)
    except OSError:
        pass
    temporary = Path(str(path) + ".new")
    temporary.write_text("".join(json.dumps(rows[key]) + "\n" for key in order), encoding="utf-8")
    temporary.replace(path)
'
}

# Remove one row from the durable ranking tail immediately before core ranks it.
# Rows after the 60-second boundary remain for the next minute's tick.
adapter_mark_tick_candidate() {
  local task_id="$1" board="$2" file
  file="$STATE_DIR/$SLUG.ranking-pending.$board.jsonl"
  [ "${DRY_RUN:-no}" != "yes" ] || return 0
  [ -f "$file" ] || return 0
  TASK_ID="$task_id" python3 - "$file" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
rows = []
with open(path, encoding="utf-8") as handle:
    for line in handle:
        if not line.strip():
            continue
        row = json.loads(line)
        if str(row.get("id") or "") != os.environ["TASK_ID"]:
            rows.append(row)
temporary = path + ".new"
with open(temporary, "w", encoding="utf-8") as handle:
    for row in rows:
        handle.write(json.dumps(row) + "\n")
os.replace(temporary, path)
PYEOF
}

# adapter_queue_order <candidate-json>
# New queued work sorts expedited tickets first, then by due date. Core keeps
# its ownership ranks ahead of this key and supplies board order as the final tie.
adapter_queue_order() {
  printf '%s' "$1" | python3 -c '
from datetime import datetime, timedelta, timezone
import json, sys

row = json.load(sys.stdin)
raw_due = str(row.get("dueDate") or "").strip()
due = None
if raw_due:
    try:
        due = datetime.fromisoformat(raw_due[:-1] + "+00:00" if raw_due.endswith("Z") else raw_due)
        if due.tzinfo is None:
            due = due.replace(tzinfo=timezone.utc)
        due = due.astimezone(timezone.utc)
    except ValueError:
        pass
urgent = str(row.get("priority") or "").strip().casefold() == "urgent"
due_soon = due is not None and due <= datetime.now(timezone.utc) + timedelta(hours=48)
if urgent or due_soon:
    print("0 %.6f" % (due.timestamp() if due is not None else 253402300799))
else:
    print("1 0")
'
}

# adapter_ticket_ref <token-file> <ticket-ref-or-url>
# URLs are resolved through the same normalized task rows used by ticket pickup,
# so project ids never become a second hard-coded prefix map in core.
adapter_ticket_ref() {
  local token_file="$1" ticket="$2" board_id rows
  if [[ ! "$ticket" =~ ^https://app\.hypertask\.ai/detail/project-([0-9]+)/([0-9]+)$ ]]; then
    printf '%s' "$ticket"
    return 0
  fi
  board_id="${BASH_REMATCH[1]}"
  rows="$(adapter_list_candidates "$token_file" "$board_id" "*")" || return 1
  printf '%s\n' "$rows" | TICKET_URL="$ticket" python3 -c '
import json, os, re, sys
wanted = os.environ["TICKET_URL"]
for line in sys.stdin:
    if not line.strip():
        continue
    row = json.loads(line)
    ref = str(row.get("ref") or "")
    if row.get("url") == wanted and re.fullmatch(r"[A-Za-z][A-Za-z0-9]*-[0-9]+", ref):
        print(ref)
        raise SystemExit(0)
raise SystemExit(1)
'
}

# adapter_ticket_comments <token-file> <task-id> <board-id>
# One JSON array of normalized comments. A comment's real actor is the "agent"
# field, not "creator": an agent-authenticated comment still carries the
# account owner as creator.
adapter_ticket_comments() {
  local token_file="$1" task_id="$2" board_id="$3" json
  json="$(_ht_get "$token_file" "/mcp/comments?task_id=${task_id}&project_id=${board_id}")"
  printf '%s' "$json" | python3 -c '
import json, sys
rows = []
for comment in json.load(sys.stdin).get("comments") or []:
    agent = comment.get("agent") if isinstance(comment.get("agent"), dict) else None
    creator = comment.get("creator") if isinstance(comment.get("creator"), dict) else {}
    rows.append({
        "id": comment.get("id"),
        "createdAt": comment.get("createdAt") or "",
        "html": comment.get("text") or comment.get("commentText") or comment.get("html") or "",
        "author": (agent or creator).get("displayName") or "",
        "author_id": "" if agent else str(creator.get("id") or creator.get("userId") or ""),
        "agent_id": (agent or {}).get("id") or "",
    })
print(json.dumps(rows))
'
}

# adapter_latest_comment <token-file> <task-id> <board-id>
# JSON {"id":..., "createdAt":..., "html":..., "author":..., "author_id":..., "agent_id":...}
# or an empty line when there is none.
adapter_latest_comment() {
  local comments
  comments="$(adapter_ticket_comments "$1" "$2" "$3")"
  COMMENTS="$comments" python3 -c '
import json, os
comments = json.loads(os.environ["COMMENTS"])
if comments:
    print(json.dumps(max(comments, key=lambda c: (c.get("createdAt") or "", c.get("id") or 0))))
'
}

# adapter_is_owner_mention <board-cli> <board-id> <comment-json> <agent-mention-token>
adapter_is_owner_mention() {
  local board_cli="$1" board_id="$2" comment="$3" mention="$4" project
  project="$($board_cli --json project show "$board_id" 2>/dev/null)" || return 1
  COMMENT="$comment" PROJECT="$project" MENTION="$mention" python3 -c '
import json, os, sys
try:
    comment = json.loads(os.environ["COMMENT"])
    raw = os.environ["PROJECT"]
    project_doc = json.loads(raw[raw.find("{"):raw.rfind("}") + 1])
    project = project_doc.get("project") if isinstance(project_doc.get("project"), dict) else project_doc
except (json.JSONDecodeError, TypeError):
    raise SystemExit(1)
owner_id = str(project.get("ownerId") or (project.get("owner") or {}).get("id") or "")
author_id = str(comment.get("author_id") or "")
mentioned = os.environ["MENTION"] in str(comment.get("html") or "")
sys.exit(0 if owner_id and author_id == owner_id and mentioned else 1)
'
}

# adapter_qa_board_config <board-cli> <board-ids> <fail-override> <blocked-override>
# One JSON object per board with the protected owner and resolved QA columns.
adapter_qa_board_config() {
  local board_cli="$1" board_ids="$2" fail_override="$3" blocked_override="$4"
  local board project
  for board in $(printf '%s' "$board_ids" | tr ',' ' '); do
    [ -n "$board" ] || continue
    project="$($board_cli --json project show "$board" 2>/dev/null)" || return 1
    printf '%s' "$project" | BOARD="$board" FAIL="$fail_override" BLOCKED="$blocked_override" python3 -c '
import json, os, sys
raw = sys.stdin.read()
start, end = raw.find("{"), raw.rfind("}")
if start < 0 or end <= start:
    raise SystemExit(1)
doc = json.loads(raw[start:end + 1])
project = doc.get("project") if isinstance(doc.get("project"), dict) else doc
sections = project.get("sections") or []
def name(item):
    if isinstance(item, dict):
        return str(item.get("section_title") or item.get("title") or item.get("name") or item.get("id") or "")
    return str(item or "")
names = [name(item) for item in sections if name(item)]
def canonical(value):
    value = str(value or "").strip()
    return next((item for item in names if item.casefold() == value.casefold()), value)
fail = os.environ["FAIL"].strip()
if fail:
    fail = canonical(fail)
else:
    for key in ("intakeSection", "intake_section", "defaultSection", "default_section"):
        fail = name(project.get(key))
        if fail:
            break
    if not fail:
        defaults = project.get("defaultSections") or project.get("default_sections") or []
        fail = name(defaults[0]) if defaults else ""
    if not fail:
        intake = [name(item) for item in sections if isinstance(item, dict) and (
            item.get("isIntake") or str(item.get("type") or item.get("role") or "").casefold() == "intake")]
        fail = intake[0] if intake else (names[0] if names else "")
blocked = os.environ["BLOCKED"].strip()
if blocked:
    blocked = canonical(blocked)
else:
    blocked = canonical("Agent Blocked (Infra)")
owner = project.get("ownerId") or (project.get("owner") or {}).get("id") or ""
print(json.dumps({"board": os.environ["BOARD"], "owner_id": str(owner),
                  "fail_section": fail, "blocked_section": blocked}))
'
  done
}

# adapter_clear_assignees <board-cli> <ref>
adapter_clear_assignees() {
  local board_cli="$1" ref="$2" task assignees assignee
  task="$($board_cli --json task get "$ref" 2>/dev/null)" || return 1
  assignees="$(printf '%s' "$task" | python3 -c '
import json, sys
raw = sys.stdin.read()
start, end = raw.find("{"), raw.rfind("}")
if start < 0 or end <= start:
    raise SystemExit(1)
doc = json.loads(raw[start:end + 1])
task = (doc.get("tasks") or [doc.get("task") or doc])[0]
for who in task.get("assignees") or []:
    if not isinstance(who, dict):
        continue
    agent = who.get("agent") if isinstance(who.get("agent"), dict) else {}
    value = agent.get("id") or who.get("id") or who.get("userId")
    if value is not None:
        print(value)
')" || return 1
  while IFS= read -r assignee; do
    [ -n "$assignee" ] || continue
    "$board_cli" task unassign "$ref" --assignee "$assignee" >/dev/null 2>&1 || return 1
  done <<< "$assignees"
}

# _ht_owned_row <token-file> <task-id> <row-json> <board-id> <agent-id>
# Given a candidate row (already known to be assigned to this agent, or to
# have at least one comment) and its task id, prints the same row with
# "trigger": "new_comment" added when its newest comment is a human's or
# another agent's and this agent owns the ticket, or nothing at all. One read.
#
# Ownership here is assigned, or having posted the most recent agent comment
# before this one: the "claimed by a comment, never assigned" case a plain
# Q&A agent needs, since it has no claim step of its own. A ticket only ever
# claimed in words no comment carries (rare, and unusual for this board's own
# claim-ticket.sh, which assigns) is outside this check's reach.
_ht_owned_row() {
  local token_file="$1" task_id="$2" row="$3" board_id="$4" agent_id="$5" comments
  comments="$(_ht_get "$token_file" "/mcp/comments?task_id=${task_id}&project_id=${board_id}" 2>/dev/null)" || return 0
  if ! printf '%s\n%s' "$row" "$comments" | AID="$agent_id" ANAME="${AGENT_NAME:-}" OWNED_REPLY_ADDRESSED="${OWNED_REPLY_ADDRESSED:-}" python3 -c '
import json, os, sys
row = json.loads(sys.stdin.readline())
doc = json.load(sys.stdin)
aid = os.environ["AID"]
comments = doc.get("comments") or []
if not comments:
    sys.exit(0)
comments.sort(key=lambda c: (c.get("createdAt") or "", c.get("id") or 0))
newest = comments[-1]
# This agent cannot wake itself. A human or a different agent can provide new
# instruction and therefore may bypass the per-ticket cooldown in core.
newest_agent = newest.get("agent") if isinstance(newest.get("agent"), dict) else {}
if str(newest_agent.get("id") or "") == aid:
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
# OWNED_REPLY_ADDRESSED=yes: on a board where humans talk to each other under a
# ticket the agent once commented on, only a reply that addresses the agent
# (its name, or a "fix:" correction) is work for it. Assigned tickets always are.
if os.environ.get("OWNED_REPLY_ADDRESSED", "").lower() == "yes" and not assigned:
    import re
    text = re.sub(r"<[^>]+>", " ", newest.get("html") or newest.get("text") or "")
    name = os.environ.get("ANAME", "").strip().casefold()
    if not (name and name in text.casefold()) and not re.match(r"\s*fix\s*:", text, re.I):
        sys.exit(0)
row["trigger"] = "new_comment"
print(json.dumps(row))
'; then
    echo "ERROR: could not inspect comments for task $task_id; its owned-reply wake check failed" >&2
    return 1
  fi
}

# _record_valentin_comments <jsonl-file> <board-id> <ticket-ref>
# Every direct owner comment becomes one compact, deduplicated line shared by
# all runners. Keeping all of Valentin's own words avoids guessing which short
# sentence was intended as a durable rule.
_record_valentin_comments() {
  local comments_file="$1" board_id="$2" ref="$3"
  local record="${VALENTIN_RULES_RECORD:-$STATE_DIR/valentin-ticket-rules.tsv}"
  [ -s "$comments_file" ] || return 0
  mkdir -p "$(dirname "$record")"
  touch "$record"
  exec 8>>"$record.lock"
  flock 8
  BOARD="$board_id" REF="$ref" python3 - "$comments_file" "$record" <<'PYEOF'
import html
import json
import os
import re
import sys

source, target = sys.argv[1:]
seen = set()
with open(target, encoding="utf-8") as handle:
    for line in handle:
        if line.strip():
            seen.add(line.split("\t", 1)[0])
rows = []
with open(source, encoding="utf-8") as handle:
    for line in handle:
        if not line.strip():
            continue
        comment = json.loads(line)
        if isinstance(comment.get("agent"), dict):
            continue
        creator = comment.get("creator") if isinstance(comment.get("creator"), dict) else {}
        creator_id = str(creator.get("id") or creator.get("userId") or "")
        author = str(creator.get("displayName") or creator.get("name") or "")
        if creator_id != "6" and not author.casefold().startswith("valentin"):
            continue
        key = "%s:%s" % (os.environ["BOARD"], comment.get("id") or "")
        if key in seen:
            continue
        raw = str(comment.get("text") or comment.get("commentText") or comment.get("html") or "")
        links = re.findall(r'(?:href|src)=["\x27]([^"\x27]+)', raw, flags=re.I)
        text = " ".join(html.unescape(re.sub(r"<[^>]+>", " ", raw)).split())
        if links:
            text += " [links: %s]" % ", ".join(dict.fromkeys(links))
        text = text.replace("\t", " ").replace("\n", " ")
        rows.append("\t".join((key, os.environ["REF"], str(comment.get("createdAt") or ""), text)))
        seen.add(key)
if rows:
    with open(target, "a", encoding="utf-8") as handle:
        handle.write("\n".join(rows) + "\n")
PYEOF
  flock -u 8
  exec 8>&-
}

# adapter_new_comments_on_owned <token-file> <board-id> <agent-id> <agent-name>
# Optional: reads each board's recently updated ticket comments until it reaches
# the last comment id this agent saw there. The cursor avoids rereading a fixed
# window of ticket histories, and the per-tick ceiling bounds a genuine backlog
# without emitting one warning per skipped ticket.
adapter_new_comments_on_owned() {
  local token_file="$1" board_id="$2" agent_id="$3" agent_name="$4"
  local one status tasks rows task task_id task_ref comments page_stats page_count page_max
  local page_caught page_cursor comments_cursor remaining direct offset returned
  local cursor_file updated_cursor_file updated_cutoff last_seen max_seen read_count hit_ceiling ceiling_board page_has_new comments_file
  local ceiling="${OWNED_COMMENT_READ_CEILING:-500}"
  read_count=0
  hit_ceiling="no"
  ceiling_board=""

  for one in $(printf '%s' "$board_id" | tr ',' ' '); do
    [ -n "$one" ] || continue
    cursor_file="$STATE_DIR/$SLUG.comment-cursor.$one"
    updated_cursor_file="$STATE_DIR/$SLUG.updated-cursor.$one"
    updated_cutoff=""
    [ -r "$updated_cursor_file" ] && read -r updated_cutoff < "$updated_cursor_file" || true
    last_seen=0
    if [ -r "$cursor_file" ]; then
      read -r last_seen < "$cursor_file" || last_seen=0
    fi
    [[ "$last_seen" =~ ^[0-9]+$ ]] || last_seen=0
    max_seen="$last_seen"

    # Archived tickets are a separate API status, not a board column. Scan
    # both feeds so a human can address the agent after a ticket was archived.
    for status in Normal Archive; do
      offset=0
      while [ "$read_count" -lt "$ceiling" ]; do
        tasks="$(_ht_get "$token_file" "/mcp/tasks?project_id=${one}&status=${status}&sort_by=updatedAt&sort_order=desc&limit=100&offset=${offset}")"
        rows="$(printf '%s' "$tasks" | BOARD="$one" CUTOFF="$updated_cutoff" python3 -c '
import json, os, sys
board = os.environ["BOARD"]
cutoff = os.environ["CUTOFF"]
for task in json.load(sys.stdin).get("tasks") or []:
    updated = str(task.get("updatedAt") or "")
    if cutoff and updated and updated <= cutoff:
        continue
    if not (task.get("commentCount") or 0):
        continue
    assignees = task.get("assignees") or []
    agent_ids = []
    for who in assignees:
        agent = who.get("agent") if isinstance(who, dict) else None
        if isinstance(agent, dict) and agent.get("id"):
            agent_ids.append(str(agent["id"]))
    labels = []
    for label in task.get("labels") or []:
        name = (label.get("name") or label.get("title") or label.get("label") or "") if isinstance(label, dict) else str(label)
        if name:
            labels.append(str(name).strip().casefold())
    priority = task.get("priority") or ""
    if isinstance(priority, dict):
        priority = priority.get("name") or priority.get("title") or ""
    ref = str(task.get("ticketNumber") or "")
    index = ref.rsplit("-", 1)[-1] if "-" in ref else str(task.get("id"))
    print(json.dumps({
        "id": task.get("id"), "ref": ref, "section": str(task.get("section") or ""),
        "title": task.get("title") or "", "description": task.get("description") or "",
        "priority": str(priority), "dueDate": task.get("dueDate") or "",
        "updated_at": task.get("updatedAt") or "",
        "section_entered_at": (task.get("sectionEnteredAt") or task.get("sectionChangedAt")
                               or task.get("sectionUpdatedAt") or task.get("movedAt") or ""),
        "agent_ids": agent_ids, "assignee_count": len(assignees), "labels": labels,
        "comment_count": task.get("commentCount") or 0, "board": board,
        "url": "https://app.hypertask.ai/detail/project-%s/%s" % (board, index),
    }))
')"
        returned="$(printf '%s' "$tasks" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("tasks") or []))')"
        [ "$returned" -gt 0 ] || break
        page_has_new="no"

        while IFS= read -r task; do
          [ -n "$task" ] || continue
          [ "$read_count" -lt "$ceiling" ] || { hit_ceiling="yes"; break; }
          task_id="$(ROW="$task" python3 -c 'import json,os; print(json.loads(os.environ["ROW"])["id"])')"
          task_ref="$(ROW="$task" python3 -c 'import json,os; print(json.loads(os.environ["ROW"])["ref"])')"
          comments_file="${TMPDIR:-/tmp}/agent-board-comments.$$.$one.$task_id"
          : > "$comments_file"
          comments_cursor=""

          while [ "$read_count" -lt "$ceiling" ]; do
            remaining=$((ceiling - read_count))
            [ "$remaining" -le 100 ] || remaining=100
            comments="$(_ht_get "$token_file" "/mcp/comments?task_id=${task_id}&project_id=${one}&limit=${remaining}${comments_cursor:+&cursor=${comments_cursor}}" 2>/dev/null)" || break
            page_stats="$(printf '%s' "$comments" | LAST="$last_seen" OUT="$comments_file" python3 -c '
import json, os, sys
doc = json.load(sys.stdin)
last = int(os.environ["LAST"])
comments = doc.get("comments") or []
new = [c for c in comments if int(c.get("id") or 0) > last]
with open(os.environ["OUT"], "a", encoding="utf-8") as handle:
    for comment in new:
        handle.write(json.dumps(comment) + "\n")
maximum = max([int(c.get("id") or 0) for c in new] or [last])
caught = any(int(c.get("id") or 0) <= last for c in comments) or not doc.get("nextCursor")
print("%d\t%d\t%s\t%s" % (len(new), maximum, "yes" if caught else "no", doc.get("nextCursor") or ""))
')"
            IFS=$'\t' read -r page_count page_max page_caught page_cursor <<< "$page_stats"
            read_count=$((read_count + page_count))
            [ "$page_max" -le "$max_seen" ] || max_seen="$page_max"
            [ "$page_count" -eq 0 ] || page_has_new="yes"
            if [ "$page_caught" = "yes" ]; then break; fi
            comments_cursor="$page_cursor"
          done

          if [ -s "$comments_file" ]; then
            _record_valentin_comments "$comments_file" "$one" "$task_ref"
            direct="$(ROW="$task" COMMENTS="$comments_file" AID="$agent_id" ANAME="$agent_name" MENTION="agent-$agent_id" python3 -c '
import html, json, os, re
row = json.loads(os.environ["ROW"])
with open(os.environ["COMMENTS"], encoding="utf-8") as handle:
    comments = [json.loads(line) for line in handle if line.strip()]

def key(c):
    return (str(c.get("createdAt") or ""), int(c.get("id") or 0))

def actor(c):
    agent = c.get("agent") if isinstance(c.get("agent"), dict) else None
    creator = c.get("creator") if isinstance(c.get("creator"), dict) else {}
    return agent, (agent or creator).get("displayName") or ""

def body(c):
    return c.get("text") or c.get("commentText") or c.get("html") or ""

latest_own = None
addressed = []
for comment in comments:
    agent, author = actor(comment)
    own = (agent and str(agent.get("id") or "") == os.environ["AID"]) or (
        not agent and author.strip().casefold() == os.environ["ANAME"].strip().casefold())
    if own:
        if latest_own is None or key(comment) > key(latest_own):
            latest_own = comment
        continue
    if agent:
        continue
    text = body(comment)
    plain = html.unescape(re.sub(r"<[^>]+>", " ", text))
    if os.environ["MENTION"] in text or "?" in plain:
        addressed.append(comment)
if addressed:
    trigger = max(addressed, key=key)
    if latest_own is None or key(trigger) > key(latest_own):
        _, author = actor(trigger)
        creator = trigger.get("creator") if isinstance(trigger.get("creator"), dict) else {}
        row["trigger"] = "reply_only"
        row["trigger_comment"] = {
            "id": trigger.get("id"), "createdAt": trigger.get("createdAt") or "",
            "html": body(trigger), "author": author,
            "author_id": str(creator.get("id") or creator.get("userId") or ""),
            "agent_id": "",
        }
        print(json.dumps(row))
')"
            if [ -n "$direct" ]; then
              printf '%s\n' "$direct"
            else
              _ht_owned_row "$token_file" "$task_id" "$task" "$one" "$agent_id"
            fi
          fi
          rm -f "$comments_file"
          if [ "$read_count" -ge "$ceiling" ]; then hit_ceiling="yes"; break; fi
        done <<< "$rows"

        [ "$hit_ceiling" = "no" ] || break
        # Tickets are updated newest first. Once a whole page has no comment
        # newer than the board cursor, older task pages are already caught up.
        [ "$page_has_new" = "yes" ] || break
        [ "$returned" -eq 100 ] || break
        offset=$((offset + returned))
      done
      [ "$hit_ceiling" = "no" ] || break
    done

    if [ "$max_seen" -gt "$last_seen" ]; then
      printf '%s\n' "$max_seen" > "$cursor_file.new"
      mv "$cursor_file.new" "$cursor_file"
    fi
    if [ "$hit_ceiling" = "yes" ]; then
      ceiling_board="$one"
      break
    fi
  done
  if [ "$hit_ceiling" = "yes" ]; then
    warn "adapter_new_comments_on_owned: hit comment read ceiling $ceiling on board $ceiling_board; remaining comments wait for the next tick"
  fi
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

  # The repository-wide cache is the only PR listing path in a runner tick.
  # It deliberately contains open PRs and recent merges, never PR bodies.
  if [ -n "$repo" ] && command -v gh >/dev/null 2>&1; then
    pr_json="$(_ht_pr_cache_rows "$repo" 2>/dev/null || printf '[]')"
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
       (str(p.get("title") or "") + " " + str(p.get("headRefName") or "")).casefold()]
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
  local board_cli="$1" ref="$2" section="$3" attempt
  for attempt in 1 2; do
    "$board_cli" task move "$ref" --section "$section" && return 0
  done
  return 1
}

# adapter_unassign_task <board-cli> <ref> <agent-id>
adapter_unassign_task() {
  local board_cli="$1" ref="$2" agent_id="$3" attempt task
  task="$("$board_cli" --json task get "$ref" 2>/dev/null || true)"
  if ! TASK="$task" AID="$agent_id" python3 -c '
import json, os, sys
raw = os.environ["TASK"]
start, end = raw.find("{"), raw.rfind("}")
try:
    doc = json.loads(raw[start:end + 1]) if start >= 0 and end > start else {}
    task = (doc.get("tasks") or [doc.get("task") or doc])[0]
except (IndexError, TypeError, ValueError):
    raise SystemExit(1)
for who in task.get("assignees") or []:
    agent = who.get("agent") if isinstance(who, dict) else None
    if isinstance(agent, dict) and str(agent.get("id") or "") == os.environ["AID"]:
        raise SystemExit(0)
raise SystemExit(1)
'; then
    return 0
  fi
  for attempt in 1 2; do
    "$board_cli" task unassign "$ref" --assignee "$agent_id" && return 0
  done
  return 1
}

# adapter_claimed_by_other <token-file> <board> <ref> <agent-id>
# Re-read immediately before claim. Prints the first conflicting agent name;
# empty output means the ticket is still safe for this agent to start.
adapter_claimed_by_other() {
  local token_file="$1" board="$2" ref="$3" agent_id="$4" task
  task="$(_ht_get "$token_file" "/mcp/tasks?ticket_number=${ref}")" || return 1
  TASK="$task" BOARD="$board" REF="$ref" AID="$agent_id" python3 -c '
import json, os
rows = json.loads(os.environ["TASK"]).get("tasks") or []
task = next((row for row in rows
             if str(row.get("ticketNumber") or "").casefold() == os.environ["REF"].casefold()
             and str(row.get("projectId") or os.environ["BOARD"]) == os.environ["BOARD"]), None)
if task is None:
    raise SystemExit(1)
for who in task.get("assignees") or []:
    agent = who.get("agent") if isinstance(who, dict) else None
    if isinstance(agent, dict) and agent.get("id") and str(agent["id"]) != os.environ["AID"]:
        print(str(agent.get("displayName") or agent.get("name") or agent["id"]))
        break
'
}

# adapter_assign_task <board-cli> <ref> <agent-id>
adapter_assign_task() {
  local board_cli="$1" ref="$2" agent_id="$3" attempt task
  task="$($board_cli --json task get "$ref" 2>/dev/null || true)"
  if TASK="$task" AID="$agent_id" python3 -c '
import json, os, sys
raw = os.environ["TASK"]
start, end = raw.find("{"), raw.rfind("}")
try:
    doc = json.loads(raw[start:end + 1]) if start >= 0 and end > start else {}
    task = (doc.get("tasks") or [doc.get("task") or doc])[0]
except (IndexError, TypeError, ValueError):
    raise SystemExit(1)
for who in task.get("assignees") or []:
    agent = who.get("agent") if isinstance(who, dict) else None
    if isinstance(agent, dict) and str(agent.get("id") or "") == os.environ["AID"]:
        raise SystemExit(0)
raise SystemExit(1)
'; then
    return 0
  fi
  for attempt in 1 2; do
    "$board_cli" task assign "$ref" --assignee "$agent_id" && return 0
  done
  return 1
}

# adapter_claim <token-file> <board-cli> <board> <ref> <agent-id>
# Prints "held" when this agent owns the claim, or "backoff<TAB>reason" when
# another agent owns it. Errors fail closed with no result.
adapter_claim() {
  local token_file="$1" board_cli="$2" board="$3" ref="$4" agent_id="$5"
  local jitter settle task assignees other winner winner_name
  jitter="${ADAPTER_CLAIM_TEST_JITTER_SECONDS:-$((RANDOM % 5 + 1))}"
  settle="${ADAPTER_CLAIM_TEST_SETTLE_SECONDS:-2}"
  [[ "$jitter" =~ ^[0-9]+$ ]] && [[ "$settle" =~ ^[0-9]+$ ]] || return 1
  sleep "$jitter"

  task="$(_ht_get "$token_file" "/mcp/tasks?ticket_number=${ref}")" || return 1
  assignees="$(TASK="$task" BOARD="$board" REF="$ref" python3 -c '
import json, os
rows = json.loads(os.environ["TASK"]).get("tasks") or []
task = next((row for row in rows
             if str(row.get("ticketNumber") or "").casefold() == os.environ["REF"].casefold()
             and str(row.get("projectId") or os.environ["BOARD"]) == os.environ["BOARD"]), None)
if task is None:
    raise SystemExit(1)
for who in task.get("assignees") or []:
    agent = who.get("agent") if isinstance(who, dict) else None
    if isinstance(agent, dict) and agent.get("id"):
        print("%s\t%s" % (agent["id"], agent.get("displayName") or agent.get("name") or agent["id"]))
')" || return 1
  other="$(printf '%s\n' "$assignees" | awk -F '\t' -v aid="$agent_id" '$1 != "" && $1 != aid { print $2; exit }')"
  if [ -n "$other" ]; then
    printf 'backoff\talready claimed by %s' "$other"
    return 0
  fi

  adapter_assign_task "$board_cli" "$ref" "$agent_id" >/dev/null || return 1
  sleep "$settle"
  task="$(_ht_get "$token_file" "/mcp/tasks?ticket_number=${ref}")" || return 1
  assignees="$(TASK="$task" BOARD="$board" REF="$ref" python3 -c '
import json, os
rows = json.loads(os.environ["TASK"]).get("tasks") or []
task = next((row for row in rows
             if str(row.get("ticketNumber") or "").casefold() == os.environ["REF"].casefold()
             and str(row.get("projectId") or os.environ["BOARD"]) == os.environ["BOARD"]), None)
if task is None:
    raise SystemExit(1)
for who in task.get("assignees") or []:
    agent = who.get("agent") if isinstance(who, dict) else None
    if isinstance(agent, dict) and agent.get("id"):
        print("%s\t%s" % (agent["id"], agent.get("displayName") or agent.get("name") or agent["id"]))
')" || return 1
  printf '%s\n' "$assignees" | awk -F '\t' -v aid="$agent_id" '$1 == aid { found=1 } END { exit !found }' \
    || return 1
  other="$(printf '%s\n' "$assignees" | awk -F '\t' -v aid="$agent_id" '$1 != "" && $1 != aid { print $1; exit }')"
  if [ -n "$other" ]; then
    winner="$(printf '%s\n' "$assignees" | awk -F '\t' '$1 != "" { print $1 }' | LC_ALL=C sort | head -n1)"
    if [ "$winner" != "$agent_id" ]; then
      winner_name="$(printf '%s\n' "$assignees" | awk -F '\t' -v winner="$winner" '$1 == winner { print $2; exit }')"
      adapter_unassign_task "$board_cli" "$ref" "$agent_id" >/dev/null || return 1
      printf 'backoff\tlost deterministic tie-break to %s' "${winner_name:-$winner}"
      return 0
    fi
  fi
  printf 'held'
}

# adapter_current_section <board-cli> <ref>
adapter_current_section() {
  local board_cli="$1" ref="$2" task
  task="$($board_cli --json task get "$ref" 2>/dev/null)" || return 1
  printf '%s' "$task" | python3 -c '
import json, sys
raw = sys.stdin.read()
start, end = raw.find("{"), raw.rfind("}")
if start < 0 or end <= start:
    raise SystemExit(1)
doc = json.loads(raw[start:end + 1])
task = (doc.get("tasks") or [doc.get("task") or doc])[0]
print(task.get("section") or "")
'
}

_ht_pr_cache_file() {
  local repo="$1" cache_dir
  cache_dir="${AGENT_PR_CACHE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-board-poll/pr-cache}"
  printf '%s/%s.json' "$cache_dir" "${repo//\//__}"
}

_ht_github_paused() {
  local repo="$1" pause_file reset now
  pause_file="$(_ht_pr_cache_file "$repo").rate-limit"
  [ -s "$pause_file" ] || return 1
  read -r reset < "$pause_file" || return 1
  if ! [[ "$reset" =~ ^[0-9]+$ ]]; then
    rm -f "$pause_file"
    return 1
  fi
  now="$(date +%s)"
  if [ "$now" -lt "$reset" ]; then
    return 0
  fi
  rm -f "$pause_file"
  return 1
}

_ht_pause_github() {
  local repo="$1" error_file="$2" cache_file pause_file reset now tmp
  cache_file="$(_ht_pr_cache_file "$repo")"
  pause_file="$cache_file.rate-limit"
  now="$(date +%s)"
  reset="$(python3 - "$error_file" <<'PYEOF'
import re
import sys

try:
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except OSError:
    text = ""
match = re.search(r"(?:x-ratelimit-reset|reset(?:_at|At|_epoch)?)['\" :=]+([0-9]{10})", text, re.I)
print(match.group(1) if match else "")
PYEOF
)"
  if ! [[ "$reset" =~ ^[0-9]+$ ]] || [ "$reset" -le "$now" ]; then
    reset="$(command gh api rate_limit --jq '.rate.reset' 2>/dev/null || true)"
  fi
  if ! [[ "$reset" =~ ^[0-9]+$ ]] || [ "$reset" -le "$now" ]; then
    reset=$((now + 60))
  fi
  mkdir -p "$(dirname "$pause_file")"
  tmp="$(mktemp "$pause_file.XXXXXX")"
  printf '%s\n' "$reset" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$pause_file"
  printf 'github rate limited until %s\n' \
    "$(date -u -d "@$reset" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$reset")" >&2
}

_ht_gh() {
  local repo="$1" error_file rc
  shift
  _ht_github_paused "$repo" && return 75
  error_file="$(mktemp)"
  if command gh "$@" 2>"$error_file"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ] && grep -Eqi 'rate.?limit|HTTP 429|abuse detection' "$error_file"; then
    _ht_pause_github "$repo" "$error_file"
    cat "$error_file" >&2
    rm -f "$error_file"
    return 75
  fi
  cat "$error_file" >&2
  rm -f "$error_file"
  return "$rc"
}

# adapter_merged_pr_from_comments <repo>
# Reads one Hypertask comments response on stdin and prints the first linked
# pull request URL whose cached GitHub state is MERGED. A ticket link is
# authoritative; the PR does not also need the ticket reference in its title.
adapter_merged_pr_from_comments() {
  local repo="$1" numbers rows cache_rc
  [ -n "$repo" ] || return 2
  numbers="$(REPO="$repo" python3 -c '
import html, json, os, re, sys
repo = re.escape(os.environ["REPO"])
pattern = re.compile(r"https://github[.]com/" + repo + r"/pull/([0-9]+)(?![0-9])", re.I)
seen = set()
for comment in json.load(sys.stdin).get("comments") or []:
    text = html.unescape(str(comment.get("text") or comment.get("commentText") or comment.get("comment") or comment.get("html") or ""))
    for match in pattern.finditer(text):
        if match.group(1) not in seen:
            seen.add(match.group(1))
            print(match.group(1))
')" || return 2
  [ -n "$numbers" ] || return 1
  if rows="$(_ht_pr_cache_rows "$repo")"; then
    cache_rc=0
  else
    cache_rc=$?
  fi
  [ "$cache_rc" -eq 0 ] || return "$cache_rc"
  NUMBERS="$numbers" ROWS="$rows" python3 -c '
import json, os, sys
numbers = set(os.environ["NUMBERS"].splitlines())
for row in json.loads(os.environ["ROWS"] or "[]"):
    if str(row.get("number")) in numbers and str(row.get("state") or "").upper() == "MERGED":
        print(row.get("url") or "")
        raise SystemExit(0)
raise SystemExit(1)
'
}

# adapter_ticket_merged_pr <token-file> <board-id> <task-id> <repo> <ref>
adapter_ticket_merged_pr() {
  local token_file="$1" board_id="$2" task_id="$3" repo="$4" ref="$5"
  local rows url comments comment_rc direct_failed="no" cache_rc
  [ -n "$repo" ] && [ -n "$ref" ] || return 2
  if command -v gh >/dev/null 2>&1; then
    if rows="$(_ht_pr_cache_rows "$repo")"; then
      cache_rc=0
    else
      cache_rc=$?
    fi
    if [ "$cache_rc" -eq 75 ]; then
      return 75
    elif [ "$cache_rc" -ne 0 ]; then
      direct_failed="yes"
    elif ! url="$(ROWS="$rows" REF="$ref" python3 -c '
import json, os, re
pattern = re.compile(r"(?<![A-Z0-9-])" + re.escape(os.environ["REF"]) + r"(?![0-9])", re.I)
for pr in json.loads(os.environ["ROWS"] or "[]"):
    if str(pr.get("state") or "").upper() == "MERGED" and pattern.search(str(pr.get("title") or "")) and pr.get("url"):
        print(pr["url"])
        break
')"; then
      direct_failed="yes"
    elif [ -n "$url" ]; then
      printf '%s\n' "$url"
      return 0
    fi
  else
    direct_failed="yes"
  fi

  comments="$(_ht_get "$token_file" "/mcp/comments?task_id=$task_id&project_id=$board_id")" || return 2
  if url="$(printf '%s' "$comments" | adapter_merged_pr_from_comments "$repo")"; then
    printf '%s\n' "$url"
    return 0
  else
    comment_rc=$?
  fi
  [ "$direct_failed" = "no" ] || return 2
  return "$comment_rc"
}

_ht_pr_cache_rows() (
  local repo="$1" cache_file cache_dir lock_file now modified age ttl tmp rc page returned stop
  [ -n "$repo" ] && command -v gh >/dev/null 2>&1 || return 1
  cache_file="$(_ht_pr_cache_file "$repo")"
  cache_dir="$(dirname "$cache_file")"
  lock_file="$cache_file.lock"
  mkdir -p "$cache_dir"
  exec 8>>"$lock_file"
  flock 8
  now="$(date +%s)"
  ttl="${PR_CACHE_TTL_SECONDS:-60}"
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=60
  [ "$ttl" -ge 60 ] || ttl=60
  _ht_github_paused "$repo" && return 75
  if [ -s "$cache_file" ]; then
    modified="$(stat -c %Y "$cache_file" 2>/dev/null || printf 0)"
    age=$((now - modified))
    if [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ] \
       && python3 -c 'import json,sys; assert isinstance(json.load(open(sys.argv[1])).get("prs"), list)' "$cache_file" 2>/dev/null; then
      python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["prs"]))' "$cache_file"
      return 0
    fi
  fi

  tmp="$(mktemp -d "$cache_dir/.refresh.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  : > "$tmp/open.pages"
  page=1
  while :; do
    if _ht_gh "$repo" api "repos/$repo/pulls?state=open&per_page=100&page=$page" > "$tmp/page.json"; then
      rc=0
    else
      rc=$?
    fi
    [ "$rc" -eq 0 ] || { [ "$rc" -eq 75 ] && return 75; printf 'ERROR: cannot refresh pull request cache for %s\n' "$repo" >&2; return 1; }
    cat "$tmp/page.json" >> "$tmp/open.pages"
    printf '\n' >> "$tmp/open.pages"
    returned="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$tmp/page.json")" || return 1
    [ "$returned" -eq 100 ] || break
    page=$((page + 1))
  done

  : > "$tmp/closed.pages"
  page=1
  while :; do
    if _ht_gh "$repo" api "repos/$repo/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=$page" > "$tmp/page.json"; then
      rc=0
    else
      rc=$?
    fi
    [ "$rc" -eq 0 ] || { [ "$rc" -eq 75 ] && return 75; printf 'ERROR: cannot refresh pull request cache for %s\n' "$repo" >&2; return 1; }
    cat "$tmp/page.json" >> "$tmp/closed.pages"
    printf '\n' >> "$tmp/closed.pages"
    stop="$(NOW="${PR_GATE_NOW:-}" python3 - "$tmp/page.json" <<'PYEOF'
import datetime
import json
import os
import sys

rows = json.load(open(sys.argv[1], encoding="utf-8"))
try:
    now = datetime.datetime.fromisoformat(os.environ.get("NOW", "").replace("Z", "+00:00"))
except ValueError:
    now = datetime.datetime.now(datetime.timezone.utc)
if now.tzinfo is None:
    now = now.replace(tzinfo=datetime.timezone.utc)
cutoff = now - datetime.timedelta(hours=48)
value = str((rows[-1] if rows else {}).get("updated_at") or "")
try:
    oldest = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if oldest.tzinfo is None:
        oldest = oldest.replace(tzinfo=datetime.timezone.utc)
except ValueError:
    oldest = None
print("yes" if len(rows) < 100 or (oldest is not None and oldest < cutoff) else "no")
PYEOF
)"
    [ "$stop" = "no" ] || break
    page=$((page + 1))
  done

  REPO="$repo" NOW="${PR_GATE_NOW:-}" FETCHED_AT="$now" python3 - \
    "$tmp/open.pages" "$tmp/closed.pages" "$cache_file.new" <<'PYEOF'
import datetime
import json
import os
import sys

open_path, closed_path, output_path = sys.argv[1:]
now_text = os.environ.get("NOW") or ""
try:
    now = datetime.datetime.fromisoformat(now_text.replace("Z", "+00:00"))
except ValueError:
    now = datetime.datetime.now(datetime.timezone.utc)
if now.tzinfo is None:
    now = now.replace(tzinfo=datetime.timezone.utc)
cutoff = now - datetime.timedelta(hours=48)

def pages(path):
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                yield from json.loads(line)

def parsed(value):
    try:
        result = datetime.datetime.fromisoformat(str(value or "").replace("Z", "+00:00"))
        return result.replace(tzinfo=result.tzinfo or datetime.timezone.utc)
    except ValueError:
        return None

def normalize(row, state):
    number = row.get("number")
    head = row.get("head") if isinstance(row.get("head"), dict) else {}
    base = row.get("base") if isinstance(row.get("base"), dict) else {}
    user = row.get("user") if isinstance(row.get("user"), dict) else {}
    branch = head.get("ref") or ""
    login = user.get("login") or ""
    return {
        "number": number,
        "state": state,
        "url": row.get("html_url") or "https://github.com/%s/pull/%s" % (os.environ["REPO"], number),
        "title": row.get("title") or "",
        "branch": branch,
        "headRefName": branch,
        "baseRefName": base.get("ref") or "",
        "author": {"login": login},
        "draft": bool(row.get("draft")),
        "createdAt": row.get("created_at") or row.get("updated_at") or "",
        "updatedAt": row.get("updated_at") or "",
        "mergedAt": row.get("merged_at") if state == "MERGED" else None,
    }

rows = [normalize(row, "OPEN") for row in pages(open_path)]
for row in pages(closed_path):
    merged = parsed(row.get("merged_at"))
    if merged is not None and merged >= cutoff:
        rows.append(normalize(row, "MERGED"))
seen = set()
rows = [row for row in rows if row["number"] is not None and not (row["number"] in seen or seen.add(row["number"]))]
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump({"fetched_at": int(os.environ["FETCHED_AT"]), "repo": os.environ["REPO"], "prs": rows}, handle)
    handle.write("\n")
PYEOF
  chmod 600 "$cache_file.new"
  mv "$cache_file.new" "$cache_file"
  python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["prs"]))' "$cache_file"
)

_ht_distinct_agent_login() {
  local configured="${GH_LOGIN:-}" host_login
  [ -n "$configured" ] || return 0
  host_login="$(_ht_gh "${PR_REPO:-}" api user --jq .login 2>/dev/null || true)"
  [ -n "$host_login" ] && [ "${configured,,}" != "${host_login,,}" ] || return 0
  printf '%s' "$configured"
}

# adapter_agent_has_open_pr <repo> <ref> <ignored-legacy-prefix> <opened-prs>
adapter_agent_has_open_pr() {
  local repo="$1" ref="$2" opened_prs="$4" rows login cache_rc
  [ -n "$repo" ] && command -v gh >/dev/null 2>&1 || return 2
  if rows="$(_ht_pr_cache_rows "$repo")"; then
    cache_rc=0
  else
    cache_rc=$?
  fi
  [ "$cache_rc" -eq 0 ] || { [ "$cache_rc" -eq 75 ] && return 75; return 2; }
  login="$(_ht_distinct_agent_login)"
  _ht_github_paused "$repo" && return 75
  ROWS="$rows" REF="$ref" SLUG="${AGENT_SLUG:-}" LOGIN="$login" \
    KIND="${AGENT_KIND:-${AGENT_ROLE:-${ROLE:-}}}" REPO="$repo" OPENED="$opened_prs" python3 -c '
import json, os, sys
ref = os.environ["REF"].casefold()
slug = os.environ["SLUG"].casefold()
login = os.environ["LOGIN"].casefold()
qa = os.environ["KIND"].casefold() == "qa"
prefixes = [slug + "/"] if slug else []
if slug == "dev-2":
    prefixes.extend(("dev-cursor-2/", "cursor-dev-2/"))
owned = set()
try:
    with open(os.environ["OPENED"], encoding="utf-8") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) >= 2 and fields[0] == os.environ["REPO"]:
                owned.add(fields[1])
except OSError:
    pass
for pr in json.loads(os.environ["ROWS"] or "[]"):
    if str(pr.get("state") or "").upper() != "OPEN":
        continue
    haystack = " ".join(str(pr.get(key) or "") for key in ("title", "headRefName")).casefold()
    if ref not in haystack:
        continue
    number = str(pr.get("number"))
    if number in owned:
        raise SystemExit(0)
    if qa:
        continue
    branch = str(pr.get("headRefName") or "").casefold()
    author = pr.get("author") or {}
    author_login = str(author.get("login") or "").casefold() if isinstance(author, dict) else ""
    if any(branch.startswith(prefix) for prefix in prefixes) or (login and author_login == login):
        raise SystemExit(0)
raise SystemExit(1)
'
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
# adapter_pr_gate <token-file> <board-ids> <agent-id> <agent-name> <slug> <cache-dir> <config-dir> <opened-prs>
# Prints one JSON object per pull request still owned by this agent, open PRs
# before merged PRs awaiting QA. Ownership comes only from the <slug>/ branch
# prefix (plus dev-2's two historical aliases), the opened-PR ledger, or an
# explicitly configured GH_LOGIN that differs from the host gh identity.
#
# An open PR with no owner among the living conf files is ignored and logged
# once per UTC day through stderr, which core appends to the tick log.
#
# LIVE is merged + the base contains the merge commit + the newest Production
# deployment created after the merge succeeded and contains that commit. Repos
# with no deployment records use merged + contained as the documented fallback.
adapter_pr_gate() (
  local token_file="$1" board_ids="$2" agent_id="$3" agent_name="$4" slug="$5" cache_dir="$6"
  local config_dir="${7:-}" opened_prs="${8:-}" repo="${PR_REPO:-}"
  local state_dir released_prs tmp pr number live branch marker today owner_conf owner_slug one board_json pr_state
  local offset path returned github_login host_login cache_rc agent_role rc

  [ -n "$repo" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  mkdir -p "$cache_dir"
  state_dir="$(dirname "${opened_prs:-$cache_dir/none}")"
  released_prs="$state_dir/$slug.released-prs"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  if pr="$(_ht_pr_cache_rows "$repo")"; then
    cache_rc=0
  else
    cache_rc=$?
  fi
  [ "$cache_rc" -eq 0 ] || return "$cache_rc"
  _ht_github_paused "$repo" && return 75
  printf '%s\n' "$pr" > "$tmp/prs.json"
  python3 - "$tmp/prs.json" <<'PYEOF' > "$tmp/open.json"
import json, sys
print(json.dumps([row for row in json.load(open(sys.argv[1]))
                  if str(row.get("state") or "").upper() == "OPEN"]))
PYEOF
  if python3 - "$tmp/prs.json" <<'PYEOF'
import json, sys
raise SystemExit(0 if not json.load(open(sys.argv[1], encoding="utf-8")) else 1)
PYEOF
  then
    return 0
  fi

  # Author ownership is opt-in and valid only when the configured login differs
  # from the shared host identity. An absent or unverifiable host login disables it.
  host_login=""
  if [ -n "${GH_LOGIN:-}" ] \
     || { [ -n "$config_dir" ] && grep -qE '^GH_LOGIN=' "$config_dir"/*.conf 2>/dev/null; }; then
    host_login="$(_ht_gh "$repo" api user --jq .login 2>/dev/null || true)"
    _ht_github_paused "$repo" && return 75
  fi
  github_login=""
  if [ -n "${GH_LOGIN:-}" ] && [ -n "$host_login" ] \
     && [ "${GH_LOGIN,,}" != "${host_login,,}" ]; then
    github_login="$GH_LOGIN"
  fi
  agent_role="${AGENT_KIND:-${AGENT_ROLE:-${ROLE:-}}}"
  printf '%s\t%s\t%s\t%s\t%s\n' "$slug" "$agent_id" "$opened_prs" "$github_login" "$agent_role" > "$tmp/owners.tsv"
  if [ -n "$config_dir" ] && [ -d "$config_dir" ]; then
    for owner_conf in "$config_dir"/*.conf; do
      [ -f "$owner_conf" ] || continue
      if ! grep -qE '^BOARD_ADAPTER=' "$owner_conf"; then
        printf 'skipping legacy agent conf %s: no BOARD_ADAPTER schema marker\n' \
          "$(basename "$owner_conf")" >&2
        continue
      fi
      (
        unset AGENT_SLUG AGENT_ID AGENT_KIND AGENT_ROLE ROLE PR_REPO GH_LOGIN GITHUB_LOGIN
        # shellcheck disable=SC1090
        . "$owner_conf"
        [ "${PR_REPO:-}" = "$repo" ] || exit 0
        owner_slug="${AGENT_SLUG:-$(basename "$owner_conf" .conf)}"
        github_login=""
        if [ -n "${GH_LOGIN:-}" ] && [ -n "$host_login" ] \
           && [ "${GH_LOGIN,,}" != "${host_login,,}" ]; then
          github_login="$GH_LOGIN"
        fi
        agent_role="${AGENT_KIND:-${AGENT_ROLE:-${ROLE:-}}}"
        printf '%s\t%s\t%s\t%s\t%s\n' "$owner_slug" "${AGENT_ID:-}" \
          "$state_dir/$owner_slug.opened-prs" "$github_login" "$agent_role"
      ) >> "$tmp/owners.tsv"
    done
  fi

  : > "$tmp/tasks.jsonl"
  for one in $(printf '%s' "$board_ids" | tr ',' ' '); do
    [ -n "$one" ] || continue
    offset=0
    while :; do
      path="/mcp/tasks?project_id=${one}&limit=100"
      [ "$offset" -eq 0 ] || path="$path&offset=$offset"
      if ! board_json="$(_ht_get "$token_file" "$path")"; then
        printf 'ERROR: cannot list board %s assignments for the one-ticket-until-live gate\n' "$one" >&2
        return 1
      fi
      printf '%s\n' "$board_json" >> "$tmp/tasks.jsonl"
      returned="$(printf '%s' "$board_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("tasks") or []))')"
      [ "$returned" -eq 100 ] || break
      offset=$((offset + returned))
    done
  done

  SLUG="$slug" REPO="$repo" OPENED_PRS="$opened_prs" RELEASED_PRS="$released_prs" BOARDS="$board_ids" \
    python3 - "$tmp/prs.json" "$tmp/owners.tsv" "$tmp/tasks.jsonl" <<'PYEOF' > "$tmp/candidates.jsonl"
import json, os, re, sys
prs_path, owners_path, tasks_path = sys.argv[1:]
slug = os.environ["SLUG"].casefold()
repo = os.environ["REPO"]
owners = []
with open(owners_path, encoding="utf-8") as handle:
    for line in handle:
        owner_slug, owner_id, state_path, login, role = line.rstrip("\n").split("\t", 4)
        row = (owner_slug.casefold(), owner_id, state_path, login.casefold(), role.casefold())
        if row not in owners:
            owners.append(row)
tasks = {}
with open(tasks_path, encoding="utf-8") as handle:
    for line in handle:
        for task in (json.loads(line).get("tasks") or []):
            tasks[str(task.get("ticketNumber") or "").upper()] = task
opened = set()
try:
    with open(os.environ.get("OPENED_PRS") or "", encoding="utf-8") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) >= 2 and fields[0] == repo:
                opened.add(fields[1])
except OSError:
    pass
released, released_tickets = set(), set()
try:
    with open(os.environ.get("RELEASED_PRS") or "", encoding="utf-8") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) >= 2 and fields[0] == repo:
                released.add(fields[1])
                if len(fields) >= 3 and fields[2]:
                    released_tickets.add(fields[2].upper())
except OSError:
    pass
ticket_pattern = re.compile(r"(?<![0-9A-Za-z])([A-Z][A-Z0-9]{1,10}-[0-9]+)(?![0-9A-Za-z])", re.I)
def title_ticket(pr):
    match = ticket_pattern.search(str(pr.get("title") or ""))
    return match.group(1).upper() if match else ""
def display_ticket(pr):
    ref = title_ticket(pr)
    if ref:
        return ref
    match = ticket_pattern.search(str(pr.get("headRefName") or ""))
    return match.group(1).upper() if match else "PR-%s" % pr["number"]
def owned_prefixes(owner_slug):
    values = [owner_slug + "/"] if owner_slug else []
    if owner_slug == "dev-2":
        values.extend(("dev-cursor-2/", "cursor-dev-2/"))
    return tuple(values)
with open(prs_path, encoding="utf-8") as handle:
    prs = json.load(handle)
current = next((owner for owner in owners if owner[0] == slug and owner[4]),
               next((owner for owner in owners if owner[0] == slug), (slug, "", "", "", "")))
for pr in sorted(prs, key=lambda row: (str(row.get("state") or "").upper() != "OPEN", row.get("createdAt") or "")):
    state = str(pr.get("state") or "").upper()
    number = str(pr.get("number"))
    if state not in ("OPEN", "MERGED") or number in released:
        continue
    branch = str(pr.get("headRefName") or "").casefold()
    ref = title_ticket(pr)
    if ref in released_tickets or (state == "MERGED" and ref not in tasks):
        continue
    author = pr.get("author") or {}
    author_login = str(author.get("login") or "").casefold() if isinstance(author, dict) else ""
    by_state = number in opened
    by_prefix = current[4] != "qa" and any(branch.startswith(value) for value in owned_prefixes(current[0]))
    by_author = current[4] != "qa" and bool(current[3] and author_login == current[3])
    if not (by_state or by_prefix or by_author):
        continue
    pr["ticket"] = display_ticket(pr)
    task = tasks.get(ref, {})
    pr["task_id"] = task.get("id") or ""
    pr["board"] = str(task.get("projectId") or os.environ["BOARDS"].split(",", 1)[0])
    pr["ticket_section"] = str(task.get("section") or "")
    pr["labels"] = [str((item.get("name") or item.get("title") or item.get("label") or "")
                        if isinstance(item, dict) else item).strip().casefold()
                    for item in task.get("labels") or []]
    pr["human_assignee_ids"] = [str(item.get("id") or item.get("userId"))
                                for item in task.get("assignees") or []
                                if isinstance(item, dict) and not isinstance(item.get("agent"), dict)
                                and (item.get("id") is not None or item.get("userId") is not None)]
    print(json.dumps(pr))
PYEOF

  # Orphans never become candidates. Branch, explicit login, and per-agent
  # opened-PR state are checked across all active confs before a warning.
  today="$(date -u +%F)"
  REPO="$repo" python3 - "$tmp/open.json" "$tmp/owners.tsv" <<'PYEOF' > "$tmp/orphans.tsv"
import json, os, sys
open_path, owners_path = sys.argv[1:]
repo = os.environ["REPO"]
owners = []
with open(owners_path, encoding="utf-8") as handle:
    for line in handle:
        slug, agent_id, state_path, login, role = line.rstrip("\n").split("\t", 4)
        row = (slug.casefold(), state_path, login.casefold(), role.casefold())
        if row not in owners:
            owners.append(row)
opened = set()
for _, path, _, _ in owners:
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                fields = line.rstrip("\n").split("\t")
                if len(fields) >= 2 and fields[0] == repo:
                    opened.add(fields[1])
    except OSError:
        pass
def prefixes(slug):
    values = [slug + "/"] if slug else []
    if slug == "dev-2":
        values.extend(("dev-cursor-2/", "cursor-dev-2/"))
    return tuple(values)
for pr in json.load(open(open_path)):
    branch = str(pr.get("headRefName") or "")
    folded = branch.casefold()
    number = str(pr.get("number"))
    author = pr.get("author") or {}
    author_login = str(author.get("login") or "").casefold() if isinstance(author, dict) else ""
    prefix_owner = any(role != "qa" and any(folded.startswith(value) for value in prefixes(slug))
                       for slug, _, _, role in owners)
    author_owner = any(role != "qa" and login and author_login == login
                       for _, _, login, role in owners)
    if prefix_owner or number in opened or author_owner:
        continue
    print("%s\t%s" % (number, branch))
PYEOF
  while IFS=$'\t' read -r number branch; do
    [ -n "$number" ] || continue
    marker="$cache_dir/orphaned-${repo//\//-}-$number-$today"
    if mkdir "$marker" 2>/dev/null; then
      printf 'orphaned PR #%s (%s) has no owning agent\n' "$number" "$branch" >&2
    fi
  done < "$tmp/orphans.tsv"

  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    number="$(ROW="$pr" python3 -c 'import json,os;print(json.loads(os.environ["ROW"])["number"])')"
    if live="$(_ht_pr_live_state "$repo" "$number" "$cache_dir")"; then
      rc=0
    else
      rc=$?
    fi
    [ "$rc" -eq 0 ] || { _ht_github_paused "$repo" && return 75; return 1; }
    pr_state="$(ROW="$pr" python3 -c 'import json,os;print(str(json.loads(os.environ["ROW"]).get("state") or "").upper())')"
    if [ "$pr_state" = "MERGED" ]; then
      _ht_pr_qa_state "$token_file" "$pr" "$live" "${DONE_SECTION:-Done}" || return 1
    elif ! _ht_pr_work_state "$repo" "$pr" "$live"; then
      _ht_github_paused "$repo" && return 75
      return 1
    fi
  done < "$tmp/candidates.jsonl"
)

# A merged PR remains this agent's work until QA passes and the reconciler moves
# its ticket to Done. A new QA Handoff is a red round on the same PR counter.
_ht_pr_qa_state() {
  local token_file="$1" pr="$2" live="$3" done_section="$4" task_id board comments="[]"
  task_id="$(ROW="$pr" python3 -c 'import json,os;print(json.loads(os.environ["ROW"]).get("task_id") or "")')"
  board="$(ROW="$pr" python3 -c 'import json,os;print(json.loads(os.environ["ROW"]).get("board") or "")')"
  if ROW="$pr" DONE="$done_section" python3 -c 'import json,os,sys; row=json.loads(os.environ["ROW"]); sys.exit(0 if str(row.get("ticket_section") or "").casefold() == os.environ["DONE"].casefold() else 1)'; then
    return 0
  fi
  if [ -n "$task_id" ] && [ -n "$board" ]; then
    comments="$(_ht_get "$token_file" "/mcp/comments?task_id=${task_id}&project_id=${board}" 2>/dev/null || printf '{"comments":[]}')"
  fi
  PR="$pr" LIVE="$live" COMMENTS="$comments" python3 -c '
import html, json, os, re
pr, live = json.loads(os.environ["PR"]), json.loads(os.environ["LIVE"])
comments = json.loads(os.environ["COMMENTS"]).get("comments") or []
merged_at = str(pr.get("mergedAt") or "")
def plain(row):
    value = row.get("text") or row.get("commentText") or row.get("html") or ""
    return " ".join(html.unescape(re.sub(r"<[^>]+>", " ", str(value))).split())
def agent_comment(row):
    return bool(row.get("agent") or row.get("agentId") or row.get("agent_id"))
failures = [row for row in comments
            if agent_comment(row) and str(row.get("createdAt") or "") > merged_at
            and re.match(r"Handoff:", plain(row), re.I)]
latest = max(failures, key=lambda row: (row.get("createdAt") or "", str(row.get("id") or ""))) if failures else {}
message = plain(latest) if latest else ""
qa_failed = bool(latest)
state = "red" if qa_failed else "in-qa"
checks = ["QA fail"] if qa_failed else []
print(json.dumps({"action":"fix" if qa_failed else "wait", "state":state,
                  "wait_reason":("red: QA fail" if qa_failed else "in-qa"),
                  "definition":live.get("definition") or "merged and awaiting QA",
                  "number":pr["number"], "url":pr["url"], "ticket":pr["ticket"],
                  "title":pr["title"], "branch":pr["headRefName"],
                  "base":pr.get("baseRefName") or "main", "since":pr.get("mergedAt") or pr["createdAt"],
                  "merged_at":pr.get("mergedAt"), "task_id":pr.get("task_id") or "",
                  "board":pr.get("board") or "", "ticket_section":pr.get("ticket_section") or "",
                  "labels":pr.get("labels") or [], "human_assignee_ids":pr.get("human_assignee_ids") or [],
                  "feedback":("QA failure comment:\n" + message if qa_failed else ""),
                  "failed_checks":checks, "first_error_line":message if qa_failed else "",
                  "qa_failure_id":str(latest.get("id") or "") if qa_failed else "",
                  "pickup_slot":True, "unfixable":False}))
'
}

# _ht_pr_live_state <repo> <number> <cache-dir>: one JSON answer, cached 60s.
_ht_pr_live_state() {
  local repo="$1" number="$2" cache_dir="$3" cache
  local now mtime view state base merge merged_at compare deployments deployment dep_id dep_sha dep_at statuses dep_state deploy_contains base_contains_deploy marker
  mkdir -p "$cache_dir"
  cache="$cache_dir/$number.json"
  now="$(date +%s)"
  if [ -f "$cache" ]; then
    mtime="$(stat -c %Y "$cache" 2>/dev/null || printf 0)"
    if [ "$((now - mtime))" -lt 60 ]; then cat "$cache"; return 0; fi
  fi
  view="$(_ht_gh "$repo" pr view "$number" --repo "$repo" --json state,baseRefName,mergedAt,mergeCommit 2>/dev/null)" || return $?
  state="$(printf '%s' "$view" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("state") or "")')"
  if [ "$state" != "MERGED" ]; then
    printf '{"live":false,"state":"open","definition":"GitHub Production deployments"}\n' | tee "$cache"
    return 0
  fi
  base="$(printf '%s' "$view" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("baseRefName") or "")')"
  merge="$(printf '%s' "$view" | python3 -c 'import json,sys;d=json.load(sys.stdin);print((d.get("mergeCommit") or {}).get("oid") or "")')"
  merged_at="$(printf '%s' "$view" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("mergedAt") or "")')"
  [ -n "$base" ] && [ -n "$merge" ] && [ -n "$merged_at" ] || return 1
  compare="$(_ht_gh "$repo" api "repos/$repo/compare/$merge...$base" 2>/dev/null)" || return 1
  if ! printf '%s' "$compare" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if d.get("status") in ("ahead","identical") else 1)'; then
    # The merge commit can never become an ancestor of base again once base's
    # history has been rewritten (force-push/reset past the merge), so nothing
    # the agent does can clear this by waiting. Treat it as done rather than a
    # permanent gate, and log once a day so the rewrite stays visible.
    marker="$cache_dir/base-rewritten-${repo//\//-}-$number-$(date -u +%F)"
    if mkdir "$marker" 2>/dev/null; then
      printf 'PR #%s merge commit %s is not contained in base %s (base history was rewritten); treating as superseded so it never blocks pickup\n' \
        "$number" "$merge" "$base" >&2
    fi
    printf '{"live":true,"state":"superseded","definition":"merge commit not contained in base (base history rewritten); can never become live, so treated as non-blocking"}\n' | tee "$cache"
    return 0
  fi

  deployments="$(_ht_gh "$repo" api "repos/$repo/deployments?per_page=100" 2>/dev/null)" || return 1
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
  statuses="$(_ht_gh "$repo" api "repos/$repo/deployments/$dep_id/statuses?per_page=1" 2>/dev/null)" || return 1
  dep_state="$(printf '%s' "$statuses" | python3 -c 'import json,sys;d=json.load(sys.stdin);print((d[0] if d else {}).get("state") or "")')"
  deploy_contains="no"
  base_contains_deploy="no"
  if [ -n "$dep_sha" ]; then
    compare="$(_ht_gh "$repo" api "repos/$repo/compare/$merge...$dep_sha" 2>/dev/null)" || return 1
    if printf '%s' "$compare" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if d.get("status") in ("ahead","identical") else 1)'; then
      deploy_contains="yes"
    fi
    compare="$(_ht_gh "$repo" api "repos/$repo/compare/$dep_sha...$base" 2>/dev/null)" || return 1
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
  local repo="$1" pr="$2" live="$3" number view checks reviews inline feedback action wait_state head run_rows check_name run_id logs first_error rc run_log
  number="$(ROW="$pr" python3 -c 'import json,os;print(json.loads(os.environ["ROW"])["number"])')"
  view="$(_ht_gh "$repo" pr view "$number" --repo "$repo" --json state,url,title,body,headRefName,headRefOid,baseRefName,createdAt,statusCheckRollup,reviews,comments 2>/dev/null)" || return $?
  state="$(printf '%s' "$view" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("state") or "")')"
  if [ "$state" = "MERGED" ]; then
    PR="$pr" LIVE="$live" python3 -c '
import json, os
pr, live = json.loads(os.environ["PR"]), json.loads(os.environ["LIVE"])
print(json.dumps({"action":"wait", "state":live["state"], "definition":live["definition"],
                  "number":pr["number"], "url":pr["url"], "ticket":pr["ticket"],
                  "title":pr["title"], "branch":pr["headRefName"], "since":pr["createdAt"],
                  "merged_at":pr.get("mergedAt"), "pickup_slot":False, "unfixable":False}))
'
    return 0
  fi
  if inline="$(_ht_gh "$repo" api "repos/$repo/pulls/$number/comments?per_page=100" 2>/dev/null)"; then
    rc=0
  else
    rc=$?
    [ "$rc" -ne 75 ] || return 75
    inline='[]'
  fi
  feedback="$(VIEW="$view" INLINE="$inline" python3 -c '
import json, os
view, inline = json.loads(os.environ["VIEW"]), json.loads(os.environ["INLINE"])
failed, pending, review = [], [], []
for check in view.get("statusCheckRollup") or []:
    name = check.get("name") or check.get("context") or "unnamed check"
    ctx_state = str(check.get("state") or "").upper()
    status = str(check.get("status") or "").upper()
    conclusion = str(check.get("conclusion") or "").upper()
    if ctx_state:
        if ctx_state == "PENDING":
            pending.append(name)
        elif ctx_state != "SUCCESS":
            failed.append({"name": name, "conclusion": ctx_state, "url": check.get("targetUrl") or ""})
    elif status != "COMPLETED" or not conclusion:
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
  run_rows="$(printf '%s' "$feedback" | python3 -c '
import json, re, sys
seen = set()
for check in json.load(sys.stdin)["failed"]:
    match = re.search(r"/actions/runs/([0-9]+)", check.get("url") or "")
    if match and (check["name"], match.group(1)) not in seen:
        seen.add((check["name"], match.group(1)))
        print("%s\t%s" % (check["name"], match.group(1)))
')"
  logs=""
  while IFS=$'\t' read -r check_name run_id; do
    [ -n "$run_id" ] || continue
    if run_log="$(_ht_gh "$repo" run view "$run_id" --repo "$repo" --log-failed 2>&1)"; then
      rc=0
    else
      rc=$?
      [ "$rc" -ne 75 ] || return 75
    fi
    logs="${logs}${logs:+$'\n\n'}[$check_name, last 80 failed-log lines]"$'\n'"$(printf '%s\n' "$run_log" | tail -n 80)"
  done <<< "$run_rows"
  first_error="$(LOGS="$logs" python3 -c '
import os, re
lines = [line.strip() for line in os.environ["LOGS"].splitlines() if line.strip() and not line.startswith("[")]
match = next((line for line in lines if re.search(r"(?:^|\b)(?:error|failed?|fatal|exception)(?:\b|:)", line, re.I)), None)
print((match or (lines[0] if lines else "no error line reported"))[:500])
')"
  action="$(printf '%s' "$feedback" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("fix" if d["failed"] or d["review"] else "wait")')"
  wait_state="$(printf '%s' "$feedback" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("pending" if d["pending"] else "awaiting-review")')"
  PR="$pr" VIEW="$view" LIVE="$live" FEEDBACK="$feedback" LOGS="$logs" FIRST_ERROR="$first_error" ACTION="$action" WAIT_STATE="$wait_state" python3 -c '
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
action = os.environ["ACTION"]
state = "red" if action == "fix" else os.environ["WAIT_STATE"]
failed_names = [check["name"] for check in feedback["failed"]]
wait_reason = "red: " + ", ".join(failed_names) if state == "red" else state
print(json.dumps({"action":action, "state":state, "wait_reason":wait_reason,
                  "definition":live["definition"], "number":pr["number"], "url":pr["url"],
                  "ticket":pr["ticket"], "title":view.get("title") or pr["title"],
                  "branch":view.get("headRefName") or pr["headRefName"],
                  "base":view.get("baseRefName") or "main", "head":view.get("headRefOid") or "",
                  "since":pr["createdAt"], "task_id":pr.get("task_id") or "",
                  "board":pr.get("board") or "", "ticket_section":pr.get("ticket_section") or "",
                  "labels":pr.get("labels") or [], "human_assignee_ids":pr.get("human_assignee_ids") or [],
                  "feedback":"\n\n".join(parts), "pending":feedback["pending"],
                  "failed_checks":failed_names, "first_error_line":os.environ["FIRST_ERROR"],
                  "pickup_slot":True, "unfixable":False}))
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
  local comments pr_json="" repo="${PR_REPO:-}" pr_known="no" linked_merged_pr="" linked_rc

  comments="$(_ht_get "$token_file" "/mcp/comments?task_id=${task_id}&project_id=${board_id}")"
  if linked_merged_pr="$(printf '%s' "$comments" | adapter_merged_pr_from_comments "$repo")"; then
    :
  else
    linked_rc=$?
    if [ "$linked_rc" -eq 2 ]; then
      printf 'ERROR: could not check a linked pull request for %s in %s\n' "$ref" "$repo" >&2
    fi
  fi

  # Every rank in this tick reads the same repository cache. A rate-limit pause
  # makes PR state unknown without blocking unrelated board work.
  if command -v gh >/dev/null 2>&1; then
    if pr_json="$(_ht_pr_cache_rows "$repo" 2>/dev/null)"; then
      pr_known="yes"
    else
      pr_json=""
    fi
  else
    printf 'ERROR: PR_REPO=%s is set but gh is not on PATH, so %s cannot learn its pull request state\n' \
      "$repo" "$ref" >&2
  fi

  printf '%s' "$comments" | \
  AGENT_ID="$agent_id" AGENT_NAME="$agent_name" REF="$ref" SECTION="$section" \
  REASON="$reason" PR_JSON="${pr_json:-[]}" HAVE_PR_VIEW="$pr_known" \
  LINKED_MERGED_PR="$linked_merged_pr" python3 -c '
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

done = section in {"done", "archive", "archived", "shipped"}
reply_only = "reply_only" in reason.split("+")

prs = json.loads(os.environ["PR_JSON"]) or []
# Keep only cached pull requests that name this ticket in the branch or title.
prs = [p for p in prs if ref.casefold() in
       (str(p.get("title") or "") + " " + str(p.get("headRefName") or "")).casefold()]
merged = bool(os.environ["LINKED_MERGED_PR"]) or any(
    str(p.get("state") or "").upper() == "MERGED" for p in prs)
open_pr = [p for p in prs if str(p.get("state") or "").upper() == "OPEN"]
pr_known = os.environ["HAVE_PR_VIEW"] == "yes"

if reply_only and done:
    print("-3 %s has a human direct mention or question, so it is a reply-only candidate in %s"
          % (ref, section))
elif done:
    print("0 %s is %s, nothing left to do" % (ref, section))
elif merged:
    print("0 %s has a merged pull request, so it cannot start another run" % ref)
elif reply_only:
    print("-3 %s has a human direct mention or question, so it is a reply-only candidate in %s"
          % (ref, section))
elif qa_fail and worked:
    print("2 %s was sent back by QA on work this agent did, so it comes before any new ticket" % ref)
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

# adapter_open_pr_numbers <ticket-ref>: exact open PR matches, one number per
# line. Core compares this before and after a run so a newly opened PR remains
# attributable even when its branch predates the agent prefix convention.
adapter_open_pr_numbers() {
  local ref="$1" rows
  [ -n "${PR_REPO:-}" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  rows="$(_ht_pr_cache_rows "$PR_REPO" 2>/dev/null || printf '[]')"
  REF="$ref" ROWS="$rows" python3 -c '
import json, os, re
ref = os.environ["REF"]
pattern = re.compile(r"(?<![0-9A-Za-z])" + re.escape(ref) + r"(?![0-9A-Za-z])", re.I)
for row in json.loads(os.environ["ROWS"] or "[]"):
    if str(row.get("state") or "").upper() == "OPEN" and pattern.search(
            "%s %s" % (row.get("title") or "", row.get("headRefName") or "")):
        print(row["number"])
'
}

# adapter_posted_pr_numbers <token-file> <task-id> <board-id> <repo> <ids>
# A PR opened during this tick cannot trigger a second cache refresh. Its ticket
# link is enough to attribute it until the next minute's cache includes it.
adapter_posted_pr_numbers() {
  local token_file="$1" task_id="$2" board_id="$3" repo="$4" ids="$5" comments
  [ -n "$repo" ] && [ -n "$ids" ] || return 0
  comments="$(adapter_ticket_comments "$token_file" "$task_id" "$board_id")" || return 0
  COMMENTS="$comments" IDS="$ids" REPO="$repo" python3 -c '
import html, json, os, re
ids = set(os.environ["IDS"].split())
pattern = re.compile(r"https://github[.]com/" + re.escape(os.environ["REPO"]) + r"/pull/([0-9]+)(?![0-9])", re.I)
seen = set()
for row in json.loads(os.environ["COMMENTS"] or "[]"):
    if str(row.get("id") or "") not in ids:
        continue
    for number in pattern.findall(html.unescape(str(row.get("html") or ""))):
        if number not in seen:
            seen.add(number)
            print(number)
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
  local ref="$1" rows
  [ -n "${PR_REPO:-}" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  rows="$(_ht_pr_cache_rows "$PR_REPO" 2>/dev/null || printf '[]')"
  REF="$ref" ROWS="$rows" python3 -c '
import json, os, re
ref = os.environ["REF"].casefold()
pattern = re.compile(r"(?<![0-9a-z])" + re.escape(ref) + r"(?![0-9a-z])")
for row in json.loads(os.environ["ROWS"] or "[]"):
    if str(row.get("state") or "").upper() != "OPEN":
        continue
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
  if [ ! -e "$dir" ]; then
    git -C "$source" worktree prune >/dev/null 2>&1 || true
    return 0
  fi
  if [ -d "$dir" ]; then
    if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ] \
       || [ -n "$(git -C "$dir" log --oneline HEAD --not --remotes 2>/dev/null | head -1)" ]; then
      printf 'kept worktree %s: unpushed commits\n' "$dir" >&2
      return 1
    fi
  fi
  if ! git -C "$source" worktree remove --force "$dir" >/dev/null 2>&1; then
    printf 'kept worktree %s: git worktree remove failed\n' "$dir" >&2
    return 1
  fi
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
  local title="$6" description="$7" latest="$8" why="${9:-}" finish_contract claim_contract
  if [ "${MAINTAINER:-off}" = "on" ]; then
    IFS= read -r -d '' finish_contract <<'EOF' || true
FINISH IT AS THE SETUP MAINTAINER. A ticket asking for an allowlisted merge, release, update, or build is direct maintainer work:
- Merge or release an existing pull request with `agent-template merge <pr-url>`.
- Start a requested code change with `agent-template build --repo <key> --ticket <url> --spec <file|-> [--effort high|xhigh]`.
- Deploy a merged toolkit release with `agent-template update --keep-timers`.
Run the relevant command in this run. This replaces the ordinary developer pull request workflow. Do not create an implementation branch for a direct operation, delegate it, hand it to a developer, or say that a developer must release it. After a successful direct merge, post a `Done:` comment that names the result and links the pull request. A background build is not done when it starts; its completion checker posts the final result.
EOF
  else
    IFS= read -r -d '' finish_contract <<'EOF' || true
FINISH IT. The run counts for something only when the work is in a pull
request that can merge on its own: branch off the production branch, commit,
push, open the PR, and turn auto-merge on with
`gh pr merge --auto --squash <number>` in the same breath as opening it. A
PR sitting green with auto-merge off is work nobody gets. GitHub refuses that
command on a private repo whose plan does not carry auto-merge; when it is
refused, do not retry it and do not fail the run over it: leave the PR open,
say so in your result comment, and move the ticket to the review lane anyway.
Checks turning green on a PR that could not get auto-merge is what the
supervisor's pr-hygiene check looks for; it merges those by hand. Then move
the ticket to the review lane the lifecycle skill names. Do not leave commits
unpushed: this working directory is thrown away when the process exits.
EOF
  fi
  # $skills_index is now a readable phrase naming every pack, so the lifecycle
  # scripts are looked up under the FIRST pack (the company one), which is
  # where ticket-lifecycle lives. The runner exports it.
  local primary="${SKILLS_INDEX_PRIMARY:-$skills_index}"
  local route_sh="$(dirname "$primary")/ticket-lifecycle/scripts/route.sh"
  local claim_sh="$(dirname "$primary")/ticket-lifecycle/scripts/claim-ticket.sh"
  if [ "${AGENT_KIND:-dev}" = "dev" ]; then
    claim_contract="The runner already won the claim, posted Claimed., and moved $ref to the working column. Do not claim it again."
  else
    claim_contract="Claim the ticket with \`$claim_sh $ref\` before you write any code. Never assign userId 6: only Valentin assigns Valentin."
  fi
  if [ "${AGENT_KIND:-dev}" = "qa" ]; then
    cat <<EOF
You are $agent_name. Verify one ticket, $ref, and do not change its implementation.

Ticket $url: $title

$description

Latest comment: ${latest:-none}

Read $skills_index first, in order. Inspect the shipped behavior and run the
smallest test that proves each acceptance step. Finish with exactly one verdict
comment and the matching board move. Never stop after posting the verdict.
EOF
    return 0
  fi
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

$claim_contract

$finish_contract

${AGENT_ADVISOR_GUIDANCE:+$AGENT_ADVISOR_GUIDANCE

}Ticket comments have exactly five allowed kinds. Start one with \`Question:\`
only when a human must answer; name what you need and end it with a question
mark. Start one with \`Answer:\` when replying to a direct owner question or
mention. Start one with \`Decision:\` for a fact the owner must know. Start one
with \`Handoff:\` and name the receiving agent. Start one with \`Done:\` and
explain what shipped with the pull request link. The runner's one claim message
is mechanical; do not post another. Plans, progress, checks, retries, blockers,
costs, and gate ledgers are run activity, not comments. The board wrapper
redirects any unmarked comment to activity.

When QUIET is on, do not @mention the board owner unless replying to a comment
where the owner directly mentioned you. That direct reply keeps the owner mention
even when the daily owner-mention allowance was already used. Otherwise move the
ticket to the review lane for attention. The existing maximum of three comments
per ticket per day and one reminder per day remains. Write as $agent_name, in HTML block tags, with
\`$board_cli comment add $ref --text '<p>Done: https://github.com/org/repo/pull/1</p>'\`.

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
