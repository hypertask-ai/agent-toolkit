#!/usr/bin/env bash
# adapters/none/adapter.sh
#
# No tracker. The agent is an identity, a mission, a skills index and a repo.
# You trigger it yourself: by hand, from cron, from CI, from a git hook.
#
# Every contract function is defined. The read functions return nothing, so a
# poll loop against this adapter is a well-behaved no-op rather than a crash,
# and the write functions refuse loudly instead of pretending to post.

_none_refuse() {
  die "this agent has no tracker configured, so it cannot $1" \
      "re-run create-agent.sh with a board adapter, or trigger this agent by hand"
}

adapter_id() { printf 'none'; }
adapter_config_dir_default() { printf ''; }
adapter_require_tools() { :; }
adapter_supports_fleet_wiring() { return 1; }

adapter_find_identity() { printf ''; }
adapter_rotate_token_hint() { printf 'nothing: this agent has no tracker token'; }

adapter_create_identity() {
  die "there is no tracker to create an identity on" \
      "a repo-only agent needs no identity: its name lives in its conf and its commits"
}
adapter_extract_token() { return 1; }
adapter_extract_identity_id() { return 1; }
adapter_install_board_cli() { :; }

adapter_list_candidates() { :; }
adapter_latest_comment() { printf '\n'; }
adapter_mention_token() { printf '%s' "$1"; }
adapter_task_url() { printf ''; }

adapter_post_comment() { _none_refuse "post a comment"; }
adapter_move_task() { _none_refuse "move a ticket"; }
adapter_fleet_wire() {
  die "fleet wiring needs a tracker and a worker runtime; this agent has neither" \
      "use --wiring none, and trigger the agent from cron or by hand"
}
