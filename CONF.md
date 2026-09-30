# Agent conf schema

Each agent has a 0600 `<config dir>/<slug>.conf`. It is declarative `KEY=value` shell syntax with uppercase keys only.

## Board 15 escalation

Every worker, including Product Bot's reply worker, never mentions the owner
or addresses him by name, regardless of quiet mode, raw writes or reply type.
Ask the supervisor in a plain comment and move the ticket to `Supervisor Review`.
Only Product Bot's `ht-supervisor` caller may mention the owner. It first tries
to fix, answer, route or re-queue the blocker and comments whether it fixed it.
Only an unresolved product decision (money, access, security, irreversible
changes or product direction) gets one owner-mentioned `Question:` with a plain
yes/no question and a move to `Valentin Review`. Other boards retain their rules.

## Board 15 model settings

Ordinary Hypertask board-15 agents use only `hax --provider=codex --model=gpt-6.1-sol --effort=high --no-session -p` from `~/.local/bin`.
Creation, installation, updates, and `agent-template model <slug> codex-sol` replace the entire model policy, including existing ladders and obsolete provider commands.
Research keeps `--raw` but uses high effort too.
Quota exhaustion waits for Codex rather than trying an old model.
Existing owner-approved Cursor extra workers using `cursor-grok-4.7-high` keep their settings.
Legacy configurations without `BOARD_ADAPTER` are not migrated.
The generic examples below apply to other boards.

The independent second-opinion checks still refuse the worker's own provider family.
Board-15 second opinions therefore cannot run under the Sol-only policy and do not silently fall back to Claude.

### Installation and live verification

1. After this change merges and the toolkit release is available, run `agent-template update --keep-timers` through the normal operator update path.
2. Check QA 1's effective `~/.config/hypertask-agents/Hypertask Product/qa-1.conf` and any separately managed staged copy for Sol 6.1 high commands and `PROVIDER_ORDER="codex"`.
3. Regenerate staged settings through the updated toolkit, or pass their configuration directory to the updated `scripts/migrate-provider-policy.py --version <installed-version>` through the normal staging process.
4. Verify a completed end-to-end QA 1 run records Codex, `gpt-6.1-sol`, high effort, and its final outcome before claiming live completion.

Backups retain the previous settings for recovery and are not runnable configuration choices.
An active service or passing configuration tests do not prove the installation or the completed live run.
The app's already shipped code reviewer is unchanged.

## The conf decides the provider

The conf owns each provider's full command and its subscription fallback order. The runner only switches commands when the current provider reports exhausted quota. Other failures keep the normal attempt and ladder behavior.

| Key | Meaning |
|---|---|
| `MODEL_CLI` | Required command for normal ticket work and rung 1 when no provider order is configured. |
| `PROVIDER_ORDER` | Optional comma-separated subscription order, such as `codex,cursor`. The first installed provider serves the run. Quota exhaustion retries the same run on the next installed provider immediately. |
| `PROVIDER_<NAME>_CLI` | Full command for the matching name in `PROVIDER_ORDER`, for example `PROVIDER_CODEX_CLI` and `PROVIDER_CURSOR_CLI`. Missing commands and commands whose executable is not installed are skipped before routing. |
| `LADDER` | Optional `\|`-separated full commands. Once three non-quota attempts have failed, the next attempt selects command one; after four failures, the next selects command two, and so on. Empty or absent means no escalation. |
| `RESEARCH_CLI` | Optional command for `agent-advisor` and supervisor research. Empty or absent means no research step. |
| `TRIAGE_HARD_CLI` | Optional command for a ticket labelled `hard`. Empty or absent means `MODEL_CLI`. |
| `OWNER_COMMENT_CLASSIFIER_CLI` | Optional command that classifies the board owner's newest comment before pickup. It defaults to `TRIAGE_MODEL_CLI` and must return exactly `hold`, `go`, `question`, or `feedback`. |
| `CHAT_CLI` | Optional command for Agent Chat. Empty or absent means `MODEL_CLI`. |

Each value is the complete non-interactive command, including its model, tool, permission, and print flags. The runner splits it into arguments without shell evaluation and appends the prompt as the final argument, which is the existing `MODEL_CLI` contract. Put `-p`, `--print`, or the harness's equivalent before that final prompt. Shell pipelines and a literal `|` cannot appear inside a command because `|` separates ladder entries.

One run record stays open during quota fallback. Run telemetry records the provider that served the run. If every installed provider reports exhausted quota, the runner returns the ticket to its original column, posts the earliest reset reported by those providers, and retries after that time. If none reports a time, the ticket says the reset time is unavailable and waits for a new ticket update.

Reply-only runs ignore these provider keys. They always use Codex GPT-5.6 Sol at high effort in the five-minute read-only reply sandbox, then let the runner validate and post the returned HTML.

A pi-only agent can carry no escalation policy at all:

```sh
MODEL_CLI="pi --print --tools read,bash,edit,write --no-extensions --no-skills --provider zai --model glm-5.3-flash"
```

A Codex-first agent with immediate Cursor subscription fallback can use:

