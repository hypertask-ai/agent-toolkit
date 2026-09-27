#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if rg -n 'pr[[:space:]]+merge|--enable-auto-merge|enable(AutoMerge|PullRequestAutoMerge)[[:space:]]*\(|allow_auto_merge[=:]true' \
    "$ROOT/scripts" "$ROOT/adapters" --glob '!agent-identity-shim'; then
  echo 'FAIL no-agent-merge                 runner can merge or enable auto-merge'
  exit 1
fi
echo 'PASS no-agent-merge                 no runner merge or auto-merge enable call'
