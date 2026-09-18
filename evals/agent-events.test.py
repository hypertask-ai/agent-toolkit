#!/usr/bin/env python3
"""Behavioral checks for signed event dispatch and durable per-agent queueing."""

from __future__ import annotations

import hashlib
import hmac
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import urllib.request

root = Path(__file__).resolve().parent.parent
loader = importlib.machinery.SourceFileLoader("agent_events", str(root / "scripts/agent-events"))
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec is not None
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)

with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    config = base / "config"
    secrets = base / "secrets"
    state = base / "state"
    binary = base / "bin"
    for directory in (config, secrets, state, binary):
        directory.mkdir()
    (config / "test-agent.conf").write_text(
        'AGENT_SLUG="test-agent"\nAGENT_ID="agent-1"\nBOARD_ID="15"\n'
        'WIRING="events"\nMAX_CONCURRENT_RUNS="1"\n', encoding="utf-8"
    )
    secret = "test-signing-secret"
    (secrets / "test-agent.secret").write_text(secret + "\n", encoding="utf-8")
    calls = base / "runner.calls"
    runner = binary / "agent-board-poll"
    runner.write_text(
        "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"$RUNNER_CALLS\"\n",
        encoding="utf-8",
    )
    runner.chmod(0o755)

    os.environ["AGENT_CONFIG_DIR"] = str(config)
    os.environ["AGENT_EVENTS_SECRET_DIR"] = str(secrets)
    os.environ["AGENT_EVENTS_STATE_DIR"] = str(state)
    os.environ["AGENT_BOARD_POLL"] = str(runner)
    os.environ["RUNNER_CALLS"] = str(calls)

    threading.Thread(target=module.dispatch, daemon=True).start()
    server = module.ThreadingHTTPServer(("127.0.0.1", 0), module.EventHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        payload = {
            "deliveryId": "delivery-1",
            "event": "task.assigned",
            "occurredAt": "2026-01-01T00:00:00Z",
            "agentId": "agent-1",
            "projectId": 15,
            "taskId": 38,
            "ticketNumber": "AGTE-38",
            "actor": {"userId": 6, "agentId": None},
        }
        raw = json.dumps(payload, separators=(",", ":")).encode()
        timestamp = str(int(time.time()))
        signature = "sha256=" + hmac.new(
            secret.encode(), timestamp.encode() + b"." + raw, hashlib.sha256
        ).hexdigest()
        request = urllib.request.Request(
            f"http://127.0.0.1:{server.server_port}/webhook/hypertask",
            data=raw, method="POST",
            headers={
                "Content-Type": "application/json",
                "X-Hypertask-Timestamp": timestamp,
                "X-Hypertask-Signature": signature,
                "X-Hypertask-Event": "task.assigned",
                "X-Hypertask-Delivery": "delivery-1",
            },
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            assert response.status == 202
        deadline = time.time() + 5
        while time.time() < deadline and not calls.exists():
            time.sleep(0.01)
        assert calls.read_text(encoding="utf-8").strip() == (
            "--once --ticket AGTE-38 --board 15 test-agent"
        )
        status_path = state / "test-agent.status.json"
        deadline = time.time() + 5
        while time.time() < deadline:
            status = json.loads(status_path.read_text(encoding="utf-8"))
            if status.get("queueLength") == 0 and status.get("lastRunTicket") == "AGTE-38":
                break
            time.sleep(0.01)
        assert status["lastEvent"] == "task.assigned"
        assert status["queueLength"] == 0
        with urllib.request.urlopen(request, timeout=5) as response:
            assert response.status == 202
        time.sleep(0.05)
        assert calls.read_text(encoding="utf-8").strip().splitlines() == [
            "--once --ticket AGTE-38 --board 15 test-agent"
        ]
    finally:
        server.shutdown()
        thread.join(timeout=5)

print("PASS agent-events-signed-targeted-queue")
