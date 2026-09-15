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
   - **Chat page?** : default **no**. Say yes only if a person needs to message
     the agent in a hosted chat window. It is the one thing poll wiring cannot
     give you.
   Never show a flag name to him: map his words yourself.
3. **Show a five-line plan and ask "go?"** before anything real happens. If the
   skills index has no skill matching this agent's domain, write that skill
   first; an agent with nothing to read is not an agent.
4. **Run the script dry first, then with `--yes`.** If the identity already
   exists, add `--resume`: it skips creation and only fills in what is missing.
5. **Finish with evidence.** A self-test ticket, the reply quoted verbatim, and
   the timer's state. An agent nobody has seen do one piece of work is not
   finished, and saying so plainly beats a green checklist.

## The three wiring modes

| Mode | What it needs | What you get | When to pick it |
|---|---|---|---|
| **poll** (default) | the board CLI and a model CLI on this machine, nothing else | a 60-second timer; each tick reads the board and starts one short-lived process per new ticket | almost always, and always for a growth, CRO or support bot |
| **fleet** | a long-lived worker runtime already installed on this machine, which the adapter checks for | webhooks, a chat lane, the runtime's own queue and retries | only where that runtime is already running |
| **none** | nothing | an identity, a conf, a skills index; you trigger it from cron, CI or by hand | repo-only agents, and CLI identities |

**Poll mode runs on any machine that has the board CLI and a model CLI. It
needs no shared fleet infrastructure and no second machine.** If `--wiring
fleet` is asked for where the runtime is absent, the script stops and names
poll mode instead of dead-ending.

A chat page is the one capability poll mode does not have, which is why the
question defaults to no.

## Where the agent runs

Put this agent on a plain Linux host with systemd: a laptop, a VPS, a
container. It needs a shell, a git checkout on disk, a model CLI it can spawn
as a child process (claude, cursor-agent, codex), a token file at 0600, and a
poll tick that runs for minutes.

This agent probably should not live on Cloudflare Workers or Pages Functions:
no shell, no subprocess, no disk, no git, CPU time capped per request, cron
capped at minutes, and secrets in a dashboard instead of a file. We tried a
docs agent as a Worker and retired it in September 2026. Cloudflare still
suits the thin parts: a webhook relay to the host, a public intake endpoint, a
status page. The agent itself stays on the host.

## Shape of the code

```
VERSION                       bumped on every pull request; reported by feedback
CHANGELOG.md                  one entry per version; ACTION: lines are read by update
core
  scripts/create-agent.sh     provisioning: identity, conf, wrapper, wiring
  scripts/agent-board-poll    one work tick: read, decide, spawn, log
  scripts/agent-template      feedback: file a correction where it can be replayed;
                               update: pull, reinstall, convert old-schema confs
  scripts/agent-template-weekly  turn a week of corrections into one pull request
  scripts/lib/core.sh         slug, conf files, secrets, adapter loading, poll units
adapters/
  hypertask/adapter.sh        everything that talks to a Hypertask board
  linear/adapter.sh           stub: same function names, all refuse loudly
  none/adapter.sh             repo-only: reads return nothing, writes refuse
evals/
  cases.jsonl                 one line per correction anyone has made
  run-evals.sh                replays them all; non-zero on any failure
```

Core names no tracker, no vendor and no machine. The runner sources
`adapters/<board>/adapter.sh` and calls its functions. Adding a tracker means
writing one adapter file; nothing in core changes. The contract is the function
list in `scripts/lib/core.sh`, and a missing function fails at load time with
our own message rather than "command not found" three layers down.

## What a poll tick does

1. Read the agent's conf and load its adapter.
2. Take a non-blocking lock; if a tick is already running, exit.
3. List the board's tickets in the watched columns.
4. Keep the ones **assigned to this agent id**, or whose **newest comment
   @mentions it**.
5. Drop anything already handled. The state key is `<task id>:<newest comment
   id>`, so a fresh reply on an old ticket counts as new work and a re-read of
   the same one does not.
6. For each remaining ticket, up to `MAX_CONCURRENT_RUNS`, start **one
   short-lived process**: the prompt tells it to read the skills index first,
   gives it the ticket and the latest comment, and tells it to post its reply
   with the agent's own board CLI and move the ticket per the skills index.
