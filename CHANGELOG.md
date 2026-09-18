## 3.40.0 - 2026-09-18

- AGTE-20 makes reply-only owner responses start with `Answer:` instead of `Decision:`.
- Answers use the existing comment cap and plain-language check, and may end
  with a `Decision needed:` question only when the owner must choose.
- Focused offline coverage checks the managed reply rule, posted marker, and
  optional decision-question shape.
- ACTION: run `agent-template update --keep-timers` so current agents receive
  the fifth comment kind without changing timer state.

## 3.39.0 - 2026-09-18

- AGTE-46, corrected by AGTE-47, routes direct ticket replies through fixed
  high-effort Codex GPT-5.6 Sol with a five-minute limit and no resumable model
  session.
- AGTE-44 context is folded in: replies retain the full ticket thread, read a
  deduplicated shared record of Valentin's comments, and receive the exact
  terminal communication rules.
- The reply sandbox exposes repository code and runner logs read-only, permits
  web and image research with writes only under `/tmp`, and never receives the
  board token; the runner validates and posts the answer afterward.
- The outbound comment gate now holds invalid drafts unchanged instead of
  rewriting words, links, markers, or em dashes.
- HTPR-3533 coverage verifies that its screenshot produces the Google
  authorized redirect-address fix.
- ACTION: run `agent-template update --keep-timers` so current agents receive
  contextual sandboxed replies without changing timer state.

## 3.38.0 - 2026-09-18

- AGTE-53 carries Hypertask priority and dueDate into runner candidates.
- New queued work with Priority Urgent or a due date within 48 hours is picked
  before ordinary queued work, with due date and then board order breaking ties.
- Offline coverage proves the urgent ticket starts first and a concurrent tick
  cannot replace or interrupt its active run.
- ACTION: run `agent-template update --keep-timers` so current runners receive
  queue ordering without changing timer state.

## 3.37.0 - 2026-09-18

- AGTE-39 preserves the original quiet-mode marker through a plain-language
  rewrite and refuses a replacement when the marker is missing.
- `Handoff:` and `Done:` comments now use the plain-language gate, explain what
  shipped, and cannot contain only a link.
- Another bot's status marker no longer wakes an agent unless the comment
  directly mentions that agent or asks it a question.
- ACTION: run `agent-template update --keep-timers` so current agents receive
  the quiet-mode routing fixes without changing timer state.

## 3.36.0 - 2026-09-18

- AGTE-37 adds atomic schema-version-1 runner progress snapshots for completed
  runs, pull requests, waits, eligible work, repeated failures, and build or
  instruction results.
- Product Bot detects four mechanical stall conditions, keeps one `Decision:`
  comment per stall updated, sends one-line Telegram alerts through the existing
  transport, and publishes stall fields for analytics.
- A stall lasting six hours switches only the affected runner to manual mode and
  notifies the owner once, with fixture coverage including a 30-hour PR wait.
- ACTION: run `agent-template update --keep-timers` so every runner publishes
  progress without changing timer state.

## 3.35.0 - 2026-09-18

- AGTE-34 adds an opt-in, keyless structural Graft trial with the CLI, run-scoped
  MCP configuration, and one ask-before-grep prompt line.
- Run records and runtime heartbeats explicitly report Graft as `on` or `off`,
  while new and migrated agent confs default to `off`.
- Graft subprocesses disable telemetry and remove provider keys so the trial
  cannot use LLM enrichment or paid services.
- ACTION: install Graft, structurally index the hypertasks checkout, set
  `GRAFT="on"` for dev-1 and `GRAFT="off"` for dev-2, then run
  `agent-template update --keep-timers`.

## 3.34.0 - 2026-09-18

- AGTE-32 applies a final outbound check to agent chat and ticket comments that
  fetches authoritative titles and turns ticket ids into full clickable links.
- Manager command replies become one plain outcome sentence instead of exposing
  command output, and the final check removes em dashes from replies.
- Offline coverage separately verifies ticket-link rewriting, command reply
  shaping, and em-dash removal.
- ACTION: run `agent-template update --keep-timers` so current agents receive
  the outbound reply checks without changing timer state.

## 3.33.0 - 2026-09-17

- AGTE-25 keeps the installed core path private to the update re-exec so staged
  evals resolve files from the incoming release.
- Offline coverage fails when the installed core path leaks into staged evals.
- ACTION: run `agent-template update --keep-timers` to install the update bootstrap fix.

## 3.32.0 - 2026-09-17

- AGTE-25 turns queued advisor instructions into visible toolkit board tickets
  assigned to Product Bot through its own identity.
