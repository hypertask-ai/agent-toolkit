#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK='{"task":{"description":"<h2>Acceptance criteria</h2><ul><li><p>Checkout completes.</p></li><li><p>Receipt appears.</p></li></ul>"}}'
check() {
  local expected="$1" label="$2" author="$3" text="$4" comments result=0
  comments="$(AUTHOR="$author" TEXT="$text" python3 - <<'PY'
import json, os
print(json.dumps({"comments": [{"agent": {"id": os.environ["AUTHOR"]}, "text": os.environ["TEXT"]}]}))
PY
)"
  python3 "$ROOT/scripts/qa-live-verdict.py" --task "$TASK" --comments "$comments" \
    --qa-agent-id qa >/dev/null 2>&1 || result=$?
  if [ "$result" -ne "$expected" ]; then
    echo "FAIL $label: expected exit $expected, got $result"
    exit 1
  fi
  echo "PASS $label"
}
check 0 'QA names both criteria and records live results' qa \
  'Done: AC 1, checkout completes. Live evidence: checkout completed at https://live.example.test/checkout. AC 2, receipt appears. Live evidence: receipt displayed in production browser.'
check 1 'developer verdict cannot close ticket' dev \
  'Done: AC 1, checkout completes. Live evidence: checkout completed on live. AC 2, receipt appears. Live evidence: receipt appeared on live.'
check 1 'QA must name actual criterion' qa \
  'Done: AC 1, payment works. Live evidence: payment succeeded on live. AC 2, receipt appears. Live evidence: receipt appeared on live.'
check 1 'QA must cover every criterion' qa \
  'Done: AC 1, checkout completes. Live evidence: checkout completed on live.'
check 1 'merged PR is not live evidence' qa \
  'Done: AC 1, checkout completes. Live evidence: PR merged at https://github.com/example/repo/pull/1. AC 2, receipt appears. Live evidence: PR merged at https://github.com/example/repo/pull/1.'
