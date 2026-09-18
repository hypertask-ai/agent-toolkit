#!/usr/bin/env python3
import runpy
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "scripts"))
from ticket_links import format_ticket_links, remove_em_dashes

payloads = {
    "TEST-7": {"tasks": [{"ticketNumber": "TEST-7", "title": "Fix mobile flow", "projectId": 42, "uniqueIndex": 7}]},
    "AGTE-32": {"tasks": [{"ticketNumber": "AGTE-32", "title": "Link every reply", "projectId": 5500, "uniqueIndex": 32}]},
}
calls = []


def lookup(reference):
    calls.append(reference)
    return payloads[reference]


chat = format_ticket_links(
    "See TEST-7 and [AGTE-32 stale title](https://app.hypertask.ai/detail/project-5500/32).",
    "chat",
    lookup,
)
assert chat == (
    "See [TEST-7 Fix mobile flow](https://app.hypertask.ai/detail/project-42/7) and "
    "[AGTE-32 Link every reply](https://app.hypertask.ai/detail/project-5500/32)."
)
comment = format_ticket_links(
    '<p>Decision: TEST-7 is ready.</p>',
    "html",
    lookup,
)
assert comment == (
    '<p>Decision: <a href="https://app.hypertask.ai/detail/project-42/7">'
    "TEST-7 Fix mobile flow</a> is ready.</p>"
)
assert calls.count("TEST-7") == 2 and calls.count("AGTE-32") == 1
print("PASS ticket-link-final-rewrite")

module = runpy.run_path(str(root / "scripts" / "agent-chat"))
finalize_chat_reply = module["finalize_chat_reply"]
feedback = finalize_chat_reply(
    "diagnostic output\nfiled AGTE-32 https://app.hypertask.ai/detail/project-5500/32\nmore output",
    "file a toolkit ticket",
    lookup,
)
assert feedback == (
    "Feedback was filed as "
    "[AGTE-32 Link every reply](https://app.hypertask.ai/detail/project-5500/32)."
)
delegated = finalize_chat_reply(
    "Handed to QA Bot by product-bot: Check it\nraw command detail",
    "give TEST-7 to QA",
    lookup,
)
assert delegated == (
    "[TEST-7 Fix mobile flow](https://app.hypertask.ai/detail/project-42/7) was delegated to QA Bot."
)
controlled = finalize_chat_reply(
    "ctl status dev-1: timer=active service=inactive\nraw command detail",
    "is dev 1 running",
    lookup,
)
assert controlled == "The ticket runner for dev 1 is active, and its current job is inactive."
refused = finalize_chat_reply(
    "delegate refused: TEST-7 is held by the board owner\nraw command detail",
    "give TEST-7 to QA",
    lookup,
)
assert refused == (
    "[TEST-7 Fix mobile flow](https://app.hypertask.ai/detail/project-42/7) could not be delegated."
)
assert "raw command" not in feedback + delegated + controlled + refused
print("PASS command-result-one-sentence")

assert remove_em_dashes("Ready — ship it.") == "Ready, ship it."
assert format_ticket_links("Done — no ticket.", "chat", lookup) == "Done, no ticket."
print("PASS outbound-em-dash-removal")
