# Looking after this bot

For the Claude session that checks on a bot, not the bot itself. Read this
before you touch its conf.

Start by reading `~/.local/state/agent-template/actions.log`: it holds every
CHANGELOG.md line marked `ACTION:` that `agent-template update` has found on
this host, one thing this template could not do for itself, still pending
until you do it.

## What the bot is made of

- **Runner timer** — `agent-board-poll@<slug>.timer` runs a cheap delta tick
  every 60 seconds in poll mode. Events mode uses the same runner every five
  minutes as a safety net, while `agent-events.service` starts exact-ticket ticks immediately.
- **Reconciler timer** — `agent-board-reconcile.timer` checks every five minutes.
  It moves tickets with merged pull requests whose titles contain the ticket
  reference as a whole token, linked merged pull requests, or matching direct
  base-branch commits to Done and restores tickets left in In Progress after a
  run stops without a pull request. The runner comments with every pull request
  URL it opens before moving the ticket to review.
- **Update timer** — `agent-template-update.timer` checks every five minutes.
  It fetches the configured release and stops when `VERSION` has not changed.
  A changed version must pass its staged evals before installation. A passing
  update restarts chat and enabled timers, then posts one line on Board health.
  A failing update keeps the installed version and files one deduplicated bug
  on the toolkit board.
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
  on the writable agent-toolkit maintainer host only. It judges Backlog
  tickets, opens
  one auto-merge fix pull request per accepted ticket, and closes shipped work.
  `agent-template-weekly` is a compatibility alias. `agent-template report`
  prints the local filing scorecard.

## Identity

An agent run can only ever write as itself. Ticket, triage, chat, and advisor
provider processes receive a per-agent command shim first on `PATH`; bare
`hypertask`, `ht`, and `htbot` calls enter through that agent's token-bearing
wrapper. A missing token ends the run with `no agent token for <slug>` before a
board write, rather than falling back to the login in the owner's home config.

Bot comments use the `improve-readability` writer mode unless the caller passes
`--raw`. If the writer refuses a comment, the wrapper prints the CLI error and
posts the original text instead.

## Manager access

Manager access is per agent, not per host. Set `MANAGER="on"` only in a trusted
manager's current-schema conf. `MAINTAINER="on"` includes the manager controls
and adds the setup commands below. Missing or any other value means off.

- `agent-template ctl start|stop|status <slug>` controls only
  `agent-board-poll@<slug>.timer` and `.service` for a current-schema conf.
- `agent-template delegate <ticket> <slug> --why "<one line reason>"` uses the
  manager's `BOARD_CLI`, assigns the target agent UUID, and posts the handoff.
- `agent-template mode manual|auto [--board <id>|--runner <slug>]` changes
  `CLAIM_UNASSIGNED` for every dev and QA conf on that board, or only the named
  runner. The manager's board is the default.
- `agent-template model <slug> <preset>` accepts `grok-fast`, `glm-flash`, or
  `codex-sol` and writes only that preset's exact `MODEL_CLI` command.
- `agent-template sections <slug> <list>` writes a comma-separated
  `WATCH_SECTIONS` list, or `*`, to one current conf.
- `agent-template quiet on|off [<slug>|all]` writes `QUIET` to one or every
  current conf.
- `agent-template feedback --as <slug> ...` reads `BOARD_CLI` from the calling
  manager's conf and files a toolkit ticket as that identity.
- Every changed conf is backed up as `<conf>.bak-<timestamp>` before the write.
- Commands refuse token and credential settings, foreign units, paths outside
  the conf directory, and confs without the `BOARD_ADAPTER` schema marker.
- Delegation refuses userId 6 and a ticket explicitly held by its board owner.
- Every accepted or refused call is logged with caller, command, and timestamp
  in `~/.local/state/agent-board-poll/manager-actions.log`.

Runner and chat prompts expose these commands only when `MANAGER="on"` or
`MAINTAINER="on"`. A chat reply after a command is one plain outcome sentence,
never raw command output. An affected ticket appears as a Markdown link whose
visible text is its full id plus authoritative title.

## Setup maintainer

Set `MAINTAINER="on"` only for the one agent that owns setup changes. It must
use a build job for every change to the toolkit, supervisor rules, analytics
site, app, CLI, or Slack bot. Update and build requests run in the current
maintainer session and are never delegated. Runners never merge a pull request
by hand. Auto-merge or the supervisor handles merges. The advisor session queues
instructions and does not edit those repositories itself.

