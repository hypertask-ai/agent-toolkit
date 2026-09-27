#!/usr/bin/env bash
# Board-folder lookup and merged-PR QA pickup use only isolated fixtures.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }
export HOME="$TMP/home" AGENT_CONFIG_DIR="$TMP/config"
CORE_ROOT="$ROOT"
. "$ROOT/scripts/lib/core.sh"
mkdir -p "$AGENT_CONFIG_DIR/Agent Toolkit/credentials" "$HOME/.config/agents" "$TMP/bin"
touch "$AGENT_CONFIG_DIR/Agent Toolkit/tk-dev-1.conf" "$AGENT_CONFIG_DIR/flat.conf"
if [ "$(core_find_conf tk-dev-1)" = "$AGENT_CONFIG_DIR/Agent Toolkit/tk-dev-1.conf" ]; then
  ok board-subfolder 'lookup resolves slug under board title with spaces'
else bad board-subfolder 'board conf not found'; fi
if [ "$(core_find_conf flat)" = "$AGENT_CONFIG_DIR/flat.conf" ]; then
  ok flat-fallback 'legacy flat conf remains discoverable'
else bad flat-fallback 'flat conf not found'; fi
printf 'safe fixture\n' > "$AGENT_CONFIG_DIR/Agent Toolkit/credentials/tk-dev-1-agent-token"
if [ "$(core_agent_file tk-dev-1 credentials/tk-dev-1-agent-token)" = "$AGENT_CONFIG_DIR/Agent Toolkit/credentials/tk-dev-1-agent-token" ] \
   && [ "$(core_agent_file tk-dev-1 tk-dev-1.env)" = "$AGENT_CONFIG_DIR/tk-dev-1.env" ]; then
  ok sibling-paths 'credentials follow conf, missing env falls back to flat'
else bad sibling-paths 'sibling or fallback path incorrect'; fi
mkdir -p "$AGENT_CONFIG_DIR/Second Board"
touch "$AGENT_CONFIG_DIR/Second Board/tk-dev-1.conf"
if error="$(core_find_conf tk-dev-1 2>&1)"; then
  bad duplicate-slug 'lookup accepted duplicate'
elif [[ "$error" == *'Agent Toolkit/tk-dev-1.conf'* && "$error" == *'Second Board/tk-dev-1.conf'* ]]; then
  ok duplicate-slug 'both conflicting paths are named'
else bad duplicate-slug "$error"; fi
rm "$AGENT_CONFIG_DIR/Second Board/tk-dev-1.conf"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" PR_REPO=example/repo
. "$ROOT/adapters/hypertask/adapter.sh"
_ht_get() { cat "$TMP/comments.json"; }
_ht_pr_cache_rows() { printf '%s\n' '[{"title":"AGTE-180 fix","state":"MERGED","url":"https://github.com/example/repo/pull/1","mergedAt":"2026-01-01T00:00:00Z"}]'; }
adapter_merged_pr_from_comments() { return 1; }
printf '%s\n' '{"comments":[]}' > "$TMP/comments.json"
for kind in qa dev; do
  result="$(AGENT_KIND="$kind" adapter_pick_rank "$TMP/token" 5500 agent-1 Tester AGTE-180 task-180 QA new)"
  if { [ "$kind" = qa ] && [[ "$result" == '3 '* ]]; } || { [ "$kind" = dev ] && [[ "$result" == '0 '* ]]; }; then
    ok "merged-$kind" "$kind pickup rank for merged ticket in QA"
  else bad "merged-$kind" "$result"; fi
done
printf '%s\n' '{"comments":[{"text":"QA PASS: verified","createdAt":"2026-01-02T00:00:00Z"}]}' > "$TMP/comments.json"
result="$(AGENT_KIND=qa adapter_pick_rank "$TMP/token" 5500 agent-1 Tester AGTE-180 task-180 QA new)"
if [[ "$result" == '0 '* ]]; then ok merged-qa-verdict 'QA stops after post-merge verdict'
else bad merged-qa-verdict "$result"; fi
# A second page carries board 15; a multi-board agent belongs to that first board.
cat > "$TMP/bin/hypertask" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *' project list '*'--offset 0'*) printf '%s\n' '{"projects":[{"id":999,"title":"Other"}],"total":2,"offset":0}' ;;
  *' project list '*'--offset 100'*) printf '%s\n' '{"projects":[{"id":15,"title":"Agent Toolkit"}],"total":2,"offset":100}' ;;
  *' agents list '*) printf '%s\n' '{"agents":[]}' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/hypertask"
mkdir -p "$TMP/repo"
printf '# Agent skills\n' > "$TMP/INDEX.md"
plan="$(COMPANY_SKILLS_INDEX= "$ROOT/scripts/create-agent.sh" --name 'New Bot' \
  --kind dev --board hypertask --project '15,5500' --repo "$TMP/repo" \
  --pr-repo example/new-bot --skills-index "$TMP/INDEX.md" --dry-run 2>&1)" || true
if [[ "$plan" == *"conf      $AGENT_CONFIG_DIR/Agent Toolkit/new-bot.conf"* ]]; then
  ok first-board-page 'second-page board title is used for multi-board conf'
else bad first-board-page "$plan"; fi
if collision="$(COMPANY_SKILLS_INDEX= "$ROOT/scripts/create-agent.sh" --name 'TK Dev 1' \
  --board hypertask --project 15 --repo "$TMP/repo" --pr-repo example/new-bot \
  --skills-index "$TMP/INDEX.md" --dry-run 2>&1)"; then
  bad create-duplicate 'create accepted a slug in a board folder'
elif [[ "$collision" == *"agent slug tk-dev-1 already exists"* ]]; then
  ok create-duplicate 'create refuses existing slug before any board work'
else bad create-duplicate "$collision"; fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
