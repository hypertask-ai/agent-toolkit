#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/confs/retired"
printf 'BOARD_ADAPTER="hypertask"\nQUIET="off"\n' > "$TMP/confs/current.conf"
printf 'BOARD_ADAPTER="hypertask"\nAGENT_KIND="qa"\nWATCH_SECTIONS="AI Review"\nQUIET="on"\n' > "$TMP/confs/qa.conf"
printf 'BOARD_ADAPTER="hypertask"\nAGENT_KIND="qa"\nWATCH_SECTIONS="*"\nQUIET="on"\n' > "$TMP/confs/qa-all.conf"
printf 'HT_AGENT_ID="old"\n' > "$TMP/confs/legacy.conf"
printf 'BOARD_ADAPTER="hypertask"\n' > "$TMP/confs/retired/old.conf"

python3 "$ROOT/scripts/migrate-quiet-mode.py" --version 3.23.0 "$TMP/confs" > "$TMP/out"

if grep -q '^QUIET="on"$' "$TMP/confs/current.conf" \
   && [ -f "$TMP/confs/current.conf.bak-3.23.0" ] \
   && grep -q '^WATCH_SECTIONS="AI Review,QA"$' "$TMP/confs/qa.conf" \
   && [ -f "$TMP/confs/qa.conf.bak-3.23.0" ] \
   && grep -q '^WATCH_SECTIONS="\*"$' "$TMP/confs/qa-all.conf" \
   && [ ! -f "$TMP/confs/qa-all.conf.bak-3.23.0" ] \
   && ! grep -q '^QUIET=' "$TMP/confs/legacy.conf" \
   && ! grep -q '^QUIET=' "$TMP/confs/retired/old.conf"; then
  printf 'PASS %-36s %s\n' current-defaults-migration 'quiet mode and QA sections migrate; wildcard, legacy, and retired confs are preserved'
else
  printf 'FAIL %-36s %s\n' current-defaults-migration "output=$(cat "$TMP/out")"
  exit 1
fi
