#!/usr/bin/env bash
# Behavioural checks on scripts/agent-rules, the learned-rules store: a
# correction becomes a scored rule (AGTE-10). Not expressible as a text-only
# case in cases.jsonl, because the thing under test is state on disk moving
# through add -> promote -> confirm -> decay -> archive over injected dates.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES="$HERE/../scripts/agent-rules"
[ -x "$RULES" ] || { echo "FAIL learned-rules: no executable at $RULES" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FILE="$TMP/RULES.jsonl"

fails=0
ok()  { printf 'PASS %-34s %s\n' "$1" "$2"; }
bad() { printf 'FAIL %-34s %s\n' "$1" "$2"; fails=$((fails + 1)); }

# --- add writes a proposed rule, never active straight away -----------------
add_out="$(bash "$RULES" add --file "$FILE" --text "Never use em dashes in PR bodies" \
  --source "https://app.hypertask.ai/detail/project-5500/10" --now 2026-01-01)"
RULE_ID="$(python3 -c "import json;print(json.loads(open('$FILE').readlines()[-1])['id'])")"
if printf '%s' "$add_out" | grep -q 'proposed' \
  && [ "$(python3 -c "import json;print(json.loads(open('$FILE').readlines()[-1])['status'])")" = "proposed" ]; then
  ok rules-add-is-proposed "a new rule starts proposed, not active"
else
  bad rules-add-is-proposed "expected a proposed row, got: $add_out"
fi

# --- a proposed rule is invisible to the default active listing, and an ----
# empty active list is not an error: it is the normal state of a fresh repo,
# and the learned-rules skill runs `list --status active` before every ticket.
list_out="$(bash "$RULES" list --file "$FILE" --status active)" && list_exit=0 || list_exit=$?
if [ "$list_exit" -eq 0 ] && printf '%s' "$list_out" | grep -q "no active rules"; then
  ok rules-proposed-not-loaded "a proposed rule is not yet load-bearing, and listing none is not an error"
else
  bad rules-proposed-not-loaded "expected exit 0 and 'no active rules', got exit $list_exit: $list_out"
fi

# --- promote is the human veto point: only a proposed rule can be promoted --
bash "$RULES" promote --file "$FILE" --id "$RULE_ID" --now 2026-01-02 >/dev/null
if bash "$RULES" list --file "$FILE" --status active | grep -qF "$RULE_ID"; then
  ok rules-promote-activates "promote moves a proposed rule to active"
else
  bad rules-promote-activates "the promoted rule is not in the active list"
fi
if bash "$RULES" promote --file "$FILE" --id "$RULE_ID" --now 2026-01-02 2>/dev/null; then
  bad rules-promote-once "promoting an already-active rule should refuse"
else
  ok rules-promote-once "promoting an already-active rule refuses"
fi

# --- confirm raises confidence when a run follows the rule and the PR lands -
before="$(python3 -c "import json;print(json.loads(open('$FILE').readlines()[-1])['confidence'])")"
bash "$RULES" confirm --file "$FILE" --id "$RULE_ID" --now 2026-01-03 >/dev/null
after="$(python3 -c "import json;print(json.loads(open('$FILE').readlines()[-1])['confidence'])")"
if python3 -c "import sys; sys.exit(0 if $after > $before else 1)"; then
  ok rules-confirm-raises "confirming a rule raised its confidence ($before -> $after)"
else
  bad rules-confirm-raises "confidence did not rise: $before -> $after"
fi

# --- unused for 30 days lowers confidence; below the floor, it archives -----
bash "$RULES" decay --file "$FILE" --now 2026-01-10 >/dev/null   # inside the window: no-op
mid="$(python3 -c "import json;print(json.loads(open('$FILE').readlines()[-1])['confidence'])")"
if [ "$mid" = "$after" ]; then
  ok rules-decay-inside-window "no decay before 30 days unused"
else
  bad rules-decay-inside-window "confidence moved before the 30-day window: $after -> $mid"
fi
bash "$RULES" decay --file "$FILE" --now 2026-02-05 >/dev/null
bash "$RULES" decay --file "$FILE" --now 2026-03-10 >/dev/null
bash "$RULES" decay --file "$FILE" --now 2026-04-15 >/dev/null
status="$(python3 -c "import json;print(json.loads(open('$FILE').readlines()[-1])['status'])")"
if [ "$status" = "archived" ]; then
  ok rules-decay-archives "repeated 30-day decay drops it below the floor and archives it"
else
  bad rules-decay-archives "expected archived after repeated decay, got $status"
fi

# --- decay never rewrites last_confirmed, only its own last_decayed marker --
lc="$(python3 -c "import json;print(json.loads(open('$FILE').readlines()[-1])['last_confirmed'])")"
if [ "$lc" = "2026-01-03" ]; then
  ok rules-decay-preserves-last-confirmed "last_confirmed still names the real confirmation date, not a decay tick"
else
  bad rules-decay-preserves-last-confirmed "expected last_confirmed 2026-01-03, decay overwrote it to $lc"
fi

# --- archived is never deleted -----------------------------------------------
if [ "$(wc -l < "$FILE" | tr -d ' ')" != "0" ] && grep -qF "$RULE_ID" "$FILE"; then
  ok rules-never-deleted "the archived row is still on disk"
else
  bad rules-never-deleted "the row disappeared from $FILE"
fi

# --- confirming an archived rule brings it back to active -------------------
bash "$RULES" confirm --file "$FILE" --id "$RULE_ID" --now 2026-04-16 >/dev/null
revived="$(python3 -c "import json;print(json.loads(open('$FILE').readlines()[-1])['status'])")"
if [ "$revived" = "active" ]; then
  ok rules-confirm-revives "a confirmation un-archives a rule that proved right again"
else
  bad rules-confirm-revives "expected active after confirming an archived rule, got $revived"
fi

# --- manual archive keeps the row and records why ----------------------------
bash "$RULES" archive --file "$FILE" --id "$RULE_ID" --why "superseded by a newer rule" --now 2026-04-17 >/dev/null
reason="$(python3 -c "import json;print(json.loads(open('$FILE').readlines()[-1])['archived_reason'])")"
if [ "$reason" = "superseded by a newer rule" ]; then
  ok rules-manual-archive "a manual archive records its reason"
else
  bad rules-manual-archive "expected the given reason, got: $reason"
fi

# --- add refuses a source that is not a full https URL ----------------------
if bash "$RULES" add --file "$FILE" --text "bad source" --source "app.hypertask.ai/x" 2>/dev/null; then
  bad rules-source-must-be-https "a scheme-less source was accepted"
else
  ok rules-source-must-be-https "a scheme-less source is refused"
fi

printf '\n%d learned-rules behavioural check(s) failed\n' "$fails"
[ "$fails" -eq 0 ]