```sh
agent-template build --repo <key> --ticket <url> --spec <file|-> [--effort high|xhigh]
agent-template build status [id]
agent-template build list
agent-template update --keep-timers
agent-template instruct <slug> <text|-> [--ticket <url>]
```

`repos.allow` beside the agent conf is CSV. Each row starts with `key,path,
github slug,base branch,memory cap`; the cap is optional and any remaining
fields are pull request labels. The cap defaults to 12 GB when the host has more
than 32 GB of RAM and half of RAM otherwise. On first install, the slug and
branch are discovered from each checkout's `origin` and `origin/HEAD`. Updates
preserve host policy and add shipped label defaults only to rows without labels.
Build refuses a checkout whose current origin differs from its allowlist row.
The runner applies configured labels through GitHub's REST labels endpoint before
pull request creation returns. The reconciler fetches each listed
base branch without changing the checkout and keeps a per-repository commit
cursor under its state directory; its first pass reads the previous 48 hours.

A build writes its guarded prompt and output under
`~/.local/state/agent-board-poll/<slug>-builds/`, launches a memory-capped
systemd user unit, and records durable state in `<slug>-builds.json`. The prompt
requires a scratch worktree, the non-engineer pull request body, green checks,
auto-merge, timer-preserving toolkit update, cleanup, and a report under ten
lines. It leaves the pull request open for the supervisor when auto-merge is
unavailable. `build status` returns the exit marker and the last twelve output lines.

Before each tick, the service checks completed build units and records any
non-success result as failed even when no exit marker was written. An OOM kill
posts `Decision: build failed: out of memory` in that tick. Successful builds
post one `Done:` line with the pull request URL, and other failures post one
plain-language `Decision: build failed:` comment. A stored ticket URL is
resolved to its board reference through the
adapter first. A failed comment stops after two attempts and records the command,
exit code, and stderr in the run log.

`instruct` is the advisor's only identity-free entry point. It still refuses a
target without `MAINTAINER="on"`, writes one JSON item under
`<slug>-instructions/`, and logs the action. It then uses the target's own board
CLI to create an HTML ticket on board 5500, assigns the target agent with
`task assign --self`, records the ticket id under
`agent-template/instruction-tickets/`, and removes the transport JSON. A board
failure returns non-zero with the API error and keeps the JSON for install to
retry. Install uses the ticket-id record to avoid duplicate migrations. Tickets
created by hand on board 5500 and assigned to Product Bot use the same normal
run, build, and completion-comment path.

Maintainer prompts require a four-part build spec: Ticket, What, Done when, and
Guardrails. An update or build instruction for an allowlisted repository runs
the matching maintainer command in that run. It never enters the ordinary
developer pull request workflow or gets delegated. Manual merge requests are
refused; background builds keep using the completion checker. Maintainer prompts
forbid direct model-harness launches and answer questions about completed work
from `build list`, not from memory.

## Channels

The host config is `~/.config/agent-template/config`. Ordinary hosts default to
`CHANNEL=stable`; their update checks out the `stable` tag and never follows main.
This maintainer host uses `CHANNEL=latest` and `MAINTAINER=yes`, so each five-minute
check reads `main`. Only that setting allows `agent-template promote`, which moves
`stable` to the installed commit after 24 hours of running and a fresh green eval
run. The timer runs promotion after each update check. Set `AUTO_UPDATE=off` to make
timer runs print `auto-update off, current X, stable Y` and do nothing else.

## What update does before it swaps

The updater fetches and selects the channel, then compares its exact commit with the
installed commit even when their version numbers match. It detects local changes
against the installed manifest, stages the complete target template, and runs the
staged eval suite. A red suite leaves the installed tree untouched, names the first three
failing cases in the refusal, keeps the complete eval output beside the update-failure
record under `~/.local/state/agent-template/`, and updates one open toolkit bug for that
version with every failing eval name. A passing timer update restarts chat and every enabled
`agent-board-poll@<slug>.timer` instance without restarting the bare template unit,
then records the installed version on Board health.
`--force` skips the eval gate. A normal install evaluates its source before its first
copy as well. Use `agent-template update --keep-timers` when deployment must leave
every runner timer in its current started or stopped state.

## Local patches

