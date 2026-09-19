#!/usr/bin/env python3
import os
import runpy
import tempfile
import threading
import time
from dataclasses import replace
from pathlib import Path

root = Path(__file__).resolve().parents[1]
module = runpy.run_path(str(root / "scripts/agent-chat"))
Agent = module["Agent"]
AgentApi = module["AgentApi"]
ChatDaemon = module["ChatDaemon"]
prompt_for = module["prompt_for"]
ERROR_REPLY = module["ERROR_REPLY"]
real_run_provider = module["run_provider"]


with tempfile.TemporaryDirectory() as temporary:
    temporary = Path(temporary)
    common = (
        'CHAT="on"\nAGENT_SLUG="chat"\nAGENT_NAME="Chat"\nAGENT_ID="id-chat"\n'
        f'TOKEN_FILE="{temporary}/token"\nBOARD_CLI="{temporary}/board"\nMODEL_CLI="model-command --normal"\n'
        'BOARD_ID="15,5500"\nROOM_DAILY_TURN_BUDGET="7"\n'
    )
    fallback = temporary / "fallback.conf"
    fallback.write_text(common)
    explicit = temporary / "explicit.conf"
    explicit.write_text(common + 'CHAT_CLI="chat-command --brief"\n')
    manager = temporary / "manager.conf"
    manager.write_text(common + 'MANAGER="on"\n')
    maintainer = temporary / "maintainer.conf"
    maintainer.write_text(common + 'MAINTAINER="on"\n')
    assert Agent.from_conf(fallback).model_cli == "model-command --normal"
    assert Agent.from_conf(explicit).model_cli == "chat-command --brief"
    assert Agent.from_conf(fallback).manager is False
    assert Agent.from_conf(fallback).maintainer is False
    assert Agent.from_conf(fallback).board_ids == (15, 5500)
    assert Agent.from_conf(fallback).room_daily_turn_budget == 7
    assert Agent.from_conf(manager).manager is True
    assert Agent.from_conf(maintainer).maintainer is True
    print("PASS agent-chat-command-from-conf")


def agent(slug):
    return Agent(
        slug=slug,
        name=slug.title(),
        agent_id=f"id-{slug}",
        mission="Answer clearly.",
        repo="",
        token_file=Path("/unused"),
        board_cli=Path("/unused-board"),
        model_cli="fake-provider",
        skills=("/company/INDEX.md", f"/{slug}/INDEX.md"),
        api_url="https://example.invalid/api",
        webhook_secret_file=None,
    )


room_id = "18c7b6ec-ff09-4899-82f7-88b765203397"
route_calls = []
room_api = AgentApi(agent("routes"))
room_api.request = lambda method, path, body=None: route_calls.append((method, path, body)) or {"messages": []}
room_api.room_pending()
room_api.room_history(room_id)
room_api.room_reply(room_id, "message-1", "reply", "AGTE-86", "topic-1")
assert [call[:2] for call in route_calls] == [
    ("GET", "/mcp/chat/rooms/pending"),
    ("GET", f"/mcp/chat/rooms/{room_id}/messages"),
    ("POST", f"/mcp/chat/rooms/{room_id}/messages"),
]
print("PASS agent-room-global-pending-and-message-room-routes")


