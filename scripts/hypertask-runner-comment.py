#!/usr/bin/env python3
"""Format ticket references before runner board comments reach Hypertask."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ticket_links import TICKET_PATTERN, TicketLinkError, format_ticket_links  # noqa: E402


def task_lookup(board_cli: str, reference: str) -> dict[str, Any]:
    result = subprocess.run(
        [board_cli, "--json", "task", "get", reference],
        check=True,
        capture_output=True,
        text=True,
    )
    raw = result.stdout
    start, end = raw.find("{"), raw.rfind("}")
    if start < 0 or end <= start:
        raise ValueError(f"the board CLI did not return {reference}")
    return json.loads(raw[start : end + 1])


def main() -> int:
    board_cli = os.environ["AGENT_RUNNER_BOARD_CLI_TARGET"]
    args = sys.argv[1:]
    text = ""
    value_at: int | None = None
    for index, arg in enumerate(args):
        if arg in {"--text", "--body"} and index + 1 < len(args):
            text = args[index + 1]
            value_at = index
            break
        if arg == "--file" and index + 1 < len(args):
            text = Path(args[index + 1]).read_text(encoding="utf-8").rstrip("\n")
            value_at = index
            break
    if text and value_at is not None:
        without_links = re.sub(
            r"<a\b[^>]*>.*?</a>",
            "",
            text,
            flags=re.IGNORECASE | re.DOTALL,
        )
        if TICKET_PATTERN.search(without_links):
            try:
                text = format_ticket_links(
                    text, "html", lambda reference: task_lookup(board_cli, reference)
                )
            except (
                OSError,
                ValueError,
                subprocess.CalledProcessError,
                TicketLinkError,
            ) as error:
                print(f"ticket link formatting failed: {error}", file=sys.stderr)
                return 1
        args[value_at : value_at + 2] = ["--text", text]

    os.execvpe(board_cli, [board_cli, *args], os.environ)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
