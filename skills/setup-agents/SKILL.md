---
name: setup-agents
description: Set up a named lead and runners for a project on a Hypertask board. Show a plan first, preserve project rules and keep credentials private.
---

Canonical copy maintained privately and synced here. This public copy contains only generic project setup, not application-specific policy.

# Set up project agents

Use `/setup-agents` for a new team or `/setup-agents Growth Lead` to add one
agent. Ask only what is missing:

1. Project repository: a checkout or `owner/name`. Read a checkout's origin and
   retain its path as `--root`.
2. Hypertask board: its positive numeric ID (extract it from a supplied link),
   or `new` to create a board in the first accessible workspace.
3. Number of runners: default two.
4. Lead name: default `<Project> Lead`. For one extra agent, a name containing
   the word `Lead` defaults to lead; otherwise runner. Honor an explicit role.

Discover the project's default branch, tests, PR title and deployment rules.
Use an existing setup YAML contract when available. Without one, the CLI uses
main, `git diff --check`, descriptive PR titles, owner-approved deployment,
no feature flags and no agent closing tickets. The default live check is
`false`: it blocks a live claim until real project checks are configured.
Only write discovered facts into a YAML contract after approval. Never infer
application-specific rules merely because the project uses a Hypertask board.

## Plan first

Resolve `KIT_HOME` to **this skill folder**, the folder containing this file.
All bundled paths are relative to it. Do not enable shell tracing.

```sh
"$KIT_HOME/bin/setup-agents" --config <project.yaml> --runners <N> --lead "<name>"
# Without a contract:
"$KIT_HOME/bin/setup-agents" --repo <owner/name> --board <id-or-new> --runners <N> --lead "<name>"
# Add one agent:
"$KIT_HOME/bin/setup-agents" --config <project.yaml> --new-agent "Growth Lead" --role lead
```

Dry run is the default. It reads no credentials, calls no board, clones nothing
and writes no files, including Python bytecode. Explain the proposed names,
paths and project rules. Ask for approval to apply that exact plan. Invoking
this skill alone is not approval.

## Apply the approved plan

Repeat the exact command with `--apply`. It will:

- Clone only if necessary and verify an existing checkout's origin. Preserve
  existing CLAUDE.md rules, local hooks, skills and identities. Refuse conflicting
  generated files rather than overwrite them; reconcile in a reviewed change.
- Use the bundled Hypertask adapter to mint board-scoped write identities with
  the authenticated `hypertask` CLI. Capture responses privately, save one-time
  credentials as 0600 and never print tokens or put them on command lines.
  Missing tokens stop setup; never rotate credentials automatically.
- Store project credentials under `~/.config/agent-kit/credentials/` and link
  named-session credentials under `~/.config/hypertask-agents/credentials/sessions/`.
  Optional `SETUP_AGENTS_CREDENTIALS_DIR` and `SETUP_AGENTS_SESSION_CREDENTIALS_DIR`
  customize the links. A conflicting name stops setup. No identity fallback.
- Install project rules, `/unlazy`, this skill, a generic `/ship`, project YAML,
  private identity profiles, per-agent launchers and an acceptance-ledger template.
  Identity resolution and project checks use bundled `bin/kit-identity` and
  `bin/kit-check`, not tools from a separate kit checkout.
- Optionally merge a browser guard hook when `SETUP_AGENTS_BROWSER_GUARD` names
  an existing executable guard. It receives Claude's hook JSON on stdin and
  `SETUP_AGENT_ROLE` in the environment. It must deny forbidden browser actions
  for every runner, regardless of session name. Without this option, no browser
  hook is installed. Runners still put links on tickets rather than control
  the owner's browser.
- Start named tmux panes. The lead starts `/loop 5m` to follow up on the board
  and keep runners alive; its launcher restarts after exit. Runners start `/ship`
  with their own name and identity. Existing live panes are not duplicated.
- Append a ready record per agent to `~/.local/state/setup-agents/runs.log` only
  after successful setup.

Host requirements: Linux or another POSIX host with Python 3, PyYAML, git, jq,
node, tmux, Claude Code and the authenticated Hypertask CLI. Install `/unlazy`
at `~/.agents/skills/unlazy/` first. `gh` is needed for cloning and PR work.
Missing tools, inaccessible boards, conflicting files or refused operations are
blockers; never borrow another login. Keep local settings, generated profiles,
credentials and ledgers out of git.

## Before saying ready

Verify exit zero, live named panes, ready records for all requested slugs and
0600 credential files. Inside each pane's environment run
`"$KIT_HOME/bin/kit-identity"`; it prints only the pane's name and token-file
path. Use `"$KIT_HOME/bin/kit-identity" --board <command> ...` for board work,
not a host-default identity. If setup stops partway through, preserve already
minted credentials and rerun the same plan after fixing the cause. A dry run
is not provisioning.

For offline tests only, `SETUP_AGENTS_MINT_COMMAND` supplies an argv-compatible
fake board command. Never use one that logs responses or credentials.
