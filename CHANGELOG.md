# agent-template changelog

One entry per version. A line marked `ACTION:` is something the template
cannot do for itself; `agent-template update` prints it and logs it once per
version to `~/.local/state/agent-template/actions.log` for a maintainer
session to read and act on.

## 3.9.0 - 2026-09-15

- Tickets are scored before pickup. A ticket carrying neither `easy` nor `hard`
  is put through `scripts/triage.sh`, which decides on rules first: realtime,
  auth, money, schema and "it only happens sometimes" are hard; a ticket
  somebody already failed at (a QA FAIL comment, a "Run failed" comment, a pull
  request that closed unmerged) is hard; a ticket that names the file,
  component or screen is easy; a ticket under 200 characters with no acceptance
  criteria and nothing named is vague, so hard. The naming rule is checked
  before the vague rule on purpose: a one-line CSS ticket is short AND easy.
  Only when no rule fires does one cheap model call (`claude -p --model haiku`,
  strict JSON) decide, and `--rules-only` skips even that.
- A score becomes a label on the ticket through the new `adapter_add_label`,
  which reads the ticket's current labels and writes them back with the new
  one. `task update --labels` SETS the list, so anything less wipes `Bug` and
  the rest; label names are resolved to UUIDs first, because name matching on
  this board is fuzzy and `hard` would otherwise land on `intensity:hard`. A
  missing label is created on the project. When the board refuses, the score is
  held in `~/.local/state/agent-board-poll/triage/<REF>` instead. Every score,
  label or not, is logged with its reason to
  `~/.local/state/agent-board-poll/triage.jsonl`.
- A `hard` ticket routes to a stronger model and has to plan first. The runner
  writes the per-ticket model override (`cursor-agent` agents get
  `claude-opus-5-thinking-high`, anything else gets `opus`) and prepends a
  block telling the agent its first comment must be a numbered three-point plan
  (root cause, files, how it will verify) before any code. That plan counts
  toward the three-comment cap, it is not an extra. `easy` changes nothing.
- Scoring is for agents that BUILD. `AGENT_KIND=qa` is not scored: QA verifies
  somebody else's work, and how hard the fix was is not its problem.
- `agent-board-poll --once --dry-run <slug>` prints the score, the reason and
  which model the ticket would run on, and writes nothing: no label, no
  override file, and no model call for the tie-break.
- New `agent-advisor` on PATH: `agent-advisor "<question>"` answers one precise
  question with `claude -p --model opus`, given the ticket, its last ten
  comments and the run's current `git diff`. Two calls per run; the third
  prints "advisor cap reached, write what you tried on the ticket" and exits 1.
  It reads the board and never writes to it. The dev prompt now tells an agent
  to use it when two approaches have already failed.
- Evals: `triage_scores "easy"|"hard"` is a new predicate that runs the real
  scorer over a ticket JSON case, rules only, so the suite needs no model and
  no network. Six triage cases added, including the four shapes that matter.
- ACTION: nothing to do on a host that already runs 3.8.0. On a host where the
  `hard` label does not exist on the board, the first hard ticket creates it;
  if the agent's token cannot create labels, scores land in
  `~/.local/state/agent-board-poll/triage/` and the runner says so in its log.
  Give that token label-create rights, or create `hard` by hand once.

## 3.8.0 - 2026-09-15

- `SKILLS_INDEX` is a list, not one path: the shared company pack first, this
  bot's own pack second. The runner validates each, concatenates them in order
  for the prompt, and pushes a skill correction back to whichever pack it
  landed in. A conf with one path is a list of one and needs no change.
- `install.sh` clones or fast-forwards `hypertask-ai/company-skills` to
  `~/projects/company-skills` on every host, so the shared pack is present
  wherever the template is. `SKIP_COMPANY_SKILLS=yes` opts out; a host that
  cannot reach GitHub gets a warning and keeps the copy it has.
- `agent-template update` prints which commit the company pack is on, so the
  daily run says out loud whether every bot here reads the current rules.
- `create-agent.sh --skills-index` is repeatable and prepends the company pack
  by default. The domain-words warning now checks the bot pack, the last entry:
  a company pack is generic and would never match.
- The hypertask adapter resolves `ticket-lifecycle`'s scripts under the first
  pack, and its route script resolves a skill name across both packs.
- MAINTAINER.md and SKILL.md document company pack + bot pack, and where a
  rule goes when it would be true for another board.
- ACTION: a conf written before 3.8.0 still names one index. Add the company
  pack in front of it (`SKILLS_INDEX="<company>/INDEX.md,<bot>/INDEX.md"`) for
  every bot that should read the shared rules.

## 3.7.0 - 2026-09-15

- Added `agent-template update`: pulls this repo, reinstalls, and brings any
  bot conf still on the old HT_* fleet schema forward to the current one, so
  nobody has to explain the same fix to every bot host by hand.
- Fixed `agent-board-poll@.service`: it had no `PATH` beyond systemd's bare
  default, so a tick could never find the `hypertask` CLI under
  `~/.local/bin` or `~/.npm-global/bin` and every run failed with "the
  hypertask CLI is not on PATH". The shared unit now sets `PATH` and `HOME`
  itself; hand-added per-slug `path.conf` drop-ins are redundant and
  `agent-template update` removes them.
- `install.sh` now refreshes the shared `agent-board-poll@.service`/`.timer`
  pair and installs `agent-template-update.timer` (daily, 06:30 local) on
  every run, not only when a new agent is provisioned.
- ACTION: rerun /create-agent in poll mode for any bot still on the old worker
