#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
TEMPLATE="$ROOT/scripts/agent-template"
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/feedback.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
ok() { printf 'PASS %-34s %s\n' "$1" "$2"; }
bad() { printf 'FAIL %-34s %s\n' "$1" "$2"; fails=$((fails + 1)); }

help="$(bash "$TEMPLATE" feedback --help)"
if printf '%s' "$help" | grep -qF 'https://app.hypertask.ai/detail/project-5500' \
  && printf '%s' "$help" | grep -qF 'Example:' \
  && printf '%s' "$help" | grep -qF -- '--what "<summary>" --got'; then
  ok feedback-help-discovery 'help names the board and the canonical example'
else
  bad feedback-help-discovery 'help is missing the board, example, or canonical flags'
fi

NOTE="$TMP/CLAUDE.md"
printf 'before\n\nkeep this byte for byte\n' > "$NOTE"
original="$(cat "$NOTE")"
feedback_update_note "$NOTE" 9.9.9 yes
first="$(cat "$NOTE")"
feedback_update_note "$NOTE" 9.9.9 yes
second="$(cat "$NOTE")"
if [ "$first" = "$second" ] && [ "$(grep -c '<!-- agent-template:begin -->' "$NOTE")" -eq 1 ]; then
  ok managed-block-idempotent 'the second write is byte-for-byte unchanged'
else
  bad managed-block-idempotent 'the second write changed or duplicated the block'
fi

outside="$(python3 - "$NOTE" <<'PYEOF'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
print(re.sub(r'<!-- agent-template:begin -->.*?<!-- agent-template:end -->\n?', '', text, flags=re.S), end='')
PYEOF
)"
if [ "$outside" = "$original" ]; then
  ok managed-block-preserves-content 'bytes outside the markers are unchanged'
else
  bad managed-block-preserves-content 'unrelated CLAUDE.md content changed'
fi

cat > "$TMP/CHANGELOG.md" <<'EOF'
# changelog

## 3.16.0 - 2026-09-16

- AGTE-3 fixed the missing release callback.
- Follow-up verification for AGTE-3.
EOF
ship="$(XDG_STATE_HOME="$TMP/state" bash "$ROOT/scripts/agent-template-feedback" --dry-run --changelog "$TMP/CHANGELOG.md")"
if [ "$(printf '%s\n' "$ship" | grep -c 'Shipped in')" -eq 1 ] \
  && printf '%s' "$ship" | grep -qF 'AGTE-3: Shipped in 3.16.0'; then
  ok shipped-action-once 'one changelog ticket produces one dry-run shipped action'
else
  bad shipped-action-once "expected one AGTE-3 shipped action, got: $ship"
fi

printf '\n%d feedback-loop behavioural check(s) failed\n' "$fails"
[ "$fails" -eq 0 ]
