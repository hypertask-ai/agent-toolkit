#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-34s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-34s %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/bin" "$TMP/home/.config/hypertask" "$TMP/home/.config/agents" "$TMP/company" "$TMP/repo"
printf '{"token":"owner-token"}\n' > "$TMP/home/.config/hypertask/config.json"
printf '# company pack\n' > "$TMP/company/INDEX.md"
printf 'test\n' > "$TMP/company/VERSION"
printf 'agent-token\n' > "$TMP/token"

cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
token=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "--token" ]; then token="${args[$((i + 1))]:-}"; fi
done
if [ -z "$token" ]; then token="owner-token"; fi
if [[ " $* " = *" comment add "* ]]; then touch "$BOARD_POSTED"; fi
printf '%s\n' "$token"
EOF
for name in ht htbot; do
  cat > "$TMP/bin/$name" <<'EOF'
#!/usr/bin/env bash
exec hypertask "$@"
EOF
done
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *'/mcp/tasks?'*) cat "$BOARD_JSON"; printf '\n200' ;;
  *'/mcp/comments?'*) printf '{"comments":[]}\n200' ;;
  *) printf '{}\n200' ;;
esac
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CAPTURE"
if [ "${1:-} ${2:-}" = "pr view" ] && [[ " $* " = *' --json state,labels '* ]]; then
  printf '%s\n' "${GH_PR_STATE:-OPEN}"
  [ -z "${GH_PR_LABEL:-}" ] || printf '%s\n' "$GH_PR_LABEL"
elif [ "${1:-} ${2:-}" = "pr create" ]; then
  printf 'https://github.com/example/repo/pull/7\n'
elif [ "${1:-}" = "api" ] && [ "${4:-}" = "repos/example/repo/issues/7/labels" ]; then
  cat > "$GH_LABEL_BODY"
  printf '{}\n'
else
  printf '[]\n'
fi
EOF
cat > "$TMP/bin/provider" <<'EOF'
#!/usr/bin/env bash
command -v hypertask > "$RESOLVED_CAPTURE"
command -v ht >> "$RESOLVED_CAPTURE"
command -v htbot >> "$RESOLVED_CAPTURE"
command -v gh >> "$RESOLVED_CAPTURE"
hypertask --json status > "$TOKEN_CAPTURE"
gh pr create --repo example/repo --title test --body test > "$PR_CREATE_OUTPUT"
cat "$AGENT_OPENED_PRS" > "$PR_OWNERSHIP_CAPTURE"
printf 'after-pr-create\n' >> "$GH_CAPTURE"
if gh pr merge 7 > /dev/null 2> "$MANUAL_MERGE_ERROR"; then
  printf '0\n' > "$MANUAL_MERGE_RC"
else
  printf '%s\n' "$?" > "$MANUAL_MERGE_RC"
fi
gh pr merge --repo example/repo --auto --squash 7 >/dev/null
GH_PR_LABEL=valentin-review gh pr merge --repo example/repo --disable-auto 7 >/dev/null
if gh api -X PUT repos/example/repo/pulls/7/merge > /dev/null 2> "$API_MERGE_ERROR"; then
  printf '0\n' > "$API_MERGE_RC"
else
  printf '%s\n' "$?" > "$API_MERGE_RC"
fi
if gh api graphql -f 'query=mutation { mergePullRequest(input: {}) { clientMutationId } }' \
    > /dev/null 2> "$GRAPHQL_MERGE_ERROR"; then
  printf '0\n' > "$GRAPHQL_MERGE_RC"
else
  printf '%s\n' "$?" > "$GRAPHQL_MERGE_RC"
fi
if GH_PR_LABEL=valentin-review gh pr comment 7 --body blocked > /dev/null 2> "$PROTECTED_PR_ERROR"; then
  printf '0\n' > "$PROTECTED_PR_RC"
else
  printf '%s\n' "$?" > "$PROTECTED_PR_RC"
fi
if GH_PR_LABEL=valentin-review gh api /repos/example/repo/issues/7/comments -f body=blocked \
    > /dev/null 2> "$PROTECTED_API_ERROR"; then
  printf '0\n' > "$PROTECTED_API_RC"
else
  printf '%s\n' "$?" > "$PROTECTED_API_RC"
fi
if GH_PR_STATE=MERGED GH_PR_LABEL=valentin-review gh pr comment 7 --body allowed-after-merge >/dev/null; then
  printf '0\n' > "$MERGED_PR_RC"
else
  printf '%s\n' "$?" > "$MERGED_PR_RC"
