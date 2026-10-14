# Agent Toolkit

The agent toolkit provisions and operates skills-driven agents on a host. Its
canonical repository is https://github.com/hypertask-ai/agent-toolkit.

## Install

Clone this repository and run `./install.sh`. Existing hosts update through
`agent-template update`, which uses `~/projects/agent-toolkit` by default.

See [SKILL.md](SKILL.md) for the operator-facing guide and
[MAINTAINER.md](MAINTAINER.md) for host maintenance.

Set up a project lead and runners on your Hypertask board with
[/setup-agents](skills/setup-agents/SKILL.md), a standalone, plan-first skill.
To expose the command in Claude Code, link `skills/setup-agents/` from this
checkout into `~/.claude/skills/setup-agents` (preserve any existing skill).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for bug reports, ideas, and our contribution policy.
