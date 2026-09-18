#!/usr/bin/env python3
"""Final outbound formatting for Hypertask ticket references."""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
import urllib.parse
import urllib.request
from collections.abc import Callable
from typing import Any

TICKET_PATTERN = re.compile(r"\b(?!PR-\d+\b)[A-Z][A-Z0-9]*-\d+\b")
TICKET_URL_PATTERN = r"https://app\.hypertask\.ai/detail/project-\d+/\d+"


class TicketLinkError(RuntimeError):
    pass


def _task_from_payload(reference: str, payload: dict[str, Any]) -> dict[str, Any]:
    task = payload.get("task")
    rows = [task] if isinstance(task, dict) else payload.get("tasks") or []
    for row in rows:
        if isinstance(row, dict) and str(row.get("ticketNumber") or "").upper() == reference:
            return row
    raise TicketLinkError(f"the board API did not return {reference}")


def ticket_details(reference: str, payload: dict[str, Any]) -> tuple[str, str]:
    task = _task_from_payload(reference, payload)
    title = " ".join(str(task.get("title") or "").split())
    project = task.get("projectId") or task.get("project_id") or task.get("boardId")
    project_row = task.get("project")
    if not project and isinstance(project_row, dict):
        project = project_row.get("id")
    index = task.get("uniqueIndex") or task.get("unique_index") or reference.rsplit("-", 1)[-1]
    if not title or not project or not index:
        raise TicketLinkError(f"the board API returned incomplete details for {reference}")
    return title, f"https://app.hypertask.ai/detail/project-{project}/{index}"


def remove_em_dashes(text: str) -> str:
    return re.sub(r"\s*—\s*", ", ", text)


def format_ticket_links(
    text: str,
    mode: str,
    lookup: Callable[[str], dict[str, Any]],
) -> str:
    references = list(dict.fromkeys(match.group(0) for match in TICKET_PATTERN.finditer(text)))
    if not references:
        return remove_em_dashes(text)

    details = {reference: ticket_details(reference, lookup(reference)) for reference in references}
    placeholders: dict[str, str] = {}

    def link(reference: str) -> str:
        title, url = details[reference]
        label = f"{reference} {title}"
        if mode == "html":
            return f'<a href="{html.escape(url, quote=True)}">{html.escape(label)}</a>'
        escaped = label.replace("\\", "\\\\").replace("]", "\\]")
        return f"[{escaped}]({url})"

    def hold(value: str) -> str:
        key = f"\x00TICKETLINK{len(placeholders)}\x00"
        placeholders[key] = value
        return key

    def replace_existing(match: re.Match[str]) -> str:
        found = TICKET_PATTERN.search(match.group(0))
        return hold(link(found.group(0))) if found else match.group(0)

    if mode == "html":
        text = re.sub(r"<a\b[^>]*>.*?</a>", replace_existing, text, flags=re.IGNORECASE | re.DOTALL)
    else:
        text = re.sub(
            rf"\[[^\]]*{TICKET_PATTERN.pattern}[^\]]*\]\({TICKET_URL_PATTERN}\)",
            replace_existing,
            text,
        )

    plain_reference = re.compile(rf"({TICKET_PATTERN.pattern})(?:\s+{TICKET_URL_PATTERN})?")
    if mode == "html":
        parts = re.split(r"(<[^>]+>)", text)
        for index in range(0, len(parts), 2):
            parts[index] = plain_reference.sub(lambda match: hold(link(match.group(1))), parts[index])
        text = "".join(parts)
    else:
        text = plain_reference.sub(lambda match: hold(link(match.group(1))), text)

    for key, value in placeholders.items():
        text = text.replace(key, value)
    return remove_em_dashes(text)


def api_lookup(api_url: str, token: str) -> Callable[[str], dict[str, Any]]:
    base = api_url.rstrip("/")

    def lookup(reference: str) -> dict[str, Any]:
        query = urllib.parse.urlencode({"ticket_number": reference})
        request = urllib.request.Request(
            f"{base}/mcp/tasks?{query}",
            headers={
                "Authorization": f"Bearer {token}",
                "User-Agent": "agent-ticket-links/1",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                payload = json.load(response)
        except Exception as error:
            raise TicketLinkError(f"the board API lookup failed for {reference}") from error
        if not isinstance(payload, dict) or payload.get("success") is False:
            raise TicketLinkError(f"the board API returned an invalid response for {reference}")
        return payload

    return lookup


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("chat", "html"), required=True)
    parser.add_argument("--api-url", default="https://app.hypertask.ai/api")
    parser.add_argument("--token-file", required=True)
    args = parser.parse_args()
    try:
        token = open(args.token_file, encoding="utf-8").read().strip()
        output = format_ticket_links(sys.stdin.read(), args.mode, api_lookup(args.api_url, token))
    except (OSError, TicketLinkError) as error:
        print(str(error), file=sys.stderr)
        return 1
    sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