fi
if GH_PR_STATE=CLOSED GH_PR_LABEL=valentin-review gh api /repos/example/repo/issues/7/comments -f body=allowed-after-close >/dev/null; then
  printf '0\n' > "$CLOSED_PR_RC"
else
  printf '%s\n' "$?" > "$CLOSED_PR_RC"
fi
EOF
chmod +x "$TMP/bin/"*

CORE_ROOT="$ROOT"
PATH="$TMP/bin:$PATH"
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/core.sh"
core_load_adapter hypertask
adapter_install_board_cli test "$TMP/token" "$TMP/board" "Test Agent"

cat > "$TMP/board.json" <<'EOF'
{"tasks":[{"id":"task-1","ticketNumber":"TEST-1","section":"Bugs","title":"Identity test","description":"Verify the provider identity boundary","assignees":[{"agent":{"id":"agent-1"}}],"labels":[],"commentCount":0}]}
EOF
printf 'test,%s,example/repo,main,,full-ci,needs-checks\n' "$TMP/repo" \
  > "$TMP/home/.config/agents/repos.allow"
cat > "$TMP/home/.config/agents/test.conf" <<EOF
AGENT_ID="agent-1"
AGENT_NAME="Test Agent"
AGENT_KIND="dev"
AGENT_REPO="$TMP/repo"
AGENT_SLUG="test"
BOARD_ADAPTER="hypertask"
BOARD_ID="1"
TOKEN_FILE="$TMP/token"
BOARD_CLI="$TMP/board"
WATCH_SECTIONS="Bugs"
SKILLS_INDEX=""
MODEL_CLI="provider"
PR_REPO="example/repo"
TRIAGE="no"
EOF

run_poll() {
  env -u AGENT_ORIGINAL_PATH -u AGENT_IDENTITY_PATH \
    HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/home/.config/agents" \
    XDG_RUNTIME_DIR= XDG_STATE_HOME="$TMP/state" COMPANY_SKILLS_DIR="$TMP/company" \
    BOARD_JSON="$TMP/board.json" BOARD_POSTED="$TMP/posted" \
    RESOLVED_CAPTURE="$TMP/resolved" TOKEN_CAPTURE="$TMP/received-token" \
    GH_CAPTURE="$TMP/gh-calls" GH_LABEL_BODY="$TMP/gh-label-body" \
    PR_CREATE_OUTPUT="$TMP/pr-create-output" PR_OWNERSHIP_CAPTURE="$TMP/pr-ownership" \
    MANUAL_MERGE_RC="$TMP/manual-merge.rc" \
    MANUAL_MERGE_ERROR="$TMP/manual-merge.error" API_MERGE_RC="$TMP/api-merge.rc" \
    API_MERGE_ERROR="$TMP/api-merge.error" GRAPHQL_MERGE_RC="$TMP/graphql-merge.rc" \
    GRAPHQL_MERGE_ERROR="$TMP/graphql-merge.error" PROTECTED_PR_RC="$TMP/protected-pr.rc" \
    PROTECTED_PR_ERROR="$TMP/protected-pr.error" PROTECTED_API_RC="$TMP/protected-api.rc" \
    PROTECTED_API_ERROR="$TMP/protected-api.error" MERGED_PR_RC="$TMP/merged-pr.rc" \
    CLOSED_PR_RC="$TMP/closed-pr.rc" \
    PATH="$TMP/bin:$PATH" "$ROOT/scripts/agent-board-poll" --once test
}

if run_poll > "$TMP/run.out" 2> "$TMP/run.err" \
   && [ "$(sed -n '1p' "$TMP/resolved")" = "$TMP/state/agent-identity-shims/test/hypertask" ] \
   && [ "$(sed -n '2p' "$TMP/resolved")" = "$TMP/state/agent-identity-shims/test/ht" ] \
   && [ "$(sed -n '3p' "$TMP/resolved")" = "$TMP/state/agent-identity-shims/test/htbot" ] \
   && [ "$(sed -n '4p' "$TMP/resolved")" = "$TMP/state/agent-identity-shims/test/gh" ]; then
  ok identity-shim-first-on-path "board and GitHub commands resolve inside the agent shim"
else
  bad identity-shim-first-on-path "resolved paths: $(paste -sd, "$TMP/resolved" 2>/dev/null || true)"
fi

if GH_CALLS="$TMP/gh-calls" python3 -c '
import os
from pathlib import Path
lines = Path(os.environ["GH_CALLS"]).read_text().splitlines()
create = lines.index("pr create --repo example/repo --title test --body test")
labels = lines.index("api --method POST repos/example/repo/issues/7/labels --input -")
returned = lines.index("after-pr-create")
assert create < labels < returned
' \
   && [ "$(cat "$TMP/gh-label-body")" = '{"labels":["full-ci","needs-checks"]}' ] \
   && [ "$(cat "$TMP/pr-create-output")" = 'https://github.com/example/repo/pull/7' ]; then
  ok identity-shim-pr-labels 'configured labels use the REST endpoint before pull request creation returns'
