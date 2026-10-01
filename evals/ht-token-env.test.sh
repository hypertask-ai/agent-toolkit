#!/usr/bin/env bash
# Board wrappers and webhook callers must not put the agent token on argv.
# The CLI reads HT_TOKEN. A process list must not show the token.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-34s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-34s %s\n' "$1" "$2"; fail=$((fail + 1)); }

# The same scanner has to fail when a wrapper still passes --token.
printf '%s\n' 'exec hypertask --token "$TOKEN" "$@"' > "$TMP/bad-wrapper"
if grep -qE -- '--token([^A-Za-z0-9_-]|$)' "$TMP/bad-wrapper"; then
  ok token-argv-negative-control "a wrapper that still passes --token is detected"
else
  bad token-argv-negative-control "the scanner missed a --token argument"
fi

mkdir -p "$TMP/bin"
printf 'fixture-token\n' > "$TMP/token"
chmod 600 "$TMP/token"
cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
if printf '%s\n' "$*" | grep -F -q -e "$EXPECT_TOKEN"; then
  printf 'argv-leak\n' >> "$ARGV_LOG"
fi
if [ "${HT_TOKEN:-}" = "$EXPECT_TOKEN" ]; then
  printf 'env-ok\n' >> "$ARGV_LOG"
else
  printf 'env-missing\n' >> "$ARGV_LOG"
fi
exit 0
EOF
chmod 755 "$TMP/bin/hypertask"
# shellcheck disable=SC1091
CORE_ROOT="$ROOT"
. "$ROOT/scripts/lib/core.sh"
core_load_adapter hypertask
PATH="$TMP/bin:$PATH" adapter_install_board_cli dev-1 "$TMP/token" "$TMP/bin/ht-dev-1" "Dev 1" agent-1 15

mode="$(stat -c %a "$TMP/token")"
if [ "$mode" = 600 ] \
   && grep -q 'export HT_TOKEN=' "$TMP/bin/ht-dev-1" \
   && grep -q 'identity-shims' "$TMP/bin/ht-dev-1" \
   && ! grep -qE -- '--token([^A-Za-z0-9_-]|$)' "$TMP/bin/ht-dev-1"; then
  ok token-argv-wrapper "ht-dev-1 exports HT_TOKEN, skips the identity shim, and does not pass --token"
else
  bad token-argv-wrapper "generated wrapper still puts a token on the command line or skips the export"
fi

ARGV_LOG="$TMP/argv.log"
EXPECT_TOKEN="$(cat "$TMP/token")"
export ARGV_LOG EXPECT_TOKEN
mkdir -p "$TMP/identity-shims/dev-1"
cat > "$TMP/identity-shims/dev-1/hypertask" <<EOF
#!/usr/bin/env bash
exec "$TMP/bin/ht-dev-1" "\$@"
EOF
chmod 755 "$TMP/identity-shims/dev-1/hypertask"
if PATH="$TMP/identity-shims/dev-1:$TMP/bin:$PATH" timeout 5 "$TMP/bin/ht-dev-1" status \
   && [ "$(grep -c '^env-ok$' "$ARGV_LOG")" = 1 ] \
   && ! grep -q '^argv-leak$' "$ARGV_LOG"; then
  ok token-argv-runtime "a wrapper call keeps the token in HT_TOKEN and does not re-enter through the identity shim"
else
  bad token-argv-runtime "the wrapper did not export HT_TOKEN, leaked it, or called itself through the shim"
fi

leaks="$(grep -RInE -- '--token([^A-Za-z0-9_-]|$)' "$ROOT/adapters" "$ROOT/scripts" || true)"
if [ -z "$leaks" ]; then
  ok token-argv-sources "adapters and scripts do not build a --token argument"
else
  bad token-argv-sources "a --token argument is still built in adapters or scripts"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