- Failed board writes retain the transport file, while install migration records
  ticket ids and avoids duplicate tickets on repeated runs.
- Product Bot handles assigned board 5500 tickets through its normal build and
  completion-comment path, including tickets created by hand.
- ACTION: set `BOARD_ID="15,5156,5500"` in `~/.config/hypertask-agents/product-bot.conf`, then run `agent-template update --keep-timers`.

## 3.31.0 - 2026-09-17

- AGTE-8 adds the `codex-sol` manager model preset for the Codex subscription.
- Manager commands write the exact high-effort GPT-5.6 Sol command into `MODEL_CLI`.
- Offline coverage verifies the preset command and configuration update.
- ACTION: run `agent-template update --keep-timers` to install the new preset.

## 3.30.0 - 2026-09-17

- AGTE-23 records successful run completion as mechanical action activity and
  never as a human response.
- Human response activities and ticket comments now share the same marker and
  plain-language rewrite gate.
- Updates accept an installed hand patch when the incoming release contains the
  exact same file, so the upstream completion fix installs without a conflict.
- Offline coverage verifies completion activity, response rewriting, quiet
  prefixes, and clean installation over an already-upstream hand patch.
- ACTION: run `agent-template update --keep-timers` so current agents receive
  the activity classification and response gate without changing timer state.

## 3.29.0 - 2026-09-17

- AGTE-17 moves each advisor instruction into its own transient systemd unit, so
  the launch tick returns without waiting for the model or a build.
- A later tick reads the instruction result, reports completion, removes its
  state, and still allows reply-only owner questions while other work runs.
- AGTE-19 resolves stored ticket URLs through the Hypertask adapter before
  completion comments, preserves prefixed quiet replies byte for byte, and
  stops after two failed comment attempts with the command, exit, and stderr logged.
- Offline coverage verifies URL conversion, exact quiet output, bounded errors,
  detached execution, later completion reporting, and concurrent owner replies.
- ACTION: run `agent-template update --keep-timers` so current agents receive
  the completion and scheduling fixes without changing timer state.

## 3.28.0 - 2026-09-17

- Owner questions now choose one reply-only agent by machine mention, assignee,
  latest prior `Done:` or `Decision:` author, then configured fallback.
- One normalized comment read suppresses duplicate answers when another agent
  already replied, while losing agents remain eligible for ordinary ticket work.
- New offline coverage verifies every answerer rank, the answered-question race,
  owned-ticket replies, and adapter-default conf resolution for manager commands.
- `ANSWERER_FALLBACK` defaults empty in the shared schema and has no bot-specific
  runner default.
- ACTION: set `ANSWERER_FALLBACK="product-bot"` in this host's agent confs and run `agent-template update --keep-timers`.

## 3.27.0 - 2026-09-17

- AGTE-14 adds a per-agent setup-maintainer gate with allowlisted background
  builds, durable build status, and green-check-only squash merges.
- The runner closes finished builds with one agent-authenticated comment and
  consumes queued advisor instructions as normal runs with `source=advisor`.
- Maintainer runner and chat prompts require four-part build specs, forbid
  direct model-harness launches, and report completed work from the build log.
- Offline coverage verifies allowlist refusal, guarded job recording, status,
  red-check merge refusal, instruction pickup, completion, and non-maintainer refusal.
- ACTION: set `MAINTAINER="on"` in `product-bot.conf`, run `agent-template update --keep-timers`, and confirm the dev-1, dev-2, qa-1, and product-bot timer states are unchanged.

## 3.26.0 - 2026-09-17

- Human questions and direct mentions now become reply-only runs in every
  ticket state, including Done and archived tickets.
- Reply-only runs answer without code changes, claims, pull requests, or column
  moves, and rank ahead of normal ticket work and pull-request debt.
- Owned-comment discovery now advances a per-board comment cursor through
  paginated reads, with a 500-comment tick ceiling and one warning per tick.
- ACTION: run `agent-template update --keep-timers` so current agents answer
  old-ticket questions promptly without changing timer state.

## 3.25.0 - 2026-09-17

- Question and Decision comments now receive the pospeak, unslop, and
  i-have-adhd rules in every runner prompt and pass a plain-language check in
  the board wrapper before posting.
- A failed draft gets one 60-second rewrite through the configured cheap model;
  a second failure keeps the draft and reasons in the run log and emits held
  activity instead of posting the raw comment.
- Focused coverage verifies rewrite, unchanged pass-through, em dash refusal,
  and unchanged Handoff and Done handling.