The install baseline is `~/.claude/skills/create-agent/.manifest.sha256`. Changed
files are copied to `local-patches/<installed-version>/<path>` and printed. The
updater applies them to a staged copy and runs the incoming release's eval suite,
so an archived old eval runner cannot hide a regression. Passing patches are
reapplied after install. Failing patches remain archived while the clean release
installs. The updater also removes untracked Python and pytest cache artifacts
before staging the release. File each patch with `agent-template feedback` so the
host override can eventually be removed.

## Events

Set `WIRING="events"` for an agent that should react immediately. The shared
`agent-events.service` listens on localhost, verifies each signed delivery with
the agent's 0600 secret under `~/.config/agent-template/webhooks/`, and queues an
exact-ticket tick for `comment.created`, `comment.mention`, and assignment events.
The queue is durable under `~/.local/state/agent-events/` and serializes targeted
ticks behind an active run without exceeding `MAX_CONCURRENT_RUNS`.

The host owner must provide the public HTTPS route. A Cloudflare tunnel or
local-helper can forward it to `http://127.0.0.1:8793/webhook/hypertask`. Register
one agent with `agent-template events register <slug> --url <public-url>`, or put
`EVENTS_URL` in `~/.config/agent-template/config` before installation. If no URL
is configured, the receiver still runs and the five-minute timer remains the path.

Agent creation and toolkit updates inspect every managed agent subscription. Only
an events-wired agent's configured host or recorded manual registration is served.
The toolkit deactivates every other active webhook and logs it once. Board health
reports active foreign webhooks that remain.

Run `agent-template events status` to see the registered URL, last event time,
and queue length per agent. The 60-second poll mode remains available as a
fallback. Its ordinary ticks use paginated task lists and `updatedAt` cursors,
retain the existing `<slug>.comment-cursor.<board>` files, stop ranking after 60
seconds, and perform at most one full board scan per hour.

A failed ticket run writes its normal host status and leaves the board trigger
eligible for the five-minute safety scan. Event delivery never bypasses the existing
claim, cooldown, pull request, identity, or comment rules.

Event and poll pickups share the same claim handshake. The adapter waits a random
one to five seconds, checks assignees again, assigns the runner, then checks again
after two seconds. If two agents landed, the lower agent id keeps the ticket and
the other unassigns itself without commenting. The runner posts `Claimed.` and
moves to In Progress only after that handshake holds.

## Fleet throughput watch

`agent-fleet-watch.timer` runs every 15 minutes, starting five minutes after boot.
It is a deterministic host check and never invokes a model itself. It reads runner state
and agent confs locally, reads each board separately through Product Bot's
existing Hypertask adapter and token, and uses at most two GitHub REST calls per
repository per run. An unreadable board is listed in `fleet-health.json` while
readable boards continue; the service fails only when no board can be read. A
GitHub rate-limit response pauses the GitHub-dependent checks for that run instead
of retrying.

The watch raises one High ticket in toolkit `Review` per rule, with a six-hour
per-rule cooldown. Each ticket is a manager report labelled `manager-only`; it
contains the observation and asks agents to take no merge, assignment, or release
action. Dev and QA runners skip that label. The watch sends no toast, chat-room
message, or Telegram message. When a rule recovers, its open alarm moves to `Done`.

The seven rules cover: three hours without a merge while unassigned intake work
waits during local daytime; an eligible agent with no completed run for one hour;
three failed runner ticks in a row; duplicate agent bindings to one pull request;
host disk use above 85 percent; exhausted GitHub REST capacity; and an agent left
in manual claiming mode for two hours while unassigned intake work waits. The
one-hour idle-agent rule queues an immediate poll for every affected agent. Its
alarm, durable rule state, health snapshot, and summary log record each start
and whether systemd accepted it.

Every pass atomically writes
`~/.local/state/agent-board-poll/fleet-health.json`. The Agents page can read its
current breaches and the merge, run, failed-tick, disk, and GitHub metrics. The
alarm cooldown and manual-mode start times are in `fleet-watch-state.json`, and
exactly one summary line per pass is appended to `fleet-watch.log`.

Run `agent-fleet-watch` for an immediate check. Check the schedule with
`systemctl --user status agent-fleet-watch.timer` and service failures with
`journalctl --user -u agent-fleet-watch.service`.

## Fleet progress contract

