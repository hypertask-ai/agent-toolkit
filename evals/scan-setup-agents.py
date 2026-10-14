#!/usr/bin/env python3
"""Reject private deployment details in the public skill, including filenames."""

from pathlib import Path
import os
import re
import sys

ROOT = Path(__file__).resolve().parents[1] / "skills/setup-agents"
# Maintainers keep deployment-specific words (names, ids, hosts) in a private
# file, one regex per line, so this public scanner never lists them itself.
PRIVATE = os.environ.get("SETUP_AGENTS_PRIVATE_PATTERNS")
EXTRA = ""
if PRIVATE and Path(PRIVATE).is_file():
    lines = [line.strip() for line in Path(PRIVATE).read_text().splitlines()]
    EXTRA = "".join(line + "|" for line in lines if line and not line.startswith("#"))
FORBIDDEN = re.compile(
    EXTRA +
    r"/home/|\brunner[- ]\d+\b|"
    r"ghp_|sk-[a-z0-9]{20}|github_pat_|"
    r"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b|"
    r"project-\d+|\b(?:account|owner|team|project)[-_ ]id\s*[:=]\s*[\"']?\d+|"
    r"app_profile|APP_REPO|app-ship|"
    r"https?://(?:localhost|127\.0\.0\.1|[^/\s]+\.(?:internal|local))\b",
    re.IGNORECASE,
)


def scan(root):
    if not root.is_dir() or root.is_symlink():
        raise ValueError("missing or linked public skill directory")
    files = sorted(path for path in root.rglob("*") if path.is_file() or path.is_symlink())
    if not files:
        raise ValueError("empty public skill directory")
    failures = []
    for path in files:
        relative = path.relative_to(root)
        if path.is_symlink() or FORBIDDEN.search(str(relative)):
            failures.append(str(relative))
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeError, OSError):
            failures.append(str(relative))
            continue
        if FORBIDDEN.search(text):
            failures.append(str(relative))
    return failures


if __name__ == "__main__":
    try:
        failures = scan(Path(sys.argv[1]) if len(sys.argv) == 2 else ROOT)
        if failures:
            print("Public skill scan refused files: " + ", ".join(failures), file=sys.stderr)
            sys.exit(1)
        print("Public skill scan: 0 forbidden files")
    except (ValueError, OSError):
        print("Public skill scan could not inspect the complete skill", file=sys.stderr)
        sys.exit(1)