- ACTION: run `agent-template update --keep-timers` so current agents receive
  the plain-language comment guard without changing timer state.

## 3.24.0 - 2026-09-17

- AGTE-11 adds manager-only mode, model preset, quiet, and identity-bound
  feedback commands with one-line results naming changed confs.
- Config writes make timestamped backups and refuse free-form model commands,
  credentials, foreign units, paths outside the conf directory, and legacy confs.
- Runner and chat prompts list exact command syntax and plain-language examples
  only for agents with `MANAGER="on"`.
- ACTION: run `agent-template update --keep-timers` on the manager host, then
  confirm only dev-1, dev-2, qa-1, and product-bot timers remain enabled.

## 3.23.0 - 2026-09-17

- Runtime ticket work now opens an app run, streams lifecycle progress as run
  activities, closes with a final status, and falls back to local-only logging
  when the runs route returns HTTP 404.
- The board wrapper permits only Question, Decision, Handoff, and Done ticket
  comments; other text becomes activity, while quiet mode strips owner mentions.
- New and migrated current-schema agents default to `QUIET="on"`; focused evals
  cover comment routing, mention stripping, marker acceptance, and 404 fallback.
- ACTION: run `agent-template update --keep-timers` so current agents receive quiet mode without changing timer state.

## 3.22.0 - 2026-09-17

- Agents with `MANAGER="on"` can start, stop, or inspect current runner units
  and delegate a ticket to a current agent identity through their own board CLI.
- Manager actions are identity-gated, owner-held tickets and userId 6 are
  protected, every attempt is logged, and runner plus chat prompts expose the
  commands only to managers.
- Feedback accepts `--board-cli` and `--as`, and `update --keep-timers` deploys
  without restarting a timer whose state must be preserved.
- ACTION: set `MANAGER="on"` in `product-bot.conf` to enable manager commands.

## 3.21.6 - 2026-09-17

- Setup guidance, generated briefs, and every runner prompt now require reminder
  and status comments to be edited in place, with one reminder and three total
  comments per ticket per day unless a human replies.
- The board wrapper now reads file-backed comment bodies, updates a matching
  recent comment instead of adding it, and logs a three-comment UTC daily cap.
- Focused coverage verifies the prompt and setup contract, file-backed
  near-duplicate updates, and the daily cap.
- ACTION: run `agent-template update` on bot hosts so scheduled reminders use
  refreshed wrappers and stop creating duplicate ticket comments.

## 3.21.5 - 2026-09-16

- Comment candidates now reject the current agent's identity in both owned-reply
  and mention paths, including QA-returned tickets.
- A per-ticket run ledger enforces a 30-minute cooldown unless a new human or
  different-agent comment arrived after the prior run began.
- The prompt and refreshed board wrapper limit board-owner mentions to one per
  ticket per 24 hours, with refused repeats recorded only in the runner log.
- Focused coverage verifies own-comment filtering, cooldown bypass rules, and
  prompt plus mechanical owner-mention enforcement.
- ACTION: run `agent-template update` on bot hosts so pollers refresh existing
  board wrappers and stop self-triggered comment loops.

## 3.21.4 - 2026-09-16

- The one-ticket-until-live gate now owns a PR by agent branch prefix, current
  ticket assignment without another agent prefix, or the runner's persisted
  record that the agent opened it; shared GitHub authorship owns nothing.
- Every owned non-live PR is ranked oldest first, logged together, and stored in
  the blocked state; multiple debts block all new claims, including emergencies.
- Focused coverage verifies prefix, assignment, persisted-state, orphan,
  oldest-first, complete blocked-state, and runner persistence behavior.
- ACTION: run `agent-template update` on bot hosts so legacy branches are tied
  to their assigned agents and every owned non-live PR blocks new pickup.

## 3.21.3 - 2026-09-16

- Poll explanations now report why every listed ticket is ineligible, including
  tickets assigned to another owner and unassigned tickets an agent cannot claim.
- Pull request ownership discovery skips legacy agent confs without the
  `BOARD_ADAPTER` schema marker before sourcing them, with one diagnostic line.
- Focused coverage verifies complete ineligibility explanations and safe handling
  of a malformed legacy conf.
- ACTION: run `agent-template update` on bot hosts so polling ignores legacy confs
  and explains every board candidate.

## 3.21.2 - 2026-09-16

- The one-ticket-until-live gate now assigns PR debt only by the agent's
  configured branch prefix or optional GitHub login. Ticket claims,
  assignments, and comments no longer transfer PR ownership.
