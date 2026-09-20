#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
TMP="$(mktemp -d)"
trap '[ -n "${KEEP_TMP:-}" ] || rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.config/hypertask-agents" "$TMP/company" "$TMP/repo"
printf 'test\n' > "$TMP/company/INDEX.md"
printf '1\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"

cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ -z "${BOARD_CALL_LOG:-}" ] || printf '%s\n' "$*" >> "$BOARD_CALL_LOG"
if [ "${1:-}" = "--token" ] && [ "$#" -ge 2 ]; then shift 2; fi
[ -z "${ACTION_LOG:-}" ] || printf 'board %s\n' "$*" >> "$ACTION_LOG"
if [ "${1:-} ${2:-} ${3:-}" = "--json comment list" ] \
   && [ -e "${MODEL_OPEN_MARKER:-/no-marker}" ]; then
  printf '%s\n' '{"comments":[{"id":"opened-8","agent":{"displayName":"Dev One"},"text":"<p><strong>Handoff: The pull request is ready for review.</strong></p><p><a href=\"https://github.com/example/repo/pull/8\">https://github.com/example/repo/pull/8</a></p><p>Next: Review the linked change.</p>"}]}'
  exit 0
fi
if [ "${1:-} ${2:-}" = "task create" ]; then
  printf '{"task":{"ticketNumber":"AGTE-999"}}\n'
  exit 0
fi
if [ "${1:-}" = "--json" ] && [ "${2:-} ${3:-}" = "task get" ]; then
  printf '{"task":{"ticketNumber":"%s","section":"Bugs","assignees":[{"agent":{"id":"agent-1"}}]}}\n' "${4:-HTPR-1}"
fi
if [ "${1:-} ${2:-}" = "task unassign" ] && [ -n "${UNASSIGNED_MARKER:-}" ]; then
  touch "$UNASSIGNED_MARKER"
fi
if [ "${1:-} ${2:-}" = "comment add" ]; then
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--file" ] && [ "$#" -gt 1 ] && [ -n "${BOARD_COMMENT_LOG:-}" ]; then
      cat "$2" >> "$BOARD_COMMENT_LOG"
      break
    elif [ "$1" = "--text" ] && [ "$#" -gt 1 ] && [ -n "${BOARD_COMMENT_LOG:-}" ]; then
      printf '%s\n' "$2" >> "$BOARD_COMMENT_LOG"
      break
    fi
    shift
  done
fi
exit 0
EOF
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ -z "${MODEL_OPEN_MARKER:-}" ] || touch "$MODEL_OPEN_MARKER"
if [ -n "${MODEL_OPEN_MARKER:-}" ] && [ -n "${AGENT_BOARD_CLI:-}" ]; then
  "$AGENT_BOARD_CLI" comment add HTPR-1 --text '<p><strong>Handoff: The pull request is ready for review.</strong></p><p><a href="https://github.com/example/repo/pull/8">https://github.com/example/repo/pull/8</a></p><p>Next: Review the linked change.</p>'
  mkdir -p "$HOME/.local/state/agent-board-poll"
  printf 'HTPR-1 opened-8\n' >> "$HOME/.local/state/agent-board-poll/dev-1.posted-comments"
fi
[ -z "${WORKER_LOG:-}" ] || printf '%s\n' "${*: -1}" >> "$WORKER_LOG"
if [ "${WORKER_COMMIT:-no}" = yes ]; then
  printf 'worker change\n' >> app
  git add app
  git -c user.name=Eval -c user.email=eval@example.test commit -qm 'worker fix'
fi
exit "${WORKER_EXIT:-0}"
EOF
cat > "$TMP/bin/reviewer" <<'EOF'
#!/usr/bin/env bash
[ -z "${REVIEWER_LOG:-}" ] || printf '%s\n' "${*: -1}" >> "$REVIEWER_LOG"
printf '%s\n' "${SECOND_OPINION_RESULT:-Pin the failing dependency before rebuilding.}"
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
scenario="${PR_TEST_SCENARIO:-pending}"
[ -z "${GH_CALL_LOG:-}" ] || printf '%s\n' "$*" >> "$GH_CALL_LOG"
if [ "$1 $2" = "pr comment" ] || [ "$1 $2" = "pr close" ] \
   || [ "$1 $2" = "run rerun" ]; then
  [ -z "${ACTION_LOG:-}" ] || printf 'gh %s\n' "$*" >> "$ACTION_LOG"
  exit 0
fi
if [ "$1" = api ] && printf ' %s ' "$*" | grep -q ' -X POST ' \
   && printf ' %s ' "$*" | grep -q ' labels\[\]=intentional-revert '; then
  [ -z "${ACTION_LOG:-}" ] || printf 'gh %s\n' "$*" >> "$ACTION_LOG"
  printf '[]\n'
  exit 0
fi
if [ "$1 $2" = "pr diff" ]; then
  printf 'diff --git a/app b/app\n+broken dependency\n'
  exit 0
fi
if [ "$1 $2" = "pr list" ]; then
  if printf ' %s ' "$*" | grep -q ' --search '; then
    if [ "$scenario" = "record-open" ] && [ -e "${MODEL_OPEN_MARKER:-/no-marker}" ]; then
      printf '[{"number":8,"title":"HTPR-1 fix","headRefName":"legacy/fix-1"}]\n'
    else
      printf '[]\n'
    fi
    exit 0
  fi
  if printf ' %s ' "$*" | grep -q ' --state merged '; then
    case "$scenario" in
      deployed|undeployed|fallback|base-missing|qa-fail|qa-passed)
        printf '[{"number":1,"state":"MERGED","url":"https://github.test/pull/1","title":"HTPR-1 fix","body":"","headRefName":"agent/dev-1-htpr-1","baseRefName":"production","author":{"login":"dev-one"},"createdAt":"2026-01-01T00:00:00Z","mergedAt":"2026-01-02T00:00:00Z"}]\n' ;;
      *) printf '[]\n' ;;
    esac
    exit 0
  fi
  case "$scenario" in
    deployed|undeployed|fallback|base-missing|qa-fail|qa-passed) printf '[]\n'; exit 0 ;;
  esac
  if [ "$scenario" = "oldest" ] || [ "$scenario" = "two-green" ]; then
    cat <<JSON
[{"number":9,"state":"OPEN","url":"https://github.test/pull/9","title":"HTPR-9 old","body":"","headRefName":"agent/dev-1-htpr-9","createdAt":"2026-09-18T21:00:00Z"},{"number":10,"state":"OPEN","url":"https://github.test/pull/10","title":"HTPR-10 new","body":"","headRefName":"agent/dev-1-htpr-10","createdAt":"2026-09-18T21:01:00Z"}]
JSON
  elif [ "$scenario" = "stale-red-green" ]; then
    cat <<JSON
[{"number":9,"state":"OPEN","url":"https://github.test/pull/9","title":"HTPR-9 stale","body":"","headRefName":"agent/dev-1-htpr-9","createdAt":"2026-09-18T19:00:00Z"},{"number":10,"state":"OPEN","url":"https://github.test/pull/10","title":"HTPR-10 green","body":"","headRefName":"agent/dev-1-htpr-10","createdAt":"2026-09-18T21:01:00Z"}]
JSON
  elif [ "$scenario" = "qa-claim" ]; then
    cat <<JSON
