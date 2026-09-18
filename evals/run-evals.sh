#!/usr/bin/env bash
# run-evals.sh: replay every correction this template has been given.
#
# Each line of cases.jsonl is one correction that a human made once. The case
# holds the output that would have been right, and the name of a predicate
# that has to hold for it. A case that stops passing means the template has
# drifted back to the mistake somebody already paid for.
#
# Usage:
#   ./run-evals.sh [--cases FILE] [--case ID] [-h|--help]
#
# Exits non-zero if any case fails, and prints the failing ids.
#
# Case shape, one JSON object per line:
#   id       short slug, unique
#   adapter  hypertask | linear | none
#   kind     bug | rule
#   input    the text the predicate runs over: the corrected output
#   check    a predicate name, optionally with one argument
#   source   full https URL of the ticket the correction came from
#   added    YYYY-MM-DD
#
# Predicates are an allowlist, not shell. A case file is appended to by an
# automated feedback run, and a file that CI executes must never be able to
# carry arbitrary commands. Adding a predicate is a deliberate edit here.
#
#   starts_with_block_tag   the text opens with an HTML block tag
#   has_section "<title>"   the text has a heading with that title
#   is_full_https_url       every ticket reference is a full https:// URL
#   bans_owner_jargon       no ROUTE: list, skill name, unlinked PR number,
#                           file path, or branch name
#   triage_scores "<easy|hard>"  the input is a ticket JSON object, and
#                           scripts/triage.sh --rules-only scores it that way.
#                           Rules only: a check that needs a model and a
#                           network is a check that fails on somebody else's
#                           machine for a reason that is not the code.

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
CASES="$HERE/cases.jsonl"
ONLY=""

usage() { sed -n '2,34p' "$SELF" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --cases) CASES="${2:?--cases needs a path}"; shift 2 ;;
    --case) ONLY="${2:?--case needs an id}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown option %s. Do this next: run run-evals.sh --help\n' "$1" >&2; exit 1 ;;
  esac
done

[ -f "$CASES" ] || {
  printf 'ERROR: no case file at %s. Do this next: create it, one JSON object per line\n' "$CASES" >&2
  exit 1
}

TRIAGE_SH="$(dirname "$HERE")/scripts/triage.sh"
[ -f "$TRIAGE_SH" ] || {
  printf 'ERROR: no triage scorer at %s. Do this next: run this from inside the template folder\n' "$TRIAGE_SH" >&2
  exit 1
}

CASES="$CASES" ONLY="$ONLY" TRIAGE_SH="$TRIAGE_SH" python3 <<'PYEOF'
import json
import os
import re
import subprocess
import sys

BLOCK_TAGS = ("p", "ul", "ol", "h2", "h3", "h4", "blockquote", "pre", "table")


def starts_with_block_tag(text, _arg):
    stripped = text.lstrip()
    for tag in BLOCK_TAGS:
        if re.match(r"<%s(\s[^>]*)?>" % tag, stripped, re.IGNORECASE):
            return True, ""
    return False, "starts with %r, not an HTML block tag" % stripped[:40]


def has_section(text, arg):
    if not arg:
        return False, "has_section needs a heading title as its argument"
    wanted = arg.strip().casefold()
    for line in text.splitlines():
        line = line.strip()
        # Markdown heading, or an HTML heading, or a bold line on its own.
        body = re.sub(r"^#+\s*", "", line)
        body = re.sub(r"</?h[1-6][^>]*>", "", body, flags=re.IGNORECASE)
        body = body.strip("*_ ").strip()
        if body.casefold() == wanted:
            return True, ""
    return False, "no heading titled %r" % arg


def is_full_https_url(text, _arg):
    # A bare ticket id, or a host with no scheme, is a dead link to a reader.
    bare_host = re.search(r"(?<!//)\bapp\.hypertask\.ai/\S+", text)
    if bare_host:
        return False, "scheme-less link %r" % bare_host.group(0)
    linked = set()
    for match in re.finditer(r"https://app\.hypertask\.ai/detail/project-\d+/(\d+)", text):
        linked.add(match.group(1))
    for match in re.finditer(r"\b([A-Z]{2,8})-(\d+)\b", text):
        if match.group(2) not in linked:
            return False, "bare ticket id %r with no full https URL" % match.group(0)
    return True, ""


