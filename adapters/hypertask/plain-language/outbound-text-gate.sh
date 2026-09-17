#!/usr/bin/env bash
# Shared outbound gate for ticket comments and human-addressed run responses.

_plain_comment() {
  COMMENT_TEXT="$1" python3 -c '
import html, os, re
print(html.unescape(re.sub(r"<[^>]+>", " ", os.environ["COMMENT_TEXT"])).strip())
'
}

_rewrite_plain_comment() {
  local draft="$1" reasons="$2" cli="${AGENT_COMMENT_REWRITE_CLI:-${COMMENT_REWRITE_CLI:-}}"
  local prompt output
  local -a argv
  [ -n "$cli" ] || return 1
  for skill in "$POSPEAK_SKILL" "$UNSLOP_SKILL" "$ADHD_SKILL"; do
    [ -r "$skill" ] || return 1
  done
  prompt="$(cat <<PROMPTEOF
Rewrite the HTML ticket comment below. A product owner with ADHD reads it on a phone. Use low effort and return only the replacement HTML, with no code fence or explanation. Start with <p><strong> and bold the complete first sentence. Use at most 80 words. Remove paths, function calls, code spans, commit hashes, and em dashes. Put each ticket or PR reference inside an <a href="https://..."> link. End the last block with a question mark or start it with Next:.

The mechanical check rejected it for:
$reasons

Draft:
$draft

POSPEAK RULES, VERBATIM:
$(cat "$POSPEAK_SKILL")

UNSLOP RULES, VERBATIM:
$(cat "$UNSLOP_SKILL")

I-HAVE-ADHD RULES, VERBATIM:
$(cat "$ADHD_SKILL")
PROMPTEOF
)"
  read -r -a argv <<< "$cli"
  [ "${#argv[@]}" -gt 0 ] || return 1
  output="$(timeout 60 "${argv[@]}" "$prompt")" || return 1
  [ -n "$output" ] || return 1
  printf '%s' "$output"
}

_enforce_plain_comment() {
  local original="$1" plain kind reasons rewritten final_draft final_reasons
  plain="$(_plain_comment "$original")"
  kind="${plain%%:*}"
  case "$kind" in
    Question|Decision) ;;
    *) TEXT="$original"; return 0 ;;
  esac
  if reasons="$(printf '%s' "$original" | python3 "$PLAIN_LANGUAGE_CHECK" 2>&1)"; then
    TEXT="$original"
    return 0
  fi
  final_draft="$original"
  final_reasons="$reasons"
  if rewritten="$(_rewrite_plain_comment "$original" "$reasons" 2>>"$RUN_LOG")"; then
    final_draft="$rewritten"
    if final_reasons="$(printf '%s' "$rewritten" | python3 "$PLAIN_LANGUAGE_CHECK" 2>&1)"; then
      TEXT="$rewritten"
      return 0
    fi
  else
    final_reasons="$reasons
rewrite model did not return a replacement within 60 seconds"
  fi
  mkdir -p "$(dirname "$RUN_LOG")" 2>/dev/null || true
  {
    printf '%s plain-language-held: draft follows\n%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$final_draft"
    printf 'plain-language-held: reasons follow\n%s\n' "$final_reasons"
  } >> "$RUN_LOG" 2>/dev/null || true
  _outbound_gate_activity action "Question held: did not pass the plain-language check"
  _outbound_gate_note "Question held: did not pass the plain-language check"
  return 1
}

_outbound_text_gate() {
  local original="$1" verbatim="${2:-no}" plain
  TEXT="$original"
  plain="$(_plain_comment "$TEXT")"
  case "$plain" in
    Question:*|Decision:*|Handoff:*|Done:*) ;;
    *)
      _outbound_gate_activity action "${plain:-empty comment}"
      _outbound_gate_note "quiet mode: redirected unmarked ticket comment to run activity"
      return 1 ;;
  esac
  if [ "$verbatim" != "yes" ]; then
    _enforce_plain_comment "$TEXT" || return 1
  fi
}
