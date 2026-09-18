#!/usr/bin/env python3
"""Make the former 3.14 built-in command policy explicit in matching confs."""
from __future__ import annotations

import argparse
import re
import shlex
import shutil
from pathlib import Path

POLICY_KEYS = ("LADDER", "RESEARCH_CLI", "TRIAGE_HARD_CLI")


def read_conf(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", raw)
        if not match:
            continue
        key, value = match.groups()
        try:
            parsed = shlex.split(value, posix=True)
        except ValueError:
            continue
        if len(parsed) == 1:
            values[key] = parsed[0]
    return values


def option(argv: list[str], name: str) -> str:
    for index, item in enumerate(argv):
        if item == name and index + 1 < len(argv):
            return argv[index + 1]
        if item.startswith(name + "="):
            return item.split("=", 1)[1]
    return ""


def had_314_policy(command: str) -> bool:
    try:
        argv = shlex.split(command)
    except ValueError:
        return False
    if not argv:
        return False
    executable = Path(argv[0]).name
    if executable in {"cursor-agent", "codex", "claude"}:
        return True
    return executable == "hax" and option(argv, "--provider") == "codex"


def quoted(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`") + '"'


def migrate(path: Path, version: str, dry_run: bool) -> bool:
    values = read_conf(path)
    command = values.get("MODEL_CLI", "")
    if not command or any(key in values for key in POLICY_KEYS) or not had_314_policy(command):
        return False

    binary = str(Path.home() / ".local/bin/hax")
    high = f"{binary} --provider=codex --model=gpt-5.6-sol --effort=high --no-session -p"
    research = f"{binary} --provider=codex --model=gpt-5.6-sol --effort=xhigh --no-session --raw -p"
    additions = {
        "LADDER": f"{high}|{high}|{high}",
        "RESEARCH_CLI": research,
        "TRIAGE_HARD_CLI": high,
    }
    if dry_run:
        print(f"  would rewrite {path}: " + ", ".join(f"{key}={value}" for key, value in additions.items()))
        return True

    backup = path.with_name(path.name + f".bak-{version}")
    if not backup.exists():
        shutil.copy2(path, backup)
    existing = path.read_text(encoding="utf-8")
    with path.open("a", encoding="utf-8") as handle:
        if existing and not existing.endswith("\n"):
            handle.write("\n")
        for key, value in additions.items():
            handle.write(f"{key}={quoted(value)}\n")
    path.chmod(0o600)
    print(f"  rewrote {path} (backup {backup}): " + ", ".join(additions))
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
        for path in sorted(directory.glob("*.conf")):
            changed += int(migrate(path, args.version, args.dry_run))
    action = "would rewrite" if args.dry_run else "rewrote"
    print(f"  {action} {changed} conf(s) with the former 3.14 policy")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
