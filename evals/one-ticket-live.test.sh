#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.config/hypertask-agents" "$TMP/company" "$TMP/repo"
printf 'test\n' > "$TMP/company/INDEX.md"
printf '1\n' > "$TMP/company/VERSION"
printf 'token\n' > "$TMP/token"

cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
[ -z "${MODEL_OPEN_MARKER:-}" ] || touch "$MODEL_OPEN_MARKER"
exit 0
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
scenario="${PR_TEST_SCENARIO:-pending}"
[ -z "${GH_CALL_LOG:-}" ] || printf '%s\n' "$*" >> "$GH_CALL_LOG"
if [ "$1 $2" = "pr list" ]; then
  if printf ' %s ' "$*" | grep -q ' --search '; then
    if [ "$scenario" = "record-open" ] && [ -e "${MODEL_OPEN_MARKER:-/no-marker}" ]; then
      printf '[{"number":8,"title":"HTPR-1 fix","headRefName":"legacy/fix-1"}]\n'
    else
      printf '[]\n'
    fi
    exit 0
  fi
  if [ "$scenario" = "oldest" ]; then
    cat <<JSON
[{"number":9,"state":"OPEN","url":"https://github.test/pull/9","title":"HTPR-9 old","body":"","headRefName":"agent/dev-1-htpr-9","createdAt":"2026-01-01T00:00:00Z"},{"number":10,"state":"OPEN","url":"https://github.test/pull/10","title":"HTPR-10 new","body":"","headRefName":"agent/dev-1-htpr-10","createdAt":"2026-01-02T00:00:00Z"}]
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
  elif [ "$scenario" = "record-open" ]; then
    printf '[]\n'
  else
    state="OPEN"; [ "$scenario" = "deployed" ] || [ "$scenario" = "undeployed" ] || [ "$scenario" = "fallback" ] || state="OPEN"
    if [ "$scenario" = "deployed" ] || [ "$scenario" = "undeployed" ] || [ "$scenario" = "fallback" ]; then state="MERGED"; fi
    printf '[{"number":1,"state":"%s","url":"https://github.test/pull/1","title":"HTPR-1 fix","body":"https://app.hypertask.ai/detail/project-15/1","headRefName":"agent/dev-1-htpr-1","author":{"login":"dev-one"},"createdAt":"2026-01-01T00:00:00Z"}]\n' "$state"
  fi
  exit 0
fi
if [ "$1 $2" = "pr view" ]; then
  number="$3"
  if [ "$scenario" = "deployed" ] || [ "$scenario" = "undeployed" ] || [ "$scenario" = "fallback" ]; then
    printf '{"state":"MERGED","baseRefName":"production","mergedAt":"2026-01-02T00:00:00Z","mergeCommit":{"oid":"merge%s"}}\n' "$number"
    exit 0
  fi
  if printf ' %s ' "$*" | grep -q ' state,baseRefName,mergedAt,mergeCommit '; then
    printf '{"state":"OPEN","baseRefName":"production","mergedAt":null,"mergeCommit":null}\n'
    exit 0
  fi
  checks='[{"name":"ci-tests","status":"IN_PROGRESS","conclusion":"","detailsUrl":"https://github.test/actions/runs/77/job/1"}]'
  reviews='[]'
  comments='[]'
  if [ "$scenario" = "red" ] || [ "$scenario" = "oldest" ] || [ "$scenario" = "qa-claim" ] || [ "$scenario" = "orphan" ] || [ "$scenario" = "author-owned" ] || [ "$scenario" = "custom-prefix" ]; then
    checks='[{"name":"ci-tests","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.test/actions/runs/77/job/1"},{"name":"revert-guard","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.test/actions/runs/77/job/2"},{"name":"pr-title","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.test/actions/runs/77/job/3"}]'
    comments='[{"author":{"login":"claude-review"},"body":"CONCERNS: preserve the existing authorization check."}]'
  fi
  printf '{"state":"OPEN","url":"https://github.test/pull/%s","title":"HTPR-%s fix","body":"","headRefName":"agent/dev-1-htpr-%s","headRefOid":"head%s","baseRefName":"production","createdAt":"2026-01-01T00:00:00Z","statusCheckRollup":%s,"reviews":%s,"comments":%s}\n' "$number" "$number" "$number" "$number" "$checks" "$reviews" "$comments"
  exit 0