else
  bad identity-shim-pr-labels "calls=$(cat "$TMP/gh-calls") body=$(cat "$TMP/gh-label-body" 2>/dev/null || true)"
fi

if grep -qxF $'example/repo\t7\tTEST-1' "$TMP/pr-ownership"; then
  ok identity-shim-pr-ownership 'pull request ownership is durable before the create command returns'
else
  bad identity-shim-pr-ownership "opened-prs=$(cat "$TMP/pr-ownership" 2>/dev/null || true)"
fi

if [ "$(cat "$TMP/manual-merge.rc")" -ne 0 ] \
   && [ "$(cat "$TMP/api-merge.rc")" -ne 0 ] \
   && [ "$(cat "$TMP/graphql-merge.rc")" -ne 0 ] \
   && grep -qF 'runners never merge pull requests by hand' "$TMP/manual-merge.error" \
   && grep -qF 'runners never merge pull requests by hand' "$TMP/api-merge.error" \
   && grep -qF 'runners never merge pull requests by hand' "$TMP/graphql-merge.error" \
   && grep -qxF 'pr merge --repo example/repo --auto --squash 7' "$TMP/gh-calls" \
   && grep -qxF 'pr merge --repo example/repo --disable-auto 7' "$TMP/gh-calls" \
   && ! grep -qxF 'pr merge 7' "$TMP/gh-calls" \
   && ! grep -qF 'api -X PUT repos/example/repo/pulls/7/merge' "$TMP/gh-calls" \
   && ! grep -qF 'mergePullRequest' "$TMP/gh-calls"; then
  ok identity-shim-manual-merge-blocked 'CLI, REST, and GraphQL manual merges are refused while auto-merge reaches GitHub'
else
  bad identity-shim-manual-merge-blocked "rc=$(cat "$TMP/manual-merge.rc") calls=$(cat "$TMP/gh-calls")"
fi

if [ "$(cat "$TMP/protected-pr.rc")" -ne 0 ] \
   && [ "$(cat "$TMP/protected-api.rc")" -ne 0 ] \
   && grep -qF 'open PR label valentin-review is manager-only' "$TMP/protected-pr.error" \
   && grep -qF 'open PR label valentin-review is manager-only' "$TMP/protected-api.error" \
   && ! grep -qF 'pr comment 7 --body blocked' "$TMP/gh-calls" \
   && ! grep -qF 'body=blocked' "$TMP/gh-calls"; then
  ok identity-shim-protected-pr-blocked 'CLI and implicit-POST API changes to an open valentin-review PR are refused'
else
  bad identity-shim-protected-pr-blocked "rc=$(cat "$TMP/protected-pr.rc") calls=$(cat "$TMP/gh-calls")"
fi

if [ "$(cat "$TMP/merged-pr.rc")" -eq 0 ] \
   && [ "$(cat "$TMP/closed-pr.rc")" -eq 0 ] \
   && grep -qF 'pr comment 7 --body allowed-after-merge' "$TMP/gh-calls" \
   && grep -qF 'body=allowed-after-close' "$TMP/gh-calls"; then
  ok identity-shim-protection-open-only 'valentin-review protection ends when a PR merges or closes'
else
  bad identity-shim-protection-open-only "merged=$(cat "$TMP/merged-pr.rc") closed=$(cat "$TMP/closed-pr.rc") calls=$(cat "$TMP/gh-calls")"
fi

if cmp -s "$TMP/received-token" <(printf 'agent-token\n'); then
  ok identity-shim-agent-token "a bare board command receives the agent token"
else
  bad identity-shim-agent-token "a bare board command did not receive the agent token"
fi

rm -f "$TMP/token" "$TMP/posted"
if run_poll > "$TMP/missing.out" 2> "$TMP/missing.err"; then
  missing_rc=0
else
  missing_rc=$?
fi
if [ "$missing_rc" -ne 0 ] \
   && grep -qF 'no agent token for test' "$TMP/missing.err" \
   && grep -qF 'no agent token for test' "$TMP/state/agent-board-poll/test.log" \
   && [ ! -e "$TMP/posted" ]; then
  ok identity-shim-missing-token "the run fails loudly before any board write"
else
  bad identity-shim-missing-token "missing token exit=$missing_rc or the run reached a board write"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
