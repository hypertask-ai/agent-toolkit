---
name: create-agent
description: Provision a skills-driven agent identity : a worker that reads a skills index before it does anything, optionally wired into a tracker board, or just pointed at a repo. Invoke via /create-agent. Dry-run by default; never creates or revokes a real identity without an explicit go-ahead.
version: 3.6.0
---

# /create-agent : provision an agent identity

This skill is about the method, not about any one tool. An agent is a name, a
mission, a skills index, a model CLI and somewhere to work. A tracker is
optional, and when there is one it sits behind an adapter.

Valentin types `/create-agent` and answers in plain words. He never sees a
flag. This file is the conversation; the scripts are the mechanism.

## Where this comes from

The canonical copy lives in the `vstack` repo under
`templates/agent-skills/create-agent/`. What sits in `~/.claude/skills` and
`~/.local/bin` on any machine is an installed copy, put there by that folder's
`install.sh`. Fix bugs in the repo and re-run `install.sh`, never the other way
round.

## Channels

Host release settings live in `~/.config/agent-template/config`. `CHANNEL=stable`
is the default and makes `agent-template update` fetch and check out the repository's
`stable` tag. Maintainer hosts set `CHANNEL=latest` and `MAINTAINER=yes`, so updates
select `origin/main`. `AUTO_UPDATE=off` makes the 06:30 timer report the current and
stable versions without fetching or changing files; a manual update still works.

Only a maintainer host can run `agent-template promote`. Promotion moves `stable` to
the exact installed commit only after that version has run for 24 hours and its
installed eval suite is green at promotion time. The daily maintainer timer tries
promotion after its own update and prints whether it promoted or refused.

## What update does before it swaps

`agent-template update` selects the configured channel, compares the installed copy
with its install manifest, copies host edits into `local-patches`, stages the target
release, and runs the staged `evals/run-evals.sh`. Only then does `install.sh` rename
the staged directories into place. A red suite prints `update to X refused: N evals
red`, logs that line, exits successfully, and leaves the old version installed.
`--force` is the explicit way to skip only the eval gate.

## Local patches

Every install writes `.manifest.sha256`. On update, a changed installed file is
copied to `~/.claude/skills/create-agent/local-patches/<installed-version>/<path>`,
listed, and reapplied after the release installs. Untracked Python and pytest
cache artifacts are removed before staging. File the change as feedback with
`agent-template feedback` so the source-of-truth fix can move into the repository.

## Mentions

`agent-kick.service` is one localhost HTTP receiver per host. When
`WEBHOOK_URL` is present in the host config, install and update register each agent
for signed `comment.mention` events. A valid request immediately starts
`agent-board-poll@<slug>.service`; the unit's existing lock still prevents overlap.
Without a public URL, installation prints `no WEBHOOK_URL, mentions wait for the
poll` and the 60-second timer remains the fallback.

A failed run posts no board comment and never writes the triggering comment key to
`<slug>.seen`, so the mention remains eligible next tick. Its detail goes to
`<slug>.log` and one-line `<slug>.status` JSON for the agents feed instead.

## Example dialogue

```
Valentin: /create-agent
Claude: Four things, one message:
  1. Name? (e.g. "FP CRO Bot")
  2. What does it do : ships fixes, verifies only, or a plain worker?
  3. Where does its work come from : a board (which one?), or just a repo?
  4. Does it need a chat page people can message it on? (default: no)
Valentin: FP CRO Bot, plain worker, board 2078, no chat
Claude: Plan:
  1. Mission built, pointed at the skills index
  2. Identity created on board 2078, its token saved to a 0600 file
  3. Poll wiring: a timer runs one tick a minute on this machine
  4. Dry run first, then the real run
  5. Self-test on a throwaway ticket, and I quote its reply
  Go?
Valentin: go
Claude: [runs the script with --yes] ... FP CRO Bot picked up the test ticket
  and replied "Read the skills index, matched cro-audit, ran the fixture."
  Timer active. Conf and token both 0600.
```

## What the session does

1. **Read whatever free text followed `/create-agent`.** If it already answers
   name / kind / where the work comes from / chat page, skip to the plan. Only
   ask for what is missing.
2. **Ask the missing questions in one `AskUserQuestion` call:**
   - **Name** : plain text.
   - **Kind** : dev (ships fixes), QA (verifies, never fixes), plain worker, or
     a CLI identity (a name for logs and commit trails, nothing else).
   - **Which board** : the tracker and the board id, or "just a repo".
   - **Chat page?** : default **yes** for every non-CLI board agent. Say no
     only when this identity must not answer in the hosted chat window.
   Never show a flag name to him: map his words yourself.
3. **Show a five-line plan and ask "go?"** before anything real happens. If the
   skills index has no skill matching this agent's domain, write that skill
   first; an agent with nothing to read is not an agent.
4. **Run the script dry first, then with `--yes`.** If the identity already
   exists, add `--resume`: it skips creation and only fills in what is missing.
5. **Finish with evidence.** A self-test ticket, the reply quoted verbatim, and
   the timer's state. An agent nobody has seen do one piece of work is not
   finished, and saying so plainly beats a green checklist.

