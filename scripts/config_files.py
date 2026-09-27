"""Agent config files in board folders, with legacy flat files as fallback."""

import sys
from pathlib import Path


def is_paused(value: str | None, slug: str = "") -> bool:
    normalized = (value or "").casefold()
    if normalized in {"", "no", "false", "0", "off"}:
        return False
    if normalized not in {"yes", "true", "1", "on"}:
        print(f"WARNING: {slug or 'agent'}: unrecognized PAUSED={value!r}; treating as paused", file=sys.stderr)
    return True


def config_files(root: Path):
    seen = set()
    for folder in sorted(path for path in root.iterdir() if path.is_dir() and not path.is_symlink() and path.name != "retired") if root.is_dir() else []:
        for path in sorted(folder.glob("*.conf")):
            if path.stem not in seen:
                seen.add(path.stem)
                yield path
    for path in sorted(root.glob("*.conf")):
        if path.stem not in seen:
            yield path
