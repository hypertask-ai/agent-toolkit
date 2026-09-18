#!/usr/bin/env python3
"""Post one wrapper comment through the real CLI against a local dry-run API."""

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
ORIGINAL = (
    "<p><strong>Decision: The dry-run comment is ready.</strong></p>"
    "<p>Next: no action.</p>"
)
IMPROVED = (
    "<p><strong>Decision: The clearer dry-run comment is ready.</strong></p>"
    "<p>Next: no action.</p>"
)


def real_cli() -> Path:
    candidates = [
        os.environ.get("HYPERTASK_REAL_CLI"),
        str(Path.home() / ".local/bin/hypertask"),
        "/usr/local/bin/hypertask",
        shutil.which("hypertask"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return Path(candidate).resolve()
    raise SystemExit("FAIL real-cli-comment-dry-run: set HYPERTASK_REAL_CLI to the real Hypertask CLI")


class DryRunApi(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), DryRunHandler)
        self.requests = []


class DryRunHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8")
        body = json.loads(raw) if raw else None
        path = urllib.parse.urlparse(self.path).path
        self.server.requests.append((self.command, path, body))

        if path == "/mcp/projects":
            response = {"projects": [{"id": 5500, "ownerId": "owner-1"}], "has_more": False}
        elif path == "/mcp/comments" and self.command == "GET":
            response = {"comments": [], "total": 0, "offset": 0}
        elif path == "/mcp/tasks":
            response = {"tasks": [{"id": 42348, "projectId": 5500}]}
        elif path == "/mcp/ai/improve":
            response = {"success": True, "html": IMPROVED}
        elif path == "/mcp/comments" and self.command == "POST":
            response = {"success": True, "comment": {"id": 1, "text": body["text"]}}
        else:
            self.send_error(404)
            return

        payload = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, _format, *_args):
        pass


def main():
    cli = real_cli()
    with tempfile.TemporaryDirectory() as temporary:
        tmp = Path(temporary)
        bin_dir = tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "hypertask").symlink_to(cli)
        token = tmp / "token"
        token.write_text("dry-run-token\n", encoding="utf-8")
        wrapper = tmp / "htbot"
        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env['PATH']}"
        subprocess.run(
            [
                "bash",
                "-c",
                '. "$1"; adapter_install_board_cli real-cli "$2" "$3" "Product Bot" agent-product 5500 off',
                "bash",
                str(ROOT / "adapters/hypertask/adapter.sh"),
                str(token),
                str(wrapper),
            ],
            check=True,
            env=env,
        )

        api = DryRunApi()
        thread = threading.Thread(target=api.serve_forever, daemon=True)
        thread.start()
        env.update(
            {
                "HOME": str(tmp / "home"),
                "XDG_STATE_HOME": str(tmp / "state"),
                "HYPERTASKS_API_URL": f"http://127.0.0.1:{api.server_port}",
            }
        )
        try:
            result = subprocess.run(
                [str(wrapper), "comment", "add", "AGTE-96", "--text", ORIGINAL],
                capture_output=True,
                text=True,
                env=env,
            )
        finally:
            api.shutdown()
            thread.join()

    assert result.returncode == 0, result.stderr
    improve = [body for method, path, body in api.requests if method == "POST" and path == "/mcp/ai/improve"]
    comments = [body for method, path, body in api.requests if method == "POST" and path == "/mcp/comments"]
    assert improve == [{"project_id": 5500, "text": ORIGINAL, "command": "ImproveReadability"}], improve
    assert comments == [{"ticket_number": "AGTE-96", "text": IMPROVED}], comments
    print("PASS real-cli-comment-dry-run       real CLI improved and posted one comment to the local dry-run API")


if __name__ == "__main__":
    main()