message = {"userName": "Valentin", "text": "stop dev 1"}
regular_prompt = prompt_for(agent("regular"), message, [])
manager_prompt = prompt_for(replace(agent("manager"), manager=True), message, [])
maintainer_prompt = prompt_for(replace(agent("maintainer"), maintainer=True), message, [])
assert "agent-template ctl" not in regular_prompt
assert "agent-template delegate" not in regular_prompt
assert "agent-template ctl start|stop|status <slug>" in manager_prompt
assert 'agent-template delegate <ticket> <slug> --why "<one line reason>"' in manager_prompt
assert "agent-template mode manual|auto [--board <id>|--runner <slug>]" in manager_prompt
assert "agent-template model <slug> <preset>" in manager_prompt
assert "agent-template sections <slug> <list>" in manager_prompt
assert "agent-template quiet on|off [<slug>|all]" in manager_prompt
assert "agent-template feedback --as <slug>" in manager_prompt
assert "switch the product board to manual" in manager_prompt
assert "put dev 2 on grok fast" in manager_prompt
assert "watch AI Review and QA for qa-1" in manager_prompt
assert "quiet off for qa-1" in manager_prompt
assert "file a toolkit ticket:" in manager_prompt
assert "agent-template mode" not in regular_prompt
assert "return one plain sentence describing its outcome" in manager_prompt
assert "Never paste raw command output" in manager_prompt
assert "agent-template build --repo <key>" not in regular_prompt
assert "agent-template build --repo <key>" not in manager_prompt
assert "agent-template build --repo <key>" in maintainer_prompt
assert "agent-template build status [id]" in maintainer_prompt
assert "agent-template build list" in maintainer_prompt
assert "agent-template merge <pr-url>" in maintainer_prompt
assert "agent-template update --keep-timers" in maintainer_prompt
assert "Never launch a model harness directly" in maintainer_prompt
print("PASS agent-chat-manager-command-contract")


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
    module["run_provider"].__globals__["run_provider"] = lambda current, prompt, stop=None: calls.append(current.slug) or "once"
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
    def fail(_agent, _prompt, stop=None):
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
    module["run_provider"].__globals__["run_provider"] = lambda current, _prompt, stop=None: f"reply from {current.slug}"
    first_api, second_api = FakeApi(), FakeApi()
    daemon.handle(agent("alpha"), {"id": "message-alpha", "sessionId": "session-alpha", "text": "a"}, first_api)
    daemon.handle(agent("beta"), {"id": "message-beta", "sessionId": "session-beta", "text": "b"}, second_api)
    assert first_api.replies == [("session-alpha", "message-alpha", "reply from alpha")]
    assert second_api.replies == [("session-beta", "message-beta", "reply from beta")]
    print("PASS agent-chat-two-agents-independent")


class FakeRoomApi:
    def __init__(self, history):
        self.history_rows = history
        self.history_requests = []
        self.replies = []

    def room_history(self, room_id):
        self.history_requests.append(room_id)
        return self.history_rows

    def room_reply(self, room_id, message_id, text, ticket, topic_id):
        self.replies.append((room_id, message_id, text, ticket, topic_id))

    def ticket(self, _reference):
        return {}


with tempfile.TemporaryDirectory() as temporary:
    temporary = Path(temporary)
    daemon = ChatDaemon(temporary / "conf", temporary / "state")
    room_calls = []
    module["run_provider"].__globals__["run_provider"] = (
        lambda current, _prompt, stop=None: room_calls.append(current.slug) or "I will check it."
    )
    current = replace(agent("dev-one"), name="Dev One", board_ids=(5500,), room_daily_turn_budget=5)
    addressed = {
        "id": "room-addressed",
        "roomId": "18c7b6ec-ff09-4899-82f7-88b765203397",
        "topicId": "topic-1",
        "ticketNumber": "AGTE-22",
        "text": "Dev One, can you check AGTE-22?",
        "authorName": "Product Bot",
        "authorAgentId": "product-bot-id",
    }
    api = FakeRoomApi([addressed])
    daemon.handle_room(current, addressed, api)
    daemon.handle_room(current, addressed, api)
    assert room_calls == ["dev-one"]
    assert api.history_requests == [addressed["roomId"]]
    assert api.replies == [(
        addressed["roomId"], "room-addressed", "I will check it.", "AGTE-22", "topic-1",
    )]

    unaddressed = dict(addressed, id="room-unaddressed", text="QA One, can you check AGTE-22?")
    daemon.handle_room(current, unaddressed, api)
    assert room_calls == ["dev-one"]
    assert len(api.replies) == 1
    print("PASS agent-room-addressed-once-unaddressed-silent")


class FakeRoomPollApi:
    calls = 0

    def __init__(self, _agent):
        pass

    def pending(self):
        return []

    def room_pending(self):
        self.__class__.calls += 1
        return [{"id": "global-room-message", "roomId": room_id}]


with tempfile.TemporaryDirectory() as temporary:
    temporary = Path(temporary)
    daemon = ChatDaemon(temporary / "conf", temporary / "state")
    current = replace(agent("multi-board"), board_ids=(15, 5500))
    submissions = []
    daemon.agents = lambda: [current]
    daemon.submit_room = lambda selected, pending: submissions.append((selected.slug, pending))
    poll_globals = ChatDaemon.poll_once.__globals__
    original_api = poll_globals["AgentApi"]
    poll_globals["AgentApi"] = FakeRoomPollApi
    try:
        daemon.poll_once()
    finally:
        poll_globals["AgentApi"] = original_api
    assert FakeRoomPollApi.calls == 1
    assert submissions == [("multi-board", {"id": "global-room-message", "roomId": room_id})]
    print("PASS agent-room-global-pending-polled-once")


