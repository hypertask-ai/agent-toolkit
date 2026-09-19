#!/usr/bin/env python3
"""Behavioral checks for signed event dispatch and durable per-agent queueing."""

from __future__ import annotations

import contextlib
import hashlib
import hmac
import importlib.machinery
import importlib.util
import io
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

    host_config = base / "host-config"
    host_config.write_text('EVENTS_URL="https://toolkit.example/webhook/hypertask"\n', encoding="utf-8")
    os.environ["AGENT_TEMPLATE_HOST_CONFIG"] = str(host_config)
    subscriptions = {
        "local-agent": {"active": True, "url": "https://toolkit.example/old-path"},
        "foreign-agent": {"active": True, "url": "https://retired.example/webhook"},
        "inactive-agent": {"active": False, "url": "https://retired.example/webhook"},
        "missing-agent": None,
        "poll-agent": {"active": True, "url": "https://toolkit.example/webhook/hypertask"},
        "registered-agent": {"active": True, "url": "https://manual.example/webhook/hypertask"},
    }
    for slug in subscriptions:
        token = base / f"{slug}.token"
        token.write_text("token\n", encoding="utf-8")
        wiring = "events" if slug in ("local-agent", "registered-agent") else "poll"
        (config / f"{slug}.conf").write_text(
            f'AGENT_SLUG="{slug}"\nAGENT_ID="{slug}-id"\nBOARD_ADAPTER="hypertask"\n'
            f'TOKEN_FILE="{token}"\nWIRING="{wiring}"\n',
            encoding="utf-8",
        )
    (state / "registered-agent.registration.json").write_text(
        '{"url":"https://manual.example/webhook/hypertask"}\n', encoding="utf-8"
    )
    (secrets / "registered-agent.secret").write_text("secret\n", encoding="utf-8")

    original_subscription = module.webhook_subscription
    original_request = module.api_request
    configure_calls = []

    def fake_subscription(values):
        return subscriptions[values["AGENT_SLUG"]]

    def fake_request(values, body):
        configure_calls.append((values["AGENT_SLUG"], body))
        subscriptions[values["AGENT_SLUG"]]["active"] = False
        return {"success": True}

    module.webhook_subscription = fake_subscription
    module.api_request = fake_request
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        assert module.audit_all(json_output=True) == 0
    audit = json.loads(output.getvalue())
    assert audit["foreign_webhooks"] == [{
        "agent": "foreign-agent",
        "url": "https://retired.example/webhook",
        "host": "retired.example",
    }, {
        "agent": "poll-agent",
        "url": "https://toolkit.example/webhook/hypertask",
        "host": "toolkit.example",
    }]
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        assert module.reconcile_all() == 0
        assert module.reconcile_all() == 0
    assert output.getvalue().splitlines() == [
        "foreign webhook deactivated for foreign-agent: retired.example",
        "foreign webhook deactivated for poll-agent: toolkit.example",
    ]
    assert configure_calls == [
        ("foreign-agent", {"action": "configure", "agent_id": "self", "active": False}),
        ("poll-agent", {"action": "configure", "agent_id": "self", "active": False}),
    ]
    module.webhook_subscription = original_subscription
    module.api_request = original_request

    assert '"$CORE_ROOT/scripts/agent-events" reconcile-all' in (root / "scripts/create-agent.sh").read_text()
    assert '"$BIN/agent-events" reconcile-all' in (root / "install.sh").read_text()

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
