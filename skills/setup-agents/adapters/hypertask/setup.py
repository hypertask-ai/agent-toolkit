"""Board provisioning and legacy session lookup paths, not app policy."""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess

DEFAULT_BASE_URL = "https://api.hypertask.ai/api"
TICKET_URL_TEMPLATE = "https://app.hypertask.ai/detail/project-{projectId}/{number}"


def run(args):
    command = shlex.split(os.environ.get("SETUP_AGENTS_MINT_COMMAND", "hypertask"))
    result = subprocess.run(command + args, capture_output=True, text=True)
    if result.returncode:
        raise ValueError("board provisioning failed (output withheld)")
    try:
        doc = json.loads(result.stdout)
        if isinstance(doc, dict) and doc.get("success") is False:
            raise ValueError("board operation refused")
        return doc
    except (ValueError, TypeError):
        raise ValueError("board provisioning returned invalid JSON (output withheld)") from None


def mint(name, board):
    # Same create call as setup-runner and create-agent; never a new token service.
    doc = run(["agents", "create", "--name", name, "--project", str(board), "--role", "write", "--json"])
    agent = doc.get("agent", {})
    values = [doc.get("token"), agent.get("token")]
    values += [doc.get(key) for key in ("bearer_token", "bearerToken", "agent_token", "agentToken")]
    for value in values:
        if isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", value):
            return value
    raise ValueError("agent created but token missing; stop and ask the owner before rotating (output withheld)")


def create_board(project):
    teams = run(["teams", "list", "--json"])
    if not isinstance(teams, list) or not teams or not isinstance(teams[0].get("id"), str):
        raise ValueError("no accessible workspace found; board creation refused")
    doc = run(["project", "create-board", "--team", teams[0]["id"], "--title", project, "--sections",
               "Todo,In Progress,AI Review,Owner Review,Done,Blocked", "--json"])
    board = doc.get("project", doc.get("board", doc)).get("id")
    if type(board) is not int or board < 1:
        raise ValueError("board creation returned no board id (output withheld)")
    return board


def session_path(slug):
    credentials = Path(os.environ.get("SETUP_AGENTS_CREDENTIALS_DIR", str(Path.home() / ".config/hypertask-agents/credentials")))
    sessions = Path(os.environ.get("SETUP_AGENTS_SESSION_CREDENTIALS_DIR", str(credentials / "sessions")))
    return sessions / (slug + "-agent-token")


def board_prefix(board):
    doc = run(["project", "show", str(board), "--json"])
    prefix = doc.get("project", {}).get("uniqueIdentifier")
    if not isinstance(prefix, str) or not re.fullmatch(r"[A-Z][A-Z0-9]*", prefix):
        raise ValueError("board prefix unavailable; refuse setup rather than guess ticket numbers")
    return prefix
