"""Shared config loading for the kit's project-owned checks and identity."""

import os
from pathlib import Path
import re
import runpy
import shlex

import yaml

CONTRACT = runpy.run_path(str(Path(__file__).with_name("agent-kit")))
REFERENCE = CONTRACT["REFERENCE"]
BOARD_PROJECT = CONTRACT["BOARD_SOURCE"]


def expand(value):
    def replace(match):
        result = os.environ.get(match[1], "")
        if not result.strip():
            raise ValueError("required host profile reference is unset (value not echoed)")
        return result
    return REFERENCE.sub(replace, value)


def load_config():
    path = os.environ.get("KIT_CONFIG")
    if not path:
        pilot = os.environ.get("KIT_PILOT_ENV")
        if not pilot:
            raise ValueError("set KIT_CONFIG or KIT_PILOT_ENV; no project identity fallback")
        for line in Path(pilot).read_text(encoding="utf-8").splitlines():
            parts = shlex.split(line)
            if len(parts) == 2 and parts[0] == "export" and parts[1].startswith("KIT_CONFIG="):
                path = parts[1].split("=", 1)[1]
        if not path:
            raise ValueError("pilot env has no KIT_CONFIG; reinstall the pilot")
    path = Path(expand(path)).expanduser().resolve()
    config = CONTRACT["doctor"](path, quiet=True)
    if config is None:
        raise ValueError("invalid project config")
    if "ship" not in config:
        raise ValueError("config.ship is required for kit runtime")
    return config, path


def ticket(config, value):
    prefixes = "|".join(map(re.escape, config["ship"]["ticket_prefixes"]))
    if not re.fullmatch(r"(?:" + prefixes + r")-[0-9]+", value):
        raise ValueError("ticket must use the configured prefix and number")
    return value


def identity(config, config_path):
    ref = config["ship"].get("identity_profile_ref")
    if not ref or not REFERENCE.fullmatch(ref):
        raise ValueError("identity profile reference is missing; board writes refused")
    profile_path = Path(expand(ref)).expanduser()
    if not profile_path.is_absolute():
        profile_path = config_path.parent / profile_path
    profile = yaml.safe_load(profile_path.read_text(encoding="utf-8"))
    if not isinstance(profile, dict) or profile.get("project") != config["project"]:
        raise ValueError("identity profile must belong to this project; board writes refused")
    name, token_file = profile.get("name"), profile.get("token_file")
    if not isinstance(name, str) or not name.strip() or any(c in name for c in "\r\n\t"):
        raise ValueError("identity profile name is missing or invalid; board writes refused")
    if not isinstance(token_file, str) or not token_file.strip():
        raise ValueError("identity profile token file is missing; board writes refused")
    path = Path(expand(token_file)).expanduser()
    if not path.is_absolute():
        path = profile_path.parent / path
    path = path.resolve()
    if not path.is_file() or path.stat().st_mode & 0o777 != 0o600 or not os.access(path, os.R_OK):
        raise ValueError("identity token file missing or unreadable; board writes refused")
    token = path.read_text(encoding="utf-8").strip()
    if not token or "\n" in token or "\r" in token:
        raise ValueError("identity token file empty or invalid; board writes refused")
    return name, path, token
