#!/usr/bin/env python3
"""Assemble changelog fragments into the next minor release."""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
from pathlib import Path

VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--date", default=os.environ.get("RELEASE_DATE") or dt.date.today().isoformat())
    args = parser.parse_args()

    root = args.root.resolve()
    version_path = root / "VERSION"
    changelog_path = root / "CHANGELOG.md"
    fragment_dir = root / "changelog.d"
    fragments = sorted(
        path for path in fragment_dir.glob("*.md") if path.name.casefold() != "readme.md"
    )
    if not fragments:
        print("no changelog fragments")
        return 0

    current = version_path.read_text(encoding="utf-8").strip()
    match = VERSION_RE.fullmatch(current)
    if not match:
        raise SystemExit(f"VERSION is not semantic: {current}")
    major, minor, _ = (int(part) for part in match.groups())
    release = f"{major}.{minor + 1}.0"

    entries = []
    for path in fragments:
        text = path.read_text(encoding="utf-8").strip()
        if not text:
            raise SystemExit(f"empty changelog fragment: {path.name}")
        entries.append(text)

    previous = changelog_path.read_text(encoding="utf-8").lstrip()
    assembled = f"## {release} - {args.date}\n\n" + "\n\n".join(entries) + "\n\n" + previous
    changelog_path.write_text(assembled, encoding="utf-8")
    version_path.write_text(release + "\n", encoding="utf-8")
    for path in fragments:
        path.unlink()
        print(f"included {path.name}")
    print(f"assembled release {release}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
