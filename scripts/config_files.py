"""Agent config files in board folders, with legacy flat files as fallback."""

import re
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


# Match shell assignment tokens, not shell programs. A comment needs separating
# whitespace: KEY="x"#text is a different value when sourced by Bash.
_ASSIGNMENT = re.compile(
    r"^([A-Z][A-Z0-9_]*)=("
    r"[A-Za-z0-9_./,:@%+=-]+|'[^'\n\r\x00]*'|"
    r'"(?:[^"$`\\\n\r\x00]|\\[\\"$`])*"|'
    r")(?:[ \t]+(?:#[^\n\r\x00]*)?)?$"
)


class ConfError(ValueError):
    pass


def parse_conf(text: str, path: Path | str) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, line in enumerate(text.split("\n"), 1):
        if re.fullmatch(r"[ \t]*(?:#[^\r\x00]*)?", line):
            continue
        match = _ASSIGNMENT.fullmatch(line)
        if not match:
            key = re.match(r"([A-Z][A-Z0-9_]*)=", line)
            key = key[1] if key else f"line {number}"
            raise ConfError(
                f"ERROR: conf {path}: invalid {key}. Do this next: edit {key} "
                "to a plain double-quoted value (escape backslash, double quote, dollar and backtick)"
            )
        key, value = match.groups()
        if value.startswith('"'):
            value = re.sub(r'\\([\\"$`])', r'\1', value[1:-1])
        elif value.startswith("'"):
            value = value[1:-1]
        values[key] = value
    return values


def read_conf(path: Path) -> dict[str, str]:
    try:
        return parse_conf(path.read_bytes().decode("utf-8", errors="surrogateescape"), path)
    except OSError:
        return {}
    except ConfError as error:
        print(error, file=sys.stderr)
        return {}


def quoted(value: str) -> str:
    if "\n" in value or "\r" in value or "\x00" in value:
        raise ValueError("conf values must be single-line text")
    return '"' + re.sub(r'([\\"$`])', r'\\\1', value) + '"'


if __name__ == "__main__":
    path = Path(sys.argv[1])
    try:
        values = parse_conf(path.read_bytes().decode("utf-8", errors="surrogateescape"), path)
    except (OSError, ConfError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
    if len(sys.argv) > 2:
        print(values.get(sys.argv[2], ""), end="")
