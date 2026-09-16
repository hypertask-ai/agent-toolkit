#!/usr/bin/env bash
# triage.sh: how hard is this ticket, before anyone starts it.
#
# Reads one JSON object on stdin and prints one JSON object on stdout:
#
#   in   {"ref": "...", "title": "...", "description": "...",
#         "comments": ["...", "..."], "closed_unmerged_pr": false}
#   out  {"score": "easy"|"hard", "reason": "...", "by": "rules"|"model"|"default"}
#
# Usage:
#   triage.sh [--rules-only] [--model-cli "<cmd>"] [-h|--help]
#
# --rules-only never calls a model. The eval suite and install.sh run with it,
# because a check that needs a network and a subscription is a check that fails
# on somebody else's machine for a reason that has nothing to do with the code.
#
# The rules, in this order. The order is the whole design: a ticket that names
# a file is concrete even when it is short, so the "vague" rule must not see it
# first, and a ticket somebody already failed at is hard however tidy it reads.
#
#   1. hard  a subject that is hard here whoever writes it: realtime, auth,
#            money, schema, or a bug that only happens sometimes.
#   2. hard  somebody already tried and failed: a QA FAIL, a "Run failed"
#            comment, or a pull request that closed without merging.
#   3. easy  it names the file, component or screen to change.
#   4. hard  it is vague: under 200 characters, no acceptance criteria, and
#            nothing named.
#   5. ?     none of the above. One cheap model call decides, unless
#            --rules-only, in which case it stays on the default model (easy).
#
# Failure contract: every error prints "ERROR: <what>. Do this next: <step>"
# on stderr and exits non-zero. Nothing is swallowed.

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"

usage() { sed -n '2,32p' "$SELF" | sed 's/^# \{0,1\}//'; }

RULES_ONLY="no"
# The cheap model, not the good one. This call decides a label, not a fix.
TRIAGE_MODEL_CLI="${TRIAGE_MODEL_CLI:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --rules-only) RULES_ONLY="yes"; shift ;;
    --model-cli) TRIAGE_MODEL_CLI="${2:?--model-cli needs a command}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown option %s. Do this next: run triage.sh --help\n' "$1" >&2; exit 1 ;;
  esac
done

INPUT="$(cat)"
[ -n "$INPUT" ] || {
  printf 'ERROR: triage.sh got nothing on stdin. Do this next: pipe it the ticket JSON, see triage.sh --help\n' >&2
  exit 1
}

# The rules are Python, not a pile of greps, because "does the description name
# a file" is a regex over two fields at once and shell quoting would own this
# file otherwise.
VERDICT="$(TRIAGE_IN="$INPUT" python3 <<'PYEOF'
import json
import os
import re
import sys

try:
    doc = json.loads(os.environ["TRIAGE_IN"])
except json.JSONDecodeError as error:
    print("ERROR: the ticket JSON on stdin is not JSON: %s. Do this next: fix the caller"
          % error, file=sys.stderr)
    sys.exit(1)

title = str(doc.get("title") or "")
description = str(doc.get("description") or "")
comments = [str(c) for c in (doc.get("comments") or [])]
closed_unmerged_pr = bool(doc.get("closed_unmerged_pr"))

# HTML in, prose out: a description written in the board's editor is a wall of
# tags, and every length and keyword rule below would read the markup instead
# of the sentence.
def plain(text):
    text = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", text, flags=re.I | re.S)
    text = re.sub(r"<[^>]+>", " ", text)
    text = text.replace("&nbsp;", " ").replace("&amp;", "&")
    text = text.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"')
    return re.sub(r"\s+", " ", text).strip()

body = plain(description)
subject = (title + "\n" + body).casefold()

