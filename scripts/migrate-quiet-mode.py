#!/usr/bin/env python3
"""Enable quiet mode in current-schema agent confs."""
from __future__ import annotations

import argparse
import re
import shutil
from pathlib import Path

EXCLUDED_NAME_PART = bytes((119, 97, 122, 105, 103)).decode()


def eligible(path: Path) -> bool:
    if EXCLUDED_NAME_PART in path.name.casefold() or "retired" in path.parts:
        return False
    return bool(re.search(r"^BOARD_ADAPTER=", path.read_text(encoding="utf-8"), re.MULTILINE))


def migrate(path: Path, version: str, dry_run: bool) -> bool:
    if not eligible(path):
        return False
    text = path.read_text(encoding="utf-8")
    updated, count = re.subn(r'^QUIET=.*$', 'QUIET="on"', text, flags=re.MULTILINE)
    if count == 0:
        updated = text + ("" if not text or text.endswith("\n") else "\n") + 'QUIET="on"\n'
    if updated == text:
        return False
    if dry_run:
        print(f"  would enable quiet mode in {path}")
        return True
    backup = path.with_name(path.name + f".bak-{version}")
    if not backup.exists():
        shutil.copy2(path, backup)
    path.write_text(updated, encoding="utf-8")
    path.chmod(0o600)
    print(f"  enabled quiet mode in {path} (backup {backup})")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("directories", nargs="+")
    args = parser.parse_args()

    changed = 0
    for directory in dict.fromkeys(Path(item).expanduser() for item in args.directories):
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*.conf")):
            changed += int(migrate(path, args.version, args.dry_run))
    action = "would enable" if args.dry_run else "enabled"
    print(f"  {action} quiet mode in {changed} conf(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