def bans_owner_jargon(text, _arg):
    # A comment can pass the mechanical shape check and still be noise: it
    # names a skill, a ROUTE: list, or a file/branch path the owner never
    # asked for. AGTE-16: a Decision comment shaped correctly still read as
    # noise to the owner because it mixed in exactly this kind of detail.
    reasons = []
    if re.search(r"\bROUTE\s*:", text, re.IGNORECASE):
        reasons.append("a ROUTE: list")
    if re.search(r"\bskill\b", text, re.IGNORECASE):
        reasons.append("a skill name")
    visible = re.sub(r"<a\b[^>]*>.*?</a>", "", text, flags=re.IGNORECASE | re.DOTALL)
    if re.search(r"\bPR\s*#?\d+\b", visible, re.IGNORECASE):
        reasons.append("a PR number with no linked URL")
    if re.search(r"\b[\w.-]+/[\w.-]+\b", visible):
        reasons.append("a file path or branch name")
    if reasons:
        return False, "contains " + " and ".join(reasons)
    return True, ""


def triage_scores(text, arg):
    # The input is a whole ticket, not a sentence, so this predicate hands it
    # to the real scorer rather than reimplementing the rules here. A rule that
    # is tested against a copy of itself is not tested.
    wanted = (arg or "").strip().casefold()
    if wanted not in ("easy", "hard"):
        return False, 'triage_scores needs "easy" or "hard" as its argument'
    try:
        json.loads(text)
    except json.JSONDecodeError as error:
        return False, "the case input is not ticket JSON: %s" % error
    result = subprocess.run(
        ["bash", os.environ["TRIAGE_SH"], "--rules-only"],
        input=text, capture_output=True, text=True,
    )
    if result.returncode != 0:
        return False, "triage.sh exited %d: %s" % (result.returncode, result.stderr.strip()[:200])
    try:
        verdict = json.loads(result.stdout)
    except json.JSONDecodeError:
        return False, "triage.sh printed %r, not JSON" % result.stdout.strip()[:120]
    got = str(verdict.get("score") or "")
    if got == wanted:
        return True, ""
    return False, "scored %r, not %r (%s)" % (got, wanted, verdict.get("reason"))


PREDICATES = {
    "starts_with_block_tag": starts_with_block_tag,
    "has_section": has_section,
    "is_full_https_url": is_full_https_url,
    "bans_owner_jargon": bans_owner_jargon,
    "triage_scores": triage_scores,
}

path = os.environ["CASES"]
only = os.environ.get("ONLY") or ""
failed = []
ran = 0
seen_ids = set()