Every real runner tick atomically rewrites
`~/.local/state/agent-board-poll/<slug>.progress.json`. Product Bot reads every
schema-version-1 file at the end of its own tick. This keeps fleet supervision
inside the existing Product Bot runner and does not add another timer or
supervisor.

All timestamps are UTC ISO 8601 strings. Missing events are JSON `null`.
Analytics may read `stall.stalled_since` for the badge and `stall.reason` for
its one-line explanation without deriving a stall again.

| Field | Contract |
|---|---|
| `schema_version` | Integer `1`. Readers skip unknown versions. |
| `runner`, `updated_at`, `last_tick_at` | Runner slug and snapshot times. |
| `last_completed_run` | Last successful ticket run with `ticket`, `ticket_url`, and `at`. |
| `last_pr_opened` | Last PR first seen during a run with `number`, `url`, `ticket`, and `at`. |
| `last_merge` | Last owned merge with `number`, `url`, `ticket`, and `at`. |
| `wait` | Current `state`, `since`, `ticket`, one-line `reason`, and optional PR `number` plus `url`. States are `checks-pending`, `awaiting-merge`, `blocked`, or `null`. |
| `eligible_work` | Current `count`, when a non-zero count began in `since`, and the first ranked ticket plus URL. |
| `repeated_attempt` | Current ticket, consecutive `count`, stable `failure_signature`, safe one-line `failure_summary`, `first_at`, and `last_at`. Success on that ticket clears it. |
| `units` | Recent build and instruction units with `kind`, `id`, `unit`, `ticket`, `status`, `ended_at`, and nullable `produced_result`. `false` means the unit ended without its result marker. |
| `stall` | Oldest active stall with `rule`, `stalled_since`, and one-line `reason`, or `null`. |
| `stalls` | Every active stall in the same three-field analytics shape. |

Product Bot creates one phone-friendly `Decision:` comment per stall, stores its
comment id in `fleet-stalls.json`, and edits that comment when the reason or
manual state changes. It sends one line through `FLEET_TELEGRAM_NOTIFIER` when
that existing notifier command is configured. Otherwise it uses the established
`TELEGRAM_HYPERTASK_BOT_TOKEN` and `TELEGRAM_HYPERTASK_CHAT_ID` transport from
`~/.config/hypertask-env.sh`. No token is copied into progress state.

A two-hour pull request alarm is filed separately in toolkit `Review` at High
priority. Product Bot posts its one-line title and ticket URL in the toolkit
agent room and, when `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` both exist in
`~/.config/agent-template/config`, sends the same line to Telegram. Open alarms
are mirrored in `board-health.json` with `open_since` for the status page. When
the pull request clears, Product Bot comments `cleared at HH:MM` once and moves
the alarm ticket to `Done`.

The four mechanical rules are: a pending-check, awaiting-merge, or blocked wait
past two hours; non-zero eligible work without a completed run for three hours;
three attempts on one ticket with one failure signature; and a build or
instruction unit ending without a result. A pull request that is red or still
unmerged after two hours also creates one deduplicated bug in the toolkit Backlog.
A red-PR bug names every failing check reported by GitHub. After six hours from
`stalled_since`,
Product Bot runs `mode manual --runner <slug>` and sends one separate owner
notification once. `FLEET_STALL_TICKET` selects the toolkit ticket used when a
stall has no runner ticket and defaults to `AGTE-37`.

## Quiet ticket traffic

Ticket comments have exactly five allowed kinds: `Question:` asks a human and
ends with a question mark while naming what is needed; `Answer:` replies to a
direct owner question or mention; `Decision:` records a fact the owner must
know; `Handoff:` names the receiving agent and explains what shipped; and
`Done:` explains what shipped and includes the pull request link. Neither
`Handoff:` nor `Done:` can be only a link. Outside a reply-only run, the board
wrapper redirects anything else to run activity. `QUIET="on"` is the default
and strips board-owner mentions from comments, logging the change. An `Answer:`
to the owner's direct mention keeps the owner mention even after this agent used
its daily owner-mention allowance. The review column provides attention in all
other cases. The existing one-reminder and three-comments-per-day limits still
apply.