fi
if [ "$1" = "api" ]; then
  endpoint="$2"
  case "$endpoint" in
    */pulls/*/comments*) printf '[]\n' ;;
    */compare/*) printf '{"status":"ahead"}\n' ;;
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
if [[ "$url" == *'/mcp/tasks?'* ]]; then
  emergency_labels='[{"name":"emergency"}]'
  [ "${BOARD_TEST_SCENARIO:-}" != "no-emergency" ] || emergency_labels='[]'
  cat <<JSON
{"tasks":[{"id":"task-1","ticketNumber":"HTPR-1","section":"Bugs","title":"PR ticket","description":"fix it","assignees":[{"agent":{"id":"agent-1"}}],"labels":[],"commentCount":0},{"id":"task-2","ticketNumber":"HTPR-2","section":"Bugs","title":"Emergency","description":"urgent fix","assignees":[{"agent":{"id":"agent-1"}}],"labels":$emergency_labels,"commentCount":0},{"id":"task-3","ticketNumber":"HTPR-3","section":"Bugs","title":"Claimed in a comment","description":"fix it","assignees":[],"labels":[],"commentCount":1},{"id":"task-4","ticketNumber":"HTPR-4","section":"Bugs","title":"Another owner's ticket","description":"fix it","assignees":[{"agent":{"id":"agent-2"}}],"labels":[],"commentCount":0},{"id":"task-5","ticketNumber":"HTPR-5","section":"Bugs","title":"Legacy branch ticket","description":"fix it","assignees":[{"agent":{"id":"agent-1"}}],"labels":[],"commentCount":0}]}
JSON
elif [[ "$url" == *'task_id=task-3'* ]]; then
  printf '{"comments":[{"agent":{"id":"agent-1","displayName":"Dev One"},"text":"<p>Claimed.</p>"}]}\n'
else
  printf '{"comments":[]}\n'
fi
printf '\n200'
EOF
chmod +x "$TMP/bin/"*

# Source only the adapter for focused LIVE and feedback tests. The fake board
# API above is used through the real _ht_get parser.
PATH="$TMP/bin:$PATH"
HOME="$TMP/home"
PR_REPO="example/repo"
# shellcheck source=/dev/null
. "$ROOT/adapters/hypertask/adapter.sh"
die() { printf 'die: %s %s\n' "$*" >&2; return 1; }

cat > "$TMP/home/.config/hypertask-agents/dev-1.conf" <<'EOF'
AGENT_SLUG="dev-1"
AGENT_ID="agent-1"
AGENT_KIND="dev"
BOARD_ADAPTER="hypertask"
PR_REPO="example/repo"
GITHUB_LOGIN="dev-one"
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
  PR_TEST_SCENARIO="$scenario" PR_BRANCH_PREFIX="${4:-}" \
    adapter_pr_gate "$TMP/token" 15 agent-1 "$name" "$slug" "$cache" \
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

pending="$(run_gate pending)"
[[ "$pending" == *'"action": "wait"'* && "$pending" == *'"state": "checks-pending"'* ]]
echo 'PASS pending PR waits without inventing work'

undeployed="$(run_gate undeployed)"
[[ "$undeployed" == *'"state": "merged-undeployed"'* ]]
echo 'PASS merged but undeployed PR remains a blocker'

[[ -z "$(run_gate deployed)" ]]
echo 'PASS successful Production deployment releases pickup'

[[ -z "$(run_gate fallback)" ]]
fallback_state="$(PR_TEST_SCENARIO=fallback _ht_pr_live_state example/repo 1 "$TMP/fallback-direct")"
[[ "$fallback_state" == *'fallback: merged and base contains merge commit (no deployment records)'* ]]
echo 'PASS repository without deployment records uses the documented fallback'

: > "$TMP/gh-calls"
cache_dir="$TMP/cache-proof"
GH_CALL_LOG="$TMP/gh-calls" PR_TEST_SCENARIO=deployed _ht_pr_live_state example/repo 1 "$cache_dir" >/dev/null
first_calls="$(wc -l < "$TMP/gh-calls")"
GH_CALL_LOG="$TMP/gh-calls" PR_TEST_SCENARIO=deployed _ht_pr_live_state example/repo 1 "$cache_dir" >/dev/null
[[ "$(wc -l < "$TMP/gh-calls")" = "$first_calls" ]]
echo 'PASS LIVE answer is cached per PR for 60 seconds'

qa_claim="$(run_gate qa-claim qa-1 'QA One')"
[[ -z "$qa_claim" ]]
echo 'PASS QA claim comment does not attribute another agent branch'

assigned_owned="$(run_gate author-owned)"
[[ "$assigned_owned" == *'"number": 5'* ]]
echo 'PASS current ticket assignment attributes a legacy branch PR'

custom_prefix="$(run_gate custom-prefix dev-2 'Dev Two' 'cursor-dev-2/')"
[[ "$custom_prefix" == *'"number": 6'* ]]
echo 'PASS configured branch prefix attributes an owned PR'

printf 'example/repo\t7\tHTPR-7\n' > "$TMP/home/.local/state/agent-board-poll/dev-1.opened-prs"
state_owned="$(run_gate state-owned)"
[[ "$state_owned" == *'"number": 7'* ]]
echo 'PASS runner state attributes a legacy branch PR'

shared_author="$(run_gate shared-author 2>/dev/null)"
[[ -z "$shared_author" ]]
echo 'PASS shared GitHub authorship does not transfer PR ownership'

orphan_log="$TMP/orphan.log"
run_gate orphan >/dev/null 2>"$orphan_log"
run_gate orphan >/dev/null 2>>"$orphan_log"
[[ "$(grep -cF 'orphaned PR #4 (agent/retired-dev-htpr-4) has no owning agent' "$orphan_log")" = 1 ]]
echo 'PASS unassigned PR with no active owner blocks nobody and logs once per day'

oldest="$(run_gate oldest)"
[[ "$(printf '%s\n' "$oldest" | sed -n '1p')" == *'"number": 9'* ]]
[[ "$(printf '%s\n' "$oldest" | grep -c .)" = 2 ]]
echo 'PASS every owed PR is returned oldest first'

# Run the real pickup path in dry-run mode. One pending PR blocks ordinary work
# but the emergency row remains eligible.
cat > "$TMP/home/.config/hypertask-agents/dev-1.conf" <<EOF
AGENT_ID="agent-1"
AGENT_NAME="Dev One"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
TOKEN_FILE="$TMP/token"
WATCH_SECTIONS="Bugs"
MODEL_CLI="claude --print --model sonnet"
BOARD_CLI="$TMP/bin/hypertask"
PR_REPO="example/repo"
AGENT_REPO="$TMP/repo"
SKILLS_INDEX=""
CLAIM_UNASSIGNED="no"
TRIAGE="no"
EOF
multi_run="$(PR_TEST_SCENARIO=oldest HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" "$ROOT/scripts/agent-board-poll" --dry-run dev-1)"
[[ "$multi_run" == *'owned non-live PRs oldest first: rank 1 #9 HTPR-9 (red), rank 2 #10 HTPR-10 (red)'* ]]
[[ "$multi_run" == *'would pick up HTPR-9'* ]]
[[ "$multi_run" != *'would pick up HTPR-2'* ]]
[[ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["prs"]))' "$TMP/home/.local/state/agent-board-poll/dev-1.blocked")" = 2 ]]
echo 'PASS multiple debts list every PR, work oldest first, and block new claims'

pending_run="$(PR_TEST_SCENARIO=pending HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" "$ROOT/scripts/agent-board-poll" --dry-run dev-1)"
[[ "$pending_run" == *'would pick up HTPR-2'* ]]
[[ "$pending_run" != *'would pick up HTPR-1'* ]]
echo 'PASS emergency ticket is the only pickup that bypasses an owed PR'

rm -rf "$TMP/home/.local/state/agent-board-poll/pr-live-cache"
undeployed_run="$(PR_TEST_SCENARIO=undeployed BOARD_TEST_SCENARIO=no-emergency HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" "$ROOT/scripts/agent-board-poll" --dry-run dev-1)"
[[ "$undeployed_run" == *'waiting on PR #1: merged-undeployed; nothing was claimed.'* ]]
[[ "$undeployed_run" != *'would pick up'* ]]
echo 'PASS merged but undeployed PR claims no new ticket'

rm -rf "$TMP/home/.local/state/agent-board-poll/pr-live-cache"
deployed_run="$(PR_TEST_SCENARIO=deployed BOARD_TEST_SCENARIO=no-emergency HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" "$ROOT/scripts/agent-board-poll" --dry-run dev-1)"
[[ "$deployed_run" == *'would pick up HTPR-1'* ]]
[[ "$deployed_run" == *"skip  HTPR-3: newest comment 0 is by this agent's own identity, so it cannot trigger another run"* ]]
[[ "$deployed_run" == *'skip  HTPR-4: assigned to another owner and neither assigned nor mentioned to this agent'* ]]
echo 'PASS deployed PR releases the next ticket and explains every ineligible candidate'

# Six recent failures for the synthetic PR key do not stop the PR-fix path.
state="$TMP/home/.local/state/agent-board-poll"
mkdir -p "$state"
: > "$state/dev-1.attempts"
for _ in 1 2 3 4 5 6; do printf 'pr-1 %s cursor-agent failed\n' "$(date +%s)" >> "$state/dev-1.attempts"; done
rm -rf "$state/pr-live-cache"
red_run="$(PR_TEST_SCENARIO=red HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" "$ROOT/scripts/agent-board-poll" --dry-run dev-1)"
[[ "$red_run" == *'would pick up HTPR-1'* ]]
[[ "$red_run" == *'no ticket attempts, triage, or escalation; ticket cooldown still applies'* ]]
echo 'PASS red PR ignores failed attempts while retaining the ticket cooldown'

rm -f "$TMP/opened-marker"
PR_TEST_SCENARIO=record-open BOARD_TEST_SCENARIO=no-emergency MODEL_OPEN_MARKER="$TMP/opened-marker" \
  HOME="$TMP/home" PATH="$TMP/bin:$PATH" COMPANY_SKILLS_DIR="$TMP/company" \
  "$ROOT/scripts/agent-board-poll" --once dev-1 >/dev/null
[[ "$(awk -F '\t' '$1 == "example/repo" && $2 == "8" && $3 == "HTPR-1" { print "yes" }' "$state/dev-1.opened-prs")" = yes ]]
echo 'PASS runner persists a PR first seen after its ticket run'

echo '20 one-ticket-until-live checks passed'
