"""Provision only into a temporary HOME with fake board, model and tmux commands."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / "skills/setup-agents"
FIXTURES = ROOT / "evals/setup-agents-fixtures"
CLI = KIT / "bin/setup-agents"
TOKEN = ".".join(["fixture", "private", "credential"])


@pytest.fixture
def host(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    root = home / "projects/widget"
    root.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "-C", str(root), "remote", "add", "origin", "git@github.com:example-org/widget.git"], check=True)
    tools = home / "bin"
    tools.mkdir()
    mint = tools / "board-fake"
    mint.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["FAKE_CALLS"], "a") as f:
    f.write(json.dumps(args) + "\\n")
if os.environ.get("FAKE_FAILURE") or (os.environ.get("FAKE_FAIL_NAME") and os.environ["FAKE_FAIL_NAME"] in args):
    print(os.environ["FAKE_TOKEN"], file=sys.stderr)
    sys.exit(1)
if args[:2] == ["teams", "list"]:
    print(json.dumps([{ "id": "fixture-workspace", "title": "Workspace" }]))
elif args[:2] == ["project", "show"]:
    print(json.dumps({"project": {"uniqueIdentifier": "WIDG"}}))
elif args[:2] == ["project", "create-board"]:
    print(json.dumps({"project": {"id": 99}}))
else:
    token = "" if os.environ.get("FAKE_EMPTY") else os.environ["FAKE_TOKEN"]
    print(json.dumps({"success": True, "agent": {"id": "fixture-agent"}, "token": token}))
''')
    mint.chmod(0o755)
    tmux = tools / "tmux"
    tmux.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_TMUX"], "a") as f:
    f.write(json.dumps(args) + "\\n")
if args[0] == "has-session":
    sys.exit(0 if os.environ.get("FAKE_LIVE_PANES") else 1)
if args[0] == "list-panes":
    print(os.environ.get("FAKE_LIVE_PANES", ""))
if args[0] in ("new-session", "split-window"):
    print("%1")
''')
    tmux.chmod(0o755)
    claude = tools / "claude"
    claude.write_text("#!/bin/sh\nexit 0\n")
    claude.chmod(0o755)
    for tool in ("hypertask", "gh", "curl", "wget"):
        denied = tools / tool
        denied.write_text('#!/bin/sh\nprintf attempted > "$HOME/network-attempt"\nexit 97\n')
        denied.chmod(0o755)
    unlazy = home / ".agents/skills/unlazy"
    unlazy.mkdir(parents=True)
    (unlazy / "SKILL.md").write_text("# Fixture unlazy skill\n")
    (unlazy / "scripts").mkdir()
    (unlazy / "scripts/gate-check.mjs").write_text("// Read-only dependency fixture\n")
    guard = home / ".claude/hooks/browser-guard.sh"
    guard.parent.mkdir(parents=True)
    guard.write_text("#!/bin/sh\ncat >/dev/null\nexit 2\n")
    guard.chmod(0o700)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("KIT_", "SETUP_AGENT", "SHIP_", "SETUP_AGENTS_", "AGENT_KIT_"))}
    env.update(HOME=str(home), PATH=str(tools) + os.pathsep + os.environ["PATH"],
               PYTHONDONTWRITEBYTECODE="1", SETUP_AGENTS_MINT_COMMAND=str(mint),
               SETUP_AGENTS_BROWSER_GUARD=str(guard), FAKE_CALLS=str(home / "calls.jsonl"), FAKE_TMUX=str(home / "tmux.jsonl"), FAKE_TOKEN=TOKEN,
               TICKET_BASE_URL="https://board.example.test")
    yield home, root, env
    assert not (home / "network-attempt").exists()


def run(host, *args):
    _, root, env = host
    return subprocess.run([str(CLI), "--root", str(root), *map(str, args)], env=env,
                          cwd=root, capture_output=True, text=True, timeout=15)


def apply(host, *args):
    return run(host, "--config", FIXTURES / "widget.yaml", "--apply", *args)


def calls(home):
    path = home / "calls.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def snapshot(home):
    return {str(p.relative_to(home)): (p.readlink() if p.is_symlink() else p.read_bytes())
            for p in home.rglob("*") if p.is_file() or p.is_symlink()}


@pytest.mark.parametrize("project", ["widget"])
@pytest.mark.parametrize("flag", [[], ["--dry-run"]])
def test_dry_run_read_only(host, project, flag):
    home, _, _ = host
    before = snapshot(home)
    result = run(host, "--config", FIXTURES / (project + ".yaml"), *flag)
    assert result.returncode == 0, result.stderr
    assert "Dry run" in result.stdout
    assert "Token" not in result.stderr
    assert snapshot(home) == before
    assert not calls(home)


def test_generic_plan_and_map_have_no_app_names(host):
    result = run(host, "--config", FIXTURES / "widget.yaml")
    assert result.returncode == 0
    artifacts = result.stdout + (KIT / "templates/ship.md").read_text() + CLI.read_text()
    for forbidden in ("HTPR", "private-policy", "app_profile", "APP_REPO"):
        assert forbidden not in artifacts
        # Positive control proves the absence assertion can fail.
        with pytest.raises(AssertionError):
            assert forbidden not in artifacts + forbidden


def test_apply_private_tokens_profiles_hooks_and_panes(host):
    home, root, env = host
    result = apply(host)
    assert result.returncode == 0, result.stderr
    assert TOKEN not in result.stdout + result.stderr
    assert len(calls(home)) == 3
    assert all(c[:2] == ["agents", "create"] and "42" in c for c in calls(home))
    state = home / ".local/state/setup-agents/runs.log"
    records = state.read_text().splitlines()
    assert len(records) == 3
    assert all(re.fullmatch(r"widget-(lead|runner-[12]) ready \S+ setup-agents", line) for line in records)
    project = root / ".claude/setup-agents"
    assert (root / "CLAUDE.md").read_text().startswith("# Project sessions")
    assert "printf project-tests" in (root / ".claude/CLAUDE.md").read_text()
    ship = root / ".claude/skills/ship/SKILL.md"
    assert not ship.parent.is_symlink()
    assert ship.read_text() == (KIT / "templates/ship.md").read_text()
    assert "G1:" in (project / "GATES.md").read_text()
    assert not (root / ".claude/agent-profile.md").exists()
    assert "/loop 5m" in (project / "widget-lead.sh").read_text()
    assert "while true" in (project / "widget-lead.sh").read_text()
    assert "/ship" in (project / "widget-runner-1.sh").read_text()
    operations = [json.loads(line)[0] for line in (home / "tmux.jsonl").read_text().splitlines()]
    assert operations.count("new-session") == 1 and operations.count("split-window") == 2
    for agent in ("widget-lead", "widget-runner-1", "widget-runner-2"):
        token = home / ".config/agent-kit/credentials/widget" / (agent + "-agent-token")
        assert token.read_text().strip() == TOKEN
        assert token.stat().st_mode & 0o777 == 0o600
        session = home / ".config/hypertask-agents/credentials/sessions" / token.name
        assert session.resolve() == token
        profile = project / (agent + "-identity.yaml")
        assert yaml.safe_load(profile.read_text())["token_file"] == str(token)
        identity_env = dict(env, KIT_CONFIG=str(project / "project.yaml"), WIDGET_IDENTITY_PROFILE=str(profile))
        identity = subprocess.run([str(KIT / "bin/kit-identity")], env=identity_env, capture_output=True, text=True)
        assert identity.returncode == 0, identity.stderr
        assert TOKEN not in identity.stdout + identity.stderr
        assert str(token) in identity.stdout
        name = yaml.safe_load(profile.read_text())["name"]
    # Tokens occur only in private credential files, never in project artifacts or logs.
    for path in root.rglob("*"):
        if path.is_file() and not path.is_symlink():
            assert TOKEN.encode() not in path.read_bytes()
    assert TOKEN not in state.read_text() + (home / "calls.jsonl").read_text()


def test_apply_reuses_tokens_and_new_internal_agent(host):
    home, root, _ = host
    assert apply(host).returncode == 0
    before = (home / ".config/agent-kit/credentials/widget/widget-runner-1-agent-token").read_bytes()
    assert apply(host).returncode == 0
    assert len(calls(home)) == 3
    result = apply(host, "--new-agent", "Growth Lead")
    assert result.returncode == 0, result.stderr
    assert len(calls(home)) == 4
    assert (root / ".claude/setup-agents/growth-lead.sh").exists()
    assert "SETUP_AGENT_ROLE=lead" in (root / ".claude/setup-agents/growth-lead.sh").read_text()
    assert len((home / ".local/state/setup-agents/runs.log").read_text().splitlines()) == 7
    assert (home / ".config/agent-kit/credentials/widget/widget-runner-1-agent-token").read_bytes() == before


@pytest.mark.parametrize("failure", ["FAKE_FAILURE", "FAKE_EMPTY"])
def test_mint_failure_is_private_and_never_ready(host, failure):
    home, root, env = host
    env[failure] = "1"
    result = apply(host)
    assert result.returncode == 2
    assert TOKEN not in result.stdout + result.stderr
    assert not (home / ".local/state/setup-agents/runs.log").exists()
    assert not (root / "CLAUDE.md").exists()
    assert not list((home / ".config/agent-kit/credentials").rglob("*-agent-token"))


@pytest.mark.parametrize("conflict", ["session", "symlink", "permissions", "origin"])
def test_conflicts_refuse_before_mint_and_preserve_files(host, conflict):
    home, root, _ = host
    marker = root / "precious"
    marker.write_text("preserve")
    if conflict == "session":
        path = home / ".config/hypertask-agents/credentials/sessions/widget-lead-agent-token"
        path.parent.mkdir(parents=True)
        path.write_text("existing")
    elif conflict == "symlink":
        (root / ".claude").symlink_to(root)
    elif conflict == "permissions":
        path = home / ".config/agent-kit/credentials/widget/widget-lead-agent-token"
        path.parent.mkdir(parents=True)
        path.write_text(TOKEN)
        path.chmod(0o644)
    else:
        subprocess.run(["git", "-C", str(root), "remote", "set-url", "origin", "git@github.com:other/project.git"], check=True)
    result = apply(host)
    assert result.returncode == 2
    assert calls(home) == []
    assert marker.read_text() == "preserve"
    assert TOKEN not in result.stdout + result.stderr


def test_browser_guard_blocks_all_runners_and_preserves_existing_hook(host):
    _, root, env = host
    settings = root / ".claude/settings.local.json"
    settings.parent.mkdir()
    old = {"permissions": {"allow": ["Bash(git status)"]}, "hooks": {"PreToolUse": [{"matcher": "Read", "hooks": []}]}}
    settings.write_text(json.dumps(old))
    assert apply(host, "--new-agent", "Growth Runner 1").returncode == 0
    data = json.loads(settings.read_text())
    assert data["permissions"] == old["permissions"]
    assert data["hooks"]["PreToolUse"][0] == old["hooks"]["PreToolUse"][0]
    guard = root / ".claude/setup-agents/runner-guard.sh"
    for role, code in (("runner", 2), ("lead", 0)):
        result = subprocess.run([str(guard)], env=dict(env, SETUP_AGENT_ROLE=role, SETUP_AGENT_NAME="Growth Runner 1"),
                                input=json.dumps({"tool_input": {"command": "browser open https://example.test"}}), capture_output=True, text=True)
        assert result.returncode == code
    assert apply(host, "--new-agent", "Growth Runner 1").returncode == 0
    assert len(json.loads(settings.read_text())["hooks"]["PreToolUse"]) == 2





def test_new_board_uses_fake_only_and_is_reused(host):
    home, root, _ = host
    args = ("--repo", "example-org/widget", "--board", "new", "--runners", "0", "--apply")
    result = run(host, *args)
    assert result.returncode == 0, result.stderr
    assert calls(home)[0][:2] == ["teams", "list"]
    assert calls(home)[1][:2] == ["project", "create-board"]
    assert "fixture-workspace" in calls(home)[1]
    config = yaml.safe_load((root / ".claude/setup-agents/project.yaml").read_text())
    assert config["ship"]["board_id"] == 99
    assert "99" in calls(home)[3]
    assert config["ticket_prefix"] == "WIDG"
    assert run(host, *args).returncode == 0
    assert len([c for c in calls(home) if c[:2] == ["project", "create-board"]]) == 1
    assert len([c for c in calls(home) if c[:2] == ["agents", "create"]]) == 1


@pytest.mark.parametrize("args", [["--runners", "-1"], ["--runners", "33"], ["--lead", "Widget Runner 1"],
                                   ["--new-agent", "../../"], ["--new-agent", "Lead | ticket"], ["--board", "0"]])
def test_invalid_input_never_writes(host, args):
    home, _, _ = host
    before = snapshot(home)
    result = run(host, "--config", FIXTURES / "widget.yaml", *args)
    assert result.returncode == 2
    assert snapshot(home) == before


def test_modified_generated_file_is_not_overwritten(host):
    home, root, _ = host
    assert apply(host).returncode == 0
    file = root / ".claude/setup-agents/project.yaml"
    file.write_text("my edits")
    count = len(calls(home))
    result = apply(host, "--new-agent", "One more runner")
    assert result.returncode == 2
    assert file.read_text() == "my edits"
    assert len(calls(home)) == count


def test_existing_project_layers_are_extended_without_erasing_rules(host):
    _, root, _ = host
    (root / "CLAUDE.md").write_text("# Existing root rules\nKeep these.\n")
    (root / ".claude").mkdir()
    (root / ".claude/CLAUDE.md").write_text("# Existing local rules\nKeep these too.\n")
    assert apply(host).returncode == 0
    assert (root / "CLAUDE.md").read_text().startswith("# Existing root rules\nKeep these.\n")
    assert (root / ".claude/CLAUDE.md").read_text().startswith("# Existing local rules\nKeep these too.\n")
    before = (root / ".claude/CLAUDE.md").read_text()
    assert apply(host, "--new-agent", "Another Runner").returncode == 0
    assert (root / ".claude/CLAUDE.md").read_text() == before


def test_new_board_conflict_never_calls_board(host):
    home, root, _ = host
    existing = root / ".claude/setup-agents/project.yaml"
    existing.parent.mkdir(parents=True)
    existing.write_text("Existing setup")
    result = run(host, "--repo", "example-org/widget", "--board", "new", "--apply")
    assert result.returncode == 2
    assert calls(home) == []


def test_live_panes_not_duplicated_and_lead_name_cannot_exempt_runners(host):
    home, root, env = host
    assert apply(host, "--lead", "RUNNER").returncode == 0
    env["FAKE_LIVE_PANES"] = "setup-widget-runner 0\nsetup-widget-widget-runner-1 0\nsetup-widget-widget-runner-2 0"
    before = (home / "tmux.jsonl").read_text().splitlines()
    assert apply(host, "--lead", "RUNNER").returncode == 0
    new = [json.loads(line)[0] for line in (home / "tmux.jsonl").read_text().splitlines()[len(before):]]
    assert "new-session" not in new and "split-window" not in new
    guard = root / ".claude/setup-agents/runner-guard.sh"
    blocked = subprocess.run([str(guard)], env=dict(env, SETUP_AGENT_ROLE="runner", SETUP_AGENT_LEAD="RUNNER"),
                             input=json.dumps({"tool_input": {"command": "browser navigate https://example.test"}}), capture_output=True, text=True)
    assert blocked.returncode == 2


def test_partial_mint_recovery_reuses_saved_credential(host):
    home, _, env = host
    env["FAKE_FAIL_NAME"] = "Widget Runner 1"
    assert apply(host).returncode == 2
    saved = home / ".config/agent-kit/credentials/widget/widget-lead-agent-token"
    assert saved.read_text().strip() == TOKEN
    assert not (home / ".local/state/setup-agents/runs.log").exists()
    del env["FAKE_FAIL_NAME"]
    assert apply(host).returncode == 0
    assert len([c for c in calls(home) if "Widget Lead" in c]) == 1


def test_runner_launcher_uses_named_session_and_contains_no_token(host):
    _, root, env = host
    assert apply(host, "--runners", "1").returncode == 0
    project = root / ".claude/setup-agents"
    for script in project.glob("*.sh"):
        assert subprocess.run(["bash", "-n", str(script)], capture_output=True).returncode == 0
    launched = subprocess.run([str(project / "widget-runner-1.sh")], env=env, capture_output=True, text=True)
    assert launched.returncode == 0
    assert TOKEN not in launched.stdout + launched.stderr


def test_dry_run_creates_no_python_bytecode_without_env_opt_out(host):
    home, root, env = host
    copy = home / "kit-copy"
    shutil.copytree(KIT, copy, ignore=shutil.ignore_patterns("__pycache__", ".pytest_cache"))
    env.pop("PYTHONDONTWRITEBYTECODE", None)
    before = snapshot(home)
    result = subprocess.run([str(copy / "bin/setup-agents"), "--config", str(FIXTURES / "widget.yaml")],
                            cwd=root, env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert snapshot(home) == before
    assert not list(copy.rglob("*.pyc"))




def test_skill_frontmatter_and_bundled_helpers():
    skill = (KIT / "SKILL.md").read_text()
    assert yaml.safe_load(skill.split("---", 2)[1])["name"] == "setup-agents"
    for name in ("setup-agents", "kit-identity", "kit-check", "kit_runtime.py", "agent-kit"):
        assert (KIT / "bin" / name).is_file()


def test_apply_without_optional_guard_preserves_hooks(host):
    home, root, env = host
    env.pop("SETUP_AGENTS_BROWSER_GUARD")
    settings = root / ".claude/settings.local.json"
    settings.parent.mkdir()
    old = {"hooks": {"PreToolUse": [{"matcher": "Read", "hooks": []}]}}
    settings.write_text(json.dumps(old))
    assert apply(host).returncode == 0
    assert json.loads(settings.read_text()) == old
    assert not (root / ".claude/setup-agents/runner-guard.sh").exists()


def test_standalone_copy_applies_without_repository_helpers(host):
    home, root, env = host
    copy = home / "standalone-skill"
    shutil.copytree(KIT, copy, ignore=shutil.ignore_patterns("__pycache__"))
    result = subprocess.run([str(copy / "bin/setup-agents"), "--root", str(root),
                             "--repo", "example-org/widget", "--board", "42", "--apply"],
                            env=env, cwd=root, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stderr
    assert (root / ".claude/skills/setup-agents").resolve() == copy
    assert "KIT_HOME=" + str(copy) in (root / ".claude/setup-agents/widget-runner-1.sh").read_text()
    assert len([c for c in calls(home) if c[:2] == ["agents", "create"]]) == 3


@pytest.mark.parametrize("forbidden", [
    "/home/operator", "runner-6", "RUNNER 7", "ghp_", "sk-" + "a" * 20,
    "account_id: 123", "project_id: 123", "project-15", "https://service.internal", "app_profile",
    "11111111-1111-1111-1111-111111111111", "examplecorp", "acme-ops lead",
])
def test_public_scan_rejects_each_positive_control(tmp_path, forbidden, monkeypatch):
    import runpy
    private = tmp_path / "private-patterns.txt"
    private.write_text("# deployment words\nexamplecorp\nacme-ops lead\n")
    monkeypatch.setenv("SETUP_AGENTS_PRIVATE_PATTERNS", str(private))
    scanner = runpy.run_path(str(ROOT / "evals/scan-setup-agents.py"))["scan"]
    public = tmp_path / "public"
    public.mkdir()
    file = public / "SKILL.md"
    file.write_text("generic skill")
    assert scanner(public) == []
    file.write_text("generic skill " + forbidden)
    assert scanner(public) == ["SKILL.md"]
    result = subprocess.run(["python3", str(ROOT / "evals/scan-setup-agents.py"), str(public)],
                            capture_output=True, text=True, env=dict(os.environ))
    assert result.returncode == 1
    assert forbidden not in result.stdout + result.stderr


def test_public_scan_rejects_forbidden_filenames_and_links(tmp_path):
    import runpy
    scanner = runpy.run_path(str(ROOT / "evals/scan-setup-agents.py"))["scan"]
    (tmp_path / "private-runner-6.md").write_text("generic")
    (tmp_path / "linked.md").symlink_to(tmp_path / "private-runner-6.md")
    assert len(scanner(tmp_path)) == 2
    with pytest.raises(ValueError):
        scanner(tmp_path / "missing")


def test_public_scan_has_no_forbidden_artifacts():
    import runpy
    scanner = runpy.run_path(str(ROOT / "evals/scan-setup-agents.py"))["scan"]
    assert scanner(KIT) == []


@pytest.mark.parametrize("role", [None, "lead", "other"])
def test_optional_guard_does_not_affect_non_runner_sessions(host, role):
    _, root, env = host
    assert apply(host).returncode == 0
    guard_env = dict(env)
    guard_env.pop("SETUP_AGENT_ROLE", None)
    if role is not None:
        guard_env["SETUP_AGENT_ROLE"] = role
    result = subprocess.run([str(root / ".claude/setup-agents/runner-guard.sh")],
                            env=guard_env, input="{}", capture_output=True, text=True)
    assert result.returncode == 0
