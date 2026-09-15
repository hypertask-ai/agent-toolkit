# agent-template changelog

One entry per version. A line marked `ACTION:` is something the template
cannot do for itself; `agent-template update` prints it and logs it once per
version to `~/.local/state/agent-template/actions.log` for a maintainer
session to read and act on.

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