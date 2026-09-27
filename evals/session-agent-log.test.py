#!/usr/bin/env python3
"""Exercise redirected session comments through the generated shim and a local board API."""

import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import urllib.parse

ROOT = Path(__file__).resolve().parent.parent
TEXT = "Resume this Claude session: claude --resume 12345"


class Api(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.requests = []
        self.fail_run = False
        self.fail_activity = False


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        body = json.loads(raw) if raw else None
        path = urllib.parse.urlparse(self.path).path
        self.server.requests.append((self.command, path, body, self.headers.get("Authorization")))
        status = 200
        if path == "/mcp/tasks":
            response = {"tasks": [{"id": 42348, "ticketNumber": "AGTE-96", "projectId": 5500}]}
        elif path == "/mcp/projects":
            response = {"projects": [{"id": 5500, "ownerId": "owner-1"}], "has_more": False}
        elif path == "/mcp/agents/runs" and self.command == "POST":
            status = 503 if self.server.fail_run else 200
            response = {"run": {"id": "session-run"}}
        elif path.endswith("/activities") and self.command == "POST":
            status = 503 if self.server.fail_activity else 200
            response = {"success": True}
        else:
            status, response = 404, {}
        payload = json.dumps(response).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, _format, *_args):
        pass


def main():
    cli = os.environ.get("HYPERTASK_REAL_CLI") or str(Path.home() / ".local/bin/hypertask")
    if not Path(cli).is_file():
        cli = shutil.which("hypertask")
    assert cli, "install the Hypertask CLI or set HYPERTASK_REAL_CLI"
    with tempfile.TemporaryDirectory() as temporary:
        tmp = Path(temporary)
        bin_dir = tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "hypertask").symlink_to(Path(cli).resolve())
        token = tmp / "token"
        token.write_text("dry-run-token\n")
        wrapper = tmp / "htbot"
        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env['PATH']}"
        subprocess.run(
            ["bash", "-c", '. "$1"; adapter_install_board_cli session "$2" "$3" "Product Bot" agent-product 5500 on',
             "bash", str(ROOT / "adapters/hypertask/adapter.sh"), str(token), str(wrapper)],
            check=True, env=env,
        )
        api = Api()
        thread = threading.Thread(target=api.serve_forever, daemon=True)
        thread.start()
        env.update(HOME=str(tmp / "home"), XDG_STATE_HOME=str(tmp / "state"),
                   HYPERTASKS_API_URL=f"http://127.0.0.1:{api.server_port}",
                   BOARD_API_URL=f"http://127.0.0.1:{api.server_port}")
        try:
            for label, run_id, fail_run, fail_activity in (
                ("session", None, False, False),
                ("runner", "existing-run", False, False),
                ("open-failure", None, True, False),
                ("activity-failure", None, False, True),
            ):
                api.requests.clear()
                api.fail_run, api.fail_activity = fail_run, fail_activity
                local_env = env.copy()
                local_env.pop("AGENT_RUN_ID", None)
                if run_id:
                    local_env["AGENT_RUN_ID"] = run_id
                result = subprocess.run([str(wrapper), "comment", "add", "AGTE-96", "--text", f"<p>{TEXT}</p>"],
                                        capture_output=True, text=True, env=local_env)
                assert result.returncode == 0, (label, result.stderr)
                posts = [(path, body) for method, path, body, auth in api.requests if method == "POST"]
                assert all(auth == "Bearer dry-run-token" for _, _, _, auth in api.requests), label
                assert not any(path == "/mcp/comments" for path, _ in posts), (label, posts)
                runs = [body for path, body in posts if path == "/mcp/agents/runs"]
                assert runs == ([] if run_id else [{"taskId": 42348, "source": "runtime", "title": "Session activity on AGTE-96"}]), (label, runs)
                activities = [(path, body) for path, body in posts if path.endswith("/activities")]
                expected = [] if fail_run else [(f"/mcp/agents/runs/{run_id or 'session-run'}/activities",
                                                  {"type": "action", "text": TEXT})]
                assert activities == expected, (label, activities)
                log = (tmp / "state/agent-board-poll/session.log").read_text()
                assert f"action {TEXT}" in log, label
                if fail_run or fail_activity:
                    assert "failed" in log, label
                print(f"PASS session-agent-log-{label} local log and board activity agree")
        finally:
            api.shutdown()
            thread.join()


if __name__ == "__main__":
    main()
