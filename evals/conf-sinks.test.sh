#!/usr/bin/env bash
# Exercise the real wrapper generator, refresh block, and conf discovery sinks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "scripts"))
from config_files import quoted

with tempfile.TemporaryDirectory() as temporary:
    tmp = Path(temporary)
    (tmp / "bin").mkdir()
    (tmp / "confs").mkdir()
    (tmp / "token").write_text("fixture-not-a-real-token\n")
    # Print only the argument vector; never the token environment.
    (tmp / "bin/hypertask").write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
    (tmp / "bin/hypertask").chmod(0o755)
    # Any accidental HTTP call fails locally, never reaching the network.
    (tmp / "bin/curl").write_text('#!/bin/sh\nexit 97\n')
    (tmp / "bin/curl").chmod(0o755)
    env = {**os.environ, "HOME": str(tmp), "XDG_STATE_HOME": str(tmp / "state"),
           "CORE_ROOT": str(root), "AGENT_CONFIG_DIR": str(tmp / "confs"),
           "PATH": str(tmp / "bin") + ":" + os.environ["PATH"], "PYTHONDONTWRITEBYTECODE": "1"}
    prelude = 'set -euo pipefail; . "$CORE_ROOT/scripts/lib/core.sh"; core_load_adapter hypertask; '
    def bash(script, *args, check=True):
        return subprocess.run(["bash", "-c", prelude + script, "sinks-test", *map(str, args)],
                              env=env, capture_output=True, check=check)
    marker = tmp / "marker"
    bash('touch "$1"', marker)
    assert marker.exists()
    marker.unlink()
    poll = (root / "scripts/agent-board-poll").read_text()
    refresh = poll.split('core_load_adapter "$BOARD_ADAPTER"\nadapter_require_tools\n', 1)[1].split('\n[ -x "$BOARD_CLI" ]', 1)[0]
    discovery = 'answerer_agent_rows() {' + poll.split('answerer_agent_rows() {', 1)[1].split('\nANSWERER_AGENTS=', 1)[0]
    for payload in [f'$(touch {marker})', f'`touch {marker}`', f'"; touch {marker}; #', '\\', 'space "quote" café 日本語']:
        values = {"AGENT_NAME": payload, "AGENT_MISSION": payload, "AGENT_SLUG": "security",
                  "AGENT_ID": "id-" + payload, "BOARD_ID": "1," + payload,
                  "BOARD_ADAPTER": "hypertask", "TOKEN_FILE": str(tmp / "token"),
                  "BOARD_CLI": str(tmp / "wrapper"), "QUIET": payload}
        conf = tmp / "confs/security.conf"
        conf.write_text(''.join(f'{key}={quoted(value)}\n' for key, value in values.items()))
        # Run the actual refresh block from poll, not a second implementation.
        bash('core_read_conf "$1"; SLUG="$AGENT_SLUG"; ' + refresh, conf)
        result = subprocess.run([str(tmp / "wrapper"), "--version"], env=env, capture_output=True)
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == ["--version"]
        # Read only generated assignments to verify every generation-time byte.
        assignments = []
        for line in (tmp / "wrapper").read_text().splitlines():
            if any(line.startswith(key + '=') for key in ["AGENT_NAME", "AGENT_ID", "BOARD_IDS", "QUIET", "TOKEN_FILE"]):
                assignments.append(line)
        result = bash('\n'.join(assignments) + '\nprintf "%s\\0%s\\0%s\\0%s\\0%s" "$AGENT_NAME" "$AGENT_ID" "$BOARD_IDS" "$QUIET" "$TOKEN_FILE"')
        assert result.stdout.split(b'\0') == [values[key].encode() for key in ["AGENT_NAME", "AGENT_ID", "BOARD_ID", "QUIET", "TOKEN_FILE"]]
        result = bash(discovery + '\nBOARD_ADAPTER=hypertask; answerer_agent_rows')
        row = json.loads(result.stdout)
        assert row['id'] == values['AGENT_ID'] and row['boards'] == values['BOARD_ID']
        # Reconcile runs both discovery loops, but a non-board conf avoids all APIs.
        conf.write_text(conf.read_text().replace('BOARD_ADAPTER="hypertask"', 'BOARD_ADAPTER="none"'))
        result = subprocess.run([str(root / "scripts/agent-board-reconcile"), "--config-dir", str(tmp / "confs"),
                                 "--state-dir", str(tmp / "reconcile")], env=env, capture_output=True)
        assert result.returncode == 0, result.stderr
        assert not marker.exists()
    print("PASS real poll refresh, generated wrapper execution and discovery round-trips")

    # All remaining interpolated values, including paths and slug, are shell data.
    payload = f'$(touch {marker}) `touch {marker}` "; :; # \\ café'
    hostile_token = tmp / payload / "token"
    hostile_token.parent.mkdir(parents=True)
    hostile_token.write_text("fixture-not-a-real-token\n")
    bash('BOARD_API_URL="$1"; adapter_install_board_cli "$1" "$2" "$3" "$1" "$1" "$1" "$1"',
         payload, hostile_token, tmp / "all-values-wrapper")
    result = subprocess.run([str(tmp / "all-values-wrapper"), "--version"], env=env, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == ["--version"] and not marker.exists()
    print("PASS hostile slug, token path, ID, board list, quiet flag and API default are inert")

    for key in ["AGENT_NAME", "AGENT_MISSION"]:
        conf.write_text('BOARD_ADAPTER="hypertask"\nAGENT_ID="qa-id"\nAGENT_KIND="qa"\nBOARD_ID="1"\n' +
                        f'{key}="x $(touch {marker})"\n')
        for script in [discovery + '\nBOARD_ADAPTER=hypertask; answerer_agent_rows',
                       'adapter_qa_agent_ids 1', 'core_guard_token_wrappers "$1" no']:
            result = bash(script, tmp / "bin", check=False)
            assert b'invalid ' + key.encode() in result.stderr
            assert b'touch' not in result.stderr and not result.stdout
            assert not marker.exists()
        result = subprocess.run([str(root / "scripts/agent-board-reconcile"), "--config-dir", str(tmp / "confs"),
                                 "--state-dir", str(tmp / "reconcile")], env=env, capture_output=True)
        assert result.returncode != 0 and b'invalid ' + key.encode() in result.stderr
        result = subprocess.run([str(root / "scripts/agent-board-poll"), "--once", "--dry-run", "security"],
                                env=env, capture_output=True)
        assert result.returncode != 0 and b'invalid ' + key.encode() in result.stderr
        assert not marker.exists()
    print("PASS legacy unsafe name/mission refused by poll startup, discovery, reconcile, QA discovery and token guard")

    runner = (root / "evals/run-evals.sh").read_text()
    workflow = (root / ".github/workflows/evals.yml").read_text()
    assert 'evals/run-evals.sh' in workflow
    for name in ['conf-data.test.sh', 'conf-sinks.test.sh']:
        assert f'run_test "$HERE/{name}" bash "$HERE/{name}"' in runner
print("CONF SINKS PASS")
PY