# ---------- 1. subjects that are hard here whoever writes them ----------
# One group per reason, so the label can say which one fired. A phrase, not a
# word, wherever the word alone would fire on half the board: "session" is in
# every ticket about a browser, "live" is in "live site".
HARD_SUBJECTS = [
    ("realtime", [
        r"real[\s-]?time", r"live[\s-]?updat", r"live[\s-]?refresh", r"pusher",
        r"web[\s-]?socket", r"socket\.io", r"server[\s-]?sent event", r"\bsse\b",
        r"without (?:a )?(?:page )?reload", r"push notification",
    ]),
    ("auth", [
        r"\bauth\b", r"authenticat", r"authoris|authoriz", r"\blogin\b", r"log in\b",
        r"sign[\s-]?in\b", r"sign[\s-]?up\b", r"permission", r"\bacl\b", r"\brbac\b",
        r"access control", r"\bjwt\b", r"\boauth\b", r"magic link", r"session token",
    ]),
    ("money", [
        r"billing", r"\bstripe\b", r"\binvoice", r"payment", r"\brefund",
        r"subscription", r"checkout", r"paywall", r"price plan", r"pricing tier",
    ]),
    ("schema", [
        r"\bschema\b", r"migration", r"\bprisma\b", r"alter table", r"drop column",
        r"add column", r"\bforeign key\b", r"database index", r"\bbackfill\b",
    ]),
    ("intermittent", [
        r"intermittent", r"\bsometimes\b", r"\bflaky\b", r"\brandomly\b",
        r"\boccasionally\b", r"every so often", r"hard to reproduce",
        r"cannot (?:always )?reproduce", r"only happens (?:when|sometimes|after)",
    ]),
]

for name, patterns in HARD_SUBJECTS:
    for pattern in patterns:
        found = re.search(pattern, subject)
        if found:
            print(json.dumps({
                "score": "hard",
                "by": "rules",
                "reason": "%s work: the ticket says %r" % (name, found.group(0).strip()),
            }))
            sys.exit(0)

# ---------- 2. somebody already tried and failed ----------
# A ticket nobody has finished on the second go is not a ticket the default
# model is going to finish on the third.
def is_failure(text):
    plain_text = plain(text)
    lowered = plain_text.casefold()
    if "run failed" in lowered:
        return "a \"Run failed\" comment"
    if re.match(r"\s*fail(ed|s|ure)?\b\s*[:\-]", lowered):
        return "a FAIL comment"
    if re.search(r"\bqa\b[^.]{0,40}\bfail", lowered):
        return "a QA FAIL comment"
    if re.search(r"\bqa\b[^.]{0,40}\bcannot verify\b", lowered):
        return "a QA \"cannot verify\" comment"
    return ""

for comment in comments:
    why = is_failure(comment)
    if why:
        print(json.dumps({
            "score": "hard",
            "by": "rules",
            "reason": "already attempted: %s is on the ticket" % why,
        }))
        sys.exit(0)

if closed_unmerged_pr:
    print(json.dumps({
        "score": "hard",
        "by": "rules",
        "reason": "already attempted: a pull request for this ticket closed without merging",
    }))
    sys.exit(0)

# ---------- 3. it names what to change ----------
# Checked BEFORE the vague rule on purpose. "Make .task-row padding 8px in
# src/styles/board.css" is 60 characters and is the easiest ticket on the
# board; measuring it by length alone would send it to the expensive model.
NAMES_A_TARGET = [
    # a filename with a real extension
    (r"[\w./-]+\.(?:tsx?|jsx?|mjs|cjs|css|scss|less|html|py|sh|sql|ya?ml|json|md|vue|svelte|prisma)\b", re.I),
    # a source path
    (r"\b(?:src|app|apps|packages|components|pages|lib|styles|hooks|server|api)/[\w./-]+", re.I),
    # a named screen or widget: "the board page", "the Task Detail modal"
    (r"\b(?:the|on|in)\s+(?:[\w'-]+\s+){0,3}(?:page|screen|modal|dialog|drawer|panel|sidebar|side panel|menu|tooltip|toast|banner|card|button|column|tab)s?\b", re.I),
    # a component written as a tag, or a CSS selector with a rule body
    (r"<[A-Z][A-Za-z0-9]+\s*/?>", 0),
    (r"[.#][a-z][\w-]*\s*\{", re.I),
]
target = title + "\n" + body
for pattern, flags in NAMES_A_TARGET:
    found = re.search(pattern, target, flags)
    if found:
        print(json.dumps({
            "score": "easy",
            "by": "rules",
            "reason": "names what to change: %r" % found.group(0).strip()[:60],
        }))
        sys.exit(0)

