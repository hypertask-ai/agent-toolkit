#!/bin/bash
# PreToolUse guard (Valentin, 2026-09-15, HARD RULE): sessions never touch the Hypertask board by hand.
# Board writes come only from the runner (agent-board-poll) and the supervisor (ht-supervisor), which run as
# systemd timers outside any session. A session fixes the mechanism and runs it (ht-supervisor --now).
# Override only when Valentin says so in chat: touch /tmp/ht-board-write-approved (remove it when done).
[ -f /tmp/ht-board-write-approved ] && exit 0
cmd=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)
block() {
  echo "BLOCKED by board-write-guard: sessions never write to the Hypertask board by hand (Valentin, 2026-09-15). Only the runner (agent-board-poll) and the supervisor (ht-supervisor) act on tickets, as timers. If the board is wrong, fix the check in the supervise-board skill and run 'ht-supervisor --now' (or '--only <check>'); if an agent must act, let its runner pick the ticket. Reads (ht GET, hypertask ... get/list/search) are fine. Valentin can lift this once with: touch /tmp/ht-board-write-approved" >&2
  exit 2
}
# hypertask CLI (Valentin's token) and the Product Bot wrappers: any write subcommand
if printf '%s' "$cmd" | grep -qE '(^|[;&| ])(hypertask|htbot|htfable|htceo)[[:space:]]+(tasks?|comments?|pages?|projects?|sections?|labels?|agents?)[[:space:]]+(create|add|update|edit|move|move-board|assign|unassign|delete|archive|invite|rotate-token|revoke)'; then block; fi
# direct REST writes
if printf '%s' "$cmd" | grep -qE '(^|[;&| ])ht[[:space:]]+(POST|PUT|PATCH|DELETE)[[:space:]]'; then block; fi
exit 0
