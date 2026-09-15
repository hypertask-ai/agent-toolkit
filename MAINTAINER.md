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
- **Triage** — `scripts/triage.sh`, run by the runner before it starts a
  ticket that carries neither `easy` nor `hard`. Rules first; one cheap model
  call only when no rule fires. A `hard` ticket runs on a stronger model and
  must post a numbered plan as its first comment. QA agents are not scored.
- **Advisor** — `agent-advisor "<question>"`, for an agent mid-run that has
  already tried two approaches. Two calls per run, reads the board, never
  writes to it.
- **Weekly report** — `agent-template-weekly`, turns a week of corrections
  into checks; `agent-template report` prints this week's scorecard.

## Its own repo

`PR_REPO` in the conf, required: every bot has one, no repo-less mode. The
repo is the bot's memory. Every output, report or script it produces is a
pull request to it, never a hand edit and never a write to a chat log
nobody else can read. Skills stay in the packs above; the repo is where this
bot's own work accumulates. Created private with `create-agent.sh --pr-repo
<org/name>` from `repo-skeleton/` in this template (README, `board.yml`,
`scripts/`, `reports/`, `CHANGELOG.md`, a pr-title check). `agent-board-poll`
refuses to tick without `PR_REPO`, one line: `PR_REPO is not set: every agent
needs a repo, run create-agent --repo`.

Auto-merge does not turn on for these repos: GitHub refuses
`allow_auto_merge` on a private repo whose plan does not carry it. Expected,
not broken. `create-agent.sh` logs it and moves on; a run leaves its PR open
and moves the ticket to the review lane anyway, and the supervisor's
pr-hygiene check merges a green PR that could not get auto-merge.

## What wakes it

Assigned to it, @mentioned, or a human comment on a ticket it already owns
(assigned, or its own comment is the one right before). Plus chat, on boards
with a chat lane wired.

## Chat lane

`agent-chat.service` is shared by every agent on the host whose conf says
`CHAT="on"`. It polls the agent-authenticated chat inbox every three seconds by
default, so it works behind Cloudflare and without a public port. Set
`AGENT_CHAT_POLL_SECONDS` in a systemd override to change that cadence. The
optional webhook receiver is localhost-only and starts when
`AGENT_CHAT_WEBHOOK_PORT` is set; each webhook-enabled conf also needs
`CHAT_WEBHOOK_SECRET_FILE`. Register it only after a public HTTPS route exists.

Chat and ticket runs are separate concurrent processes. A chat prompt reads
the company skills index first, then the agent's own indexes, plus a short
brief from the conf and latest ticket log. It explicitly forbids ticket
comments, board writes, and worktrees. A message id is both the app reply's
idempotency key and a row in
`~/.local/state/agent-chat/handled.jsonl`. Provider failures still post `I
could not answer this, error logged.`

Check `systemctl --user is-active agent-chat.service`, then read
`~/.local/state/agent-chat/<slug>.log`. Test through
`https://app.hypertask.ai/agents/chat?agent=<slug>` with a human account and
quote the timestamped reply. Do not test with the owner's CLI token.

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
- Triage scores: the `easy` / `hard` label on the ticket itself. Every score
  and its reason is also in `~/.local/state/agent-board-poll/triage.jsonl`. If
  the board refused the label, the score sits in
  `~/.local/state/agent-board-poll/triage/<REF>` and the log says so.
- Per-ticket model overrides: `~/.local/state/agent-board-poll/model-override/<REF>`,
  one line, `<cli> model <id>`. Written by triage for a hard ticket and by the
  supervisor for a ticket that has failed three times. Delete the file to put
  the ticket back on the agent's usual model.

## Five daily checks

1. Is the timer active? `systemctl --user list-timers 'agent-board-poll@<slug>.timer'`
2. Did the last run finish? Tail `~/.local/state/agent-board-poll/<slug>.log`.
3. Any unresolved failure sitting on a ticket? Same log, `run FAILED` lines.
4. Scorecard: `agent-template report --days 7`.
5. Corrections repeated: same report, the `REPEAT` lines — a repeat means
   the earlier fix did not actually land.

## Feedback

Change requests and improvement ideas for the template go to the Agent
Template board, project 5500 (https://app.hypertask.ai/detail/project-5500,
prefix AGTE), via `agent-template feedback --kind change|idea --title "<short
title>" --body "<html>"`. It posts as this bot's own identity to the board's
Inbox section and prints the filed ticket's URL; run it with no arguments for
a reminder of the board link and the three kinds (`bug`, `change`, `idea`).
The paste-it-yourself fallback only shows when no token is configured for
this agent.

## Running it by hand

- `agent-board-poll --once --dry-run <slug>` — see what it would pick up, and
  what each ticket scores. Writes nothing: no label, no override file, and no
  model call for the score.
- `printf '{"title":"...","description":"...","comments":[]}' | triage.sh --rules-only`
  — score a ticket by hand, without a model.
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
- A triage score is a label a human can overrule. If somebody changes `hard` to
  `easy` on a ticket, the runner takes their word for it and does not re-score.
  Argue with the rules in `triage.sh`, never with the label.
- A fact (a number, a name, a date, a path) goes into a doc or the ticket.
  A rule (always or never do X) goes into a skill file.
- A rule that would still be true for a different board or customer goes into
  the company pack, not this bot's. Copying it into both is how two packs
  drift.

## Where skills live

Three places, and which one a skill belongs in is decided by who it serves.

| Kind | Where | Who owns it |
|---|---|---|
| Project skills | `.claude/skills/` in the repo they serve | whoever owns that repo |
| Shared skills | the `company-skills` Claude Code plugin | the company pack |
| Personal skills | `~/.claude/skills` | the person at the keyboard |

A skill about building one product lives in that product's repo, so a run
cannot read rules for code it is not editing, and a corrected rule ships in the
same pull request as the code change it came from. A skill about how anyone
here works a ticket is shared, and ships as a plugin:

```
claude plugin marketplace add hypertask-ai/company-skills
claude plugin install company-skills@company-skills
```

`install.sh` runs those two commands for you and falls back to cloning the pack
to `~/projects/company-skills` on a host where the plugin cannot be installed.
It writes which one this host resolved, and at what version, to
`~/.config/hypertask-agents/company-pack.version`.

A run reads them in order: the company pack, then `.claude/skills/INDEX.md` in
the checkout it is working in, then any extra pack the conf names in
`SKILLS_INDEX`. The first two are found without being told, so `SKILLS_INDEX`
is optional as of 3.11.0. The runner logs both versions at the start of every
run, because a bot behaving oddly is usually a bot reading an old pack.

The template keeps this layout in every project it knows about.
`create-agent.sh --sync-project <path-or-repo>` lays it down (and `--repo` runs
it for you), `agent-template update` re-runs it daily on every checkout a conf
names. It is idempotent, and it never overwrites a file a project has edited:
each file it writes carries a header naming the template version and a hash of
its own body, so an edit is visible as a hash that no longer matches.