Every setup must tell the bot and the person creating it the comment contract.
Ticket comments have exactly five allowed kinds: `Question:` asks a human,
names what is needed, and ends with a question mark; `Answer:` replies to a
direct owner question or mention; `Decision:` states a fact the owner must
know; `Handoff:` names the receiving agent and explains what shipped; and
`Done:` explains what shipped and includes the pull request link. Neither
`Handoff:` nor `Done:` can be only a link. Everything else is run activity. A
reminder that qualifies as a decision is posted once and then edited in place,
never re-posted. The existing limit remains one reminder and three comments per
ticket per day unless a human writes in between. With `QUIET="on"`, the wrapper
strips and logs board-owner mentions; moving the ticket to review requests
attention.

All five comment kinds are for a product owner reading on a phone. The agent
drafting any kind must run the draft through the real pospeak, unslop, and
i-have-adhd skills before posting, not only satisfy a mechanical shape check.
A comment can be a bold first sentence, under 80 words, and still be noise to
him: passing the shape check is not the same as being readable. Every runner
prompt includes the pospeak, unslop, and i-have-adhd rules verbatim. It reads
the canonical `skills/talk-to-valentin/` company-pack copy when present and
uses the template's bundled copy when a reference is absent. Owner-facing text
bans skill names, `ROUTE:` lists, file paths, PR numbers without a full URL,
and branch names, on top of the mechanical checks. Before any kind posts, the
board wrapper requires a bold first sentence in a first `<p>`, at most 80
words, no code-shaped detail or em dash, linked ticket and PR references, and
a final question or `Next:` block. A failure gets one 60-second rewrite through
`CHAT_CLI`, falling back to `RESEARCH_CLI`. If the rewrite still fails, the
wrapper keeps the draft and reasons in the run log, posts `Question held: did
not pass the plain-language check` as activity, and posts no comment.

When the owner writes "I don't understand" or asks for a guide, the answering
agent posts exactly one `Decision:` comment shaped as a numbered guide and
nothing else: (1) what is live, (2) what he must do, naming the page URL and
the button, (3) what needs rights he may lack, and (4) what the bots do next.

A human question or direct mention uses a separate reply-only route. The prompt
contains the complete ticket description and thread, a deduplicated shared
record of Valentin's prior ticket statements, and the terminal `CLAUDE.md`,
`pospeak`, `unslop`, and `i-have-adhd` sources verbatim. It explicitly requires
relevant images, repository code, browsing evidence, and runner logs to be read
before answering. Replies always use Codex GPT-5.6 Sol at high effort through
`hax` with `--no-session --bare`, independent of the agent conf, with a
five-minute limit. Bubblewrap exposes the repository and logs
read-only, permits writes only under `/tmp`, and does not mount the board token.
The model returns HTML; the runner checks its shape and posts it afterward.
Its mandatory first step is a private state sheet built from the description
and every ticket comment; the selected ticket's full-thread read is separate
from the capped owned-ticket scan. The sheet records current pull request
states verified with `gh`, the latest dated QA verdict, and relevant
configuration that exists or is missing. Newer verified facts win conflicts,
and the answer identifies superseded older comments. Reply-only runs default
to `Answer:` and never use `Decision:` merely to frame an answer. When a choice
is genuinely required, the reply may end with a `Decision needed:` line that
asks the owner what to choose.

## The three wiring modes

| Mode | What it needs | What you get | When to pick it |
|---|---|---|---|
| **poll** (default) | the board CLI and a model CLI on this machine, nothing else | a 60-second board timer plus the shared 3-second chat lane | almost always, and always for a growth, CRO or support bot |
| **fleet** | a long-lived worker runtime already installed on this machine, which the adapter checks for | webhooks, the shared chat lane, the runtime's own queue and retries | only where that runtime is already running |
| **none** | nothing | an identity, a conf, a skills index; you trigger it from cron, CI or by hand | repo-only agents, and CLI identities |

**Poll mode runs on any machine that has the board CLI and a model CLI. It
needs no shared fleet infrastructure and no second machine.** If `--wiring
fleet` is asked for where the runtime is absent, the script stops and names
poll mode instead of dead-ending.

Chat is independent of board wiring. Poll mode is the default because it works
behind Cloudflare and on hosts with no public port.

## Chat lane

`agent-chat.service` is one always-on process per host. Its chat loop finds
each conf with `CHAT="on"` every three seconds and asks for its newest
unanswered private message and room turns on every `BOARD_ID`. A room turn
wakes only the agent named in its text or target metadata; this includes a bot
named by Product Bot, the room's chief of staff. Unaddressed agents record the
turn as seen and stay silent. A separate loop publishes runtime state every 30
seconds for every valid agent conf, including agents with chat off. Each agent
runs concurrently with the others and with ticket work.

Room replies read the shared transcript. The fourth bot-to-bot turn in one
topic is a deterministic `Handoff:` back to its related ticket. Each posted
turn carries that ticket to the room endpoint, which writes the turn as a run
note atomically. `ROOM_DAILY_TURN_BUDGET` caps replies per board and UTC day
across the host; it defaults to 20, while 0 disables room replies.

Private chat reads conversation history, the company skills index first, then
the agent's own indexes, and a short brief from the conf and latest
`agent-board-poll` log. Chat prompts forbid board writes and worktrees. Replies
use `CHAT_CLI` from the conf, falling back to `MODEL_CLI`, with a 90-second
timeout. The message id is the idempotency key, and
`~/.local/state/agent-chat/handled.jsonl` records it after the reply lands, so
a restart cannot duplicate it. Provider errors are logged and answered with a
one-line error instead of leaving a private conversation silent. Shutdown
cancels an active provider and bounded HTTP calls keep stop within five
seconds. Per-agent logs are `~/.local/state/agent-chat/<slug>.log`.