[{"number":3,"state":"OPEN","url":"https://github.test/pull/3","title":"HTPR-3 fix","body":"","headRefName":"agent/dev-1-htpr-3","author":{"login":"dev-one"},"createdAt":"2026-01-01T00:00:00Z"}]
JSON
  elif [ "$scenario" = "orphan" ]; then
    cat <<JSON
[{"number":4,"state":"OPEN","url":"https://github.test/pull/4","title":"HTPR-12 fix","body":"","headRefName":"agent/retired-dev-htpr-4","author":{"login":"retired-dev"},"createdAt":"2026-01-01T00:00:00Z"}]
JSON
  elif [ "$scenario" = "author-owned" ]; then
    cat <<JSON
[{"number":5,"state":"OPEN","url":"https://github.test/pull/5","title":"HTPR-5 fix","body":"","headRefName":"contributor/fix-5","author":{"login":"dev-one"},"createdAt":"2026-01-01T00:00:00Z"}]
JSON
  elif [ "$scenario" = "custom-prefix" ]; then
    cat <<JSON
[{"number":6,"state":"OPEN","url":"https://github.test/pull/6","title":"HTPR-6 fix","body":"","headRefName":"cursor-dev-2/htpr-6","author":{"login":"shared-bot"},"createdAt":"2026-01-01T00:00:00Z"}]
JSON
  elif [ "$scenario" = "state-owned" ]; then
    cat <<JSON
[{"number":7,"state":"OPEN","url":"https://github.test/pull/7","title":"HTPR-7 fix","body":"","headRefName":"legacy/fix-7","author":{"login":"shared-bot"},"createdAt":"2026-01-01T00:00:00Z"}]
JSON
  elif [ "$scenario" = "shared-author" ]; then
    cat <<JSON
[{"number":11,"state":"OPEN","url":"https://github.test/pull/11","title":"HTPR-11 fix","body":"","headRefName":"legacy/fix-11","author":{"login":"dev-one"},"createdAt":"2026-01-01T00:00:00Z"}]
JSON
  elif [ "$scenario" = "slug-prefix" ]; then
    cat <<JSON
[{"number":12,"state":"OPEN","url":"https://github.test/pull/12","title":"HTPR-12 fix","body":"","headRefName":"dev-1/htpr-12-fix","author":{"login":"shared-bot"},"createdAt":"2026-01-01T00:00:00Z"}]
JSON
  elif [ "$scenario" = "record-open" ]; then
    printf '[]\n'
  else
    state="OPEN"; [ "$scenario" = "deployed" ] || [ "$scenario" = "undeployed" ] || [ "$scenario" = "fallback" ] || [ "$scenario" = "base-missing" ] || [ "$scenario" = "qa-fail" ] || [ "$scenario" = "qa-passed" ] || state="OPEN"
    if [ "$scenario" = "deployed" ] || [ "$scenario" = "undeployed" ] || [ "$scenario" = "fallback" ] || [ "$scenario" = "base-missing" ] || [ "$scenario" = "qa-fail" ] || [ "$scenario" = "qa-passed" ]; then state="MERGED"; fi
    created_at="2026-09-18T21:00:00Z"
    [ "$scenario" != "stale-red" ] || created_at="2026-09-18T19:00:00Z"
    printf '[{"number":1,"state":"%s","url":"https://github.test/pull/1","title":"HTPR-1 fix","body":"https://app.hypertask.ai/detail/project-15/1","headRefName":"agent/dev-1-htpr-1","author":{"login":"dev-one"},"createdAt":"%s"}]\n' "$state" "$created_at"
  fi
  exit 0
fi
if [ "$1 $2" = "pr view" ]; then
  number="$3"
  if printf ' %s ' "$*" | grep -q ' baseRefName,headRefName '; then
    base=production
    [ "$scenario" != "prep-fail" ] || base=missing-production
    printf '{"baseRefName":"%s","headRefName":"agent/dev-1-htpr-1"}\n' "$base"
    exit 0
  fi
  if [ "$scenario" = "deployed" ] || [ "$scenario" = "undeployed" ] || [ "$scenario" = "fallback" ] || [ "$scenario" = "base-missing" ] || [ "$scenario" = "qa-fail" ] || [ "$scenario" = "qa-passed" ]; then
    printf '{"state":"MERGED","baseRefName":"production","mergedAt":"2026-01-02T00:00:00Z","mergeCommit":{"oid":"merge%s"}}\n' "$number"
    exit 0
  fi
  if printf ' %s ' "$*" | grep -q ' state,baseRefName,mergedAt,mergeCommit '; then
    printf '{"state":"OPEN","baseRefName":"production","mergedAt":null,"mergeCommit":null}\n'
    exit 0
  fi
  if [ "$scenario" = "status-context" ]; then
    cat "$PR_FIXTURE"
    exit 0
  fi
  if printf ' %s ' "$*" | grep -q ' baseRefName,headRefName '; then
    base=production
    [ "$scenario" != "prep-fail" ] || base=missing-production
    printf '{"baseRefName":"%s","headRefName":"agent/dev-1-htpr-1"}\n' "$base"
    exit 0
  fi
  checks='[{"name":"ci-tests","status":"IN_PROGRESS","conclusion":"","detailsUrl":"https://github.test/actions/runs/77/job/1"}]'
  reviews='[]'
  comments='[]'
  if [ "$scenario" = "green" ] || [ "$scenario" = "two-green" ] \
     || { [ "$scenario" = "stale-red-green" ] && [ "$number" = "10" ]; }; then
    checks='[{"name":"ci-tests","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.test/actions/runs/77/job/1"}]'
  elif [ "$scenario" = "red" ] || [ "$scenario" = "stale-red" ] || [ "$scenario" = "stale-red-green" ] || [ "$scenario" = "oldest" ] || [ "$scenario" = "qa-claim" ] || [ "$scenario" = "orphan" ] || [ "$scenario" = "author-owned" ] || [ "$scenario" = "custom-prefix" ] || [ "$scenario" = "slug-prefix" ] || [ "$scenario" = "prep-fail" ]; then
    checks='[{"name":"ci-tests","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.test/actions/runs/77/job/1"},{"name":"revert-guard","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.test/actions/runs/77/job/2"},{"name":"pr-title","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.test/actions/runs/77/job/3"}]'
    comments='[{"author":{"login":"claude-review"},"body":"CONCERNS: preserve the existing authorization check."}]'
  elif [ "$scenario" = "revert-only" ]; then
    checks='[{"name":"revert-guard","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.test/actions/runs/88/job/1"}]'
  fi
  printf '{"state":"OPEN","url":"https://github.test/pull/%s","title":"HTPR-%s fix","body":"","headRefName":"agent/dev-1-htpr-%s","headRefOid":"head%s","baseRefName":"production","createdAt":"2026-01-01T00:00:00Z","statusCheckRollup":%s,"reviews":%s,"comments":%s}\n' "$number" "$number" "$number" "$number" "$checks" "$reviews" "$comments"
  exit 0