The drafting agent must run all five comment kinds through the real pospeak,
unslop, and i-have-adhd skills before posting, not only satisfy the mechanical
shape check below: a comment can pass that check and still be noise the owner
cannot act on. Owner-facing text bans skill names, `ROUTE:` lists, file paths,
PR numbers without a full URL, and branch names. The runner appends the
pospeak, unslop, and i-have-adhd texts verbatim for all five comment kinds and
says the product owner reads them on a phone. Paths under the company pack's
`skills/talk-to-valentin/` directory are canonical; bundled files under
`adapters/hypertask/plain-language/` fill any missing reference. The generated
board wrapper checks the first `<p>` and bold sentence, the 80-word cap,
code-shaped tokens, commit hashes, em dashes, linked ticket and PR references,
and the last block. It tries one 60-second rewrite with `CHAT_CLI` or
`RESEARCH_CLI`, then checks again. A second failure logs the draft and
reasons, emits the `Question held: did not pass the plain-language check`
activity, and sends no raw comment. When a closing `Done:` or `Handoff:` comment
is held, the runner keeps its draft until the worker exits. If that run merged
its pull request, the runner refreshes GitHub, links the draft's ticket and pull
request references, checks it again, and posts it. A rewrite failure leaves the
comment held. In either case, the merged pull request makes the run successful
and moves the ticket to Done.

Direct human questions use the fixed high-effort Codex Sol reply route instead
of the conf provider. The five-minute process uses `hax --raw`, which provides
no tools or project context, and starts in a fresh empty directory set read-only.
It needs no local repository checkout. The prompt supplies the full thread,
shared Valentin statement record, and exact terminal rules. The selected
ticket's full-thread read is separate from the capped owned-ticket scan. The
runner validates and posts the returned HTML. An empty or invalid draft gets one
retry with the failed shape rules. If that retry also fails, the original draft
posts under `Answer:` with a line saying the check was skipped. A process or
posting failure posts `I could not answer this, error logged`. These reply-only
runs default to `Answer:`, with a final `Decision needed:` question only when the
owner genuinely needs to choose.

When the owner writes "I don't understand" or asks for a guide, the answering
agent posts exactly one `Decision:` comment shaped as a numbered guide and
nothing else: what is live, what he must do (page URL and button name), what
needs rights he may lack, and what the bots do next.

At ticket-run start the adapter posts the task, agent, provider, model, and
`source: "runtime"` to `/api/mcp/agents/runs`. Claimed, started, provider
fallback, PR opened, red check, fix pushed, retrying, blocked, and done are
activities, and the final status closes the run with the provider that served it.
HTTP 404 means the app route is not deployed yet; open, activity, and close stay
in the local run log and ticket work continues.

## The conf decides the provider

For build runs, the conf sets full provider commands and their subscription
order. Reply-only runs use the fixed route above.

- `MODEL_CLI` is normal ticket work when no provider order is configured.
- `PROVIDER_ORDER` is an optional comma-separated order such as `codex,cursor`.
- `PROVIDER_<NAME>_CLI` is the full command for each ordered provider. The
  runner skips commands that are not installed.
- A quota error retries the same run on the next provider. Other errors do not.
  If every provider is out, the ticket states the earliest reported reset and
  becomes eligible again after that time without spending a normal attempt.
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

## Graft trial

`GRAFT="off"` is the default. With `GRAFT="on"`, ticket runs receive the
structural `graft` CLI, `GRAFT_MCP_COMMAND="graft mcp <repo>"`, a run-scoped
MCP JSON file at `GRAFT_MCP_CONFIG`, and one prompt line telling the agent to
ask Graft before grep. The runner's Graft wrapper
sets `DO_NOT_TRACK=1` and removes provider keys before every Graft process, so
`graft build`, queries, and MCP stay in the deterministic free tier. Install
with `npm install -g @nanonets/graft`, then index the checkout with
`DO_NOT_TRACK=1 GRAFT_NO_GITIGNORE=1 graft build <repo>`. Do not use `--deep`.
Run records and runtime heartbeats report `graft` as `on` or `off`.

## Its own repo

`PR_REPO` in the conf is required. It is the bot's memory repository, separate
from the local `AGENT_REPO` checkout used for build work. Reply-only runs do not
need that checkout.
`create-agent.sh` rejects a missing `--pr-repo` before it creates or changes an
identity. It creates the repository privately from `repo-skeleton/` in this
template. `agent-board-poll` still rejects legacy configurations without
`PR_REPO`.

Auto-merge does not turn on for these repos: GitHub refuses
`allow_auto_merge` on a private repo whose plan does not carry it. Expected,
not broken. `create-agent.sh` reads the setting back and logs the refusal. A
run leaves its pull request open after requesting auto-merge. The five-minute
reconciler squash merges it only after it has remained green, mergeable, and
without auto-merge for 30 minutes.

