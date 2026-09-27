#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/adapters/hypertask/adapter.sh"
_ht_get() { printf '%s' "$COMMENTS"; }
_ht_pr_cache_rows() { printf '%s' "$PRS"; }
PR_REPO=org/repo
PRS='[{"state":"MERGED","title":"HTPR-1 fix","mergedAt":"2026-09-18T20:00:00Z","url":"https://github.com/org/repo/pull/1"}]'
COMMENTS='{"comments":[]}'
rank() { AGENT_KIND="$1" adapter_pick_rank token 15 agent-qa 'QA One' HTPR-1 task-1 "$2" new; }
[[ "$(rank qa QA)" == '3 '* ]] || { echo 'FAIL merged ticket without verdict must reach QA'; exit 1; }
[[ "$(rank dev QA)" == '0 '* ]] || { echo 'FAIL merged ticket must not reach dev'; exit 1; }
[[ "$(rank qa Review)" == '0 '* ]] || { echo 'FAIL merged ticket outside QA must not reach QA'; exit 1; }
COMMENTS='{"comments":[{"createdAt":"2026-09-18T21:00:00Z","text":"QA verdict: passed"}]}'
[[ "$(rank qa QA)" == '0 '* ]] || { echo 'FAIL merged ticket with verdict must not repeat QA'; exit 1; }
COMMENTS='{"comments":[{"createdAt":"2026-09-18T21:00:00Z","agent":{"id":"agent-qa"},"text":"<p>Done: verified checkout</p>"}]}'
[[ "$(rank qa QA)" == '0 '* ]] || { echo 'FAIL an agent Done verdict must stop repeated QA'; exit 1; }
echo 'PASS merged ticket enters QA once, only in QA without a later verdict'