fi
if [ "$1" = "api" ]; then
  endpoint="$2"
  if [[ "$endpoint" == repos/example/repo/pulls\?state=* ]]; then
    if [ "$scenario" = "rate-limit" ]; then
      printf 'API rate limit exceeded (HTTP 403)\n' >&2
      exit 1
    fi
    REQUEST_STATE="${endpoint#*state=}"
    REQUEST_STATE="${REQUEST_STATE%%&*}"
    REQUEST_PAGE="${endpoint##*page=}"
    REQUEST_PAGE="${REQUEST_PAGE%%&*}"
    SCENARIO="$scenario" REQUEST_STATE="$REQUEST_STATE" REQUEST_PAGE="$REQUEST_PAGE" python3 <<'PYEOF'
import json
import os

scenario = os.environ["SCENARIO"]
state = os.environ["REQUEST_STATE"]
page = int(os.environ.get("REQUEST_PAGE") or "1")
def row(number, ticket, branch, author="shared-bot", updated="2026-09-18T21:00:00Z", merged=None):
    return {"number": number, "title": f"HTPR-{ticket} fix", "html_url": f"https://github.test/pull/{number}",
            "head": {"ref": branch}, "base": {"ref": "production"}, "user": {"login": author},
            "draft": False, "created_at": updated, "updated_at": updated, "merged_at": merged}
rows = []
merged_scenarios = {"deployed", "undeployed", "fallback", "base-missing", "qa-fail", "qa-passed"}
if scenario == "paginated" and state == "open":
    start = 1 if page == 1 else 101
    stop = 101 if page == 1 else 102
    rows = [row(number, number, f"dev-1/htpr-{number}") for number in range(start, stop)]
elif state == "closed":
    if scenario in merged_scenarios:
        rows = [row(1, 1, "dev-1/htpr-1", updated="2026-09-18T20:00:00Z", merged="2026-09-18T20:00:00Z")]
elif scenario not in merged_scenarios:
    if scenario in {"oldest", "two-green"}:
        rows = [row(9, 9, "dev-1/htpr-9", updated="2026-09-18T21:00:00Z"),
                row(10, 10, "dev-1/htpr-10", updated="2026-09-18T21:01:00Z")]
    elif scenario == "stale-red-green":
        rows = [row(9, 9, "dev-1/htpr-9", updated="2026-09-18T19:00:00Z"),
                row(10, 10, "dev-1/htpr-10", updated="2026-09-18T21:01:00Z")]
    elif scenario == "qa-claim":
        rows = [row(3, 3, "dev-1/htpr-3", author="dev-one", updated="2026-01-01T00:00:00Z")]
    elif scenario == "orphan":
        rows = [row(4, 12, "retired-dev/htpr-4", author="retired-dev", updated="2026-01-01T00:00:00Z")]
    elif scenario == "author-owned":
        rows = [row(5, 5, "contributor/fix-5", author="dev-one", updated="2026-01-01T00:00:00Z")]
    elif scenario == "custom-prefix":
        rows = [row(6, 6, "cursor-dev-2/htpr-6", updated="2026-01-01T00:00:00Z")]
    elif scenario == "state-owned":
        rows = [row(7, 7, "legacy/fix-7", updated="2026-01-01T00:00:00Z")]
    elif scenario == "shared-author":
        rows = [row(11, 11, "legacy/fix-11", updated="2026-01-01T00:00:00Z")]
    elif scenario == "foreign-prefix":
        rows = [row(13, 13, "dev-2/htpr-13", updated="2026-01-01T00:00:00Z")]
    elif scenario == "slug-prefix":
        rows = [row(12, 12, "DeV-1/htpr-12-fix", updated="2026-01-01T00:00:00Z")]
    elif scenario != "record-open":
        updated = "2026-09-18T19:00:00Z" if scenario == "stale-red" else "2026-09-18T21:00:00Z"
        rows = [row(1, 1, "dev-1/htpr-1", author="dev-one", updated=updated)]
