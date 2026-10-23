#!/usr/bin/env bash
# Conf text must remain data through every reader, including creation/resume.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" <<'PY'
import contextlib
import io
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "scripts"))
from config_files import ConfError, parse_conf, quoted, read_conf

def bash(script, *args, **kwargs):
    return subprocess.run(["bash", "-c", 'set -euo pipefail; . "$CORE_ROOT/scripts/lib/core.sh"; ' + script, "conf-test", *map(str, args)], **kwargs)

with tempfile.TemporaryDirectory() as temporary:
    tmp = Path(temporary)
    env = {**os.environ, "HOME": str(tmp), "CORE_ROOT": str(root),
           "AGENT_CONFIG_DIR": str(tmp / "confs"), "AGENT_BIN_DIR": str(tmp / "bin"),
           "AGENT_SYSTEMD_DIR": str(tmp / "units"), "COMPANY_SKILLS_INDEX": str(tmp / "INDEX.md"),
           "PYTHONDONTWRITEBYTECODE": "1"}
    (tmp / "bin").mkdir()
    (tmp / "INDEX.md").write_text("# Test pack\n")
    (tmp / "bin/gh").write_text("#!/bin/sh\n[ \"$*\" = 'repo view org/memory' ]\n")
    (tmp / "bin/gh").chmod(0o755)
    env["PATH"] = str(tmp / "bin") + ":" + os.environ["PATH"]
    marker = tmp / "marker"
    # Prove the marker oracle detects a real execution, without sourcing a conf.
    bash('touch "$1"', marker, env=env, check=True)
    assert marker.exists()
    marker.unlink()
    payloads = [f'$(touch {marker})', f'`touch {marker}`',
                f'"; touch {marker}; #', '\\', 'normal spaces "quotes" café 日本語 $ ` \\']
    readers = [
        runpy.run_path(str(root / "scripts/agent-chat"))["parse_conf"],
        runpy.run_path(str(root / "scripts/agent-events"))["parse_config"],
        runpy.run_path(str(root / "scripts/agent-kick"))["parse_config"],
        runpy.run_path(str(root / "scripts/migrate-provider-policy.py"))["read_conf"],
        read_conf,
    ]
    progress = runpy.run_path(str(root / "scripts/agent-progress"))["host_config_value"]
    health = runpy.run_path(str(root / "scripts/agent-board-health"))["Health"].conf_value
    status = runpy.run_path(str(root / "scripts/agent-status"))["parse_env"]
    fleet = {"__name__": "conf_test"}
    fleet_source = (root / "scripts/agent-fleet-watch").read_text().split("<<'PYEOF'\n", 1)[1].rsplit("\nPYEOF", 1)[0]
    saved_argv = sys.argv
    sys.argv = ["fleet-test", str(root)]
    exec(compile(fleet_source, "agent-fleet-watch", "exec"), fleet)
    sys.argv = saved_argv
    readers.extend([status, fleet["parse_env"]])
    for index, payload in enumerate(payloads):
        name = f"Security {index} {payload}"
        mission = tmp / "mission"
        mission.write_text(payload + "\n\n")  # cat command substitution strips trailing newlines.
        command = ["bash", str(root / "scripts/create-agent.sh"), "--name", name,
                   "--kind", "cli", "--board", "none", "--wiring", "none",
                   "--skills-index", str(tmp / "INDEX.md"), "--pr-repo", "org/memory",
                   "--project", 'board "quote" $ ` \\', "--mission-file", str(mission), "--yes"]
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        paths = list((tmp / "confs").glob("*.conf"))
        conf = next(path for path in paths if read_conf(path).get("AGENT_NAME") == name + " CLI")
        expected = read_conf(conf)
        assert expected["AGENT_MISSION"] == payload
        assert expected["AGENT_NAME"] == name + " CLI"
        for reader in readers:
            assert reader(conf) == expected
        assert progress(conf, "AGENT_MISSION") == payload
        assert health(conf, "AGENT_MISSION") == payload
        for helper in ["manager_conf_value", "instruction_conf_value"]:
            script = root / ("scripts/agent-template" if helper == "manager_conf_value" else "scripts/lib/instructions.sh")
            definition = script.read_text().split(helper + "() {", 1)[1].split("\n}", 1)[0]
            result = bash(helper + "() {" + definition + "\n}; " + helper + ' "$1" AGENT_MISSION', conf, env=env, capture_output=True, check=True)
            assert result.stdout == payload.encode()
        result = bash('core_read_conf "$1"; printf "%s\\0%s" "$AGENT_NAME" "$AGENT_MISSION"',
                      conf, env=env, capture_output=True, check=True)
        assert result.stdout == (name + " CLI\0" + payload).encode()
        assert not marker.exists()
        before = conf.read_bytes()
        resumed = subprocess.run(["bash", str(root / "scripts/create-agent.sh"), "--resume", "--name", name,
                                  "--kind", "cli", "--board", "none", "--wiring", "none", "--yes"],
                                 env=env, capture_output=True, text=True)
        assert resumed.returncode == 0, resumed.stderr
        assert conf.read_bytes() == before
        assert expected["PR_REPO"] == "org/memory"
        assert expected["BOARD_ID"] in resumed.stdout
        assert not marker.exists()
    print("PASS create/resume and Python/Bash byte round-trips")

    conf = tmp / "grammar.conf"
    valid = ['KEY=', 'KEY=bare/path:foo,bar@x+1=-2', "KEY='spaces $ ` \\\"'",
             'KEY="plain legacy value"', 'KEY="quoted"  # comment', 'KEY= # comment',
             'KEY="unicode café 日本語"', 'KEY=""\t', '# comment', '  ']
    for line in valid:
        conf.write_text(line + "\n")
        expected = parse_conf(conf.read_text(), conf).get("KEY", "")
        result = bash('core_read_conf "$1"; printf "%s" "${KEY:-}"', conf, env=env, capture_output=True, check=True)
        assert result.stdout == expected.encode(), line
    bad = [f'"x $(touch {marker})"', f'"x `touch {marker}`"', f'"x"; touch {marker}',
           '"unclosed', "'unclosed", '"x"tail', '"x"#not-a-comment', r'"x\q"',
           'one two', '$HOME', '$\'ansi\'', r'bare\ word', '"x" "y"', '"x"\\',
           '"x\ny"', '"x\ry"', '"x\x00y"', '(echo no)', '"x" && true']
    for value in bad:
        conf.write_text('KEEP="must not partially load"\nAGENT_MISSION=' + value + '\n')
        result = bash('core_read_conf "$1"', conf, env=env, capture_output=True)
        assert result.returncode != 0
        assert result.stderr.count(b'\n') == 1
        assert b'AGENT_MISSION' in result.stderr and b'plain double-quoted value' in result.stderr
        assert b'touch' not in result.stderr
        for reader in readers:
            with contextlib.redirect_stderr(io.StringIO()) as error:
                assert reader(conf) == {}
            assert 'AGENT_MISSION' in error.getvalue()
        assert not marker.exists()
    # Resume must validate the whole existing file, even if all needed flags are supplied.
    existing = paths[0]
    original = existing.read_bytes()
    existing.write_text(original.decode() + f'AGENT_MISSION="x $(touch {marker})"\n')
    good_name = parse_conf(original.decode(), existing)["AGENT_NAME"].removesuffix(" CLI")
    result = subprocess.run(["bash", str(root / "scripts/create-agent.sh"), "--resume", "--name", good_name,
                             "--kind", "cli", "--board", "none", "--wiring", "none"],
                            env=env, capture_output=True)
    assert result.returncode != 0 and b'AGENT_MISSION' in result.stderr
    assert not marker.exists()
    # One-key helpers validate the whole file, even when asked for a safe key.
    for helper, name in [(progress, "progress"), (health, "health")]:
        with contextlib.redirect_stderr(io.StringIO()) as error:
            assert helper(conf, "KEEP") == ""
        assert "AGENT_MISSION" in error.getvalue(), name
    for helper, file in [("manager_conf_value", "scripts/agent-template"),
                         ("instruction_conf_value", "scripts/lib/instructions.sh")]:
        definition = (root / file).read_text().split(helper + "() {", 1)[1].split("\n}", 1)[0]
        result = bash(helper + "() {" + definition + "\n}; " + helper + ' "$1" KEEP', conf,
                      env=env, capture_output=True)
        assert result.returncode != 0 and b'AGENT_MISSION' in result.stderr and not result.stdout
    quiet = runpy.run_path(str(root / "scripts/migrate-quiet-mode.py"))["conf_value"]
    try:
        quiet(conf.read_text(), "KEEP")
        raise AssertionError("quiet migration accepted unsafe conf")
    except ConfError:
        pass
    print("PASS exact grammar, legacy rejection and no partial Python loads")

    for flag, value in [("--name", "multi\nline"), ("--model-cli", "multi\nline")]:
        result = subprocess.run(["bash", str(root / "scripts/create-agent.sh"), flag, value], env=env, capture_output=True)
        assert result.returncode != 0 and b'single-line' in result.stderr
    mission.write_text("multi\nline\n")
    result = subprocess.run(["bash", str(root / "scripts/create-agent.sh"), "--name", "Multiline", "--kind", "cli",
                             "--pr-repo", "org/memory", "--skills-index", str(tmp / "INDEX.md"),
                             "--mission-file", str(mission)], env=env, capture_output=True)
    assert result.returncode != 0 and b'AGENT_MISSION must be single-line' in result.stderr
    # Resume omitted flags must decode escaped PR_REPO, repo path and board ID,
    # not just preserve their serialized lines on disk.
    resume_repo = tmp / 'repo"$`\\'
    resume_repo.mkdir()
    resume_conf = tmp / "confs/resume-fixture.conf"
    resume_values = {"AGENT_NAME": "Resume Fixture CLI", "AGENT_REPO": str(resume_repo),
                     "PR_REPO": 'org/memory"$`\\', "SKILLS_INDEX": str(tmp / "INDEX.md"),
                     "BOARD_ID": 'board"$`\\', "AGENT_SLUG": "resume-fixture"}
    resume_conf.write_text(''.join(f'{key}={quoted(value)}\n' for key, value in resume_values.items()))
    before = resume_conf.read_bytes()
    result = subprocess.run(["bash", str(root / "scripts/create-agent.sh"), "--resume", "--name", "Resume Fixture",
                             "--kind", "cli", "--board", "none", "--wiring", "none", "--dry-run"],
                            env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    for key in ["AGENT_REPO", "PR_REPO", "SKILLS_INDEX", "BOARD_ID"]:
        # BOARD_ID is only printed when an adapter is selected, but the shared CLI
        # decoder is the exact same resume path for all four keys.
        if key != "BOARD_ID":
            assert resume_values[key] in result.stdout
    assert resume_conf.read_bytes() == before and not marker.exists()
    print("PASS resume decodes escaped omitted repo, memory repo, skills and board values")
    print("PASS creation refuses multiline names, commands and missions")
print("CONF DATA PASS")
PY