7. Log to `~/.local/state/agent-board-poll/<slug>.log` and exit.

Nothing survives the process except the board, the repo and that log. This is
the one-process-per-ticket design: the board is the state, so there is no
queue, no lock database and no daemon to drift.

**Why a timer plus `Type=oneshot`, not a service with a loop.** systemd refuses
to start a second run of a oneshot unit while one is still active, so the
concurrency guard is free and correct. A `Restart=always` loop would need its
own sleep, its own crash handling and its own guard, and would hold a process
open between ticks for no reason. The timer's schedule is also readable with
`systemctl --user list-timers`, which a loop's internal sleep is not.

## When a human corrects you

When a human corrects your output, whether they edit your comment, fail your
QA, reject your pull request or simply say that is wrong, stop and run
`agent-template feedback --what "<one sentence>" --got <the bad output>
--expected "<what should have happened>"` before you carry on with the work. A
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

## Evals

`evals/cases.jsonl` holds one line per correction: the output that would have
been right, and the name of the predicate that has to hold for it. `evals/run-evals.sh`
replays every line and exits non-zero with the failing ids. The predicates are
an allowlist inside that script, never shell from the case file, because the
case file is appended to by an automated weekly run and executed in CI.

`agent-template-weekly` reads the feedback board once a week, asks a model to
judge each ticket, appends a case per accepted one, and opens a single pull
request with auto-merge off. It may only touch `evals/cases.jsonl` and
`evals/PENDING-FIXES.md`: never `install.sh`, never an adapter's auth code, and
it never deletes or rewrites an existing case.

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
| `SKILLS_INDEX` | the indexes the agent reads first, comma separated, **company pack first, bot pack last** |
| `MODEL_CLI` | command template, default `claude -p --model sonnet` |
| `MAX_CONCURRENT_RUNS` | runs started per tick, default 1 |
| `CLAIM_UNASSIGNED` | `yes` to also take tickets nobody is assigned to, default `no` |
| `EXCLUDE_LABELS` | labels that make a ticket off limits, comma separated |
| `WORKDIR_MODE` | `repo` (default) runs in `AGENT_REPO`; `per-run` gives each ticket its own checkout |
| `WORKDIR_ROOT` | where `per-run` checkouts go, required when `WORKDIR_MODE=per-run` |
| `RETRY_LIMIT` | goes a failing ticket gets per window, default 2 |
| `RETRY_WINDOW_SECONDS` | length of that window, default 21600 (six hours) |
| `PROMPT_FILE` | a prompt of this agent's own, with `{{REF}}`, `{{URL}}`, `{{TITLE}}`, `{{DESCRIPTION}}`, `{{COMMENT}}`, `{{AGENT_NAME}}`, `{{BOARD_CLI}}`, `{{SKILLS_INDEX}}`, `{{BOARD}}` |
| `PR_REPO` | the repository whose pull requests say whether a ticket is finished |
| `TRIAGE` | `yes` to score a ticket before pickup; defaults to `yes` for `AGENT_KIND=dev` and `no` for everything else |
| `TRIAGE_HARD_MODEL` | the model a `hard` ticket moves to; defaults to `claude-opus-5-thinking-high` for a `cursor-agent` CLI and `opus` for anything else |
| `TRIAGE_MODEL_CLI` | the cheap model that breaks a tie the rules could not, default `claude -p --model haiku` |
| `ADVISOR_MAX` | `agent-advisor` calls allowed per run, default 2 |
| `ADVISOR_CLI` | the model `agent-advisor` asks, default `claude -p --model opus` |

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
overrule it by changing it. A `hard` ticket runs on a stronger model and has to
post a numbered plan (root cause, files, how it will verify) as its first
comment, which counts toward its three. An `easy` ticket changes nothing. QA
agents are never scored: they verify somebody else's work.

When an agent is stuck mid-run, `agent-advisor "<one precise question>"` gets a
second opinion from a stronger model, given the ticket, its last ten comments
and the run's current diff. Twice per run; the third call refuses. It reads the
board and never writes to it.

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

Override `MODEL_CLI` to change model or vendor, for example `cursor-agent -p`.
A headless model CLI usually needs its own permission flags; put them in this
value, because the runner passes the template through untouched.

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
