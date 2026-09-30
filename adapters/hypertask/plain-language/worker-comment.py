#!/usr/bin/env python3
"""Board 15 workers address blockers to the supervisor, never the owner."""
import html
import os
from pathlib import Path
import re
import sys
from html.parser import HTMLParser


NAME = re.compile(r"(?<!\w)@?Valentin(?:\s+Yeo)?\b", re.I)


def is_supervisor(slug):
    if slug == "ht-supervisor":
        return True
    if slug != "product-bot":
        return False
    # Product Bot's reply worker shares the login, but is not ht-supervisor.
    # Check the actual caller, not an environment flag a worker can set.
    entry = (Path.home() / ".local/bin/ht-supervisor").resolve()
    pid = os.getppid()
    while pid > 1:
        try:
            args = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
            if len(args) > 1 and Path(os.fsdecode(args[1])).resolve() == entry:
                return True
            status = Path(f"/proc/{pid}/status").read_text()
            pid = int(re.search(r"^PPid:\s*(\d+)", status, re.M).group(1))
        except (OSError, ValueError, AttributeError):
            return False
    return False


class Comment(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.owner = False
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        owner = attrs.get("data-label", "").lower() in {"name-6", "user-6"}
        owner |= attrs.get("data-type", "").lower() == "mention" and (
            attrs.get("data-id") == "6" or attrs.get("data-user-id") == "6")
        if owner:
            self.owner = True
            self.parts.append(" ")
            self.skip += 1
        elif self.skip:
            self.skip += 1
        elif tag == "a" and attrs.get("href", "").startswith("https://"):
            self.parts.append(" " + attrs["href"] + " ")
        elif tag in {"p", "li", "br"}:
            self.parts.append(" ")

    def handle_endtag(self, tag):
        if self.skip:
            self.skip -= 1
        elif tag in {"p", "li"}:
            self.parts.append(" ")

    def handle_data(self, text):
        if not self.skip:
            self.parts.append(text)


def rewrite(text):
    comment = Comment()
    comment.feed(text)
    plain = " ".join("".join(comment.parts).split())
    if not comment.owner and not NAME.search(plain):
        return text
    plain = NAME.sub(" ", plain)
    plain = plain.replace("\u2014", ", ").replace("\u2013", ", ").replace("`", "")
    plain = re.sub(r"https?://\S+", " ", plain)
    plain = re.sub(r"\b(?:HTPR|AGTE)-\d+\b", "the ticket", plain, flags=re.I)
    plain = re.sub(r"\bPR(?:\s*#?\s*|-)\d+\b", "the pull request", plain, flags=re.I)
    plain = re.sub(r"\b[0-9A-Fa-f]{7,}\b", " ", plain)
    plain = re.sub(r"\S+\.(?:ts|tsx|py|cjs|mjs)\b", " ", plain, flags=re.I)
    plain = re.sub(r"\bsrc/\S+", " ", plain)
    plain = re.sub(r"\b[A-Za-z_][A-Za-z0-9_]*\s*\(\s*\)", " ", plain)
    plain = re.sub(r"^(?:Question|Answer|Decision|Handoff|Done):\s*", "", plain, flags=re.I)
    plain = re.sub(r"^(?:the supervisor\s*[,.:]?\s*)+", "", plain, flags=re.I)
    plain = " ".join(plain.split()).strip(" ,.;:")
    words = plain.split()
    plain = " ".join(words[:55]) if words else "please handle this blocker"
    if not plain.endswith(("?", ".", "!")):
        plain += "."
    return ("<p><strong>Question: Supervisor, " + html.escape(plain)
            + "</strong></p><p>Next: the supervisor reviews this blocker.</p>")


if __name__ == "__main__":
    if sys.argv[1] == "--is-supervisor":
        raise SystemExit(0 if is_supervisor(sys.argv[2]) else 1)
    text = sys.stdin.read()
    ref, boards = sys.argv[1:3]
    scoped = ref.upper().startswith("HTPR-") or (
        (not ref or ref.isdigit()) and "15" in boards.split(","))
    sys.stdout.write(rewrite(text) if scoped else text)
