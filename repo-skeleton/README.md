# __AGENT_NAME__

This repo is __AGENT_NAME__'s memory. Every output, report or script it produces
is a pull request here, never a hand edit and never a write to a chat log
nobody else can read.

- **Board:** __BOARD_DESC__
- **Run it:** `agent-board-poll --once __AGENT_SLUG__` for one tick, or let
  `agent-board-poll@__AGENT_SLUG__.timer` run it every 60s.
- **Dry run:** `agent-board-poll --once --dry-run __AGENT_SLUG__` prints what
  the next tick would do without touching the board.

## Layout

- `reports/` - dated files, one per report this agent writes about its own work.
- `scripts/` - anything this agent runs on its own behalf (not the shared
  `create-agent` template, which lives in the vstack repo).
- `board.yml` - this agent's board columns, named as roles, read by
  `supervise-board`.
- `CHANGELOG.md` - one entry per change this agent's own scripts or reports go
  through.

## Feedback

Change requests and improvement ideas for the shared template go to the
Agent Template board, project 5500
(https://app.hypertask.ai/detail/project-5500, prefix AGTE), via
`agent-template feedback --kind change|idea --title "<short title>" --body
"<html>"`. Run it with no arguments for the board link and the three kinds.

## Maintainer

See the create-agent skill's `MAINTAINER.md` (installed alongside this
agent's conf) for the rules every agent on this fleet follows: never touch
the tracker board by hand, never write in the owner's name, a conf change is
proven by one completed run, not by inspection.
