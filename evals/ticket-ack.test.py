#!/usr/bin/env python3
"""AGTE-18: a busy agent acknowledges an owner question within one ack tick
and later edits that same comment in place with the full answer."""
import runpy
import stat
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
module = runpy.run_path(str(root / "scripts/agent-chat"))
Agent = module["Agent"]
ChatDaemon = module["ChatDaemon"]
ack_text = module["ack_text"]
average_run_minutes = module["average_run_minutes"]
eligible_count = module["eligible_count"]
latest_human_comment = module["latest_human_comment"]
board_comment_add = module["board_comment_add"]


assert ack_text(0, 12.0) == (
    "<p><strong>Got it, still working.</strong> this is next up, answer in about 12 minutes.</p>"
)
assert ack_text(3, 1.4) == (
    "<p><strong>Got it, still working.</strong> 3 tasks ahead, answer in about 1 minute.</p>"
)
print("PASS ticket-ack-text-shape")


def write_board_cli(path: Path, posted: Path, updates: Path) -> None:
    path.write_text(f"""#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "comment" ] && [ "$2" = "add" ]; then
  ref="$3"
  count=0
  if [ -f "{posted}" ]; then count=$(wc -l < "{posted}"); fi
  id=$((count + 1))
  printf '%s %s\\n' "$ref" "$id" >> "{posted}"
  exit 0
fi
if [ "$1" = "comment" ] && [ "$2" = "update" ]; then
  id="$3"
  shift 3
  text=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --text) text="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s\\t%s\\n' "$id" "$text" >> "{updates}"
  exit 0
fi
exit 1
""")
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


def write_conf(config: Path, slug: str, token: Path, board_cli: Path) -> None:
    (config / f"{slug}.conf").write_text(
        f'CHAT="on"\nAGENT_SLUG="{slug}"\nAGENT_NAME="Test Bot"\nAGENT_ID="agent-1"\n'
        f'TOKEN_FILE="{token}"\nBOARD_CLI="{board_cli}"\nMODEL_CLI="fake-provider"\n'
        f'BOARD_ID="15"\nWATCH_SECTIONS="*"\n'
    )


class FakeApi:
    def __init__(self, _agent):
        pass

    def ticket(self, reference):
        return {"tasks": [{
            "id": "task-9",
            "ticketNumber": reference,
            "title": "Reply to the human",
            "description": "A human replied",
        }]}

    def comments(self, task_id, board_id):
        return [{
            "id": 501,
            "createdAt": "2026-09-18T10:00:00Z",
            "text": "<p>Is this a feature flag?</p>",
            "agent": None,
            "creator": {"displayName": "Valentin"},
        }]


with tempfile.TemporaryDirectory() as temporary:
    temporary = Path(temporary)
    config, chat_state, board_state = temporary / "conf", temporary / "chat", temporary / "board"
    config.mkdir()
    board_state.mkdir()
    token = temporary / "token"
    token.write_text("secret-token")
    board_cli = temporary / "board-cli"
    posted = board_state / "acker.posted-comments"
    updates = board_state / "acker.updates"
    write_board_cli(board_cli, posted, updates)
    write_conf(config, "acker", token, board_cli)
    (board_state / "acker.lock").write_text(
        '{"ticket":"TEST-9","board_id":15,"started_at":"2026-09-18T09:50:00+00:00"}\n'
    )

    daemon = ChatDaemon(config, chat_state, board_state_dir=board_state)
    daemon.ack_once(FakeApi)
    posted_lines = posted.read_text().splitlines() if posted.exists() else []
    assert posted_lines == ["TEST-9 1"], posted_lines
    entries = daemon.ack_state.value.get("acker", {})
    assert len(entries) == 1, entries
    entry = next(iter(entries.values()))
    assert entry["ticket"] == "TEST-9"
    assert entry["answered"] is False
    print("PASS ticket-ack-busy-agent-acked-once")

    # A second tick while still busy must not post a second acknowledgement.
    daemon.ack_once(FakeApi)
    posted_lines = posted.read_text().splitlines()
    assert posted_lines == ["TEST-9 1"], posted_lines
    print("PASS ticket-ack-no-duplicate-ack")

    # The run finishes: the lock clears and the lane edits the ack in place.
    (board_state / "acker.lock").unlink()
    module["run_provider"].__globals__["run_provider"] = (
        lambda _agent, _prompt, timeout=0: "<p><strong>Yes, it is a feature flag.</strong></p>"
    )
    daemon.ack_once(FakeApi)
    posted_lines = posted.read_text().splitlines()
    assert posted_lines == ["TEST-9 1"], posted_lines
    update_lines = updates.read_text().splitlines()
    assert len(update_lines) == 1, update_lines
    comment_id, text = update_lines[0].split("\t", 1)
    assert comment_id == "1"
    assert "feature flag" in text
    entries = daemon.ack_state.value.get("acker", {})
    entry = next(iter(entries.values()))
    assert entry["answered"] is True
    print("PASS ticket-ack-answer-edits-same-comment")


