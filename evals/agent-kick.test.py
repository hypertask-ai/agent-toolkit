#!/usr/bin/env python3
"""Behavioral check for mention-to-systemd dispatch."""

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
loader = importlib.machinery.SourceFileLoader("agent_kick", str(root / "scripts/agent-kick"))
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec is not None
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)

with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    config = base / "config"
    secrets = base / "secrets"
    binary = base / "bin"
    config.mkdir()
    secrets.mkdir()
    binary.mkdir()
    (config / "test-agent.conf").write_text(
        'AGENT_SLUG="test-agent"\nAGENT_ID="agent-1"\n', encoding="utf-8"
    )
    secret = "test-signing-secret"
    (secrets / "test-agent.secret").write_text(secret + "\n", encoding="utf-8")
    calls = base / "systemctl.calls"
    systemctl = binary / "systemctl"
    systemctl.write_text(
        "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"$SYSTEMCTL_CALLS\"\n",
        encoding="utf-8",
    )
    systemctl.chmod(0o755)

    os.environ["AGENT_CONFIG_DIR"] = str(config)
    os.environ["AGENT_KICK_SECRET_DIR"] = str(secrets)
    os.environ["SYSTEMCTL_CALLS"] = str(calls)
    os.environ["PATH"] = f"{binary}:{os.environ['PATH']}"

    server = module.ThreadingHTTPServer(("127.0.0.1", 0), module.KickHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        payload = {
            "deliveryId": "delivery-1",
            "event": "comment.mention",
            "agentId": "agent-1",
        }
        raw = json.dumps(payload, separators=(",", ":")).encode()
        timestamp = str(int(time.time()))
        signature = "sha256=" + hmac.new(
            secret.encode(), timestamp.encode() + b"." + raw, hashlib.sha256
        ).hexdigest()
        request = urllib.request.Request(
            f"http://127.0.0.1:{server.server_port}/webhook/hypertask",
            data=raw,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "X-Hypertask-Timestamp": timestamp,
                "X-Hypertask-Signature": signature,
                "X-Hypertask-Event": "comment.mention",
            },
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            assert response.status == 202
        assert calls.read_text(encoding="utf-8").strip() == (
            "--user start agent-board-poll@test-agent.service"
        )
    finally:
        server.shutdown()
        thread.join(timeout=5)

print("PASS agent-kick-starts-mentioned-unit")
