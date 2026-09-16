# Agent conf schema

Each agent has a 0600 `<config dir>/<slug>.conf`. It is declarative `KEY=value` shell syntax with uppercase keys only.

## The conf decides the provider

Core treats model commands as opaque strings. It has no provider allow-list and no built-in escalation ladder.

| Key | Meaning |
|---|---|
| `MODEL_CLI` | Required command for normal ticket work and rung 1. |
| `LADDER` | Optional `\|`-separated full commands. Once three attempts have failed, the next attempt selects command one; after four failures, the next selects command two, and so on. Empty or absent means no escalation. |
| `RESEARCH_CLI` | Optional command for `agent-advisor` and supervisor research. Empty or absent means no research step. |
| `TRIAGE_HARD_CLI` | Optional command for a ticket labelled `hard`. Empty or absent means `MODEL_CLI`. |
| `CHAT_CLI` | Optional command for Agent Chat. Empty or absent means `MODEL_CLI`. |

Each value is the complete non-interactive command, including its model, tool, permission, and print flags. The runner splits it into arguments without shell evaluation and appends the prompt as the final argument, which is the existing `MODEL_CLI` contract. Put `-p`, `--print`, or the harness's equivalent before that final prompt. Shell pipelines and a literal `|` cannot appear inside a command because `|` separates ladder entries.

A pi-only agent can carry no escalation policy at all:

```sh
MODEL_CLI="pi --print --tools read,bash,edit,write --no-extensions --no-skills --provider zai --model glm-5.3-flash"
```

A Cursor-first agent that explicitly chooses the former 3.14 policy can use:

```sh
MODEL_CLI="cursor-agent -p --output-format text --model cursor-grok-4.6-high-fast -f --trust"
LADDER="/home/valentin/.local/bin/hax --provider=codex --model=gpt-5.6-sol --effort=high --no-session -p|/home/valentin/.local/bin/hax --provider=codex --model=gpt-5.6-sol --effort=high --no-session -p|claude -p --model opus --effort high"
RESEARCH_CLI="/home/valentin/.local/bin/hax --provider=codex --model=gpt-5.6-sol --effort=xhigh --no-session --raw -p"
TRIAGE_HARD_CLI="/home/valentin/.local/bin/hax --provider=codex --model=gpt-5.6-sol --effort=high --no-session -p"
CHAT_CLI="cursor-agent -p --output-format text --model cursor-grok-4.6-high-fast -f --trust --mode ask"
```

A file at `~/.local/state/agent-board-poll/model-override/<REF>` may contain one full command for that ticket. It wins over hard triage and `LADDER`; delete it to return to the conf.

## Other keys

| Key | Meaning |
|---|---|
| `AGENT_ID` | Identity id on the board. |
| `AGENT_NAME` | Display name used in prompts. |
| `AGENT_KIND` | `dev`, `qa`, `worker`, or `cli`. |
| `AGENT_REPO` | Checkout used for ticket work. |
| `PR_REPO` | Required `org/name` memory repository. |
| `PR_BRANCH_PREFIX` | Branch prefix that proves this agent owns a PR, default `agent/<slug>-`. |
| `BOARD_ADAPTER` | Adapter loaded by the runner. |
| `BOARD_ID` | Board id, or comma-separated ids. |
| `TOKEN_FILE` | Absolute path to the 0600 token file. |
| `BOARD_CLI` | Agent-authenticated board wrapper. |
| `WATCH_SECTIONS` | Comma-separated watched columns. |
| `SKILLS_INDEX` | Optional comma-separated extra indexes. |
| `MAX_CONCURRENT_RUNS` | Runs started per tick, default 1. |
| `RETRY_LIMIT` | Total failed attempts allowed per window. By default this is three plus the number of `LADDER` commands. |
| `RETRY_WINDOW_SECONDS` | Failure window, default 21600. |
| `RUN_COOLDOWN_SECONDS` | Minimum seconds between runs of one ticket without a new external comment, default 1800. |
| `TRIAGE` | Whether to score difficulty before pickup. |
| `TRIAGE_MODEL_CLI` | Optional tie-break scoring command, default `MODEL_CLI`. |
| `ADVISOR_MAX` | Research calls per run, default 2 when `RESEARCH_CLI` exists. |
| `CHAT` | `on` enables the host chat lane. |
