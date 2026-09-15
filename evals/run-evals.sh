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
# automated weekly run, and a file that CI executes must never be able to
# carry arbitrary commands. Adding a predicate is a deliberate edit here.
#
#   starts_with_block_tag   the text opens with an HTML block tag
#   has_section "<title>"   the text has a heading with that title
#   is_full_https_url       every ticket reference is a full https:// URL

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
CASES="$HERE/cases.jsonl"
ONLY=""

usage() { sed -n '2,29p' "$SELF" | sed 's/^# \{0,1\}//'; }

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

CASES="$CASES" ONLY="$ONLY" python3 <<'PYEOF'
import json
import os
import re
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


PREDICATES = {
    "starts_with_block_tag": starts_with_block_tag,
    "has_section": has_section,
    "is_full_https_url": is_full_https_url,
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