```sh
MODEL_CLI="/home/valentin/.local/bin/hax --provider=codex --model=gpt-6.1-sol --effort=high --no-session -p"
PROVIDER_ORDER="codex,cursor"
PROVIDER_CODEX_CLI="/home/valentin/.local/bin/hax --provider=codex --model=gpt-6.1-sol --effort=high --no-session -p"
PROVIDER_CURSOR_CLI="cursor-agent -p --output-format text --model cursor-grok-4.6-high-fast -f --trust"
```

Reverse `PROVIDER_ORDER` to `cursor,codex` for an agent that should spend Cursor first.

A Cursor-first agent that explicitly chooses the former 3.14 policy can use:

```sh
MODEL_CLI="cursor-agent -p --output-format text --model cursor-grok-4.6-high-fast -f --trust"
LADDER="/home/valentin/.local/bin/hax --provider=codex --model=gpt-6.1-sol --effort=high --no-session -p|/home/valentin/.local/bin/hax --provider=codex --model=gpt-6.1-sol --effort=high --no-session -p|/home/valentin/.local/bin/hax --provider=codex --model=gpt-6.1-sol --effort=high --no-session -p"
RESEARCH_CLI="/home/valentin/.local/bin/hax --provider=codex --model=gpt-6.1-sol --effort=xhigh --no-session --raw -p"
TRIAGE_HARD_CLI="/home/valentin/.local/bin/hax --provider=codex --model=gpt-6.1-sol --effort=high --no-session -p"
CHAT_CLI="cursor-agent -p --output-format text --model cursor-grok-4.6-high-fast -f --trust --mode ask"
```

A file at `~/.local/state/agent-board-poll/model-override/<REF>` may contain one full command for that ticket. It wins over hard triage and `LADDER`; delete it to return to the conf.

## Agent settings by board

New Hypertask agents keep their settings at `~/.config/hypertask-agents/<Board title>/<slug>.conf`. The folder uses the first board for agents on several boards. Agent lookup uses the slug across folders, never a board title. Flat confs still load during migration. Installation moves only the three Hypertask Product agents, dev-1, dev-2 and qa-1, into that board folder. Other boards stay flat until their owner approves moving them. Tokens stay in the shared credentials folder. Run `agent-pause <slug> [--reason "text"]` to set the pause keys in the selected conf, and `agent-resume <slug>` to remove them. Neither command changes systemd or webhook registration; already-running work is not interrupted, and events queued before pause wait for resume.

Pause is not a security boundary while agents run as the same Unix user: they can still access each other's files and credentials. The planned move to a separate Unix user fixes that isolation gap.

## Other keys

