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
  call only when no rule fires. A `hard` ticket uses `TRIAGE_HARD_CLI` when
  configured and must post a numbered plan first. QA agents are not scored.
- **Advisor** — when `RESEARCH_CLI` is configured, `agent-advisor "<question>"`
  gives a stuck agent two read-only research calls per run. Without it, there
  is no research step.
- **Feedback timer** — `agent-template-feedback.timer`, runs every four hours
  on the writable vstack maintainer host only. It judges Inbox tickets, opens
  one auto-merge fix pull request per accepted ticket, and closes shipped work.
  `agent-template-weekly` is a compatibility alias. `agent-template report`
  prints the local filing scorecard.

## Channels

The host config is `~/.config/agent-template/config`. Ordinary hosts default to
`CHANNEL=stable`; their update checks out the `stable` tag and never follows main.
This maintainer host uses `CHANNEL=latest` and `MAINTAINER=yes`. Only that setting
allows `agent-template promote`, which moves `stable` to the installed commit after
24 hours of running and a fresh green eval run. The 06:30 maintainer timer runs
promotion after update. Set `AUTO_UPDATE=off` to make timer runs print `auto-update
off, current X, stable Y` and do nothing else.

## What update does before it swaps

The updater fetches and selects the channel, detects local changes against the
installed manifest, stages the complete target template, and runs the staged eval
suite. A red suite leaves the installed tree untouched, logs `update to X refused:
N evals red`, and exits zero so the timer is not reported as crashed. `--force`
skips the eval gate. A normal install evaluates its source before its first copy as
well.

## Local patches

The install baseline is `~/.claude/skills/create-agent/.manifest.sha256`. Changed
files are copied to `local-patches/<installed-version>/<path>` and printed before
the update refuses. File each change with `agent-template feedback`, apply the
accepted fix in the repository, then remove the local edit. `--keep-local-patches`
allows the update after archiving, but it does not reapply the patch to the new
release.

## Mentions

`agent-kick.service` receives signed Hypertask mention events on localhost and runs
`systemctl --user start agent-board-poll@<slug>.service`. Put the full public HTTPS
receiver address in host-config `WEBHOOK_URL`; install and update configure every
agent through `hypertask agents webhook configure` when available, otherwise through
`POST /mcp/webhooks`. Signing secrets are 0600 files under
`~/.config/agent-template/webhooks/`. With no public URL, the installer prints `no
WEBHOOK_URL, mentions wait for the poll` and leaves the minute timer as fallback.

A failed ticket run writes only its host log and
`~/.local/state/agent-board-poll/<slug>.status`. It posts nothing on the ticket and
does not add the mention key to `<slug>.seen`, so the next tick may retry the same
mention. A later successful run removes the status file.

## The conf decides the provider

The conf is the only command policy. Core treats commands as opaque strings
and neither allows nor rejects providers, models or harnesses.

- `MODEL_CLI` is normal ticket work.
- `LADDER` optionally lists full commands separated by `|`. Three failed
  attempts stay on `MODEL_CLI`; each later attempt takes the next rung. No
  value means no escalation.
- `RESEARCH_CLI` optionally powers advisor and supervisor research. No value
  means no research step.
- `TRIAGE_HARD_CLI` optionally handles `hard`; absent means `MODEL_CLI`.
- `CHAT_CLI` optionally handles chat; absent means `MODEL_CLI`.

Commands include every model, permission, tool and non-interactive flag. The
runner splits a command into arguments without shell evaluation and appends the
prompt as the final argument. Put the harness's `-p` or `--print` before it.
See `CONF.md` for the complete schema and pi and Cursor examples.

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

## One ticket until live

Before any normal pickup, the runner lists every open PR whose branch starts
with `PR_BRANCH_PREFIX` (default `agent/<slug>-`) and every PR that names a
ticket assigned to or claimed by this agent. If one is not LIVE, the oldest is
the agent's only work. An `emergency` ticket may interrupt it; an `urgent`
ticket may not.

LIVE means all of the following:

1. The PR is merged.
2. The merge commit is contained in the PR's base branch.
3. The newest GitHub deployment for that base in environment `Production` was
   created after the merge, has status `success`, and its deployed commit
   contains the merge.

The result is cached for 60 seconds per PR. If the repository has no GitHub
deployment records, the logged fallback is merged plus base-contains-merge.
A repository that has deployment records but no qualifying Production success
is not LIVE.

A red PR starts another fix run with exact failed check names, failed-run logs,
and verbatim reviewer `CONCERNS`. Pending checks log `waiting on PR #<n>:
checks pending` and start nothing. A merged but undeployed PR also starts
nothing. The attempts file, retry limit, six-hour cooldown, model escalation,
and manager hand-off do not apply anywhere on this PR path. They apply only to
a ticket run which has not produced a PR; QA escalation starts only after live
work is rejected. The agent continues even if a supervisor flags a PR older
than 24 hours for a human look.

The owner-facing state is one JSON line at
`~/.local/state/agent-board-poll/<slug>.blocked`, with `pr`, `state`, `since`,
and `ticket`. The agents page can render that as “waiting on PR n”. The file is
removed only after all attributed PRs are LIVE. This is the first place to
look when an agent appears idle while its board still has work.

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

## Agent page

The same host daemon has a second loop that publishes every valid conf's
runtime snapshot every 30 seconds, whether chat is on or off. The Operations
block at `https://app.hypertask.ai/agents/<slug>` then shows runtime, model,
health, active ticket, or the PR it is waiting on. State comes from the poll
runner's `<slug>.lock`, `<slug>.blocked`, and `<slug>.log`; board sections come
from `board.yml` beside the conf. POST errors go to the per-agent daemon log
and never stop the next agent.

Use `agent-chat --status` to see the last publish result without exposing a
token. Read `~/.local/state/agent-chat/<slug>.log` when it says `error`.
`working`, `waiting`, `connected`, `stalled`, and `offline` are the Operations
health words. The separate top `Running` word remains an app gap because the
runtime route does not update `Agent.heartbeatAt`. Poll runs also have no app
run ID for activity cards, and `/api/mcp/chat/activity` is feature-flag gated.

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
- Per-ticket command overrides: `~/.local/state/agent-board-poll/model-override/<REF>`,
  one full command on one line. It wins over hard triage and `LADDER`. Delete
  the file to return the ticket to the policy in its conf.

## Five daily checks

1. Is the timer active? `systemctl --user list-timers 'agent-board-poll@<slug>.timer'`
2. Did the last run finish? Tail `~/.local/state/agent-board-poll/<slug>.log`.
3. Any unresolved failure sitting on a ticket? Same log, `run FAILED` lines.
4. Scorecard: `agent-template report --days 7`.
5. Corrections repeated: same report, the `REPEAT` lines — a repeat means
   the earlier fix did not actually land.

## Feedback

A bot or an interactive session files template feedback with:

```
agent-template feedback --kind bug|change|idea --what "<summary>" --got "<current behavior or context>" --expected "<desired behavior>"
```

It posts as that bot's own identity to the Agent Template Inbox, project 5500
(https://app.hypertask.ai/detail/project-5500, prefix AGTE), and prints the
filed URL. The maintainer host reads urgent first every four hours. Every
ticket gets an accepted, need-info, or declined reply; need-info contains one
question. Accepted tickets get one auto-merge fix pull request and move to
Accepted. A merged changelog line naming the ticket triggers one `Shipped in
<version>: <one line>` reply and moves it to Done. The filing host's daily
update prints `feedback waiting: AGTE-n` while the ticket remains open. The
paste-it-yourself fallback appears only when no bot token is configured.

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
