#!/usr/bin/env bash
# Shared outbound shape gate for ticket comments and human-addressed responses.

_plain_comment() {
  COMMENT_TEXT="$1" python3 -c '
import html, os, re
print(html.unescape(re.sub(r"<[^>]+>", " ", os.environ["COMMENT_TEXT"])).strip())
'
}

_enforce_plain_comment() {
  local original="$1" kind="$2" reasons
  if reasons="$(printf '%s' "$original" | python3 "$PLAIN_LANGUAGE_CHECK" 2>&1)"; then
    TEXT="$original"
    case "$kind" in
      Done|Handoff) [ -z "${AGENT_HELD_COMMENT_FILE:-}" ] || rm -f "$AGENT_HELD_COMMENT_FILE" ;;
    esac
    return 0
  fi
  mkdir -p "$(dirname "$RUN_LOG")" 2>/dev/null || true
  case "$kind" in
    Done|Handoff)
      if [ -n "${AGENT_HELD_COMMENT_FILE:-}" ]; then
        mkdir -p "$(dirname "$AGENT_HELD_COMMENT_FILE")" 2>/dev/null || true
        printf '%s' "$original" > "$AGENT_HELD_COMMENT_FILE"
      fi
      ;;
  esac
  {
    printf '%s plain-language-held: draft follows\n%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$original"
    printf 'plain-language-held: reasons follow\n%s\n' "$reasons"
  } >> "$RUN_LOG" 2>/dev/null || true
  _outbound_gate_activity action "${kind:-Reply} held: did not pass the plain-language shape check"
  _outbound_gate_note "${kind:-Reply} held: did not pass the plain-language shape check"
  return 1
}

_outbound_text_gate() {
  local original="$1" plain kind=""
  TEXT="$original"
  plain="$(_plain_comment "$TEXT")"
  case "$plain" in
    Question:*|Answer:*|Decision:*|Handoff:*|Done:*) kind="${plain%%:*}" ;;
    *)
      if [ "${AGENT_REPLY_ONLY:-no}" != "yes" ]; then
        _outbound_gate_activity action "${plain:-empty comment}"
        _outbound_gate_note "quiet mode: redirected unmarked ticket comment to run activity"
        return 1
      fi
      ;;
  esac
  _enforce_plain_comment "$TEXT" "$kind"
}
