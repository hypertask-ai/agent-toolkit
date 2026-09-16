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
