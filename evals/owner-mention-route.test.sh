#!/usr/bin/env bash
# Board 15 workers cannot mention the owner. The supervisor can. A comment
# that does not mention him is posted unchanged.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/home"
printf 'token\n' > "$TMP/token"
CALLS="$TMP/calls"
export CALLS
: > "$CALLS"

cat > "$TMP/bin/hypertask" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
if [[ " $* " == *" task get "* ]]; then
  ticket="${@: -1}"
  printf '{"tasks":[{"ticketNumber":"%s","id":"1","assignees":[{"agent":{"id":"worker"}}],"labels":[]}]}\n' "$ticket"
elif [[ " $* " == *" project show "* ]]; then
  printf '{"project":{"ownerId":6}}\n'
elif [[ " $* " == *" comment list "* ]]; then
  printf '{"comments":[]}\n'
else
  printf '{}\n'
fi
EOF
chmod +x "$TMP/bin/hypertask"

# shellcheck disable=SC1090
. "$ROOT/adapters/hypertask/adapter.sh"

POLICY="$ROOT/adapters/hypertask/plain-language/worker-comment.py"
if python3 "$POLICY" --is-supervisor ht-supervisor; then
  ok supervisor-identity 'ht-supervisor is the only identity that may mention the owner'
else
  bad supervisor-identity 'ht-supervisor was not recognised'
fi
if python3 "$POLICY" --is-supervisor qa-1; then
  bad worker-identity 'qa-1 was treated as the supervisor'
else
  ok worker-identity 'qa-1 is a worker'
fi

mention='<p><strong>Question: <span data-type="mention" class="mention" data-id="Valentin Yeo" data-label="name-6">Valentin Yeo</span>, can the supervisor arrange deployment so QA can test?</strong></p>'
plain='<p><strong>Done: The archive button now removes the task.</strong></p><p>Next: QA checks the live site.</p>'

rewritten="$(printf '%s' "$mention" | python3 "$POLICY" HTPR-6735 15)"
if printf '%s' "$rewritten" | grep -q 'Supervisor' \
   && ! printf '%s' "$rewritten" | grep -qi 'Valentin' \
   && ! printf '%s' "$rewritten" | grep -q 'name-6'; then
  ok worker-rewrite 'a worker mention is rewritten to the supervisor'
else
  bad worker-rewrite "rewritten=$rewritten"
fi
unchanged="$(printf '%s' "$plain" | python3 "$POLICY" HTPR-6735 15)"
if [ "$unchanged" = "$plain" ]; then
  ok worker-rewrite-unchanged 'a comment with no owner mention is left as written'
else
  bad worker-rewrite-unchanged "unchanged=$unchanged"
fi

post() {
  local slug="$1" dest="$2" text="$3"
  : > "$CALLS"
  adapter_install_board_cli "$slug" "$TMP/token" "$dest" "Test Bot" agent-1 15 on
  HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" PATH="$TMP/bin:$PATH" \
    "$dest" comment add HTPR-6735 --text "$text" >"$TMP/out" 2>"$TMP/err" || true
}

post qa-1 "$TMP/worker" "$mention"
if grep -q 'comment add HTPR-6735 --text' "$CALLS" \
   && grep -q 'Supervisor' "$CALLS" \
   && ! grep -qi 'Valentin' "$CALLS" \
   && ! grep -q 'name-6' "$CALLS" \
   && grep -q 'task move HTPR-6735 --section Supervisor Review' "$CALLS"; then
  ok worker-mention-routed 'a worker mention is stripped and the ticket moves to Supervisor Review'
else
  bad worker-mention-routed "calls=$(cat "$CALLS") err=$(cat "$TMP/err")"
fi

post ht-supervisor "$TMP/supervisor" "$mention"
if grep -q 'name-6' "$CALLS" \
   && grep -q 'Valentin Yeo' "$CALLS" \
   && ! grep -q 'task move HTPR-6735 --section Supervisor Review' "$CALLS"; then
  ok supervisor-mention-allowed 'the supervisor may mention the owner and the ticket stays put'
else
  bad supervisor-mention-allowed "calls=$(cat "$CALLS") err=$(cat "$TMP/err")"
fi

post qa-1 "$TMP/plain" "$plain"
if grep -F -q 'Done: The archive button now removes the task.' "$CALLS" \
   && ! grep -q 'task move HTPR-6735 --section Supervisor Review' "$CALLS"; then
  ok plain-comment-unchanged 'a comment that does not mention the owner is posted unchanged'
else
  bad plain-comment-unchanged "calls=$(cat "$CALLS") err=$(cat "$TMP/err")"
fi

printf '%s %s passed, %s failed\n' "$pass" "checks" "$fail"
[ "$fail" -eq 0 ]