## One ticket until live

Before any normal or event-ticket ranking, the runner reads one host-wide PR
cache for the repository. The first tick after 60 seconds refreshes it under a
lock and paginates every open PR plus merges from the last 48 hours. Each row
stores the PR number, title, branch, author, and labels, with no body. The binding
gate filters those rows to open PRs before ownership and labels are evaluated. A
pull request labelled `valentin-review` becomes a protected wait only while it is
open: the runner confirms its current state, then does not review, modify, close,
or merge it. The runner command shim also refuses manual merges and checks this
label before any pull request mutation. A GitHub rate-limit response records its
reset time for the repository. Every runner skips GitHub calls until then, treats
ownership as unknown, and continues its tick.

Ownership is proved only by `<slug>/` (case-insensitive), `<slug>.opened-prs`, or
an explicitly configured `GH_LOGIN` that differs from the host `gh` login.
`dev-2` also recognizes its historical `dev-cursor-2/` and `cursor-dev-2/`
branches. QA agents recognize only PRs recorded in their own opened-PR ledger.
Board assignment and shared GitHub authorship never transfer PR ownership.

A red or pending PR stops pickup for its first two hours, then remains monitored
while new work can start. One green PR awaiting review or merge is monitored
without stopping pickup; two open PRs fill the pickup slots. A merged or closed
PR never binds an agent, regardless of labels, deployment state, ticket section,
or QA result. A PR whose ticket is in the blocked section, has any human assignee,
or is held by the owner remains bound but starts no fix round while the PR is
open. An open PR with no active owner is ignored. Once per UTC day, a tick logs
`orphaned PR #<n> (<branch>) has no owning agent` so the supervisor can decide
who should take it.

A red PR resolves its current base and head with `gh pr view`, then fetches both
from the `PR_REPO` GitHub URL instead of the checkout's `origin`. Fetch or
checkout failure logs one infrastructure explanation and starts neither a fix
nor a new ticket. Three consecutive preparation failures on the same PR raise
the normal Board health alarm introduced by AGTE-118.

A successful preparation rebases the PR branch and runs the worker. A round is
recorded only after that worker process exits. Its later `Fix round N:` ticket
comment reports either the pushed commit or `no push: <reason>`. The prompt
includes exact failed check names, reviewer concerns, and the last 80 failed-log
lines for each failing check and run. PR fix runs bypass the attempts ladder and
manager handoff, but retain the per-ticket cooldown. They stop as soon as the PR
merges or closes.

Before round three, or after three hours from the first red round, the runner
asks `SECOND_OPINION_CLI` for one independent diagnosis. A lone `revert-guard`
failure runs that review immediately with deleted hunks and their origin
commits. An intended deletion adds `intentional-revert` through `gh api` and
reruns the failed check. Otherwise the next brief says which files to restore.
Every verdict is posted with the literal `Second opinion:` marker.

The runner refuses a reviewer from the development worker's provider family. A
concrete general diagnosis is included in one final fix round. A `not fixable
here because ...` verdict, or a red result after that final round, releases the
ticket without another development run: comment on and close the PR while
preserving its branch, add `needs-human`, move the ticket to
`OWNER_REVIEW_SECTION` (default `Review`), unassign the agent, and record the
release. At startup, each configured board validates that destination; a board
without the default `Review` column uses its live `HT Manager Review` lane, and
any other missing destination is logged as an error before work starts. If the
ticket move later fails, the verdict remains posted and the runner still clears
the ticket assignment and PR binding so normal pickup can resume.

The owner-facing binding state is one JSON line at
`~/.local/state/agent-board-poll/<slug>.blocked`. Released PRs are recorded in
`<slug>.released-prs`, so eventual GitHub list results and older merged repair
PRs cannot bind the agent again. The runner removes the blocked file when no
open PR blocks pickup or the complete human-release sequence succeeds. Two-hour
PR alarms and Board health reporting remain observational; they never release
this binding.

## What wakes it

Assigned to it, @mentioned, or a human comment on a ticket it already owns
(assigned, or its own comment is the one right before). Plus chat, on boards
with a chat lane wired.

## Chat lane

