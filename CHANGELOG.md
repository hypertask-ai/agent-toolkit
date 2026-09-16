## 3.18.4
- agent-template-feedback: read section names from the CLI field section_title (name is absent), so the board lookup no longer fails. ACTION: none.

## 3.18.2
- agent-template-feedback: accept a "Fixed" section as the shipped column (board 5500 uses Inbox, Accepted, Fixed, Rejected). ACTION: none.

# agent-template changelog

One entry per version. A line marked `ACTION:` is something the template
cannot do for itself; `agent-template update` prints it and logs it once per
version to `~/.local/state/agent-template/actions.log` for a maintainer
session to read and act on.

## 3.18.3 - 2026-09-16

- AGTE-5: when `WATCH_SECTIONS="*"` lists a ticket before its owned-reply row,
  the kept ticket now inherits the `new_comment` trigger and remains eligible.
- `OWNED_REPLY_ADDRESSED=yes` can limit unassigned owned replies to messages
  that name the agent or start with `fix:`.

## 3.18.1 - 2026-09-16

- AGTE-2: owned-ticket reply checks now stream ticket and comment JSON to
  Python, so large comment threads cannot exceed the process argument limit.
- A parsing failure now writes an explicit `ERROR:` line instead of silently
  skipping that ticket's wake check.

## 3.18.0 - 2026-09-16

- Feedback uses one documented `--kind/--what/--got/--expected` interface, and
  its help names the Agent Template board with a complete example.
- Install and update print the feedback route and maintain bounded notes in
  Claude, Codex when present, and synced project instructions without changing
  content outside the markers.
- The maintainer host checks urgent feedback first every four hours. Every
  ticket gets a verdict, accepted work gets one auto-merge fix pull request,
  and merged changelog references get one bot-authenticated shipped reply
  before moving to Done.
- Filing hosts report their still-open AGTE tickets during the daily update.
- ACTION: run agent-template update on the vstack maintainer host and verify agent-template-feedback.timer is active

## 3.17.1 - 2026-09-16

- AGTE-6: `agent-template update` now converts an old-schema conf without an
  optional `HT_AGENT_SLUG` instead of exiting before its filename fallback.

## 3.17.0 - 2026-09-16

- One ticket now stays with its agent until its pull request is merged,
  contained in the base branch, and followed by a successful Production
  deployment. Repositories without deployment records use the logged
  merged-and-contained fallback.
- The oldest owed PR is a hard pickup gate. Red checks and reviewer concerns
  produce another fix run with exact feedback; pending checks and undeployed
  merges wait without claiming. Only an `emergency` ticket can interrupt.
- PR fixes have no retry limit, cooldown, model escalation, or manager hand-off.
  The pre-PR attempt window and post-live QA escalation remain separate.
- `<slug>.blocked` exposes the PR number, state, and start time to the agents
  feed. Behavioral evals cover red, pending, undeployed, deployed, fallback,
  attribution, oldest-first, emergency, and unlimited retry paths.
- ACTION: run `agent-template update` on every bot host, then verify each dev's
  agents-page state names its oldest open PR before the next board pickup.

## 3.16.0 - 2026-09-16

- AGTE-3 shipped in this release: the agent conf is now the only provider and
  harness policy. `MODEL_CLI` is normal work; optional `LADDER`, `RESEARCH_CLI`,
  `TRIAGE_HARD_CLI`, and `CHAT_CLI` choose every alternative command.
- Core no longer has provider allow-lists, model rewriting, or a built-in
  ladder. Ticket override files now contain one complete command.
- `create-agent.sh --provider pi` writes a GLM 5.3 Flash pi command, while
  `--model-cli` remains available for any full command.
- `agent-template update` backs up and rewrites only confs that used the 3.14
  policy. Custom commands such as pi or GLM stay byte-for-byte unchanged.
- ACTION: run agent-template update; confs get explicit ladder lines; other teams keep their MODEL_CLI

## 3.15.0 - 2026-09-16