Polling is the default and needs no inbound port. Set
`AGENT_CHAT_POLL_SECONDS` on the service to change the three-second cadence.
An optional signed receiver can run on localhost by setting
`AGENT_CHAT_WEBHOOK_PORT`; an agent using it also needs
`CHAT_WEBHOOK_SECRET_FILE` in its conf. Expose and register that receiver only
on a host with a real public HTTPS route. Both modes call the same handler.

A third loop, the ticket-ack lane, runs every 60 seconds (`AGENT_ACK_SECONDS`)
for every `CHAT="on"` agent that also has a `BOARD_ID`. It reads
`agent-board-poll`'s own `<slug>.lock` for the ticket the agent is currently
running and, if a human posted a comment on that ticket the agent has not
answered yet, posts one acknowledgement naming how many tasks are ahead
(`agent-progress`'s `eligible_work.count`) and an estimate built from the
agent's own recent `run start`/`run done` durations, the current run's
elapsed time, and that queue length. Once the ticket frees up, the
next tick asks `CHAT_CLI` (falling back to `MODEL_CLI`) for a real answer from
the ticket and the run log alone and edits the acknowledgement in place with
`comment update`, never a second comment. State lives in
`~/.local/state/agent-chat/ack-state.json`, keyed by ticket and question
comment id.

Provisioning prints `https://app.hypertask.ai/agents/chat?agent=<slug>`. Send a
message there with a human account, then quote the timestamped reply from the
agent log. Never send that test with the owner's CLI token.

## Agent page

`https://app.hypertask.ai/agents/<slug>` shows an Operations health badge, the
`agent-board-poll <version>` runtime and model, and current work. The second
loop in `agent-chat.service` feeds that block every 30 seconds with each
agent's own MCP token. It reads the active ticket and start time from
`~/.local/state/agent-board-poll/<slug>.lock`, PR waits from `<slug>.blocked`,
recent completions from `<slug>.log`, and source sections from `board.yml`
beside the conf. One failed agent POST is logged and does not delay the rest.

A fresh empty queue is `connected`; an active ticket is `working`; PR debt is
`waiting`; a run with no progress for five minutes is `stalled`; and a missing
or stale heartbeat is `offline`. Run `agent-chat --status` for each agent's
last publish result, or read `~/.local/state/agent-chat/<slug>.log` for errors.

The page's separate top word uses the durable `Agent.heartbeatAt`, which the
runtime-heartbeat app route does not currently update. Recent comments and evidence still appear. Poll runs register against their
ticket and stream progress to activity cards. Every activity carries the agent,
model, start time, elapsed duration, current outcome, and run-log link. Hosts
remain compatible while the route rolls out because HTTP 404 uses local-only
run logging.

## Where the agent runs

Put this agent on a plain Linux host with systemd: a laptop, a VPS, a
container. It needs a shell, a git checkout on disk, a non-interactive model command it
can spawn as a child process, a token file at 0600, and a poll tick that runs
for minutes.

This agent probably should not live on Cloudflare Workers or Pages Functions:
no shell, no subprocess, no disk, no git, CPU time capped per request, cron
capped at minutes, and secrets in a dashboard instead of a file. We tried a
docs agent as a Worker and retired it in September 2026. Cloudflare still
suits the thin parts: a webhook relay to the host, a public intake endpoint, a
status page. The agent itself stays on the host.

## Every agent has a repo

No repo-less mode: `PR_REPO` is required, and `agent-board-poll` refuses to
tick without it. The repo is the agent's memory. Every output, report or
script it produces is a pull request to it, never a hand edit and never a
write to a chat log nobody else can read. Skills stay in the packs
(`SKILLS_INDEX`); the repo is where the agent's own work accumulates.

`create-agent.sh --pr-repo <org/name>` provisions it: creates a private
GitHub repo from `repo-skeleton/` (README, `board.yml`, `scripts/`,
`reports/`, `CHANGELOG.md`, a pr-title check) if it does not exist yet, and
writes `PR_REPO` into the conf either way. Re-run with `--resume --pr-repo
<org/name>` against an existing identity to add a repo it did not have
before; nothing else about that identity changes.

GitHub refuses `allow_auto_merge` on a private repo whose plan does not carry
it, which is true for these repos. That refusal is expected, not an error:
`create-agent.sh` logs "auto-merge unavailable on private repo, supervisor
merges green PRs" and keeps going, and a run's own PR step does the same
instead of failing over it.

## Shape of the code

```
VERSION                       bumped on every pull request; reported by feedback
CHANGELOG.md                  one entry per version; ACTION: lines are read by update
core
  scripts/create-agent.sh     provisioning: identity, conf, wrapper, wiring
  scripts/agent-board-poll    one work tick: read, decide, spawn, log
  scripts/agent-chat          shared host daemon: poll, answer, deduplicate
  scripts/agent-template      feedback: file a correction where it can be replayed;
                               update: pull, reinstall, convert old-schema confs
  scripts/agent-template-feedback  judge and close feedback every four hours
  scripts/agent-template-weekly    compatibility alias for agent-template-feedback
  scripts/agent-rules         a repo's learned rules: add, promote, confirm, decay, archive
  scripts/lib/core.sh         slug, conf files, secrets, adapter loading, poll units
adapters/
  hypertask/adapter.sh        everything that talks to a Hypertask board
  linear/adapter.sh           stub: same function names, all refuse loudly
  none/adapter.sh             repo-only: reads return nothing, writes refuse
evals/
  cases.jsonl                 one line per correction anyone has made
  run-evals.sh                replays them all; non-zero on any failure
project-template/.claude/skills/learned-rules/  the skill and RULES.jsonl store
                               sync-project.sh lays into every synced repo
repo-skeleton/                 what create-agent.sh --pr-repo pushes to a new
                               memory repo: README, board.yml, scripts/,
                               reports/, CHANGELOG.md, a pr-title check
```

Core names no tracker, no vendor and no machine. The runner sources
`adapters/<board>/adapter.sh` and calls its functions. Adding a tracker means
writing one adapter file; nothing in core changes. The contract is the function
list in `scripts/lib/core.sh`, and a missing function fails at load time with
our own message rather than "command not found" three layers down.

## What a poll tick does

1. Read the agent's conf and load its adapter.
2. Take a non-blocking lock; if a tick is already running, exit.
3. List PRs owned through the agent's branch prefix, current ticket assignment,
   or recorded run state, and stop normal pickup on the oldest one not LIVE.
4. List the board's tickets in the watched columns.
5. Keep the ones **assigned to this agent id**, or whose **newest comment
   @mentions it**.
6. Drop anything already handled. The state key is `<task id>:<newest comment
   id>`, so a fresh reply on an old ticket counts as new work and a re-read of
   the same one does not.
7. For each remaining ticket, up to `MAX_CONCURRENT_RUNS`, register a runtime
   run on that ticket, then start **one short-lived process**. Claimed, started,
   PR opened, red check, fix pushed, retrying, blocked, and done progress is run
   activity. A 404 from the runs API switches to local-only activity in the run
   log without stopping work. The runner closes the run with its final status.
8. The prompt tells the process to read the skills index first, gives it the
   ticket and latest comment, and limits ticket comments to the four kinds.
9. Log to `~/.local/state/agent-board-poll/<slug>.log` and exit.

## One ticket until live

An agent that owns a PR which is not LIVE does not claim another normal ticket.
A PR is owned when its branch starts with the agent's `PR_BRANCH_PREFIX`
(default `agent/<slug>-`), when the ticket in its title is currently assigned
to that agent and the branch has no other agent prefix, or when
`<slug>.opened-prs` records that the runner first saw it during that agent's
run. Shared GitHub authorship and comments do not transfer ownership.

Multiple debts are ranked oldest first and written together to the blocked
state. With more than one debt, even an `emergency` does not start new work.
An open PR whose ticket is unassigned or assigned to no active agent blocks
nobody unless branch or run state identifies an owner. The first tick each UTC
day logs `orphaned PR #<n> (<branch>) has no owning agent` for supervisor
follow-up.

**LIVE has one exact definition:** the PR is merged, its merge commit is
contained in its base branch, and the newest GitHub deployment for that base in
the `Production` environment was created after the merge, has status `success`,
and deploys a commit containing the merge. The answer is cached per PR for 60
seconds. If the repository has no GitHub deployment records at all, LIVE falls
back to merged plus base-contains-merge, and the runner logs that fallback.

An open red PR gets another fix run with the exact failed check names, failed
run logs, and verbatim `CONCERNS` or changes-requested review text. `ci-tests`,
`revert-guard`, `pr-title`, and AI review feedback are work, not reasons to move
on. Pending checks consume the tick and log `waiting on PR #<n>: checks
pending`. A merged but undeployed PR also consumes the tick. Neither path
claims a ticket.

The PR path never reads the attempts file, applies a retry limit or cooldown,
uses the model escalation ladder, or hands work to a manager. Every tick keeps
fixing or waiting for the same PR until it is LIVE. Attempt windows apply only
to ticket runs that have not produced a PR. QA escalation applies only when a
ticket is rejected after its PR was live.

The runner writes one JSON line to
`~/.local/state/agent-board-poll/<slug>.blocked`. Its top-level `pr`, `state`,
`since`, and `ticket` identify the oldest debt for existing consumers, and its
`prs` array lists every owned non-live PR in rank order. This is what the
owner-facing agents feed can show as “waiting on PR n”. A supervisor may flag
a PR older than 24 hours for a human look, but that does not release the agent
to take new work.

Every tick also atomically writes `<slug>.progress.json` in that state folder.
It records the last completed run, opened PR, merge, current wait and its start,
eligible count, repeated failure signature, and build or instruction result.
Product Bot reads every version-1 snapshot on its own tick. The oldest active
`stall` object exposes `stalled_since` and one line of `reason` directly to
analytics. The complete field contract and the four thresholds are in
`MAINTAINER.md` under “Fleet progress contract”.

Every owner question or direct mention assigned to an agent also lives in
`<slug>.reply-contract.json`. Its lifecycle records when it was received,
acknowledged, answered, and when an answer estimate was given and due. Product
Bot publishes one daily `Reply contract` result on each board's standing
`Board health` ticket and files one Bug ticket per new miss.

The same health pass posts only new pile-ups on that standing ticket. It flags
columns over eight tickets, tickets over 24 hours in Inbox or a review lane,
green or red allowlisted pull requests over two hours, runner errors, and down
poll timers. A `Question:` or `Decision:` first line keeps these comments valid
in quiet mode. The supervisor score from
`~/.local/state/ht-supervisor/health.json` is always first, and a new pile-up
may mention the board owner at most once in 24 hours.

No work process survives the tick. The board remains the work state, while the
progress file is read-only telemetry, so there is no queue, lock database, or
daemon to drift.

**Why a timer plus `Type=oneshot`, not a service with a loop.** systemd refuses
to start a second run of a oneshot unit while one is still active, so the
concurrency guard is free and correct. A `Restart=always` loop would need its
own sleep, its own crash handling and its own guard, and would hold a process
open between ticks for no reason. The timer's schedule is also readable with
`systemctl --user list-timers`, which a loop's internal sleep is not.

## When a human corrects you

When a human corrects your output, whether they edit your comment, fail your
QA, reject your pull request or simply say that is wrong, stop and run
`agent-template feedback --kind bug --what "<one sentence>" --got <the bad
output> --expected "<what should have happened>"` before you carry on with the work. A
correction that lives only in a conversation is gone tomorrow; filed, it
becomes a stored check that replays on every change to this template, so the
next agent cannot make the same mistake. Set `FEEDBACK_OPT_OUT=yes` in the conf
if an agent must never send one.

**The correction also has to land, in the same run, not wait for a human to
merge it.** When the correction is about how the agent should behave, edit the
skill file in this repo's skills folder right there and commit it, message
`skill: <what changed> (from <ticket>)`. Do not open a pull request for a
skill edit: `evals/run-evals.sh` running on push is the gate, the same check
that runs on every pull request. `agent-board-poll` pushes those commits
itself after the run, straight to the skills repo's default branch, and only
when they touch nothing outside the skills folder and the evals still pass;
otherwise it leaves a comment naming which check failed and nothing is pushed.

**Fact or rule decides where a correction goes.** A fact — a number, a name, a
date, a path — goes into the repo's docs or the ticket, never into a skill. A
rule — always or never do X — goes into the skill file. If it is unclear
which: would it still be true for a different customer? Yes means rule, no
means fact.

The paragraphs above are about correcting this template's own skill file. A
correction made on a *project* a provisioned agent works — the repos
`sync-project.sh` lays the standard layout into — goes through
`.claude/skills/learned-rules/` in that project instead: `scripts/agent-rules`
turns the correction into a scored rule, proposed as a pull request for a
human to veto, then loaded by every later run in that repo and faded out if
it stops mattering. See `project-template/.claude/skills/learned-rules/SKILL.md`.

## Feedback

A bot or an interactive session files a bug, change request, or idea with one
interface:

```
agent-template feedback --kind bug|change|idea --what "<summary>" --got "<current behavior or context>" --expected "<desired behavior>"
```

It lands in the Agent Template Inbox on project 5500
(https://app.hypertask.ai/detail/project-5500, prefix AGTE) as the bot's own
identity, never the owner's. `agent-template-feedback` reads urgent tickets
first and checks the Inbox every four hours on the maintainer host. It replies
to every ticket with accepted, need info plus one question, or declined.
Accepted work gets one auto-merge fix pull request and moves to Accepted. When
a merged release changelog names the AGTE ticket, the same bot replies
`Shipped in <version>: <one line>` and moves it to Done. Daily updates on the
filing host print `feedback waiting: AGTE-n` until that ticket closes.
`--dry-run` renders a filing without sending it.

## Evals

`evals/cases.jsonl` holds one line per correction: the output that would have
been right, and the name of the predicate that has to hold for it. `evals/run-evals.sh`
replays every line and exits non-zero with the failing ids. The predicates are
an allowlist inside that script, never shell from the case file, because the
case file can be appended to by the automated feedback run and executed in CI.

`agent-template-feedback` checks every four hours and handles urgent tickets
first. The model returns an accept, need-info, or decline verdict. Accepted
work is implemented and evaluated in an isolated worktree, then opened as one
auto-merge pull request per ticket. `agent-template-weekly` remains only as a
compatibility alias. Changelog reconciliation is independently idempotent, so
a merged ticket receives one shipped comment even if its AGTE reference appears
more than once.

## The conf decides the provider

The conf is the only command policy. Core treats every command as opaque: it
has no provider allow-list and no built-in ladder.

- `MODEL_CLI` is normal ticket work and rung 1.
- `LADDER` is an optional `|`-separated list of full commands. After three
  failed attempts, each later attempt takes the next command. Empty or absent
  means no escalation.
- `RESEARCH_CLI` is optional for `agent-advisor` and supervisor research.
  Empty or absent means no research step.
- `TRIAGE_HARD_CLI` is optional for tickets labelled `hard`; absent means
  `MODEL_CLI`.
- `CHAT_CLI` is optional for Agent Chat; absent means `MODEL_CLI`.

Each value is a complete non-interactive command, including model, tool,
permission and print flags. The runner splits it into arguments without shell
evaluation and appends the prompt as the final argument, which is the existing
`MODEL_CLI` contract. Put `-p`, `--print`, or the harness equivalent before the
prompt. A literal `|` cannot be part of a ladder command because it separates
rungs.

A pi-only conf needs no other policy:

```sh
MODEL_CLI="pi --print --tools read,bash,edit,write --no-extensions --no-skills --provider zai --model glm-5.3-flash"
```

A Cursor-first conf can explicitly choose the former ladder:

```sh
MODEL_CLI="cursor-agent -p --output-format text --model cursor-grok-4.6-high-fast -f --trust"
LADDER="/home/valentin/.local/bin/hax --provider=codex --model=gpt-5.6-sol --effort=high --no-session -p|/home/valentin/.local/bin/hax --provider=codex --model=gpt-5.6-sol --effort=high --no-session -p|/home/valentin/.local/bin/hax --provider=codex --model=gpt-5.6-sol --effort=high --no-session -p"
RESEARCH_CLI="/home/valentin/.local/bin/hax --provider=codex --model=gpt-5.6-sol --effort=xhigh --no-session --raw -p"
TRIAGE_HARD_CLI="/home/valentin/.local/bin/hax --provider=codex --model=gpt-5.6-sol --effort=high --no-session -p"
CHAT_CLI="cursor-agent -p --output-format text --model cursor-grok-4.6-high-fast -f --trust --mode ask"
```

See `CONF.md` for the complete schema.

## The conf

`<config dir>/<slug>.conf`, 0600. Core keys, no tracker prefixes:

| Key | Meaning |
|---|---|
| `AGENT_ID` | the identity's id on the board |
| `AGENT_NAME` | display name, used in the prompt |
| `BOARD_ADAPTER` | which adapter to load |
| `BOARD_ID` | the board this agent watches |
| `TOKEN_FILE` | absolute path to the 0600 token file |
| `BOARD_CLI` | the wrapper that runs board writes as this agent |
| `WATCH_SECTIONS` | comma-separated columns to watch |
| `QA_FAIL_SECTION` | optional failed-QA destination; defaults to the board's first intake column |
| `QA_BLOCKED_SECTION` | optional cannot-test destination; defaults to `HT Manager Review` when present |
| `SKILLS_INDEX` | the indexes the agent reads first, comma separated, **company pack first, bot pack last** |
| `MODEL_CLI` | required full command for normal ticket work |
| `LADDER` | optional `\|`-separated escalation commands, one per failure after three |
| `RESEARCH_CLI` | optional advisor and research command; absent disables research |
| `TRIAGE_HARD_CLI` | optional hard-ticket command; absent uses `MODEL_CLI` |
| `CHAT_CLI` | optional chat command; absent uses `MODEL_CLI` |
| `MAX_CONCURRENT_RUNS` | runs started per tick, default 1 |
| `CHAT` | `on` to answer through the host chat daemon, default `on` for non-CLI board agents |
| `QUIET` | `on` redirects unmarked comments to activity and strips board-owner mentions; default `on` |
| `ANSWERER_FALLBACK` | fallback answerer slug when no mention, agent assignee, or prior `Done:` or `Decision:` author exists; default empty |
| `MANAGER` | `on` to allow runner control and ticket delegation, default `off` |
| `MAINTAINER` | `on` to add allowlisted setup builds, merges, and advisor instructions, default `off` |
| `CLAIM_UNASSIGNED` | `yes` to also take tickets nobody is assigned to, default `no` |
| `EXCLUDE_LABELS` | labels that make a ticket off limits, comma separated |
| `WORKDIR_MODE` | `repo` (default) runs in `AGENT_REPO`; `per-run` gives each ticket its own checkout |
| `WORKDIR_ROOT` | where `per-run` checkouts go, required when `WORKDIR_MODE=per-run` |
| `RETRY_LIMIT` | failed attempts a ticket with no PR gets per window; default three plus the number of ladder commands; never used for an owed PR |
| `RETRY_WINDOW_SECONDS` | length of that pre-PR window, default 21600 (six hours); never used for an owed PR |
| `PROMPT_FILE` | a prompt of this agent's own, with `{{REF}}`, `{{URL}}`, `{{TITLE}}`, `{{DESCRIPTION}}`, `{{COMMENT}}`, `{{AGENT_NAME}}`, `{{BOARD_CLI}}`, `{{SKILLS_INDEX}}`, `{{BOARD}}` |
| `PR_REPO` | **required.** the repository whose pull requests say whether a ticket is finished; `agent-board-poll` refuses to tick without it. Set it with `create-agent.sh --resume --pr-repo <org/name>` |
| `PR_BRANCH_PREFIX` | branch prefix that proves this agent owns a PR, default `agent/<slug>-` |
| `TRIAGE` | `yes` to score a ticket before pickup; defaults to `yes` for `AGENT_KIND=dev` and `no` for everything else |
| `TRIAGE_MODEL_CLI` | optional command that breaks a tie the rules could not; default `MODEL_CLI` |
| `ADVISOR_MAX` | `agent-advisor` calls allowed per run, default 2 |

## Manager agents

`MANAGER="on"` gives that agent the commands below. `MAINTAINER="on"` includes
them. All other agents are refused and do not receive them in runner or chat
prompts.

```sh
agent-template ctl start|stop|status <slug>
agent-template delegate <ticket> <slug> --why "<one line reason>"
agent-template mode manual|auto [--board <id>|--runner <slug>]
agent-template model <slug> <preset>
agent-template sections <slug> <list>
agent-template quiet on|off [<slug>|all]
agent-template feedback --as <slug> --kind bug|change|idea --what "<summary>" --got "<context>" --expected "<result>"
```

`mode` sets `CLAIM_UNASSIGNED` to `no` for manual or `yes` for auto on every
dev and QA conf matching the selected board. An omitted board uses the
manager's `BOARD_ID`. `model` accepts only the named `grok-fast`, `glm-flash`,
and `codex-sol` presets and writes their exact template policy command, never text
supplied as a command. `sections` sets `WATCH_SECTIONS` to a comma-separated
list, or `*`, for one current agent. `quiet` sets `QUIET` for one current agent
or all current agents. Each changed conf is first copied to
`<conf>.bak-<timestamp>`, and the
one-line result names every changed conf.

`ctl` starts a runner timer, stops its timer and current service, or reports
both states. `delegate` uses the manager's own `BOARD_CLI`, assigns the target
agent UUID, and posts one handoff comment. `feedback --as` reads `BOARD_CLI`
from that manager's conf and files the toolkit ticket as that identity. Direct
feedback with `--board-cli` remains available outside the manager command path.
Chat turns command output into one plain outcome sentence instead of exposing
raw output. Affected tickets use Markdown links with the full id and board API
title.

Manager commands reject token or credential settings, foreign unit names,
paths outside the configured conf directory, and confs without the
`BOARD_ADAPTER` schema marker. Delegation also refuses the board owner's
tickets and userId 6. Every accepted or refused manager action is recorded in
`~/.local/state/agent-board-poll/manager-actions.log`.

## Setup maintainer

`MAINTAINER="on"` makes one agent the executor for setup changes. Missing or
any other value is off. Its runner and chat prompts require a build for every
change to the toolkit, supervisor rules, analytics site, app, CLI, or Slack bot,
and forbid launching a model harness directly. An allowlisted merge, release,
update, or build instruction runs the matching maintainer command in the current
run instead of entering the developer pull request workflow or being delegated.
A successful direct merge gets a `Done:` comment with the linked pull request;
the existing completion checker reports background build results.

```sh
agent-template build --repo <key> --ticket <url> --spec <file|-> [--effort high|xhigh]
agent-template build status [id]
agent-template build list
agent-template merge <pr-url>
agent-template update --keep-timers
agent-template instruct <slug> <text|-> [--ticket <url>]
```

`repos.allow` beside the conf supplies `key,path,github slug,base branch,memory
cap` CSV rows, with the memory cap optional. Its default is 12 GB on hosts with
more than 32 GB of RAM and half of RAM otherwise. A first install discovers the
slug and default branch from each checkout's `origin`; a build outside the
file or whose checkout origin differs is refused. An accepted build writes the
standard worktree, pull request, check, squash-merge, deployment, cleanup, and
reporting guardrails into a prompt, starts the capped systemd user job, and
records its paths and status in `<slug>-builds.json`. Status prints the exit
marker and twelve output lines; list is the source for answering what the
agent did.

Before each runner tick, the service reconciles completed systemd build units.
It records any non-success result as failed, including jobs killed before they
could write an exit marker. An OOM kill posts `Decision: build failed: out of
memory` in that tick. The runner posts exactly one `Done:` line with the pull
request URL on success or one checked `Decision: build failed:` comment on other
failures, then closes the record. Ticket URLs are resolved through the
board adapter before posting. Comment failures stop after two attempts and log
the command, exit code, and stderr. `merge` accepts only an allowlisted,
non-draft pull request whose checks are all green and always uses squash merge.

`instruct` is the advisor session's only setup entry point. It first writes JSON
under `<slug>-instructions/`, then uses that agent's board CLI to create an HTML
instruction ticket on toolkit board 5500 and assign it to the agent. The ticket
is due in four hours by default. Text containing `urgent` sets a one-hour due
date and Urgent priority. The ticket uses Triage when present and the board's
intake section otherwise. Once the
ticket id is recorded under `agent-template/instruction-tickets/`, the transport
file is removed. A board error leaves the JSON in place and returns non-zero, and
install retries queued files without duplicating a ticket. A ticket created by
hand on board 5500 and assigned to Product Bot follows the same normal ticket run,
build, and `Done:` comment path. A spec has four parts: Ticket, What, Done when,
and Guardrails.

## How hard is this ticket

A ticket carrying neither `easy` nor `hard` is scored before the run starts,
by `scripts/triage.sh`. Rules decide it, in this order, and the order is the
design:

1. **hard** — the subject is hard here whoever writes it: realtime, auth,
   money, database schema, or a bug that only happens sometimes.
2. **hard** — somebody already tried and failed: a QA FAIL comment, a
   "Run failed" comment, or a pull request that closed without merging.
3. **easy** — it names the file, component or screen to change. Checked before
   the vague rule, because a one-line CSS ticket is short AND easy.
4. **hard** — it is vague: under 200 characters, no acceptance criteria, and
   nothing named.
5. Only if none of those fire, one cheap model call decides.

The score is written on the ticket as a label, so a human can see it and
overrule it by changing it. A `hard` ticket runs on `TRIAGE_HARD_CLI` when
configured, otherwise `MODEL_CLI`, and has to post a numbered plan (root cause, files, how it will verify) as its first
comment, which counts toward its three. An `easy` ticket changes nothing. QA
agents are never scored: they verify somebody else's work.

## QA completion

A QA run has one terminal verdict and one matching board transition. Pass posts
one `Done:` comment and moves to Done. Fail posts one `Handoff:` comment whose
single line names the failing step, clears every assignee, and moves to
`QA_FAIL_SECTION`, or the board's first intake column when that key is empty. Cannot test posts one
`Question:` and moves to `QA_BLOCKED_SECTION`, or `HT Manager Review` when it
exists; with neither column configured it stays in QA.

The runner enforces this contract after the model exits. It parses `Done:`,
`Handoff:`, or `Question:` from the verdict comment and supplies a missing move.
On every tick it also backfills QA tickets whose newest comment is that agent's
verdict and is at least ten minutes old. A ticket labelled `valentin` or
directly assigned to the board owner is skipped and never moved.

When `RESEARCH_CLI` exists, an agent stuck mid-run can use `agent-advisor
"<one precise question>"`. It receives the ticket, last ten comments and current
diff. Twice per run; the third call refuses. It reads the board and never writes
to it. Without `RESEARCH_CLI`, the prompt does not offer this step.

## Company pack + bot pack

`SKILLS_INDEX` is a list, not one path. Every bot in a company does the same
things to a board (claim a ticket, shape a comment, escalate a decision, write
to the owner) and different things on top. So there are two packs:

- the **company pack**, one repo every bot reads first. `install.sh` clones or
  fast-forwards it to `~/projects/company-skills` on every host, and
  `agent-template update` says which commit it is on.
- the **bot pack**, what this bot alone does.

The runner concatenates them for the prompt, in order, and the first pack wins
a name collision, which is why the company pack goes first. A conf with one
path is a list of one and keeps working unchanged.

```
SKILLS_INDEX="/home/valentin/projects/company-skills/INDEX.md,/home/valentin/projects/hypertask-agent-skills/INDEX.md"
```

`create-agent.sh --skills-index` is repeatable, or takes the comma-separated
list directly. The domain-words warning checks the **bot** pack, the last one:
a company pack is generic by definition and would match nothing.

Board mechanics a skill needs but cannot hardcode (column names) come from a
`board.yml` next to the bot's conf, not from a skill file. See the company
pack's `supervise-board/scripts/board_config.py`.

`BOARD_ID` takes more than one board, comma separated. `WATCH_SECTIONS` takes
`*` for every column, which is what an agent answering @mentions needs.

Set `MODEL_CLI` to the complete non-interactive command. `create-agent.sh
--provider pi` writes the pi example above; `--model-cli` accepts any other
command without interpreting its provider or harness.

## Tokens

The board prints an agent's bearer token exactly once, when the identity is
created. The script parses it out of the reply with a JSON parser (never a
grep, which happily matches the word "token" in the reply's own advice text),
writes it straight to a 0600 file under `umask 077`, and checks the file is
non-empty and really 0600 before going on.

If the token cannot be parsed, the script **stops** and prints the exact rotate
command to run with the owner's go-ahead, plus the path to save the result to.
It never carries on with a half-made agent, and it never prints the token, not
in a log, not in a prompt, not in a command line. Board writes go through a
one-line wrapper that reads the token file at call time.

## Hard rules

- **Dry run is the default.** Nothing is created, changed or installed without
  `--yes`. Read-only checks still run, so a duplicate name fails before any
  local write.
- **Creating an identity has its own stop** on top of `--yes`: it makes a real
  account someone has to clean up.
- **Existing identities need `--resume`**, which never replaces a value that is
  already there.
- **Never print a token or a secret.** Paths only.
- **Never assign the owner's own user id** to an agent identity.
- **A CLI identity cannot chat.** Do not promise a chat test for one.
- **QA gets its own browser storage state**, never a person's and never a dev's.

## Check before you say done

- the conf and the token file are both 0600, and the token file is not empty
- the skills index exists and has a skill matching this agent's work
- `agent-board-poll --once --dry-run <slug>` lists the tickets you expect
- `agent-board-poll --once <slug>` posted a real reply as the agent, and you
  quote it
- the timer is active, and the log shows a finished tick
- fleet wiring only where the adapter confirmed a runtime; otherwise poll
- `evals/run-evals.sh` passes, and the agent knows to run `agent-template feedback`

## What Anthropic's agent guidance means here

- Every domain bot should ship with a fixture test that its skill runs
  first, before it touches anything real.
- Its operating loop should be a numbered workflow with checkpoints, not
  free-form work.
- Its skill should have an explicit "ask the human only on these" list.
- Chat replies should report concrete evidence (fixture output, source
  links) instead of bare assertions.

## Known issues

- None tracked right now. A board layer's own known issues belong in that
  adapter's part of this file, not here.

## Reference

- `install.sh` in this folder : puts the skill and the runner on a machine
- `scripts/create-agent.sh --help`, `agent-board-poll --help` : every flag
- `scripts/lib/core.sh` : the adapter contract, as a function list
- `agent-template feedback --help`, `evals/run-evals.sh --help` : the correction loop
- `MAINTAINER.md` in this folder (copied next to every bot's conf) : for the
  session that looks after a bot, not the bot itself

## Changelog

One line per version, newest first. `VERSION` and this file's frontmatter
move together.

- **3.6.0** — a third wake trigger (a human comment on a ticket the agent
  owns, even outside `WATCH_SECTIONS`); a skill edit ships and pushes itself
  in the same run instead of waiting on a pull request; `agent-template
  feedback --case` turns a correction straight into a proposed eval case,
  promoted by the weekly run; `agent-template report` scores corrections and
  repeats; a fact-vs-rule rule in the mission text and this file;
  `MAINTAINER.md` for whoever looks after a bot.
- **3.5.0** — one pull request per ticket instead of one for a whole run.
- **3.4.0** — a worktree holding the only copy of some work is kept, not deleted.
- **3.3.0** — an excluded label is a hard stop; multiple boards; a prompt per agent.
- **3.2.0** — a working directory per run, unclaimed tickets, failures written on the board.
- **3.1.0** — poll wiring mode and safe token capture.

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