# ---------- 4. vague ----------
HAS_CRITERIA = [
    r"acceptance criteri", r"steps to reproduce", r"\bexpected\b", r"\bactual\b",
    r"\bgiven\b.*\bwhen\b.*\bthen\b", r"^\s*[-*]\s*\[\s*\]", r"definition of done",
    r"how to verify", r"should (?:show|be|not|display|update|return)",
]
criteria = any(re.search(p, body, re.I | re.M) for p in HAS_CRITERIA)
if len(body) < 200 and not criteria:
    print(json.dumps({
        "score": "hard",
        "by": "rules",
        "reason": "vague: %d characters of description, no acceptance criteria, nothing named"
                  % len(body),
    }))
    sys.exit(0)

# ---------- 5. the rules are not sure ----------
print(json.dumps({"score": "", "by": "unsure", "reason": "no rule fired"}))
PYEOF
)"

SCORE="$(VERDICT="$VERDICT" python3 -c 'import json,os;print(json.loads(os.environ["VERDICT"])["score"])')"
if [ -n "$SCORE" ]; then
  printf '%s\n' "$VERDICT"
  exit 0
fi

# The rules did not fire. Either say so and keep the default model, or spend one
# cheap call on it. Nothing here falls back to the expensive model: a ticket no
# rule recognised is an ordinary ticket until a model says otherwise.
if [ "$RULES_ONLY" = "yes" ]; then
  printf '{"score": "easy", "by": "default", "reason": "no rule fired and no model call allowed, so the default model keeps it"}\n'
  exit 0
fi

read -r -a TRIAGE_ARGV <<< "$TRIAGE_MODEL_CLI"
if [ "${#TRIAGE_ARGV[@]}" -eq 0 ]; then
  printf '{"score": "easy", "by": "default", "reason": "no rule fired and no TRIAGE_MODEL_CLI is configured"}\n'
  exit 0
fi
if ! command -v "${TRIAGE_ARGV[0]}" >/dev/null 2>&1; then
  printf '{"score": "easy", "by": "default", "reason": "no rule fired and %s is not installed here"}\n' "${TRIAGE_ARGV[0]}"
  exit 0
fi

ASK="$(TRIAGE_IN="$INPUT" python3 -c '
import json, os
doc = json.loads(os.environ["TRIAGE_IN"])
print("""You are triaging one engineering ticket for a coding agent.

Answer with strict JSON and nothing else: {"score": "easy" or "hard", "reason": "<one short sentence>"}

hard means: the change touches something subtle (realtime, auth, money, database
schema), or reproduces only sometimes, or the ticket does not say enough to know
what to change. easy means: the change is local, the ticket says where it goes,
and a competent agent can finish it in one pass.

Title: %s

Description: %s""" % (doc.get("title") or "", (doc.get("description") or "")[:4000]))')"

RAW="$(printf '%s' "$ASK" | "${TRIAGE_ARGV[@]}" 2>/dev/null)" || RAW=""
RESULT="$(RAW="$RAW" python3 -c '
import json, os, re, sys
raw = os.environ["RAW"]
match = re.search(r"\{.*\}", raw, re.S)
if not match:
    sys.exit(1)
try:
    doc = json.loads(match.group(0))
except json.JSONDecodeError:
    sys.exit(1)
score = str(doc.get("score") or "").strip().casefold()
if score not in ("easy", "hard"):
    sys.exit(1)
print(json.dumps({"score": score, "by": "model",
                  "reason": str(doc.get("reason") or "the model said so")[:200]}))')" || RESULT=""

if [ -n "$RESULT" ]; then
  printf '%s\n' "$RESULT"
else
  printf '{"score": "easy", "by": "default", "reason": "no rule fired and the triage model did not answer in JSON"}\n'
fi