- Agent Chat phase A is verified against the current template release. The host
  daemon handles each message once, returns a one-line reply on provider
  failure, and keeps agents independent.
- The shared chat service is installed and enabled with the template, refreshed
  by `agent-template update`, and each created agent prints its direct chat URL.
- ACTION: after the app polling endpoint marks polling agents as chat-enabled,
  run `agent-template update` on each bot host and verify a timestamped reply.

## 3.14.0 - 2026-09-16

- `core/model-policy.conf` now owns the provider ladder used by the runner and
  supervisor. Cursor is Grok-only. Hard work and the fourth attempt use OpenAI
  Codex through `hax` at high effort; research uses xhigh; Claude Opus is
  unlocked only after two failed Codex attempts, then the ticket returns to
  Valentin.
- Attempt state records failed providers, provider overrides accept
  `provider:model:effort`, and invalid provider/model pairs fall back to the
  agent conf default with one error line.
- Local evals prove the hard-ticket Codex route, the real `hax` argument shape
  with a stub, rejection of Cursor Claude ids, and the two-Codex-failure gate
  before `claude:opus:high`.
- ACTION: outside model override writers must source `core/model-policy.conf`
  and emit `codex:gpt-5.6-sol:high`, then `claude:opus:high` only after two
  recorded Codex failures.

## 3.13.0 - 2026-09-16

Agent Chat now works for poll-wired agents on hosts with no public inbound port.

- `agent-chat.service` is one always-on daemon per host. It scans template
  confs with `CHAT="on"`, heartbeats and polls each agent's authenticated chat
  inbox every three seconds, and runs each chat turn independently of ticket
  work and other agents.
- Chat turns load the last 50 conversation messages, the company skills index
  first, each agent's own index paths, its mission, and recent ticket-run log.
  The prompt forbids ticket comments, board writes, and worktrees.
- Replies run through the conf's `MODEL_CLI` at low Claude effort with a
  90-second timeout. Provider errors still receive a one-line error reply.
  Reply idempotency and `~/.local/state/agent-chat/handled.jsonl` prevent a
  restart from answering twice.
- Polling needs no inbound port. A localhost signed-webhook receiver is
  available through `AGENT_CHAT_WEBHOOK_PORT` and the existing Hypertask HMAC
  headers when a host has a public HTTPS route.
- New non-CLI board agents default to `CHAT="on"`; `agent-template update`
  adds it to existing poll or fleet template confs. Provisioning prints the
  agent's chat URL and the acceptance checklist requires a quoted reply.
- `install.sh` installs, enables, and restarts `agent-chat.service`. Test
  installs still skip the real systemd user directory unless `--unit-dir` is
  explicitly passed.
- The eval suite proves one message is handled once, provider failure gets the
  error reply, and two agents on one host answer independently.

ACTION: after the app polling endpoint is live, run `agent-template update` on each bot host, send a human chat message, and quote the timestamped reply from `~/.local/state/agent-chat/<slug>.log`.

## 3.12.1 - 2026-09-16

- The AGENTS.md the sync lays into a project repo, and the README the
  skeleton gives a new agent's own repo, both name where feedback about the
  agent setup goes: the Agent Template board, project 5500, via
  `agent-template feedback --kind bug|change|idea`, posted as the bot's own
  identity. The README already said something close; it now names `bug` as a
  kind and says whose name the post carries. AGENTS.md said nothing at all,
  which is the file most agents actually read.
- AGENTS.md also draws the line the board keeps blurring: the setup itself
  goes to project 5500, a fact about the product goes in a doc or on the
  ticket, and a rule about working a ticket goes in the skill it belongs to.
- Docs only, no behaviour. A repo whose AGENTS.md carries the template marker
  unmodified picks this up on the next sync. A repo that wrote or edited its
  own AGENTS.md keeps it, and has to add the section by hand.

## 3.12.0 - 2026-09-16

