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

# Regression for the QA/Bugs bounce loop: the reconciler posts a hand-off
# notice under the QA agent's own identity when it moves a merged PR to QA.
# That notice is an instruction to go check, not a verdict, and must never
# block the real QA run from starting. Older tickets still carry the notice
# under its original "Handoff:" wording, so both forms are checked.
COMMENTS='{"comments":[{"createdAt":"2026-09-18T21:00:00Z","agent":{"id":"agent-qa"},"text":"<p>Handoff: QA must verify https://github.com/org/repo/pull/1 on live against every acceptance criterion.</p>"}]}'
[[ "$(rank qa QA)" == '3 '* ]] || { echo 'FAIL the reconciler hand-off notice (old Handoff: wording) must not block a real QA run'; exit 1; }
COMMENTS='{"comments":[{"createdAt":"2026-09-18T21:00:00Z","agent":{"id":"agent-qa"},"text":"<p>Decision: QA must verify https://github.com/org/repo/pull/1 on live against every acceptance criterion.</p>"}]}'
[[ "$(rank qa QA)" == '3 '* ]] || { echo 'FAIL the reconciler hand-off notice (Decision: wording) must not block a real QA run'; exit 1; }
COMMENTS='{"comments":[{"createdAt":"2026-09-18T21:00:00Z","agent":{"id":"agent-qa"},"text":"<p>Handoff: Dev must fix the failing checkout step.</p>"}]}'
[[ "$(rank qa QA)" == '0 '* ]] || { echo 'FAIL a genuine QA Handoff/FAIL verdict must still stop repeated QA'; exit 1; }
echo 'PASS the reconciler hand-off notice never blocks a real QA run, and a genuine verdict still does'
for flag in no yes; do
  verdict="$(FEATURE_FREEZE="$flag" rank dev Features)"
  if [ "$flag" = yes ]; then
    [[ "$verdict" == '0 feature freeze' ]] || { echo 'FAIL frozen Features rank'; exit 1; }
  else
    [[ "$verdict" == '0 '* ]] || { echo 'FAIL unfrozen Features rank'; exit 1; }
  fi
  echo "PASS feature-freeze-rank-$flag"
done
