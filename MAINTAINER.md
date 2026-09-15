# Looking after this bot

For the Claude session that checks on a bot, not the bot itself. Read this
before you touch its conf.

## What the bot is made of

- **Runner timer** — `agent-board-poll@<slug>.timer`, ticks every 60s, runs
  `agent-board-poll --once <slug>` once per tick.
- **Supervisor timer** — watches the fleet, not one bot: restarts a dead
  timer, flags a stuck run, escalates what a bot cannot fix itself. Generic
  version lands 2026-09-16; until then the Hypertask one at
  `~/.local/bin/ht-supervisor` is the reference.
- **Feedback command** — `agent-template feedback`, filed the moment a human
  corrects the bot's work.
- **Weekly report** — `agent-template-weekly`, turns a week of corrections
  into checks; `agent-template report` prints this week's scorecard.

## What wakes it

Assigned to it, @mentioned, or a human comment on a ticket it already owns
(assigned, or its own comment is the one right before). Plus chat, on boards
with a chat lane wired.

## Where things live

- Rules: the skill files under the skills index (`SKILLS_INDEX` in its conf).
- Skills index: `SKILLS_INDEX` in the conf, read first on every run.
- Its own conf: `<config dir>/<slug>.conf`, 0600.

## Five daily checks

1. Is the timer active? `systemctl --user list-timers 'agent-board-poll@<slug>.timer'`
2. Did the last run finish? Tail `~/.local/state/agent-board-poll/<slug>.log`.
3. Any unresolved failure sitting on a ticket? Same log, `run FAILED` lines.
4. Scorecard: `agent-template report --days 7`.
5. Corrections repeated: same report, the `REPEAT` lines — a repeat means
   the earlier fix did not actually land.

## Running it by hand

- `agent-board-poll --once --dry-run <slug>` — see what it would pick up.
- `agent-board-poll --once <slug>` — run one real tick.
- `ht-supervisor --dry-run` — see what the supervisor would do.
- `ht-supervisor --now` — run every supervisor check once, ignoring its
  normal schedule.

## Hard rules

- Never write to the board by hand. The runner and the supervisor write to
  it; only the human owner acts on it directly.
- Never write in the owner's name. The bot's own board CLI wrapper carries
  its name; nothing else should.
- A config change to the conf is done only after one completed run proves
  it, not on inspection alone.
- A fact (a number, a name, a date, a path) goes into a doc or the ticket.
  A rule (always or never do X) goes into a skill file.