with tempfile.TemporaryDirectory() as temporary:
    temporary = Path(temporary)
    daemon = ChatDaemon(temporary / "conf", temporary / "state")
    current = replace(agent("dev-one"), name="Dev One", board_ids=(5500,), room_daily_turn_budget=5)
    fourth = {
        "id": "turn-4",
        "roomId": "30da584e-3fec-487e-9b58-6a94a8b21db6",
        "topicId": "topic-limit",
        "ticketNumber": "AGTE-22",
        "text": "Dev One, one more thought on AGTE-22?",
        "authorName": "Product Bot",
        "authorAgentId": "product-bot-id",
    }
    history = [
        dict(fourth, id=f"turn-{number}", text=f"bot turn {number}")
        for number in range(1, 4)
    ]
    api = FakeRoomApi(history)
    daemon.handle_room(current, fourth, api)
    assert len(api.replies) == 1
    assert api.replies[0][2].startswith("Handoff:")
    assert "AGTE-22" in api.replies[0][2]
    print("PASS agent-room-fourth-bot-turn-handoff")

with tempfile.TemporaryDirectory() as temporary:
    original_env = real_run_provider.__globals__["agent_process_env"]
    real_run_provider.__globals__["agent_process_env"] = lambda _agent: dict(os.environ)
    stop = threading.Event()
    threading.Timer(0.2, stop.set).start()
    started = time.monotonic()
    try:
        real_run_provider(
            replace(agent("slow"), model_cli='python3 -c "import time; time.sleep(30)"'),
            "prompt",
            stop=stop,
        )
        raise AssertionError("stopped provider returned")
    except RuntimeError as error:
        assert "stopped" in str(error)
    finally:
        real_run_provider.__globals__["agent_process_env"] = original_env
    assert time.monotonic() - started < 5
    print("PASS agent-chat-stop-under-five-seconds")


def runtime_conf(root, slug, token, model="runner --model test-model", board_ids="15", graft="off"):
    (root / f"{slug}.conf").write_text(
        f'AGENT_SLUG="{slug}"\nTOKEN_FILE="{token}"\nBOARD_ID="{board_ids}"\n'
        f'WATCH_SECTIONS="Bugs,In Progress"\nMODEL_CLI="{model}"\nCHAT="off"\nGRAFT="{graft}"\n'
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
    runtime_conf(config, "runner", token, board_ids="15,5156", graft="on")
    (config / "board.yml").write_text(
        "project: 15\nfactory_project: 5156\ncolumns:\n  work:\n    bug: Bugs\n"
        "  in-progress: In Progress\n  done: Done\n"
    )
    (board_state / "runner.lock").write_text(
        '{"ticket":"HTPR-7000","title":"Live work","board_id":15,'
        '"started_at":"2026-09-16T10:00:00+00:00"}\n'
    )
    (board_state / "run-records").mkdir()
    (board_state / "run-records" / "runner-HTPR-7000.json").write_text(
        '{"last_output_at":"2026-09-16T10:15:00+00:00","waiting_on_pr":true,'
        '"wait_state":"checks-pending"}\n'
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
    assert payload["graft"] == "on"
    assert payload["cadence_seconds"] == 60
    assert payload["source_sections"] == [
        {"board_id": 15, "section": "Bugs"},
        {"board_id": 15, "section": "In Progress"},
    ]
    assert payload["queue"] == [{
        "ticket": "HTPR-7000",
        "board_id": 15,
        "state": "waiting",
        "reason": "waiting_on_pr (checks-pending)",
        "started_at": "2026-09-16T10:00:00+00:00",
        "last_output_at": "2026-09-16T10:15:00+00:00",
        "waiting_on_pr": True,
        "wait_state": "checks-pending",
    }]
    assert payload["last_progress_at"] == "2026-09-16T10:15:00+00:00"
    print("PASS runtime-heartbeat-pr-wait-state")

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
    payload = FakeHeartbeatApi.calls[0][1]
    assert payload["graft"] == "off"
    queue = payload["queue"]
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
