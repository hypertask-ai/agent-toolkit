#!/usr/bin/env python3
import runpy
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
module = runpy.run_path(str(root / "scripts/agent-chat"))
Agent = module["Agent"]
ChatDaemon = module["ChatDaemon"]
ERROR_REPLY = module["ERROR_REPLY"]


with tempfile.TemporaryDirectory() as temporary:
    temporary = Path(temporary)
    common = (
        'CHAT="on"\nAGENT_SLUG="chat"\nAGENT_NAME="Chat"\nAGENT_ID="id-chat"\n'
        f'TOKEN_FILE="{temporary}/token"\nMODEL_CLI="model-command --normal"\n'
    )
    fallback = temporary / "fallback.conf"
    fallback.write_text(common)
    explicit = temporary / "explicit.conf"
    explicit.write_text(common + 'CHAT_CLI="chat-command --brief"\n')
    assert Agent.from_conf(fallback).model_cli == "model-command --normal"
    assert Agent.from_conf(explicit).model_cli == "chat-command --brief"
    print("PASS agent-chat-command-from-conf")


def agent(slug):
    return Agent(
        slug=slug,
        name=slug.title(),
        agent_id=f"id-{slug}",
        mission="Answer clearly.",
        repo="",
        token_file=Path("/unused"),
        model_cli="fake-provider",
        skills=("/company/INDEX.md", f"/{slug}/INDEX.md"),
        api_url="https://example.invalid/api",
        webhook_secret_file=None,
    )


class FakeApi:
    def __init__(self):
        self.replies = []

    def history(self, session_id):
        return [{"role": "human", "content": f"history for {session_id}"}]

    def reply(self, session_id, message_id, text):
        self.replies.append((session_id, message_id, text))


with tempfile.TemporaryDirectory() as temporary:
    temporary = Path(temporary)
    daemon = ChatDaemon(temporary / "conf", temporary / "state")
    calls = []
    module["run_provider"].__globals__["run_provider"] = lambda current, prompt: calls.append(current.slug) or "once"
    current = agent("one")
    api = FakeApi()
    message = {"id": "message-once", "sessionId": "session-one", "text": "hello"}
    daemon.handle(current, message, api)
    daemon.handle(current, message, api)
    assert calls == ["one"], calls
    assert api.replies == [("session-one", "message-once", "once")], api.replies
    print("PASS agent-chat-message-handled-once")

with tempfile.TemporaryDirectory() as temporary:
    temporary = Path(temporary)
    daemon = ChatDaemon(temporary / "conf", temporary / "state")
    def fail(_agent, _prompt):
        raise RuntimeError("provider unavailable")
    module["run_provider"].__globals__["run_provider"] = fail
    api = FakeApi()
    daemon.handle(
        agent("failure"),
        {"id": "message-failure", "sessionId": "session-failure", "text": "hello"},
        api,
    )
    assert api.replies == [("session-failure", "message-failure", ERROR_REPLY)], api.replies
    print("PASS agent-chat-provider-failure-replies")

with tempfile.TemporaryDirectory() as temporary:
    temporary = Path(temporary)
    daemon = ChatDaemon(temporary / "conf", temporary / "state")
    module["run_provider"].__globals__["run_provider"] = lambda current, _prompt: f"reply from {current.slug}"
    first_api, second_api = FakeApi(), FakeApi()
    daemon.handle(agent("alpha"), {"id": "message-alpha", "sessionId": "session-alpha", "text": "a"}, first_api)
    daemon.handle(agent("beta"), {"id": "message-beta", "sessionId": "session-beta", "text": "b"}, second_api)
    assert first_api.replies == [("session-alpha", "message-alpha", "reply from alpha")]
    assert second_api.replies == [("session-beta", "message-beta", "reply from beta")]
    print("PASS agent-chat-two-agents-independent")


def runtime_conf(root, slug, token, model="runner --model test-model"):
    (root / f"{slug}.conf").write_text(
        f'AGENT_SLUG="{slug}"\nTOKEN_FILE="{token}"\nBOARD_ID="15"\n'
        f'WATCH_SECTIONS="Bugs,In Progress"\nMODEL_CLI="{model}"\nCHAT="off"\n'
    )