with tempfile.TemporaryDirectory() as temporary:
    temporary = Path(temporary)
    board_state = temporary / "board"
    board_state.mkdir()
    (board_state / "queue.log").write_text(
        "2026-09-18T09:00:00+00:00 run start TEST-1 key=a\n"
        "2026-09-18T09:10:00+00:00 run done TEST-1 exit=0\n"
        "2026-09-18T09:20:00+00:00 run start TEST-2 key=b\n"
        "2026-09-18T09:32:00+00:00 run done TEST-2 exit=0\n"
    )
    assert average_run_minutes(board_state, "queue") == 11.0
    assert average_run_minutes(board_state, "missing", default=15.0) == 15.0
    (board_state / "queue.progress.json").write_text('{"eligible_work": {"count": 4}}\n')
    assert eligible_count(board_state, "queue") == 4
    assert eligible_count(board_state, "missing") == 0
    print("PASS ticket-ack-queue-and-estimate-from-existing-state")


# A comment authenticated as this agent, but with no agent id on the row (the
# owner-account-as-creator case adapters/hypertask/adapter.sh warns about),
# must never be treated as an owner question just because it lacks an id.
own_comment_by_name = [{
    "id": 900,
    "createdAt": "2026-09-18T10:05:00Z",
    "text": "<p>Done: shipped it.</p>",
    "agent": None,
    "creator": {"displayName": "Test Bot"},
}]
assert latest_human_comment(own_comment_by_name, "agent-1", "Test Bot") is None
human_after = own_comment_by_name + [{
    "id": 901,
    "createdAt": "2026-09-18T10:06:00Z",
    "text": "<p>Is this deployed?</p>",
    "agent": None,
    "creator": {"displayName": "Valentin"},
}]
found = latest_human_comment(human_after, "agent-1", "Test Bot")
assert found is not None and found["id"] == 901, found
print("PASS ticket-ack-own-comment-by-name-not-mistaken-for-a-question")

# The board wrapper can exit 0 without posting (owner-mention budget, daily
# comment cap). board_comment_add must not hand back a stale id from an
# earlier, unrelated comment on the same ticket.
with tempfile.TemporaryDirectory() as temporary:
    temporary = Path(temporary)
    board_state = temporary / "board"
    board_state.mkdir()
    refusing_cli = temporary / "refusing-board-cli"
    refusing_cli.write_text("#!/usr/bin/env bash\nexit 0\n")
    refusing_cli.chmod(refusing_cli.stat().st_mode | stat.S_IEXEC)
    (board_state / "refuser.posted-comments").write_text("TEST-9 1\n")
    stale_agent = Agent(
        slug="refuser", name="Test Bot", agent_id="agent-1", mission="", repo="",
        token_file=temporary / "token", board_cli=refusing_cli, model_cli="fake-provider",
        skills=(), api_url="https://example.invalid/api", webhook_secret_file=None,
        board_ids=(15,),
    )
    result = board_comment_add(stale_agent, "TEST-9", "<p>Got it.</p>", board_state)
    assert result is None, result
    print("PASS ticket-ack-refused-add-does-not-claim-a-stale-comment-id")

print("")
print("all ticket-ack checks passed")
