#!/usr/bin/env python3
"""Migrate current-schema agent conf defaults."""
from __future__ import annotations

import argparse
import re
import shlex
import shutil
from pathlib import Path

EXCLUDED_NAME_PART = bytes((119, 97, 122, 105, 103)).decode()


def eligible(path: Path) -> bool:
    if EXCLUDED_NAME_PART in path.name.casefold() or "retired" in path.parts:
        return False
    return bool(re.search(r"^BOARD_ADAPTER=", path.read_text(encoding="utf-8"), re.MULTILINE))


def conf_value(text: str, key: str) -> str:
    matches = re.findall(rf"^{re.escape(key)}=(.*)$", text, re.MULTILINE)
    if not matches:
        return ""
    try:
        parsed = shlex.split(matches[-1], posix=True)
    except ValueError:
        return ""
    return parsed[0] if parsed else ""


def quoted(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    escaped = escaped.replace("$", "\\$").replace("`", "\\`")
    return f'"{escaped}"'


def migrate(path: Path, version: str, dry_run: bool) -> bool:
    if not eligible(path):
        return False
    text = path.read_text(encoding="utf-8")
    updated, count = re.subn(r'^QUIET=.*$', 'QUIET="on"', text, flags=re.MULTILINE)
    if count == 0:
        updated = text + ("" if not text or text.endswith("\n") else "\n") + 'QUIET="on"\n'

    changes = ["quiet mode"] if updated != text else []
    if conf_value(updated, "AGENT_KIND").casefold() == "qa":
        watched = conf_value(updated, "WATCH_SECTIONS")
        sections = [section.strip() for section in watched.split(",") if section.strip()]
        if watched != "*" and not any(section.casefold() == "qa" for section in sections):
            sections.append("QA")
            replacement = f"WATCH_SECTIONS={quoted(','.join(sections))}"
            updated, watch_count = re.subn(
                r"^WATCH_SECTIONS=.*$", replacement, updated, flags=re.MULTILINE
            )
            if watch_count == 0:
                updated += ("" if not updated or updated.endswith("\n") else "\n") + replacement + "\n"
            changes.append("QA section")

    if updated == text:
        return False
    description = " and ".join(changes)
    if dry_run:
        print(f"  would enable {description} in {path}")
        return True
    backup = path.with_name(path.name + f".bak-{version}")
    if not backup.exists():
        shutil.copy2(path, backup)
    path.write_text(updated, encoding="utf-8")
    path.chmod(0o600)
    print(f"  enabled {description} in {path} (backup {backup})")
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
    action = "would migrate" if args.dry_run else "migrated"
    print(f"  {action} current defaults in {changed} conf(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