`agent-chat.service` is shared by every agent on the host whose conf says
`CHAT="on"`. It polls the agent-authenticated private inbox and global pending
room feed every three seconds by default, so it works behind Cloudflare and
without a public port. Each pending turn's room id selects the transcript and
reply destination. Agents answer a room turn only when named
in its text or target metadata. Product Bot is chief of staff and can wake
another bot by naming it. Unaddressed bots stay silent.

A room answer reads the shared transcript and is posted with its related ticket
so the app writes the same turn as a run note. After three bot-to-bot turns on
one topic, the next answer is a `Handoff:` to that ticket. The shared per-room
UTC-day count is in `~/.local/state/agent-chat/room-budget.json`; configure its
limit with `ROOM_DAILY_TURN_BUDGET` (default 20, 0 disables room replies).

Set `AGENT_CHAT_POLL_SECONDS` in a systemd override to change the cadence. The
optional webhook receiver is localhost-only and starts when
`AGENT_CHAT_WEBHOOK_PORT` is set; each webhook-enabled conf also needs
`CHAT_WEBHOOK_SECRET_FILE`. Register it only after a public HTTPS route exists.

Chat and ticket runs are separate concurrent processes. A private-chat prompt
reads the company skills index first, then the agent's own indexes, plus a short
brief from the conf and latest ticket log. It explicitly forbids ticket
comments, board writes, and worktrees. A message id is both the app reply's
idempotency key and a row in `~/.local/state/agent-chat/handled.jsonl`.
Provider failures still post `I could not answer this, error logged.` A stop
cancels active providers and returns within five seconds.

Check `systemctl --user is-active agent-chat.service`, then read
`~/.local/state/agent-chat/<slug>.log`. Test through
`https://app.hypertask.ai/agents/chat?agent=<slug>` with a human account and
quote the timestamped reply. Do not test with the owner's CLI token.

### Ticket-ack lane

