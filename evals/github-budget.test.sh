#!/usr/bin/env bash
# Shared pull snapshot interval, installation token routing, and reset backoff.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

# shellcheck disable=SC1091
. "$ROOT/adapters/hypertask/adapter.sh"

if grep -q 'PR_CACHE_TTL_SECONDS:-300' "$ROOT/adapters/hypertask/adapter.sh"; then
  ok default-snapshot-is-five-minutes
else
  bad default-snapshot-is-five-minutes
fi

SENTINEL='sentinel-app-token-do-not-print'
printf '%s\n' "$SENTINEL" > "$TMP/token"
chmod 600 "$TMP/token"
export HT_GH_APP_TOKEN_FILE="$TMP/token"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" << 'EOF'
#!/bin/sh
if [ -n "${GH_TOKEN:-}" ]; then
  printf 'app-token=set\n'
else
  printf 'app-token=unset\n'
fi
EOF
chmod 755 "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

routed="$(_ht_with_app_token hypertask-ai/hypertask command gh api repos/hypertask-ai/hypertask/pulls/1)"
other="$(_ht_with_app_token hypertask-ai/analytics command gh api repos/hypertask-ai/analytics/pulls/1)"
if [ "$routed" = "app-token=set" ] && [ "$other" = "app-token=unset" ] && ! printf '%s' "$routed$other" | grep -q "$SENTINEL"; then
  ok app-token-routes-hypertask-only
else
  bad app-token-routes-hypertask-only
fi

reset=1893456000
printf 'HTTP/2.0 403 Forbidden\nX-RateLimit-Reset: %s\n\n{"message":"API rate limit exceeded"}\n' "$reset" > "$TMP/response"
: > "$TMP/error"
export AGENT_PR_CACHE_DIR="$TMP/pr-cache"
_ht_pause_github hypertask-ai/hypertask "$TMP/error" "$TMP/response"
saved="$(cat "$TMP/pr-cache/hypertask-ai__hypertask.json.rate-limit")"
if [ "$saved" = "$reset" ]; then
  ok backoff-uses-reset-header
else
  bad backoff-uses-reset-header
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
