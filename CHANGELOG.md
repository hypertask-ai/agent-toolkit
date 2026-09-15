# agent-template changelog

One entry per version. A line marked `ACTION:` is something the template
cannot do for itself; `agent-template update` prints it and logs it once per
version to `~/.local/state/agent-template/actions.log` for a maintainer
session to read and act on.

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

## 3.10.0 - 2026-09-15

- Every agent needs a repo now: no repo-less mode. `PR_REPO` moves from
  optional to required. `agent-board-poll` refuses to tick without it,
  printing one line: `PR_REPO is not set: every agent needs a repo, run
  create-agent --repo`. That line carries `ERROR:` (the `die` convention
  every required-key check already uses), which is what the supervisor's
  `runner-health` check greps for.
- `adapter_pick_rank` dropped the "no PR_REPO configured for this agent"
  branch added in 3.9.1: with `PR_REPO` required, that state can no longer
  happen by the time this function runs, so it collapsed back to only
  telling apart "gh answered" from "gh is missing or failed".
- `create-agent.sh` gets `--pr-repo <org/name>`: creates that repo private
  from the new `repo-skeleton/` (README, `board.yml`, `scripts/`, `reports/`,
  `CHANGELOG.md`, a pr-title check) if it does not exist yet, and writes
  `PR_REPO` into the conf either way. `--resume --pr-repo <org/name>` adds a
  repo to an existing identity without touching anything else it has:
  `core_write_missing_keys` only adds keys that are not already there, no
  identity is recreated, and no token is rotated.
- Enabling auto-merge on that new repo is best-effort, not fatal. GitHub
  returns success on `gh repo edit --enable-auto-merge` even when it refuses
  the setting (true for a private repo on a plan that does not carry
  auto-merge), so `create-agent.sh` reads `allow_auto_merge` back from the
  API instead of trusting that exit code, and logs "auto-merge unavailable
  on private repo, supervisor merges green PRs" rather than failing the
  provisioning run. The dev run prompt in the hypertask adapter carries the
  same instruction: when `gh pr merge --auto` is refused, leave the PR open
  and move the ticket to the review lane anyway; the supervisor's
  pr-hygiene check merges a green PR that could not get auto-merge.
- `agent-template feedback`: a label this board's project does not carry
  (board 2462 had none of the ones this always sent) used to fail the whole
  post and fall through to the print-and-paste fallback, which looked like
  feedback never posts even though the board CLI and token were fine. It now
  retries once with no label on a `LabelNotFound` error and says so in one
  line, instead of losing the post over a label.
- MAINTAINER.md and SKILL.md: "the repo is the bot's memory, every output,
  report or script is a PR to it; skills stay in the packs", plus the
  auto-merge caveat above.
- No new eval cases: none of these changes reduce to the harness's text
  predicates (`starts_with_block_tag`, `has_section`, `is_full_https_url`).
  The `PR_REPO`-required and label-retry changes were verified by hand
  (a throwaway private repo created end to end through `--pr-repo`, and a
  fake board CLI that fails the first call with `LabelNotFound`).
- ACTION: set `PR_REPO` for `product-bot`, `growth-bot`, `support-bot`,
  `finance-bot` (`create-agent.sh --resume --pr-repo <org/name>`). Until then
  those four will not tick after this version installs: `agent-board-poll`
  now refuses outright instead of running with a misleading "gh is
  unavailable" message.

## 3.9.1 - 2026-09-15

- Fixed the misleading "gh is unavailable" message: a claimed, unfinished
  ticket with no `PR_REPO` set was reported as "pull request state unknown,
  gh is unavailable" even when `gh` was fine. `adapter_pick_rank` now tells
  apart "no `PR_REPO` configured for this agent", "gh answered" and "gh is
  missing or failed", and a real `gh` failure prints a loud `ERROR:` line to
  the per-agent tick log (`2>>"$LOG"` on the `adapter_pick_rank` call in
  `agent-board-poll`) instead of being swallowed into the same silent `[]` as
  "no PRs found".
- Fixed `rank: unbound variable` at `agent-board-poll:436`. Root cause was
  not the ranking code: `install.sh` rewrote `scripts/`, `adapters/` and
  `evals/` in place with `rm -rf` + `cp -a` while a timer tick had one of
  those files open, so a concurrent reader could see a half-written script.
  `install.sh` now stages each directory next to the destination and swaps it
  in with `mv -T`, so a reader always sees the whole old tree or the whole
  new one, never a partial write.
- Fixed `OWNED_COMMENT_READ_CAP` starving one board while another has budget
  to spare: the cap was one counter shared across every board in `BOARD_ID`,
  so once board 15 used up 20 reads, board 5156 got 0 for the rest of the
  tick, every tick. Each board now gets its own budget, the cap default rose
  20 -> 40, and within a board the newest-updated tickets are read first so a
  fresh comment is not stuck behind stale ones when the cap is hit.
- Fixed `install.sh` overwriting the REAL `agent-board-poll@.service` when
  run with `--dest`/`--bin` pointed at a test prefix: `SYSTEMD_USER_DIR`
  used to default to `$HOME/.config/systemd/user` no matter what `--dest`/
  `--bin` said, so a test install's `ExecStart` landed on the live unit
  (this happened for real on 2026-09-15, every agent ticked from `/tmp` for
  six minutes). The live unit dir is now only touched on a real install
  (default `--dest` and `--bin`) or an explicit new `--unit-dir`; otherwise
  install.sh prints `units: skipped` and leaves the live units alone.
- No eval cases added for the three fixes above: `evals/run-evals.sh`'s
  predicates are a deliberate allowlist (`starts_with_block_tag`,
  `has_section`, `is_full_https_url`) over static text, not shell execution,
  by design (cases are auto-appended by an unattended weekly job). None of
  these fixes reduce to one of those predicates, so this release adds no
  eval case rather than forcing a fit. The `install.sh` unit-dir fix was
  instead verified by hand: an install to a temp `--dest`/`--bin` prefix,
  hashing the live `agent-board-poll@.service` before and after and
  confirming it is unchanged.

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
