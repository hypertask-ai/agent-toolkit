#!/usr/bin/env python3
"""Accept a QA Done verdict only when every acceptance criterion has live evidence."""

from __future__ import annotations

import argparse
import html
from html.parser import HTMLParser
import json
import re
import sys
from typing import Any


class TicketTextParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.heading = ""
        self.in_h2 = False
        self.in_li = False
        self.heading_parts: list[str] = []
        self.item_parts: list[str] = []
        self.criteria: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "h2":
            self.in_h2 = True
            self.heading_parts = []
        elif tag == "li" and self.heading.casefold() == "acceptance criteria":
            self.in_li = True
            self.item_parts = []

    def handle_endtag(self, tag: str) -> None:
        if tag == "h2" and self.in_h2:
            self.heading = " ".join("".join(self.heading_parts).split())
            self.in_h2 = False
        elif tag == "li" and self.in_li:
            item = " ".join("".join(self.item_parts).split())
            if item:
                self.criteria.append(item)
            self.in_li = False

    def handle_data(self, data: str) -> None:
        if self.in_h2:
            self.heading_parts.append(data)
        if self.in_li:
            self.item_parts.append(data)


def document_row(document: Any, singular: str, plural: str) -> dict[str, Any]:
    if not isinstance(document, dict):
        return {}
    if isinstance(document.get(singular), dict):
        return document[singular]
    rows = document.get(plural)
    if isinstance(rows, list) and rows and isinstance(rows[0], dict):
        return rows[0]
    return document


def acceptance_criteria(task: dict[str, Any]) -> list[str]:
    description = str(task.get("description") or task.get("html") or "")
    parser = TicketTextParser()
    parser.feed(description)
    if parser.criteria:
        return parser.criteria

    match = re.search(
        r"(?is)(?:^|\n)\s*(?:#+\s*)?acceptance criteria\s*:?[ \t]*\n(.*?)(?=\n\s*(?:#+\s*)?[A-Z][^\n]*\n|\Z)",
        html.unescape(re.sub(r"<[^>]+>", " ", description)),
    )
    if not match:
        return []
    return [
        re.sub(r"^\s*(?:[-*]|\d+[.)])\s*", "", line).strip()
        for line in match.group(1).splitlines()
        if re.match(r"^\s*(?:[-*]|\d+[.)])\s+\S", line)
    ]


def author_is_qa(comment: dict[str, Any], qa_ids: set[str]) -> bool:
    agent = comment.get("agent") if isinstance(comment.get("agent"), dict) else {}
    return bool(str(agent.get("id") or "") in qa_ids)


def plain_text(comment: dict[str, Any]) -> str:
    value = comment.get("text") or comment.get("commentText") or comment.get("html") or ""
    return " ".join(html.unescape(re.sub(r"<[^>]+>", " ", str(value))).split())


def has_live_evidence(verdict: str, criterion_count: int) -> bool:
    if not re.match(r"Done:", verdict, re.IGNORECASE):
        return False
    if criterion_count == 0:
        return bool(re.search(r"\blive evidence\s*:\s*\S", verdict, re.IGNORECASE))
    markers = list(
        re.finditer(r"\b(?:AC|acceptance criterion)\s*#?\s*(\d+)\b", verdict, re.IGNORECASE)
    )
    found: set[int] = set()
    for index, marker in enumerate(markers):
        number = int(marker.group(1))
        end = markers[index + 1].start() if index + 1 < len(markers) else len(verdict)
        block = verdict[marker.end() : end]
        evidence = re.search(r"\blive evidence\s*:\s*(\S.*)", block, re.IGNORECASE)
        name = block[: evidence.start()] if evidence else ""
        if evidence and re.search(r"[A-Za-z0-9]", name):
            found.add(number)
    return found == set(range(1, criterion_count + 1))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--task", required=True)
    parser.add_argument("--comments", required=True)
    parser.add_argument("--qa-agent-id", action="append", default=[])
    args = parser.parse_args()

    try:
        task_doc = json.loads(args.task)
        comments_doc = json.loads(args.comments)
    except json.JSONDecodeError as error:
        print(f"invalid board JSON: {error}", file=sys.stderr)
        return 2

    task = document_row(task_doc, "task", "tasks")
    comments = comments_doc.get("comments") if isinstance(comments_doc, dict) else None
    if not isinstance(comments, list):
        comments = []
    count = len(acceptance_criteria(task))
    qa_ids = set(args.qa_agent_id)
    candidates = [
        comment
        for comment in comments
        if isinstance(comment, dict)
        and author_is_qa(comment, qa_ids)
        and has_live_evidence(plain_text(comment), count)
    ]
    if not candidates:
        print(
            f"no QA Done verdict has live evidence for all {count} acceptance criteria",
            file=sys.stderr,
        )
        return 1
    newest = max(candidates, key=lambda row: (str(row.get("createdAt") or ""), str(row.get("id") or "")))
    print(newest.get("id") or "qualified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