- The board CLI wrapper (`adapter_install_board_cli`) now enforces the
  comment rules itself instead of trusting the prompt: before forwarding a
  `comment add`, it fetches the ticket's own comments and refuses (logging
  why, once, in the agent's own tick log, not on the ticket) when this
  agent already has a comment with the same bold-lead first line, or
  already has 3 or more comments on that ticket. This is what stopped Dev
  2's runner posting the same "Nothing from you." comment three times on
  one ticket.
- Core fix for a ticket being re-picked every tick after its own agent
  already replied to it: the "own comment is not new work" guard used to
  apply only to rank 3 ("new work"), so a claimed-unfinished ticket (rank
  1, the common case) had no such guard at all. Now the board CLI wrapper
  records the id of every comment it actually posts, and `agent-board-poll`
  writes each one into `<slug>.seen` right after a successful run, for
  every rank, not only rank 3. The next tick's state key (built from
  whichever comment is now newest) already matches something in `SEEN`.
- Found while verifying the fix above: `push_skill_commits` ran
  unconditionally before the run's own seen-key write, and two of its own
  git calls (`symbolic-ref refs/remotes/origin/HEAD`, `diff --name-only
  '@{u}...HEAD'`) were unguarded standalone command substitutions. Under
  `set -euo pipefail`, either one failing (a skills-repo clone with no
  `origin/HEAD`, or no upstream tracking) killed the whole tick right
  there: no "run done" line, no seen-key write, so the ticket looked
  untouched next tick and reprocessed forever until its attempt budget ran
  out. This is very likely the real mechanism behind the "re-picked every
  tick" reports, on top of the rank-3 gating above. Fixed three ways: the
  two git calls are guarded now, the seen-key/"run done" bookkeeping moved
  to before `push_skill_commits` runs, and the call itself is guarded
  (`|| log ...`) so nothing in that optional step can ever fail the tick
  again.
- Two priority labels, same meaning on every board: `emergency` ranks
  above `urgent`, which ranks above everything else this agent could pick,
  including a ticket it still owes or one QA sent back. `rank_order()`
  already sorted ascending, so this is a rank override (-2 / -1) applied
  after the adapter's own rank, nothing else changes. No process is
  stopped for either label this release: a dev mid-run on something else
  finishes it, then picks up the emergency or urgent ticket on its next
  tick. When an `emergency` ticket is genuinely unclaimed and this agent
  cannot take it (not assigned, not configured to claim unassigned work),
  it logs "emergency waiting, all devs busy" so the supervisor's 5-minute
  alert has something to catch. Clean mid-run preemption (stopping a
  running ticket for an emergency) is not in this release.
- `agent-template feedback` gets a second shape: `--kind change|idea
  --title "<short title>" --body "<html>"` files a ticket directly (no
  got/expected to report, it is not a correction), and `agent-template
  feedback` with no arguments prints the board link and the three kinds.
  Fixed two bugs found while wiring this up, both of which explain why
  feedback calls with a configured token still fell through to the
  print-and-paste fallback: the board CLI call used `--description-file`,
  a flag the real `hypertask` CLI does not have (checked against its own
  `capabilities --json`), so every post was refused before this change;
  and `FILED_URL="$(... | grep -oE 'https://\S+' | head -1)"` is a
  standalone assignment around a pipeline that legitimately finds nothing
  sometimes, which under `set -euo pipefail` killed the script right after
  printing "filed: ...". Both fixed; `--json` added to the create calls so
  the response always parses. `FEEDBACK_BOARD_URL` now points at
  `https://app.hypertask.ai/detail/project-5500`, matching the URL format
  used everywhere else. The board and the command are named in
  `SKILL.md`, `MAINTAINER.md`, and the skeleton `README.md` new repos get.
  There is no "AGENTS.md the template lays into project repos" anywhere in
  this codebase to add a line to; that mechanism does not exist yet.