| Key | Meaning |
|---|---|
| `AGENT_ID` | Identity id on the board. |
| `AGENT_NAME` | Display name used in prompts. |
| `AGENT_KIND` | `dev`, `qa`, `worker`, or `cli`. |
| `AGENT_REPO` | Checkout used for build work. Reply-only runs do not require it. |
| `PR_REPO` | Required `org/name` memory repository, validated by `create-agent.sh`. |
| `PR_BRANCH_PREFIX` | Deprecated compatibility setting. PR ownership uses a delimiter-bounded agent slug at the start of the branch or after `agent/`, plus the runner's opened-PR ledger. |
| `GH_LOGIN` | Optional agent-specific GitHub author login for PR ownership. It is used only when explicitly set and different from the host `gh` login. |
| `BOARD_ADAPTER` | Adapter loaded by the runner. |
| `BOARD_ID` | Board id, or comma-separated ids. |
| `TOKEN_FILE` | Absolute path to the 0600 token file. |
| `BOARD_CLI` | Agent-authenticated board wrapper. |
| `WATCH_SECTIONS` | Comma-separated watched columns. QA agents include `QA` by default and on template update. |
| `IN_PROGRESS_SECTION` | Destination while a model run is live, default `In Progress`. |
| `REVIEW_SECTION` | Destination after the run opens a pull request, default `AI Review`. |
| `OWNER_REVIEW_SECTION` | Destination when structured PR repair concludes that only a human can resolve the failure, default `Review`; if that default is absent, the runner uses a live `HT Manager Review` column. |
| `DONE_SECTION` | Destination only after QA posts a `Done:` verdict naming every acceptance criterion with live evidence. Defaults to `Done`. |
| `QA_SECTION` | Destination for shipped work awaiting live QA evidence. Defaults to `QA`. |
| `QA_FAIL_SECTION` | QA failure destination. Defaults to the board's first intake column. Failed QA also clears every assignee. |
| `QA_BLOCKED_SECTION` | Blocked or cannot-test destination, default `Agent Blocked (Infra)`. |
| `QA_TURNAROUND_HOURS` | Hours a ticket may remain in QA without an agent verdict before it becomes eligible again, default `4`. |
| `SKILLS_INDEX` | Optional comma-separated extra indexes. |
| `PAUSED` | `yes`, `true`, `1`, or `on` (case-insensitive) pauses poll ticks (including manual `--once`/`--ticket`), event delivery, chat replies, and board reconciliation. Only empty/absent, `no`, `false`, `0`, or `off` means running. Any other non-empty value warns and pauses (fail closed). The webhook remains registered; signed events received during a pause return 202 but are dropped, not replayed on resume. Queued events from before the pause wait until the dispatcher sees the resumed conf. Foreign-webhook audits and deactivation still run while paused. |
| `PAUSED_REASON`, `PAUSED_AT` | Optional reason and UTC timestamp written by `agent-pause`; removed by `agent-resume`. |
| `MAX_CONCURRENT_RUNS` | Runs started per tick, default 1. |
| `RETRY_LIMIT` | Total failed attempts allowed per window. By default this is three plus the number of `LADDER` commands. |
| `RETRY_WINDOW_SECONDS` | Failure window, default 21600. |
| `RUN_COOLDOWN_SECONDS` | Minimum seconds between runs of one ticket without a new external comment, default 1800. |
| `RUN_STALL_SECONDS` | Maximum seconds a model process may show no stdout, stderr, CPU-time, worktree activity, or Hax tool heartbeat before the watchdog stops it, default 1200. Runs waiting on their own PR checks are exempt. |
| `RUN_MAX_SECONDS` | Maximum model process lifetime before the watchdog stops it, default 5400. Runs waiting on their own PR checks are exempt. |
| `WORKDIR_MODE` | `repo` uses `AGENT_REPO`; `per-run` creates an isolated worktree. A capped run pushes dirty work to the ticket branch, and the next run resumes that branch. Other worktrees are removed after each run unless they contain unpushed work. Defaults to `repo`. |
| `WORKDIR_ROOT` | Absolute parent directory for isolated worktrees. Required with `WORKDIR_MODE=per-run`. |
| `TRIAGE` | Whether to score difficulty before pickup. |
| `TRIAGE_MODEL_CLI` | Optional tie-break scoring command, default `MODEL_CLI`. |
| `SECOND_OPINION_CLI` | Independent diagnosis command for repeated capped runs and pull request failures, default `claude --print --model opus`. It must use a different provider family from the development worker. |
| `ADVISOR_MAX` | Research calls per run, default 2 when `RESEARCH_CLI` exists. |
| `CHAT` | `on` enables the host chat lane, including the agent's pending room feed. With `BOARD_ID` also set, it enables the ticket-ack lane: an acknowledgement within one 60-second tick while the runner is busy on that ticket, later edited in place with the full answer. |
| `ROOM_DAILY_TURN_BUDGET` | Maximum agent-room replies per room and UTC day across this host; default `20`, and `0` disables room replies. |
| `QUIET` | `on` redirects unmarked comments to run activity and strips board-owner mentions, except an `Answer:` to the owner's direct mention keeps the owner mention; default `on`. |
| `ANSWERER_FALLBACK` | Slug of the agent that answers owner questions when there is no mention, agent assignee, or prior `Answer:`, `Done:`, or `Decision:` author; default empty. |
| `MANAGER` | `on` allows the manager control commands; default `off`. |
| `MAINTAINER` | `on` allows manager controls plus allowlisted build, merge, and advisor-instruction commands; default `off`. |
| `GRAFT` | `on` adds the keyless structural Graft CLI and MCP command to ticket runs and tells the agent to ask Graft before grepping; default `off`. |
| `FLEET_PROGRESS_SUPERVISOR` | `on` makes this runner evaluate every progress file. Defaults to `on` only for slug `product-bot`. |
| `FLEET_STALL_TICKET` | Toolkit ticket for stalls with no runner ticket, default `AGTE-37`. |
| `FLEET_TELEGRAM_NOTIFIER` | Existing notifier command that accepts the one-line alert as its final argument. Empty uses the established Telegram environment transport. |
| `FLEET_TELEGRAM_ENV` | Shell environment file for that transport, default `~/.config/hypertask-env.sh`. |
| `SUPERVISOR_HEALTH_FILE` | Supervisor score JSON shown first in Board health comments, default `~/.local/state/ht-supervisor/health.json`. |

On this maintainer host, set `ANSWERER_FALLBACK="product-bot"` in the agent confs so Product Bot handles owner questions only when the first three answerer ranks do not apply. This is host configuration, not a runner default.

A maintainer reads `repos.allow` beside its conf. Each CSV row starts with `key,path,github slug,base branch,memory cap`; the cap is optional and any remaining fields are pull request labels. The cap defaults to 12 GB on hosts with more than 32 GB of RAM and half of RAM otherwise. After opening a pull request, the runner applies those labels through GitHub's REST labels endpoint before the create command returns. First install discovers the slug and default branch from each checkout's `origin`. Paths and pull requests outside that file, and checkouts whose origin no longer matches, are refused. Build history is stored at `~/.local/state/agent-board-poll/<slug>-builds.json`. Advisor instructions use `<slug>-instructions/` only as transport to an assigned board 5500 ticket, with created ticket ids under `~/.local/state/agent-template/instruction-tickets/` for idempotent install migration.
