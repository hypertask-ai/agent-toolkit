# agent-template changelog

One entry per version. A line marked `ACTION:` is something the template
cannot do for itself; `agent-template update` prints it and logs it once per
version to `~/.local/state/agent-template/actions.log` for a maintainer
session to read and act on.

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