with open(path, encoding="utf-8") as handle:
    for number, line in enumerate(handle, start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            case = json.loads(line)
        except json.JSONDecodeError as error:
            print("ERROR: %s line %d is not JSON: %s. Do this next: fix that line"
                  % (path, number, error), file=sys.stderr)
            sys.exit(1)
        case_id = case.get("id") or "line-%d" % number
        if case_id in seen_ids:
            print("ERROR: duplicate case id %r at line %d. Do this next: give it a unique id"
                  % (case_id, number), file=sys.stderr)
            sys.exit(1)
        seen_ids.add(case_id)
        if only and case_id != only:
            continue
        check = (case.get("check") or "").strip()
        if not check:
            failed.append((case_id, "no check"))
            ran += 1
            continue
        name, _, argument = check.partition(" ")
        argument = argument.strip().strip('"').strip("'")
        predicate = PREDICATES.get(name)
        ran += 1
        if predicate is None:
            failed.append((case_id, "unknown predicate %r; the allowlist is %s"
                           % (name, ", ".join(sorted(PREDICATES)))))
            continue
        ok, why = predicate(case.get("input") or "", argument)
        if ok:
            print("PASS %-34s %s" % (case_id, check))
        else:
            print("FAIL %-34s %s : %s" % (case_id, check, why))
            failed.append((case_id, why))

if only and ran == 0:
    print("ERROR: no case with id %r in %s. Do this next: check the id" % (only, path),
          file=sys.stderr)
    sys.exit(1)

print("")
print("%d case(s) run, %d failed" % (ran, len(failed)))
if failed:
    print("failing case ids: %s" % " ".join(case_id for case_id, _ in failed))
    sys.exit(1)
PYEOF

if [ -z "$ONLY" ]; then
  echo ""
  echo "-- agent-chat behavioural checks --"
  python3 "$HERE/agent-chat.test.py"
  echo ""
  echo "-- reply formatting behavioural checks --"
  python3 "$HERE/reply-formatting.test.py"
  echo ""
  echo "-- agent-kick behavioural checks --"
  python3 "$HERE/agent-kick.test.py"
  echo ""
  echo "-- ticket ack lane behavioural checks --"
  python3 "$HERE/ticket-ack.test.py"
fi

# The case file replays text corrections. sync-project.sh is about what lands
# on disk when the layout is synced twice into a repo somebody edited in
# between, which no predicate over a string can express, so it has its own
# suite. Skipped when a single case was named with --case.
if [ -z "$ONLY" ] && [ -x "$HERE/sync-project.test.sh" ]; then
  echo ""
  echo "-- sync-project behavioural checks --"
  bash "$HERE/sync-project.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/command-policy.test.sh" ]; then
  echo ""
  echo "-- command policy behavioural checks --"
  bash "$HERE/command-policy.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/identity-shim.test.sh" ]; then
  echo ""
  echo "-- identity shim behavioural checks --"
  bash "$HERE/identity-shim.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/token-wrapper-guard.test.sh" ]; then
  echo ""
  echo "-- token wrapper guard behavioural checks --"
  bash "$HERE/token-wrapper-guard.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/hypertask-adapter.test.sh" ]; then
  echo ""
  echo "-- hypertask adapter behavioural checks --"
  bash "$HERE/hypertask-adapter.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/queue-ranking.test.sh" ]; then
  echo ""
  echo "-- queue ranking behavioural checks --"
  bash "$HERE/queue-ranking.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/owned-reply-trigger.test.sh" ]; then
  echo ""
  echo "-- owned reply trigger behavioural checks --"
  bash "$HERE/owned-reply-trigger.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/answerer-selection.test.sh" ]; then
  echo ""
  echo "-- answerer selection behavioural checks --"
  bash "$HERE/answerer-selection.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/conf-dir-resolution.test.sh" ]; then
  echo ""
  echo "-- config directory resolution checks --"
  bash "$HERE/conf-dir-resolution.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/comment-cursor.test.sh" ]; then
  echo ""
  echo "-- comment cursor behavioural checks --"
  bash "$HERE/comment-cursor.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/comment-loop.test.sh" ]; then
  echo ""
  echo "-- comment loop behavioural checks --"
  bash "$HERE/comment-loop.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/quiet-mode.test.sh" ]; then
  echo ""
  echo "-- current conf default migration checks --"
  bash "$HERE/quiet-mode.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/one-ticket-live.test.sh" ]; then
  echo ""
  echo "-- one ticket until live behavioural checks --"
  bash "$HERE/one-ticket-live.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/agent-template-update.test.sh" ]; then
  echo ""
  echo "-- agent-template update behavioural checks --"
  bash "$HERE/agent-template-update.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/release-policy.test.sh" ]; then
  echo ""
  echo "-- merge-time release policy checks --"
  bash "$HERE/release-policy.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/qa-sections.test.sh" ]; then
  echo ""
  echo "-- QA section behavioural checks --"
  bash "$HERE/qa-sections.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/qa-lifecycle.test.sh" ]; then
  echo ""
  echo "-- QA lifecycle behavioural checks --"
  bash "$HERE/qa-lifecycle.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/manager-actions.test.sh" ]; then
  echo ""
  echo "-- manager action behavioural checks --"
  bash "$HERE/manager-actions.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/manager-tick.test.sh" ]; then
  echo ""
  echo "-- manager tick regression checks --"
  bash "$HERE/manager-tick.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/maintainer-actions.test.sh" ]; then
  echo ""
  echo "-- maintainer action behavioural checks --"
  bash "$HERE/maintainer-actions.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/repos-allow.test.sh" ]; then
  echo ""
  echo "-- repository allowlist behavioural checks --"
  bash "$HERE/repos-allow.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/instruction-tickets.test.sh" ]; then
  echo ""
  echo "-- instruction ticket behavioural checks --"
  bash "$HERE/instruction-tickets.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/task-writer.test.sh" ]; then
  echo ""
  echo "-- Task Writer behavioural checks --"
  bash "$HERE/task-writer.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/feedback-loop.test.sh" ]; then
  echo ""
  echo "-- feedback loop behavioural checks --"
  bash "$HERE/feedback-loop.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/fleet-progress.test.sh" ]; then
  echo ""
  echo "-- fleet progress and stall checks --"
  bash "$HERE/fleet-progress.test.sh"
fi
if [ -z "$ONLY" ] && [ -x "$HERE/learned-rules.test.sh" ]; then
  echo ""
  echo "-- learned-rules behavioural checks --"
  bash "$HERE/learned-rules.test.sh"
fi
