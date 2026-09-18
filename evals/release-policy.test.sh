#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

if [ -n "${GITHUB_BASE_REF:-}" ]; then
  base_sha="$(python3 - "${GITHUB_EVENT_PATH:-}" <<'PYEOF'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8"))["pull_request"]["base"]["sha"])
except (OSError, KeyError, TypeError, ValueError):
    print("")
PYEOF
)"
  [ -n "$base_sha" ] || base_sha="origin/$GITHUB_BASE_REF"
  protected="$(git diff --name-only "$base_sha"...HEAD -- \
    templates/agent-skills/create-agent/VERSION \
    templates/agent-skills/create-agent/CHANGELOG.md)"
  if [ -n "$protected" ]; then
    printf 'FAIL release-files-merge-only PRs must add changelog.d fragments, not edit:\n%s\n' "$protected"
    exit 1
  fi
fi

mkdir -p "$TMP/template/changelog.d" "$TMP/template/scripts"
printf '3.45.7\n' > "$TMP/template/VERSION"
printf '## 3.45.7 - 2026-09-17\n\n- Previous.\n' > "$TMP/template/CHANGELOG.md"
printf 'keep\n' > "$TMP/template/changelog.d/README.md"
printf '%s\n' '- First fragment.' > "$TMP/template/changelog.d/b.md"
printf '%s\n' '- Second fragment.' > "$TMP/template/changelog.d/a.md"
cp "$ROOT/scripts/assemble-release.py" "$TMP/template/scripts/"
python3 "$TMP/template/scripts/assemble-release.py" --root "$TMP/template" --date 2026-09-18 > "$TMP/output"
if [ "$(cat "$TMP/template/VERSION")" = 3.46.0 ] \
   && head -1 "$TMP/template/CHANGELOG.md" | grep -qx '## 3.46.0 - 2026-09-18' \
   && [ "$(sed -n '3p' "$TMP/template/CHANGELOG.md")" = '- Second fragment.' ] \
   && [ "$(sed -n '5p' "$TMP/template/CHANGELOG.md")" = '- First fragment.' ] \
   && [ -f "$TMP/template/changelog.d/README.md" ] \
   && [ "$(find "$TMP/template/changelog.d" -type f ! -name README.md | wc -l)" -eq 0 ]; then
  ok release-assembled-on-main 'fragments create one minor release in stable filename order'
else
  bad release-assembled-on-main "version=$(cat "$TMP/template/VERSION") changelog=$(cat "$TMP/template/CHANGELOG.md")"
fi

before="$(sha256sum "$TMP/template/VERSION" "$TMP/template/CHANGELOG.md")"
second="$(python3 "$TMP/template/scripts/assemble-release.py" --root "$TMP/template")"
after="$(sha256sum "$TMP/template/VERSION" "$TMP/template/CHANGELOG.md")"
if [ "$before" = "$after" ] && [ "$second" = 'no changelog fragments' ]; then
  ok release-no-fragments-noop 'the release workflow does not create an empty release commit'
else
  bad release-no-fragments-noop "output=$second"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