A third loop in the same daemon (`AGENT_ACK_SECONDS`, default 60) closes the
gap AGTE-17 leaves: while a runner is busy, an owner question on the ticket it
is running got no reply until the slot freed. Each tick, for every `CHAT="on"`
conf with a `BOARD_ID`, it reads `<slug>.lock` for the ticket the runner is on
and checks for a human comment it has not acknowledged. The first tick it sees
one, it runs `BOARD_CLI comment add` with one line: how many tasks are ahead
(`<slug>.progress.json`'s `eligible_work.count`, written by `agent-progress`)
and an estimate built from the runner's own recent `run start`/`run done`
pairs in `<slug>.log`, how much of the current run's average has already
elapsed, and that queue length. It records the ticket, the question's comment id, and
the new comment's id (read back from `<slug>.posted-comments`) in
`~/.local/state/agent-chat/ack-state.json` so it never posts a second
acknowledgement for the same question.

Once `<slug>.lock` no longer names that ticket, the next tick asks `CHAT_CLI`
(falling back to `MODEL_CLI`) to answer from the ticket and the run log alone,
then runs `BOARD_CLI comment update` on the acknowledgement's own id, never a
new comment. A provider or board-write failure is logged and retried on the
next tick. Board-write failures include the CLI error text, and the
acknowledgement stays visible either way.

## Agent page

`agent-status.timer` runs every 60 seconds and publishes the owner-facing
Agents page independently of any retired factory loop. It reads every valid
conf under `~/.config/hypertask-agents`, the runner locks and logs under
`~/.local/state/agent-board-poll`, and supervisor violations from
`~/.local/state/ht-supervisor/health.json`. It never calls a model or writes to
the board.

Each collection atomically writes `factory-status.json`, `agent-feed.json`, and
`agent-status-metrics.json` beside the runner state. The factory document uses
schema version 1 and is uploaded through `/api/factory-status?project=hypertask`,
which stores `ops/factory-status/hypertask.json`. The page KPI document goes to
`/api/agent-feed`. Both uploads load the Cloudflare Access headers from the
mode-0600 `~/.config/hypertask-app/credentials.env` and the route's dedicated
bearer from `~/.config/hypertask-agent-runtime.env`; errors never print a
credential or response body.

Current work comes from `<slug>.lock`, including the numeric ticket identity
written by new runner versions. Execution falls back to structured run lines in
`<slug>.log`. Supervisor violations become unresolved public incidents without
copying free-form logs. First-pass rate treats the first QA result in seven days
as authoritative, with `Done` passing and `Handoff` returned. Cost per live
ticket is each model provider's share of observed run duration divided by live
QA outcomes, so the dashboard reports a measured percentage without inventing
dollar prices for subscription models.

Check `systemctl --user status agent-status.timer` and
`journalctl --user -u agent-status.service`. Run `agent-status collect` to print
the factory document without credentials or network access. A failed upload
leaves all three local snapshots available for diagnosis and retries next
minute.

The same host daemon has a second loop that publishes every valid conf's
runtime snapshot every 30 seconds, whether chat is on or off. The Operations
block at `https://app.hypertask.ai/agents/<slug>` then shows runtime, model,
health, active ticket, or the PR it is waiting on. State comes from the poll
runner's `<slug>.lock`, `<slug>.blocked`, and `<slug>.log`; board sections come
from `board.yml` beside the conf. Poll runs also publish ticket-linked activity.
POST errors go to the per-agent daemon log and never stop the next agent.

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

It posts as that bot's own identity to the Agent Template Backlog, project 5500
(https://app.hypertask.ai/detail/project-5500, prefix AGTE), and prints the
filed URL. The maintainer host reads urgent first every four hours. Every
ticket gets an accepted, need-info, or declined reply; need-info contains one
question. Accepted tickets get one auto-merge fix pull request and move to
In Progress. A merged changelog line naming the ticket triggers one `Shipped in
<version>: <one line>` reply and moves it to Done. The filing host's daily
update prints `feedback waiting: AGTE-n` while the ticket remains open. The
paste-it-yourself fallback appears only when no bot token is configured.

## Run cleanup and disk guard

Every runner start reconciles its `running` records before cleanup or ticket
ranking. A missing process, zombie, reused pid, or pid now owned by another
command marks the record `reconciled`, returns the ticket to its configured
intake column unassigned, and posts one comment naming the run and reason. The
worktree stays in place and its path is written to the runner log. Owner-held
tickets stay where they are, and a dead pull request fix round keeps its existing
pull request binding.

A ticket is requeued after its first dead process. A second dead process raises
the existing high-priority toolkit alarm instead of allowing a third run. The
alarm uses the AGTE-118 Review, agent-room, Telegram, and Board health path.

Every tick cleans before it ranks work. It sweeps isolated worktrees older than
two days when no live run record owns them, removes clean or fully pushed
worktrees, prunes generated build directories from stale worktrees kept for
unpushed work, and runs `git worktree prune`. Once per UTC day it also prunes
anonymous Docker volumes and dangling images when Docker is available. The tick
writes one `cleanup: freed N MB, kept K worktrees` line to the runner log.

The same cleanup function runs after success, failure, an explicit early exit,
an error trap, a signal, and a watchdog termination. Before cleanup, a
watchdog-capped development run commits dirty files as work in progress on the
ticket branch and pushes it. The next run checks out that branch instead of
starting again from the base branch. After two capped runs, the independent
reviewer gets the preserved commits and diff, and the runner does not start a
third development run.

For other exits, a worktree with uncommitted or unpushed work remains in place
and logs `kept worktree <path>: unpushed commits`; everything else is removed
with `git worktree remove --force`. Per-run temporary files and temporary
directories are removed at the same time.

Disk use is checked after cleanup. Above 85 percent, the runner creates one
high-priority toolkit alarm through the same Review, agent-room, Telegram, and
Board health path as pull request alarms. Above 95 percent, the tick starts no
new run. The alarm stays open until use falls below 80 percent, then it is
cleared and moved to Done.

## Running it by hand

- `agent-board-poll --once --dry-run <slug>` — see what it would pick up, and
  what each ticket scores. Writes nothing: no label, no override file, and no
  model call for the score.
- `printf '{"title":"...","description":"...","comments":[]}' | triage.sh --rules-only`
  — score a ticket by hand, without a model.
- `agent-board-poll --once <slug>` — run one real tick. Each candidate reaching
  its start point logs one `claim-check` outcome: `skipped-because-gated`,
  `no claimant`, `claimant`, or `error`. Development runs continue only after
  `no claimant`; a missing adapter check or failed ticket read stops the claim.
- `agent-template update --dry-run` — see what this host would pull in,
  convert, and clean up without changing anything.
- `agent-template update` — do it for real; safe to run any time, and
  identical to what the five-minute timer runs. It enables and starts each concrete
  timer or service installed by the update, then prints one state line per unit.
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
