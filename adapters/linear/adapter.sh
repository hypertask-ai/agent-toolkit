#!/usr/bin/env bash
# adapters/linear/adapter.sh
#
# Stub. Every function in the adapter contract is defined so that picking this
# adapter fails with our own message instead of "command not found" three
# layers down. Fill these in to add Linear support; nothing else has to change.
#
# What a real implementation needs:
#   - a webhook receiver (or a poll) for issue events: comment mention, assign
#   - an ack posted on the issue within ten seconds, so a human watching Linear
#     sees the work was picked up
#   - a typed activity entry per action (comment, status move, PR link), the
#     shape Linear's own agent session API expects
#   - an API key per identity, stored the same way: a 0600 file, never printed

_linear_todo() {
  die "the Linear adapter is a stub: $1 is not implemented" \
      "implement it in adapters/linear/adapter.sh, or pick another adapter"
}

adapter_id() { printf 'linear'; }
adapter_config_dir_default() { printf ''; }
adapter_require_tools() { _linear_todo "adapter_require_tools"; }
adapter_supports_fleet_wiring() { return 1; }
adapter_find_identity() { _linear_todo "adapter_find_identity"; }
adapter_create_identity() { _linear_todo "adapter_create_identity"; }
adapter_rotate_token_hint() { printf 'the Linear API key rotation flow for %s' "${1:-<agent>}"; }
adapter_extract_token() { _linear_todo "adapter_extract_token"; }
adapter_extract_identity_id() { _linear_todo "adapter_extract_identity_id"; }
adapter_install_board_cli() { _linear_todo "adapter_install_board_cli"; }
adapter_list_candidates() { _linear_todo "adapter_list_candidates"; }
adapter_latest_comment() { _linear_todo "adapter_latest_comment"; }
adapter_ticket_comments() { _linear_todo "adapter_ticket_comments"; }
adapter_mention_token() { _linear_todo "adapter_mention_token"; }
adapter_task_url() { _linear_todo "adapter_task_url"; }
adapter_post_comment() { _linear_todo "adapter_post_comment"; }
adapter_move_task() { _linear_todo "adapter_move_task"; }
adapter_fleet_wire() { _linear_todo "adapter_fleet_wire"; }
