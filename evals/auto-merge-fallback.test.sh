#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/config" "$TMP/state" "$TMP/home"
: > "$TMP/gh.log"

cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "${1:-} ${2:-}" = "pr list" ]; then
  cat <<'JSON'
[
  {"url":"https://github.com/example/repo/pull/1","isDraft":false,"createdAt":"2026-09-18T21:00:00Z","headRefOid":"1111111111111111111111111111111111111111","mergeable":"MERGEABLE","autoMergeRequest":null,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}],"labels":[]},
  {"url":"https://github.com/example/repo/pull/2","isDraft":false,"createdAt":"2026-09-18T21:31:00Z","headRefOid":"2222222222222222222222222222222222222222","mergeable":"MERGEABLE","autoMergeRequest":null,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}],"labels":[]},
  {"url":"https://github.com/example/repo/pull/3","isDraft":false,"createdAt":"2026-09-18T21:00:00Z","headRefOid":"3333333333333333333333333333333333333333","mergeable":"MERGEABLE","autoMergeRequest":{"enabledAt":"2026-09-18T21:01:00Z"},"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}],"labels":[]},
  {"url":"https://github.com/example/repo/pull/4","isDraft":false,"createdAt":"2026-09-18T21:00:00Z","headRefOid":"4444444444444444444444444444444444444444","mergeable":"MERGEABLE","autoMergeRequest":null,"statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":""}],"labels":[]},
  {"url":"https://github.com/example/repo/pull/5","isDraft":false,"createdAt":"2026-09-18T21:00:00Z","headRefOid":"5555555555555555555555555555555555555555","mergeable":"CONFLICTING","autoMergeRequest":null,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}],"labels":[]},
  {"url":"https://github.com/example/repo/pull/6","isDraft":true,"createdAt":"2026-09-18T21:00:00Z","headRefOid":"6666666666666666666666666666666666666666","mergeable":"MERGEABLE","autoMergeRequest":null,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}],"labels":[]},
  {"url":"https://github.com/example/repo/pull/7","isDraft":false,"createdAt":"2026-09-18T21:00:00Z","headRefOid":"7777777777777777777777777777777777777777","mergeable":"MERGEABLE","autoMergeRequest":null,"statusCheckRollup":[],"labels":[]},
  {"url":"https://github.com/example/repo/pull/8","isDraft":false,"createdAt":"2026-09-18T21:00:00Z","headRefOid":"8888888888888888888888888888888888888888","mergeable":"MERGEABLE","autoMergeRequest":null,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}],"labels":[{"name":"valentin-review"}]}
]
JSON
  exit 0
fi
if [ "${1:-} ${2:-}" = "pr merge" ]; then
  exit 0
fi
exit 1
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '[]\n200'
EOF
cat > "$TMP/bin/board" <<'EOF'
#!/usr/bin/env bash
printf '{}\n'
EOF
chmod +x "$TMP/bin/"*

printf 'token\n' > "$TMP/token"
for slug in dev-one dev-two; do
  cat > "$TMP/config/$slug.conf" <<EOF
AGENT_ID="agent-$slug"
AGENT_NAME="$slug"
AGENT_SLUG="$slug"
AGENT_KIND="dev"
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
BOARD_CLI="$TMP/bin/board"
TOKEN_FILE="$TMP/token"
PR_REPO="example/repo"
EOF
done
HOME="$TMP/home" PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log" \
  AGENT_CONFIG_DIR="$TMP/config" AGENT_BOARD_STATE_DIR="$TMP/state" \
  RECONCILE_NOW="2026-09-18T22:00:00Z" \
  "$ROOT/scripts/agent-board-reconcile"
merge_calls="$(grep -c '^pr merge ' "$TMP/gh.log" || true)"
list_calls="$(grep -c '^pr list ' "$TMP/gh.log" || true)"
if [ "$merge_calls" -eq 1 ] && [ "$list_calls" -eq 1 ] \
   && grep -qxF 'pr list --repo example/repo --state open --limit 100 --json url,isDraft,createdAt,headRefOid,mergeable,autoMergeRequest,statusCheckRollup,labels' "$TMP/gh.log" \
   && grep -qxF 'pr merge --repo example/repo --squash --match-head-commit 1111111111111111111111111111111111111111 https://github.com/example/repo/pull/1' "$TMP/gh.log"; then
  echo 'PASS reconciler-direct-merge            one scan merges only the old green mergeable PR without auto-merge'
else
  echo "FAIL reconciler-direct-merge            list=$list_calls merge=$merge_calls gh=$(cat "$TMP/gh.log")"; exit 1
fi

if ! grep -qF 'https://github.com/example/repo/pull/8' "$TMP/gh.log"; then
  echo 'PASS reconciler-protected-pr            valentin-review PRs remain untouched'
else
  echo "FAIL reconciler-protected-pr            gh=$(cat "$TMP/gh.log")"; exit 1
fi