- Open PRs with no matching living agent conf block nobody and produce one
  orphan warning per UTC day for supervisor follow-up.
- Focused coverage verifies QA claim isolation, authored dev debt, configured
  GitHub and custom-prefix ownership, and once-daily orphan reporting.
- ACTION: run `agent-template update` on bot hosts so QA and retired-agent PRs
  use the corrected gate scope.

## 3.21.1 - 2026-09-16

- AGTE-2 follow-up: Hypertask PR eligibility matching now reads the pull request
  payload from disk once per tick instead of copying it into the environment
  for every task row, avoiding host argument-size limits on large repositories.
- A 400 KB pull request fixture verifies the expected matches across 50 task rows.
- ACTION: run `agent-template update` on bot hosts so QA agents resume verifying eligible work.

## 3.21.0 - 2026-09-16

- Agent ticket, triage, chat, and advisor provider processes now put a
  per-agent board-command shim first on `PATH`, so bare `hypertask`, `ht`, and
  `htbot` calls use the agent wrapper and cannot inherit the owner's login.
- The identity boundary checks the agent token before launch and exits non-zero
  with `no agent token for <slug>` before any board write when it is missing.
- Offline coverage verifies shim resolution, agent-token injection over an
  owner home config, and the fail-closed missing-token path.
- ACTION: run `agent-template update` on every bot host, then verify the next run starts normally; a host with a missing agent token will now stop and name the affected slug.

## 3.20.0 - 2026-09-16

- `agent-chat.service` now publishes each configured agent's runtime snapshot
  every 30 seconds without coupling failures between agents.
- Operations receives the runner version and model, board sections, recent
  completions, an active ticket from `<slug>.lock`, or PR debt from
  `<slug>.blocked`.
- `agent-chat --status` reports each agent's last publish result without
  exposing credentials. Heartbeat queue evals cover running, waiting, and a
  failed POST that does not stop the next agent.
- App gaps remain explicit: runtime heartbeat does not update the durable top
  status timestamp, poll runs have no app-created run ID for activity cards,
  and the ticket-independent activity route is feature-flag gated.
- ACTION: run `agent-template update` on each bot host, then use `agent-chat --status` and the per-agent daemon log to verify heartbeat delivery.

## 3.18.6
- agent-template-feedback: when auto-merge is refused (no branch protection) wait for green checks and merge, else leave the PR open and continue; the job no longer exits 1 after one ticket. ACTION: none.

## 3.18.5
- AGTE-4: a `LADDER` rung whose command is not on the host's PATH no longer runs (and fails the ticket with exit=127) -- `core_ladder_command` checks with `command -v` first and falls back to the agent's own `MODEL_CLI`, with one `WARNING:` line on stderr. The `MODEL_PROVIDER=codex` conf key the ticket also asked for is not added: post-AGTE-3 (3.16.0) nothing routes on a provider identity, so that key would be unread. ACTION: none.

## 3.18.4
- agent-template-feedback: read section names from the CLI field section_title (name is absent), so the board lookup no longer fails. ACTION: none.

## 3.18.2
- agent-template-feedback: accept a "Fixed" section as the shipped column (board 5500 uses Inbox, Accepted, Fixed, Rejected). ACTION: none.

# agent-template changelog

One entry per version. A line marked `ACTION:` is something the template
cannot do for itself; `agent-template update` prints it and logs it once per
version to `~/.local/state/agent-template/actions.log` for a maintainer
session to read and act on.

## 3.19.0 - 2026-09-16

- Hosts now follow an explicit release channel. New hosts default to the `stable`
  tag; this maintainer host follows `latest`. Promotion requires 24 hours on the
  installed commit and a fresh green eval run.
- Updates evaluate a staged release before swapping. Red evals exit successfully
  without changing the installed version, and `--force` is explicit.
- An install manifest detects host edits, archives them under `local-patches`, and
  refuses replacement unless `--keep-local-patches` is passed. Timers also honor
  `AUTO_UPDATE=off`.
- Failed ticket runs write the host log and agents-feed status only. They post no
  failure comment and leave a triggering mention eligible for the next tick.
- `agent-kick.service` can receive signed mention webhooks and start the matching
  poll unit immediately. Hosts without `WEBHOOK_URL` keep the minute poll fallback.
- Fifty-five offline behavioral checks cover the channel, promotion, gate,
  patch, failure, and kick paths as well as the existing runner contracts.
- ACTION: Other hosts are now on `stable`; run `agent-template update` once to install the channel config, then leave `CHANNEL=stable` unless this is the maintainer host.

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