print(json.dumps(rows))
PYEOF
    exit 0
  fi
  case "$endpoint" in
    user) printf 'shared-bot\n' ;;
    rate_limit) printf '1790000000\n' ;;
    */pulls/*/comments*) printf '[]\n' ;;
    */compare/*)
      if [ "$scenario" = "base-missing" ]; then
        printf '{"status":"diverged"}\n'
      else
        printf '{"status":"ahead"}\n'
      fi ;;
    */deployments\?per_page=100)
      if [ "$scenario" = "fallback" ]; then
        printf '[]\n'
      elif [ "$scenario" = "undeployed" ]; then
        printf '[{"id":50,"environment":"Production","created_at":"2026-01-01T00:00:00Z","sha":"old"}]\n'
      else
        printf '[{"id":51,"environment":"Production","created_at":"2026-01-03T00:00:00Z","sha":"deploy"}]\n'
      fi ;;
    */deployments/*/statuses*) printf '[{"state":"success"}]\n' ;;
    *) printf '{}\n' ;;
  esac
  exit 0
fi
if [ "$1 $2" = "run view" ]; then
  printf 'ci-tests\tFAIL\texact failed log line\n'
  exit 0
fi
printf 'unexpected gh command: %s\n' "$*" >&2
exit 1
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
if [[ "$url" == *'/mcp/projects/'*'/labels'* ]]; then
  printf '{"labels":[{"id":"label-needs-human","name":"needs-human"}]}\n'
elif [[ "$url" == *'/mcp/tasks?'* ]]; then
  emergency_labels='[{"name":"emergency"}]'
  [ "${BOARD_TEST_SCENARIO:-}" != "no-emergency" ] || emergency_labels='[]'
  ticket_section='Bugs'
  [ "${PR_TEST_SCENARIO:-}" != "qa-passed" ] || ticket_section='Done'
  [ "${BOARD_TEST_SCENARIO:-}" != "blocked" ] || ticket_section='Agent Blocked (Infra)'
  task1_assignees='[{"agent":{"id":"agent-1"}}]'
  [ "${BOARD_TEST_SCENARIO:-}" != "human" ] || task1_assignees='[{"agent":{"id":"agent-1"}},{"id":"6","displayName":"Owner"}]'
  task1_labels='[]'
  [ "${BOARD_TEST_SCENARIO:-}" != "owner-hold" ] || task1_labels='[{"name":"valentin"}]'
  if [ -n "${UNASSIGNED_MARKER:-}" ] && [ -e "$UNASSIGNED_MARKER" ]; then
    ticket_section='Review'
    task1_assignees='[]'
  fi
  cat <<JSON
{"tasks":[{"id":"task-1","ticketNumber":"HTPR-1","projectId":"15","section":"$ticket_section","title":"PR ticket","description":"fix it","assignees":$task1_assignees,"labels":$task1_labels,"commentCount":0},{"id":"task-2","ticketNumber":"HTPR-2","section":"Bugs","title":"Emergency","description":"urgent fix","assignees":[{"agent":{"id":"agent-1"}}],"labels":$emergency_labels,"commentCount":0},{"id":"task-3","ticketNumber":"HTPR-3","section":"Bugs","title":"Claimed in a comment","description":"fix it","assignees":[],"labels":[],"commentCount":1},{"id":"task-4","ticketNumber":"HTPR-4","section":"Bugs","title":"Another owner's ticket","description":"fix it","assignees":[{"agent":{"id":"agent-2"}}],"labels":[],"commentCount":0},{"id":"task-5","ticketNumber":"HTPR-5","section":"Bugs","title":"Legacy branch ticket","description":"fix it","assignees":[{"agent":{"id":"agent-1"}}],"labels":[],"commentCount":0}]}
JSON
elif [[ "$url" == *'task_id=task-1'* ]] \
     && [ -e "${MODEL_OPEN_MARKER:-/no-marker}" ]; then
  printf '%s\n' '{"comments":[{"id":"opened-8","agent":{"id":"agent-1"},"createdAt":"2026-09-18T21:00:00Z","text":"<p><strong>Handoff: The pull request is ready for review.</strong></p><p><a href=\"https://github.com/example/repo/pull/8\">https://github.com/example/repo/pull/8</a></p><p>Next: Review the linked change.</p>"}]}'
elif [[ "$url" == *'task_id=task-1'* ]] && [ "${PR_TEST_SCENARIO:-}" = "qa-fail" ]; then
  printf '{"comments":[{"id":"qa-77","agent":{"id":"agent-qa"},"createdAt":"2026-09-18T21:00:00Z","text":"<p>Handoff: Dev One, checkout fails after deploy.</p>"}]}\n'
elif [[ "$url" == *'task_id=task-3'* ]]; then
  printf '{"comments":[{"agent":{"id":"agent-1","displayName":"Dev One"},"text":"<p>Claimed.</p>"}]}\n'
else
  printf '{"comments":[]}\n'
fi
printf '\n200'
EOF
chmod +x "$TMP/bin/"*

rm -rf "$TMP/repo"
git init --bare -q "$TMP/remote.git"
git init -q "$TMP/seed"
git -C "$TMP/seed" config user.name Eval
git -C "$TMP/seed" config user.email eval@example.test
printf 'base one\nbase two\nbase three\nbase four\n' > "$TMP/seed/app"
git -C "$TMP/seed" add app
git -C "$TMP/seed" commit -qm base
git -C "$TMP/seed" branch -M production
git -C "$TMP/seed" remote add origin "$TMP/remote.git"
git -C "$TMP/seed" push -q -u origin production
git -C "$TMP/seed" checkout -qb agent/dev-1-htpr-1
printf 'base four\n' > "$TMP/seed/app"
git -C "$TMP/seed" add app
git -C "$TMP/seed" commit -qm 'delete recent code'
git -C "$TMP/seed" push -q -u origin agent/dev-1-htpr-1
git --git-dir="$TMP/remote.git" symbolic-ref HEAD refs/heads/production
git clone -q "$TMP/remote.git" "$TMP/repo"
git -C "$TMP/repo" checkout -q production
git init --bare -q "$TMP/wrong-origin.git"
git -C "$TMP/repo" remote set-url origin "$TMP/wrong-origin.git"
git config --file "$TMP/home/.gitconfig" url."file://$TMP/remote.git".insteadOf https://github.com/example/repo.git

# Source only the adapter for focused LIVE and feedback tests. The fake board
# API above is used through the real _ht_get parser.
PATH="$TMP/bin:$PATH"
HOME="$TMP/home"
PR_REPO="example/repo"
export PR_GATE_NOW="2026-09-18T22:00:00Z"
# shellcheck source=/dev/null
. "$ROOT/adapters/hypertask/adapter.sh"
die() { printf 'die: %s %s\n' "$*" >&2; return 1; }

cat > "$TMP/home/.config/hypertask-agents/dev-1.conf" <<'EOF'
AGENT_SLUG="dev-1"
AGENT_ID="agent-1"
AGENT_KIND="dev"
BOARD_ADAPTER="hypertask"
PR_REPO="example/repo"
GH_LOGIN="dev-one"
EOF
cat > "$TMP/home/.config/hypertask-agents/qa-1.conf" <<'EOF'
AGENT_SLUG="qa-1"
AGENT_ID="agent-qa"
AGENT_KIND="qa"
BOARD_ADAPTER="hypertask"
PR_REPO="example/repo"
EOF
cat > "$TMP/home/.config/hypertask-agents/dev-2.conf" <<'EOF'
AGENT_SLUG="dev-2"
AGENT_ID="agent-2"
AGENT_KIND="dev"
BOARD_ADAPTER="hypertask"
PR_REPO="example/repo"
PR_BRANCH_PREFIX="cursor-dev-2/"
EOF
cat > "$TMP/home/.config/hypertask-agents/legacy-worker.conf" <<'EOF'
PR_REPO="example/repo"
LEGACY_PROMPT="unterminated
EOF

run_gate() {
  local scenario="$1" slug="${2:-dev-1}" name="${3:-Dev One}" cache opened
  cache="$TMP/cache-$scenario-$slug"
  opened="$TMP/home/.local/state/agent-board-poll/$slug.opened-prs"
  mkdir -p "$(dirname "$opened")"
  touch "$opened"
  AGENT_PR_CACHE_DIR="$cache/pr-cache" PR_TEST_SCENARIO="$scenario" \
    PR_FIXTURE="$ROOT/evals/fixtures/status-context-pr.json" \
    PR_GATE_NOW="2026-09-18T22:00:00Z" PR_BRANCH_PREFIX="${4:-}" adapter_pr_gate \
      "$TMP/token" 15 agent-1 "$name" "$slug" "$cache" \
      "$TMP/home/.config/hypertask-agents" "$opened"
}

legacy_log="$TMP/legacy.log"
run_gate pending >/dev/null 2>"$legacy_log"
[[ "$(grep -cF 'skipping legacy agent conf legacy-worker.conf: no BOARD_ADAPTER schema marker' "$legacy_log")" = 1 ]]
! grep -qF 'unexpected EOF' "$legacy_log"
rm "$TMP/home/.config/hypertask-agents/legacy-worker.conf"
echo 'PASS legacy conf without schema marker is logged once and never sourced'

red="$(run_gate red)"
[[ "$red" == *'"action": "fix"'* ]]
[[ "$red" == *'ci-tests'* && "$red" == *'revert-guard'* && "$red" == *'pr-title'* ]]
[[ "$red" == *'CONCERNS: preserve the existing authorization check.'* ]]
[[ "$red" == *'exact failed log line'* ]]
echo 'PASS open red PR returns exact checks, review feedback, and logs'

status_context="$(run_gate status-context)"
STATUS_CONTEXT="$status_context" python3 - <<'PYEOF'
import json
import os

result = json.loads(os.environ["STATUS_CONTEXT"])
assert result["action"] == "fix"
assert result["state"] == "red"
assert result["pending"] == ["release-queue"]
assert "app-smoke [FAILURE] https://ci.test/app-smoke" in result["feedback"]
assert "deploy-health [ERROR] https://ci.test/deploy-health" in result["feedback"]
assert "legacy-lint" not in result["feedback"]
PYEOF
echo 'PASS StatusContext success, failure, error, and pending states are classified'

pending="$(run_gate pending)"
[[ "$pending" == *'"action": "wait"'* && "$pending" == *'"state": "pending"'* ]]
echo 'PASS pending PR remains bound without inventing work'

green="$(run_gate green)"
GREEN="$green" python3 - <<'PYEOF'
import json, os
result = json.loads(os.environ["GREEN"])
assert result["action"] == "wait" and result["state"] == "awaiting-review"
assert result["pickup_slot"] is True and result["unfixable"] is False
PYEOF
echo 'PASS one open green PR remains bound while awaiting review or merge'

stale_red="$(run_gate stale-red)"
STALE_RED="$stale_red" python3 - <<'PYEOF'
import json, os
result = json.loads(os.environ["STALE_RED"])
assert result["action"] == "fix" and result["state"] == "red"
assert result["failed_checks"] == ["ci-tests", "revert-guard", "pr-title"]
assert result["wait_reason"] == "red: ci-tests, revert-guard, pr-title"
assert result["pickup_slot"] is True and result["unfixable"] is False
PYEOF
echo 'PASS a red PR never ages out of its binding'

undeployed="$(run_gate undeployed)"
[[ "$undeployed" == *'"state": "in-qa"'* ]]
echo 'PASS merged PR remains bound while QA is incomplete'

base_missing="$(run_gate base-missing)"
[[ "$base_missing" == *'"state": "in-qa"'* ]]
echo 'PASS rewritten deployment history does not bypass QA binding'

base_missing_dir="$TMP/base-missing-direct"
base_missing_state="$(PR_TEST_SCENARIO=base-missing _ht_pr_live_state example/repo 1 "$base_missing_dir")"
[[ "$base_missing_state" == *'"live":true'* && "$base_missing_state" == *'"state":"superseded"'* ]]
echo 'PASS a rewritten base reports live so the deadlock never recurs'

base_missing_log="$TMP/base-missing.log"
base_missing_dedup_dir="$TMP/base-missing-dedup"
PR_TEST_SCENARIO=base-missing _ht_pr_live_state example/repo 1 "$base_missing_dedup_dir" >/dev/null 2>"$base_missing_log"
rm -f "$base_missing_dedup_dir/1.json"
PR_TEST_SCENARIO=base-missing _ht_pr_live_state example/repo 1 "$base_missing_dedup_dir" >/dev/null 2>>"$base_missing_log"
[[ "$(grep -cF 'is not contained in base' "$base_missing_log")" = 1 ]]
echo 'PASS a rewritten base is only logged once per day even as the 60s cache expires'

[[ "$(run_gate deployed)" == *'"state": "in-qa"'* ]]
echo 'PASS successful Production deployment still waits for QA'

[[ "$(run_gate fallback)" == *'"state": "in-qa"'* ]]
fallback_state="$(PR_TEST_SCENARIO=fallback _ht_pr_live_state example/repo 1 "$TMP/fallback-direct")"
[[ "$fallback_state" == *'fallback: merged and base contains merge commit (no deployment records)'* ]]
echo 'PASS deployment fallback does not replace the QA verdict'

qa_failed="$(run_gate qa-fail)"
[[ "$qa_failed" == *'"state": "red"'* && "$qa_failed" == *'"qa_failure_id": "qa-77"'* ]]
[[ "$qa_failed" == *'checkout fails after deploy'* ]]
echo 'PASS QA Handoff after merge becomes a red round with a durable verdict id'

[[ -z "$(run_gate qa-passed)" ]]
echo 'PASS Done ticket proves QA passed and releases the merged PR binding'

: > "$TMP/gh-calls"
cache_dir="$TMP/cache-proof"
GH_CALL_LOG="$TMP/gh-calls" PR_TEST_SCENARIO=deployed _ht_pr_live_state example/repo 1 "$cache_dir" >/dev/null
first_calls="$(wc -l < "$TMP/gh-calls")"
GH_CALL_LOG="$TMP/gh-calls" PR_TEST_SCENARIO=deployed _ht_pr_live_state example/repo 1 "$cache_dir" >/dev/null
[[ "$(wc -l < "$TMP/gh-calls")" = "$first_calls" ]]
echo 'PASS LIVE answer is cached per PR for 60 seconds'

qa_claim="$(run_gate qa-claim qa-1 'QA One')"
[[ -z "$qa_claim" ]]
echo 'PASS QA agent never binds to a development PR it did not open'

explicit_author="$(run_gate author-owned)"
[[ "$explicit_author" == *'"number": 5'* ]]
echo 'PASS explicit agent login distinct from the host login attributes ownership'

custom_prefix="$(run_gate custom-prefix dev-2 'Dev Two' 'cursor-dev-2/')"
[[ "$custom_prefix" == *'"number": 6'* ]]
echo 'PASS dev-2 historical branch aliases attribute only to dev-2'

printf 'example/repo\t7\tHTPR-7\n' > "$TMP/home/.local/state/agent-board-poll/dev-1.opened-prs"
state_owned="$(run_gate state-owned)"
[[ "$state_owned" == *'"number": 7'* ]]
echo 'PASS runner state attributes a legacy branch PR'

shared_author="$(run_gate shared-author 2>/dev/null)"
[[ -z "$shared_author" ]]
echo 'PASS shared host GitHub authorship does not transfer PR ownership'

foreign_prefix="$(run_gate foreign-prefix 2>/dev/null)"
[[ -z "$foreign_prefix" ]]
echo 'PASS shared-login PR with a foreign branch prefix does not bind'

slug_prefix="$(run_gate slug-prefix)"
[[ "$slug_prefix" == *'"number": 12'* ]]
[[ -z "$(run_gate slug-prefix dev-2 'Dev Two' 'cursor-dev-2/' 2>/dev/null)" ]]
echo 'PASS slug branch prefix is case-insensitive and attributes only its matching agent'

pr_cache_dir="$TMP/shared-pr-cache"
pr_cache="$pr_cache_dir/example__repo.json"
rm -rf "$pr_cache_dir"
: > "$TMP/gh-calls"
for reader in 1 2 3 4 5 6; do
  AGENT_PR_CACHE_DIR="$pr_cache_dir" GH_CALL_LOG="$TMP/gh-calls" \
    PR_TEST_SCENARIO=pending _ht_pr_cache_rows example/repo > "$TMP/cache-reader-$reader" &
done
wait
AGENT_PR_CACHE_DIR="$pr_cache_dir" GH_CALL_LOG="$TMP/gh-calls" \
  PR_TEST_SCENARIO=red _ht_pr_cache_rows example/repo >/dev/null
[[ "$(grep -cF 'api repos/example/repo/pulls?' "$TMP/gh-calls")" = 2 ]]
[[ -f "$pr_cache" ]]
printf '%s\n' "$(( $(date +%s) + 60 ))" > "$pr_cache.rate-limit"
set +e
AGENT_PR_CACHE_DIR="$pr_cache_dir" GH_CALL_LOG="$TMP/gh-calls" \
  PR_TEST_SCENARIO=red _ht_pr_cache_rows example/repo >/dev/null
paused_cache_rc=$?
set -e
[[ "$paused_cache_rc" = 75 ]]
[[ "$(grep -cF 'api repos/example/repo/pulls?' "$TMP/gh-calls")" = 2 ]]
rm -f "$pr_cache.rate-limit"
python3 - "$pr_cache" <<'PYEOF'
import json, sys
row = json.load(open(sys.argv[1], encoding="utf-8"))
assert row["repo"] == "example/repo" and len(row["prs"]) == 1
pr = row["prs"][0]
assert {"number", "title", "branch", "author"} <= set(pr)
assert "body" not in pr
PYEOF
! grep -q 'pr list\|body' "$TMP/gh-calls" "$pr_cache"
echo 'PASS six readers share one repository cache refreshed no more than once per minute'

page_cache="$TMP/page-pr-cache"
: > "$TMP/page-gh-calls"
page_rows="$(AGENT_PR_CACHE_DIR="$page_cache" GH_CALL_LOG="$TMP/page-gh-calls" \
  PR_TEST_SCENARIO=paginated _ht_pr_cache_rows example/repo)"
[[ "$(PAGE_ROWS="$page_rows" python3 -c 'import json,os; print(len(json.loads(os.environ["PAGE_ROWS"])))')" = 101 ]]
[[ "$(grep -cF 'api repos/example/repo/pulls?' "$TMP/page-gh-calls")" = 3 ]]
echo 'PASS cache paginates every open pull request once for all readers'

merge_cache="$TMP/merge-pr-cache"
merge_rows="$(AGENT_PR_CACHE_DIR="$merge_cache" PR_TEST_SCENARIO=deployed _ht_pr_cache_rows example/repo)"
MERGE_ROWS="$merge_rows" python3 - <<'PYEOF'
import json, os
rows = json.loads(os.environ["MERGE_ROWS"])
assert len(rows) == 1 and rows[0]["state"] == "MERGED"
assert rows[0]["mergedAt"] == "2026-09-18T20:00:00Z"
assert {"number", "title", "branch", "author"} <= set(rows[0])
PYEOF
echo 'PASS cache keeps recent merges with the required identity fields'

rate_cache="$TMP/rate-pr-cache"
: > "$TMP/rate-gh-calls"
set +e
AGENT_PR_CACHE_DIR="$rate_cache" GH_CALL_LOG="$TMP/rate-gh-calls" \
  PR_TEST_SCENARIO=rate-limit _ht_pr_cache_rows example/repo >/dev/null 2>"$TMP/rate-first.err"
first_rate_rc=$?
AGENT_PR_CACHE_DIR="$rate_cache" GH_CALL_LOG="$TMP/rate-gh-calls" \
  PR_TEST_SCENARIO=pending _ht_pr_cache_rows example/repo >/dev/null 2>"$TMP/rate-second.err"
second_rate_rc=$?
set -e
[[ "$first_rate_rc" = 75 && "$second_rate_rc" = 75 ]]
[[ "$(wc -l < "$TMP/rate-gh-calls")" = 2 ]]
[[ -s "$rate_cache/example__repo.json.rate-limit" ]]
echo 'PASS rate-limit reset is shared and blocks later GitHub calls until reset'

orphan_log="$TMP/orphan.log"
run_gate orphan >/dev/null 2>"$orphan_log"
run_gate orphan >/dev/null 2>>"$orphan_log"
[[ "$(grep -cF 'orphaned PR #4 (retired-dev/htpr-4) has no owning agent' "$orphan_log")" = 1 ]]
echo 'PASS unassigned PR with no active owner blocks nobody and logs once per day'

oldest="$(run_gate oldest)"
[[ "$(printf '%s\n' "$oldest" | sed -n '1p')" == *'"number": 9'* ]]
[[ "$(printf '%s\n' "$oldest" | grep -c .)" = 2 ]]
echo 'PASS every owed PR is returned oldest first'

mixed="$(run_gate stale-red-green)"
MIXED="$mixed" python3 - <<'PYEOF'
import json, os
rows = [json.loads(line) for line in os.environ["MIXED"].splitlines()]
assert rows[0]["number"] == 9 and rows[0]["action"] == "fix"
assert rows[0]["pickup_slot"] is True and rows[0]["unfixable"] is False
assert rows[1]["number"] == 10 and rows[1]["pickup_slot"] is True
PYEOF
echo 'PASS old red PR remains first in the owned PR queue'

# Run the real pickup path in dry-run mode. Any one owned PR consumes the tick.
cat > "$TMP/home/.config/hypertask-agents/dev-1.conf" <<EOF
AGENT_ID="agent-1"
AGENT_NAME="Dev One"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$TMP/token"
WATCH_SECTIONS="Bugs"
MODEL_CLI="$TMP/bin/claude --print --model sonnet"
SECOND_OPINION_CLI="$TMP/bin/reviewer"
BOARD_CLI="$TMP/bin/hypertask"
PR_REPO="example/repo"
AGENT_REPO="$TMP/repo"
SKILLS_INDEX=""
CLAIM_UNASSIGNED="no"
TRIAGE="no"
EOF
state="$TMP/home/.local/state/agent-board-poll"
mkdir -p "$state"
rate_log_before="$([ ! -f "$state/dev-1.log" ] || wc -l < "$state/dev-1.log")"
rate_log_before="${rate_log_before:-0}"
rate_run="$(AGENT_PR_CACHE_DIR="$TMP/tick-rate-cache" PR_TEST_SCENARIO=rate-limit \
  BOARD_TEST_SCENARIO=no-emergency HOME="$TMP/home" PATH="$TMP/bin:$PATH" \
  COMPANY_SKILLS_DIR="$TMP/company" "$ROOT/scripts/agent-board-poll" --dry-run dev-1)"
[[ "$rate_run" != *'bound to PR'* && "$rate_run" == *'would pick up HTPR-2'* ]]
[[ "$(tail -n "+$((rate_log_before + 1))" "$state/dev-1.log" | grep -c '^github rate limited until ' || true)" = 1 ]]
echo 'PASS GitHub rate limit logs once, binds no PR, and does not fail the tick'

multi_run="$(AGENT_PR_CACHE_DIR="$TMP/dry-pr-cache-multi_run" PR_TEST_SCENARIO=oldest HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" "$ROOT/scripts/agent-board-poll" --dry-run dev-1)"
[[ "$multi_run" == *'bound to PR #9 for HTPR-9: red'* ]]
[[ "$multi_run" == *'would run a structured fix round for PR #9; no new ticket was ranked.'* ]]
[[ "$multi_run" != *'would pick up HTPR-2'* ]]
[[ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["prs"]))' "$state/dev-1.blocked")" = 1 ]]
echo 'PASS oldest owned red PR is the only work considered'

rm -rf "$state/pr-live-cache"
two_green_run="$(AGENT_PR_CACHE_DIR="$TMP/dry-pr-cache-two_green_run" PR_TEST_SCENARIO=two-green BOARD_TEST_SCENARIO=no-emergency HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" "$ROOT/scripts/agent-board-poll" --dry-run dev-1)"
[[ "$two_green_run" == *'bound to PR #9 (awaiting-review); no new ticket was ranked.'* ]]
[[ "$two_green_run" != *'would pick up'* ]]
echo 'PASS even the first green PR consumes the tick'

rm -rf "$state/pr-live-cache"
stale_red_green_run="$(AGENT_PR_CACHE_DIR="$TMP/dry-pr-cache-stale_red_green_run" PR_TEST_SCENARIO=stale-red-green BOARD_TEST_SCENARIO=no-emergency HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" "$ROOT/scripts/agent-board-poll" --dry-run dev-1)"
[[ "$stale_red_green_run" == *'would run a structured fix round for PR #9'* ]]
[[ "$stale_red_green_run" != *'would pick up'* ]]
echo 'PASS old red PR remains bound instead of aging out'

rm -rf "$state/pr-live-cache"
pending_run="$(AGENT_PR_CACHE_DIR="$TMP/dry-pr-cache-pending_run" PR_TEST_SCENARIO=pending BOARD_TEST_SCENARIO=no-emergency HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" "$ROOT/scripts/agent-board-poll" --dry-run dev-1)"
[[ "$pending_run" == *'bound to PR #1 (pending); no new ticket was ranked.'* ]]
[[ "$pending_run" != *'would pick up'* ]]
echo 'PASS one pending PR blocks normal polling pickup'

rm -rf "$state/pr-live-cache"
event_run="$(AGENT_PR_CACHE_DIR="$TMP/dry-pr-cache-event_run" PR_TEST_SCENARIO=pending BOARD_TEST_SCENARIO=no-emergency HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" "$ROOT/scripts/agent-board-poll" --dry-run --ticket HTPR-2 dev-1)"
[[ "$event_run" == *'bound to PR #1 (pending); no new ticket was ranked.'* ]]
[[ "$event_run" != *'would pick up HTPR-2'* ]]
echo 'PASS exact-ticket event pickup obeys the same PR binding'

rm -rf "$state/pr-live-cache"
green_run="$(AGENT_PR_CACHE_DIR="$TMP/dry-pr-cache-green_run" PR_TEST_SCENARIO=green BOARD_TEST_SCENARIO=no-emergency HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" "$ROOT/scripts/agent-board-poll" --dry-run dev-1)"
[[ "$green_run" == *'bound to PR #1 (awaiting-review); no new ticket was ranked.'* ]]
[[ "$green_run" != *'would pick up'* ]]
echo 'PASS one green PR blocks normal pickup'

rm -rf "$state/pr-live-cache"
undeployed_run="$(AGENT_PR_CACHE_DIR="$TMP/dry-pr-cache-undeployed_run" PR_TEST_SCENARIO=undeployed BOARD_TEST_SCENARIO=no-emergency HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" "$ROOT/scripts/agent-board-poll" --dry-run dev-1)"
[[ "$undeployed_run" == *'bound to PR #1 (in-qa); no new ticket was ranked.'* ]]
[[ "$undeployed_run" != *'would pick up'* ]]
echo 'PASS merged PR remains bound through QA'

rm -rf "$state/pr-live-cache"
qa_passed_run="$(AGENT_PR_CACHE_DIR="$TMP/dry-pr-cache-qa_passed_run" PR_TEST_SCENARIO=qa-passed BOARD_TEST_SCENARIO=no-emergency HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" "$ROOT/scripts/agent-board-poll" --dry-run dev-1)"
[[ "$qa_passed_run" == *'would pick up HTPR-2'* ]]
echo 'PASS QA pass releases the next ticket'

rm -rf "$state/pr-live-cache"
red_run="$(AGENT_PR_CACHE_DIR="$TMP/dry-pr-cache-red_run" PR_TEST_SCENARIO=red BOARD_TEST_SCENARIO=no-emergency HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" "$ROOT/scripts/agent-board-poll" --dry-run dev-1)"
[[ "$red_run" == *'would run a structured fix round for PR #1; no new ticket was ranked.'* ]]
[[ "$red_run" != *'would pick up HTPR-2'* ]]
echo 'PASS one red PR starts only its structured repair path'

run_actual() {
  local scenario="$1" board_scenario="${2:-no-emergency}"
  AGENT_PR_CACHE_DIR="$TMP/actual-pr-cache-$scenario" PR_TEST_SCENARIO="$scenario" \
    BOARD_TEST_SCENARIO="$board_scenario" RUN_COOLDOWN_SECONDS=0 \
    HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" \
    BOARD_CALL_LOG="$TMP/board-calls" BOARD_COMMENT_LOG="$TMP/board-comments" \
    WORKER_LOG="$TMP/worker-prompts" REVIEWER_LOG="$TMP/reviewer-prompts" \
    GH_CALL_LOG="$TMP/gh-calls" ACTION_LOG="$TMP/actions" UNASSIGNED_MARKER="$TMP/unassigned" \
    SECOND_OPINION_RESULT="${SECOND_OPINION_RESULT:-}" WORKER_COMMIT="${WORKER_COMMIT:-no}" \
    WORKER_EXIT="${WORKER_EXIT:-0}" \
    "$ROOT/scripts/agent-board-poll" --once dev-1 >/dev/null
}

for hold_case in blocked human owner-hold; do
  rm -rf "$state/pr-live-cache"
  rm -f "$TMP/worker-prompts"
  log_before="$(wc -l < "$state/dev-1.log")"
  run_actual red "$hold_case"
  [ ! -s "$TMP/worker-prompts" ]
  tail -n "+$((log_before + 1))" "$state/dev-1.log" | grep -qF 'is not eligible for a fix round:'
done
echo 'PASS blocked, human-assigned, and owner-held tickets start no fix or new-ticket run'

rm -rf "$state/run-records" "$state/pr-live-cache"
rm -f "$state/dev-1.released-prs" "$state/dev-1.runs" "$TMP/board-comments" "$TMP/worker-prompts" "$TMP/actions" "$state/host-alarms.json"
run_actual prep-fail
run_actual prep-fail
run_actual prep-fail
record="$state/run-records/dev-1-HTPR-1.json"
RECORD="$record" python3 -c 'import json,os; r=json.load(open(os.environ["RECORD"])); assert r["consecutive_infra_errors"] == 3 and "fix_rounds" not in r'
[ ! -s "$TMP/worker-prompts" ]
! grep -q '^Fix round' "$TMP/board-comments" 2>/dev/null
[[ "$(grep -c 'explain: infra error preparing PR #1 for HTPR-1' "$state/dev-1.log")" -ge 3 ]]
STATE="$state/host-alarms.json" python3 -c 'import json,os; s=json.load(open(os.environ["STATE"])); a=s["alarms"]["pr-fix-infra-example-repo-1"]; assert a["active"] is True and a["bug_ticket"] == "AGTE-999"'
echo 'PASS three preparation failures count as infra errors, alarm once, and start no work'

rm -rf "$state/run-records" "$state/pr-live-cache"
rm -f "$state/dev-1.released-prs" "$state/dev-1.runs" "$TMP/board-comments" "$TMP/worker-prompts"
run_actual qa-fail
record="$state/run-records/dev-1-HTPR-1.json"
RECORD="$record" python3 -c 'import json,os; r=json.load(open(os.environ["RECORD"])); assert r["fix_rounds"] == 1 and r["last_qa_failure_id"] == "qa-77"'
grep -qF 'Fix round 1: no push: worker made no commit. Trigger: QA fail | Handoff: Dev One, checkout fails after deploy.' "$TMP/board-comments"
grep -qF 'The original PR is already merged because QA found this failure.' "$TMP/worker-prompts"
run_actual qa-fail
RECORD="$record" python3 -c 'import json,os; assert json.load(open(os.environ["RECORD"]))["fix_rounds"] == 1'
[[ "$(grep -c '^Fix round' "$TMP/board-comments")" = 1 ]]
grep -qF 'pr view 1 --repo example/repo --json baseRefName,headRefName' "$TMP/gh-calls"
[ -z "$(git ls-remote --heads "$TMP/wrong-origin.git" production)" ]
echo 'PASS QA failure increments only after the worker exits and fetches GitHub refs instead of origin'

rm -rf "$state/run-records" "$state/pr-live-cache"
rm -f "$state/dev-1.released-prs" "$state/dev-1.runs" "$TMP/board-comments" "$TMP/worker-prompts" "$TMP/reviewer-prompts" "$TMP/actions" "$TMP/unassigned"
run_actual red
run_actual red
record="$state/run-records/dev-1-HTPR-1.json"
RECORD="$record" python3 -c 'import json,os; assert json.load(open(os.environ["RECORD"]))["fix_rounds"] == 2'
[[ "$(grep -c '^Fix round' "$TMP/board-comments")" = 2 ]]
echo 'PASS red PR starts repair runs and persists each fix round'

SECOND_OPINION_RESULT='not fixable here because the repository secret is owner-only.' run_actual red
RECORD="$record" python3 -c 'import json,os; r=json.load(open(os.environ["RECORD"])); assert r["fix_rounds"] == 2 and r["second_opinion_round"] == 2'
grep -qF 'Second opinion: not fixable here because the repository secret is owner-only.' "$TMP/board-comments"
grep -qF 'Review PR #1 for HTPR-1 as an independent second opinion.' "$TMP/reviewer-prompts"
python3 - "$TMP/actions" <<'PYEOF'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
need = ["gh pr comment 1", "board task update HTPR-1 --labels label-needs-human",
        "board task move HTPR-1 --section Review",
        "board task unassign HTPR-1 --assignee agent-1", "gh pr close 1"]
positions = [next(i for i, line in enumerate(lines) if value in line) for value in need]
assert positions == sorted(positions), (lines, positions)
PYEOF
[[ "$(awk -F '\t' '$1 == "example/repo" && $2 == "1" && $3 == "HTPR-1" { print "yes" }' "$state/dev-1.released-prs")" = yes ]]
[[ -e "$TMP/remote.git/refs/heads/agent/dev-1-htpr-1" ]]
echo 'PASS unfixable second opinion releases in order, closes the PR, and preserves its branch'

rm -rf "$state/pr-live-cache"
released_run="$(AGENT_PR_CACHE_DIR="$TMP/dry-pr-cache-released_run" PR_TEST_SCENARIO=red BOARD_TEST_SCENARIO=no-emergency HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" "$ROOT/scripts/agent-board-poll" --dry-run dev-1)"
[[ "$released_run" != *'bound to PR #1'* ]]
echo 'PASS released PR state prevents eventual GitHub results from rebinding'

rm -rf "$state/run-records" "$state/pr-live-cache"
rm -f "$state/dev-1.released-prs" "$TMP/board-comments" "$TMP/worker-prompts" "$TMP/actions"
WORKER_EXIT=42 run_actual red
record="$state/run-records/dev-1-HTPR-1.json"
RECORD="$record" python3 -c 'import json,os; assert json.load(open(os.environ["RECORD"]))["fix_rounds"] == 1'
grep -qF 'Fix round 1: no push: worker exited 42.' "$TMP/board-comments"
echo 'PASS an exited failing worker counts one round and reports why nothing was pushed'

rm -rf "$state/run-records" "$state/pr-live-cache"
rm -f "$TMP/board-comments" "$TMP/worker-prompts" "$TMP/actions"
old_head="$(git --git-dir="$TMP/remote.git" rev-parse refs/heads/agent/dev-1-htpr-1)"
WORKER_COMMIT=yes run_actual red
new_head="$(git --git-dir="$TMP/remote.git" rev-parse refs/heads/agent/dev-1-htpr-1)"
[ "$new_head" != "$old_head" ]
grep -Eq 'Fix round 1: pushed commit [0-9a-f]{12}\.' "$TMP/board-comments"
echo 'PASS a completed worker round pushes through the PR repository URL and reports its commit'

rm -rf "$state/run-records" "$state/pr-live-cache"
rm -f "$TMP/board-comments" "$TMP/worker-prompts" "$TMP/reviewer-prompts" "$TMP/actions"
SECOND_OPINION_RESULT='deletion intended' run_actual revert-only
record="$state/run-records/dev-1-HTPR-1.json"
RECORD="$record" python3 -c 'import json,os; r=json.load(open(os.environ["RECORD"])); assert r["revert_guard_verdict"] == "deletion intended" and "fix_rounds" not in r'
[ ! -s "$TMP/worker-prompts" ]
grep -qF 'Second opinion: deletion intended' "$TMP/board-comments"
grep -qF 'Deleted hunks:' "$TMP/reviewer-prompts"
grep -qF 'Origin commits:' "$TMP/reviewer-prompts"
grep -qF 'gh api -X POST repos/example/repo/issues/1/labels -f labels[]=intentional-revert' "$TMP/actions"
grep -qF 'gh run rerun 88 --repo example/repo --failed' "$TMP/actions"
echo 'PASS lone revert-guard failure gets immediate deletion review, label, and rerun without a fix round'

rm -rf "$state/run-records" "$state/pr-live-cache"
rm -f "$TMP/board-comments" "$TMP/worker-prompts" "$TMP/reviewer-prompts" "$TMP/actions"
SECOND_OPINION_RESULT='deletion not intended' run_actual revert-only
grep -qF 'Second opinion: restore app, do not delete them' "$TMP/board-comments"
grep -qF 'Second-opinion verdict: restore app, do not delete them' "$TMP/worker-prompts"
grep -qF 'Fix round 1: no push: worker made no commit.' "$TMP/board-comments"
echo 'PASS unintended deletion verdict becomes the next fix brief and ticket comment'

rm -f "$state/dev-1.released-prs" "$TMP/unassigned" "$TMP/opened-marker"
rm -rf "$state/pr-live-cache"
AGENT_PR_CACHE_DIR="$TMP/record-open-pr-cache" PR_TEST_SCENARIO=record-open \
  BOARD_TEST_SCENARIO=no-emergency RUN_COOLDOWN_SECONDS=0 MODEL_OPEN_MARKER="$TMP/opened-marker" \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" \
  "$ROOT/scripts/agent-board-poll" --once dev-1 >/dev/null
[[ "$(awk -F '\t' '$1 == "example/repo" && $2 == "8" && $3 == "HTPR-1" { print "yes" }' "$state/dev-1.opened-prs")" = yes ]]
echo 'PASS runner persists a PR first seen after its ticket run'

echo '50 one-ticket-until-live checks passed'