- No shell-execution eval cases this release either, for the same reason
  as 3.9.1: `evals/run-evals.sh` is a static text-predicate allowlist over
  `cases.jsonl`, on purpose, because the case file is appended to by an
  unattended weekly job. The comment cap/dedup, the seen-key fix, the
  `push_skill_commits` ordering fix, and the urgent/emergency ranking are
  all shell-state-machine behavior with no rendered-text surface to check
  against a predicate; each was verified by hand with a throwaway test
  harness (a fake `hypertask` binary, a fake skills-repo clone with no
  `origin/HEAD`) instead. One real case was added:
  `feedback-request-renders-board-and-identity`, an actual `--dry-run`
  render of a `--kind idea` call, checked with `is_full_https_url`.
- ACTION: none. This release changes no conf shape and needs no per-agent
  follow-up.

## 3.11.0 - 2026-09-15

Skills live where they are used, and the template keeps every project's layout
the same.

- **The company pack installs as a Claude Code plugin.** `install.sh` runs
  `claude plugin marketplace add hypertask-ai/company-skills` and
  `claude plugin install company-skills@company-skills`, falling back to
  cloning the pack to `~/projects/company-skills` on a host where the plugin
  cannot be installed. Which one this host resolved, and at what version, is
  written to `~/.config/hypertask-agents/company-pack.version`, and
  `agent-template update` prints it.
- **The runner finds its skills instead of being told them.** It reads, in
  order: the company pack, `.claude/skills/INDEX.md` inside the checkout the
  run works in, and then anything extra the conf names. `SKILLS_INDEX` is now
  optional and means "extra packs on top of those two"; a conf that still
  lists the two found packs keeps working and simply names them twice.
  `COMPANY_SKILLS_DIR` is exported, so a skill can name the pack root without
  hard-coding a path that differs between a plugin host and a clone host.
- **Both versions are logged at the start of every run**, on one line:
  `skills: company company-skills <v> at <dir>; repo <v> at <dir>`. A bot
  behaving oddly is usually a bot reading an old pack, and this is the line
  that shows it.
- **`create-agent.sh --sync-project <path-or-repo>`** lays the standard layout
  into any project repo that is missing it: `.claude/skills/` (`INDEX.md`
  seeded from the skills already there, `RULE-MAP.md`, `VERSION`,
  `evals/run-evals.sh`), `AGENTS.md` with the shared conventions, `board.yml`,
  the `pr-title` check, the `skills-evals` workflow, and a copy of
  `.claude/hooks/board-write-guard.sh`. `--repo` runs it automatically. Given
  `org/name` rather than a path it clones, syncs, and opens a pull request.
- **It is idempotent and it never overwrites a project's edit.** Every file it
  writes carries a header naming the template version and the sha256 of its own
  body. A matching hash means template-owned and untouched, so it is rewritten.
  A hash that no longer matches means the project edited it, so it is left
  alone and named in the diff summary. No header at all means the project wrote
  the file, so it is left alone too. `.claude/skills/VERSION` carries no header
  and is written once, because the runner reads it with `head -n1` and the
  version of a repo's own pack is the repo's to bump.
- **`agent-template update` runs the sync on every checkout a conf names**, so
  a repo that gained an agent, or a repo whose layout drifted, comes back into
  line without anyone remembering. It writes files and reports what changed; it
  does not commit or push, because a daily timer pushing to every repo it knows
  about, unattended, is worse than leaving a clean diff behind.
- `evals/sync-project.test.sh` adds seven behavioural checks the case file
  cannot express: the first sync writes the layout, the index is seeded from
  the skills already present, a script keeps its shebang on line 1, the
  laid-down eval suite passes on the laid-down pack, the second sync rewrites
  nothing, an edited file survives, and an unmarked file survives.
- `MAINTAINER.md` and the create-agent skill both gain a "Where skills live"
  section: project skills in `.claude/skills/` of the repo they serve, shared
  skills as the company plugin, personal skills in `~/.claude/skills`.

ACTION: run `agent-template update` on every bot host. It installs the company
pack as a plugin and syncs the layout into each repo a conf names.

ACTION: `SKILLS_INDEX` is now optional for dev-1, dev-2 and qa-1. Product
skills are read from the checkout instead. Leave the key in place if you like;
it is harmless, and it only names the same packs twice.