class FakeHeartbeatApi:
    calls = []
    failing = set()

    def __init__(self, current):
        self.current = current

    def heartbeat(self, body):
        if self.current.slug in self.failing:
            raise RuntimeError("post failed")
        self.calls.append((self.current.slug, body))
        return {"success": True}


with tempfile.TemporaryDirectory() as temporary:
    temporary = Path(temporary)
    config, chat_state, board_state = temporary / "conf", temporary / "chat", temporary / "board"
    config.mkdir()
    board_state.mkdir()
    token = temporary / "token"
    token.write_text("secret-token")
    runtime_conf(config, "runner", token)
    (config / "board.yml").write_text(
        "project: 15\ncolumns:\n  work:\n    bug: Bugs\n  in-progress: In Progress\n  done: Done\n"
    )
    (board_state / "runner.lock").write_text(
        '{"ticket":"HTPR-7000","title":"Live work","board_id":15,'
        '"started_at":"2026-09-16T10:00:00+00:00"}\n'
    )
    FakeHeartbeatApi.calls = []
    FakeHeartbeatApi.failing = set()
    daemon = ChatDaemon(config, chat_state, board_state_dir=board_state)
    daemon.version = "3.20.0"
    daemon.heartbeat_once(FakeHeartbeatApi)
    assert len(FakeHeartbeatApi.calls) == 1
    payload = FakeHeartbeatApi.calls[0][1]
    assert payload["runtime"] == "agent-board-poll 3.20.0"
    assert payload["model"] == "test-model"
    assert payload["cadence_seconds"] == 60
    assert payload["source_sections"] == [
        {"board_id": 15, "section": "Bugs"},
        {"board_id": 15, "section": "In Progress"},
    ]
    assert payload["queue"] == [{
        "ticket": "HTPR-7000",
        "board_id": 15,
        "state": "running",
        "reason": "other",
        "started_at": "2026-09-16T10:00:00+00:00",
    }]
    print("PASS runtime-heartbeat-running-ticket")

with tempfile.TemporaryDirectory() as temporary:
    temporary = Path(temporary)
    config, chat_state, board_state = temporary / "conf", temporary / "chat", temporary / "board"
    config.mkdir()
    board_state.mkdir()
    token = temporary / "token"
    token.write_text("secret-token")
    runtime_conf(config, "blocked", token)
    (config / "board.yml").write_text("roles:\n  in_progress: In Progress\n")
    (board_state / "blocked.blocked").write_text(
        '{"pr":91,"state":"red","since":"2026-09-16T11:00:00Z","ticket":"HTPR-7001"}\n'
    )
    FakeHeartbeatApi.calls = []
    daemon = ChatDaemon(config, chat_state, board_state_dir=board_state)
    daemon.heartbeat_once(FakeHeartbeatApi)
    queue = FakeHeartbeatApi.calls[0][1]["queue"]
    assert queue == [{
        "ticket": "HTPR-7001",
        "board_id": 15,
        "state": "waiting",
        "reason": "waiting on PR 91 (red)",
        "started_at": "2026-09-16T11:00:00Z",
    }]
    print("PASS runtime-heartbeat-blocked-ticket")

with tempfile.TemporaryDirectory() as temporary:
    temporary = Path(temporary)
    config, chat_state, board_state = temporary / "conf", temporary / "chat", temporary / "board"
    config.mkdir()
    board_state.mkdir()
    for slug in ("a-fails", "b-works"):
        token = temporary / f"{slug}.token"
        token.write_text(f"secret-{slug}")
        runtime_conf(config, slug, token)
    FakeHeartbeatApi.calls = []
    FakeHeartbeatApi.failing = {"a-fails"}
    daemon = ChatDaemon(config, chat_state, board_state_dir=board_state)
    daemon.heartbeat_once(FakeHeartbeatApi)
    assert [slug for slug, _body in FakeHeartbeatApi.calls] == ["b-works"]
    assert "runtime heartbeat error" in (chat_state / "a-fails.log").read_text()
    print("PASS runtime-heartbeat-agent-failure-isolated")
