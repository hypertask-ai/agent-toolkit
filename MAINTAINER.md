# Looking after this bot

For the Claude session that checks on a bot, not the bot itself. Read this
before you touch its conf.

Start by reading `~/.local/state/agent-template/actions.log`: it holds every
CHANGELOG.md line marked `ACTION:` that `agent-template update` has found on
this host, one thing this template could not do for itself, still pending
until you do it.

## What the bot is made of

- **Runner timer** — `agent-board-poll@<slug>.timer`, ticks every 60s, runs
  `agent-board-poll --once <slug>` once per tick.
- **Update timer** — `agent-template-update.timer`, daily at 06:30 local,
  runs `agent-template update`: pulls the template repo, reinstalls, brings
  any old-schema conf on this host forward, and clears out systemd drop-ins
  the template has since made redundant. This is what keeps a bot host in
  sync without someone explaining the fix to it by hand.
- **Supervisor timer** — watches the fleet, not one bot: restarts a dead
  timer, flags a stuck run, escalates what a bot cannot fix itself. It lives in
  the company pack as the `supervise-board` skill; `~/.local/bin/ht-supervisor`
  is a thin entry point into it. Its columns are roles mapped in `board.yml`,
  so the same checks run on any board.
- **Feedback command** — `agent-template feedback`, filed the moment a human
  corrects the bot's work.
- **Weekly report** — `agent-template-weekly`, turns a week of corrections
  into checks; `agent-template report` prints this week's scorecard.

## What wakes it

Assigned to it, @mentioned, or a human comment on a ticket it already owns
(assigned, or its own comment is the one right before). Plus chat, on boards
with a chat lane wired.

## Where things live

Two packs, always in this order:

- **Company pack** — `~/projects/company-skills`, cloned and fast-forwarded by
  `install.sh` on every host. How a bot operates here: board lifecycle, comment
  shape, escalation, where facts live, how a correction becomes a rule, the
  supervisor. Every bot reads it first. A rule that would still be true for a
  different board or customer belongs here.
- **Bot pack** — what this bot alone does. A fact that names one product (a
  repo path, a deploy command, a board id) belongs here, or in a doc, never in
  the company pack.

- Skills index: `SKILLS_INDEX` in the conf. A comma-separated list, company
  pack first, bot pack last. Read in that order on every run.
- Column names: `board.yml` next to the conf, not a skill file.
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
- `agent-template update --dry-run` — see what this host would pull in,
  convert, and clean up without changing anything.
- `agent-template update` — do it for real; safe to run any time, and
  identical to what the daily timer runs.
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
- A rule that would still be true for a different board or customer goes into
  the company pack, not this bot's. Copying it into both is how two packs
  drift.
