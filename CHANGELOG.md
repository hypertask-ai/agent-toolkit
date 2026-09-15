# agent-template changelog

One entry per version. A line marked `ACTION:` is something the template
cannot do for itself; `agent-template update` prints it and logs it once per
version to `~/.local/state/agent-template/actions.log` for a maintainer
session to read and act on.

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
