#!/usr/bin/env bash
# Behavioural checks on sync-project.sh, which lays the standard agent layout
# into a project repo.
#
# The case file next door replays text corrections. These cannot be
# expressed that way: they are about what happens on disk when the sync runs
# twice over a repo somebody has edited in between.
#
#   1. a first sync into an empty repo writes the whole layout
#   2. a second sync changes nothing
#   3. a file the project edited survives the second sync untouched
#
# Case 3 is the one that matters. A rule of "the marker is present, so the
# template owns it" would silently overwrite an edited file that still carried
# its marker, which is exactly the accident this is here to prevent.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$HERE/../scripts/sync-project.sh"
[ -x "$SYNC" ] || { echo "FAIL sync-project: no executable at $SYNC" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
mkdir -p "$PROJECT/.claude/skills/demo-skill"
printf '# demo\n' > "$PROJECT/.claude/skills/demo-skill/SKILL.md"

fails=0
ok()   { printf 'PASS %-34s %s\n' "$1" "$2"; }
bad()  { printf 'FAIL %-34s %s\n' "$1" "$2"; fails=$((fails + 1)); }

# --- 1. first sync writes the layout ----------------------------------------
first="$(bash "$SYNC" "$PROJECT" 2>&1)"
missing=""
for f in AGENTS.md board.yml .claude/skills/INDEX.md .claude/skills/RULE-MAP.md \
         .claude/skills/VERSION .claude/skills/evals/run-evals.sh \
         .claude/hooks/board-write-guard.sh .github/workflows/skills-evals.yml \
         .github/workflows/pr-title.yml; do
  [ -f "$PROJECT/$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
  bad sync-first-run "the first sync did not write:$missing"
else
  ok sync-first-run "the whole layout is on disk"
fi

# The index is seeded from the skills the repo already has, not left empty.
if grep -q 'demo-skill' "$PROJECT/.claude/skills/INDEX.md"; then
  ok sync-seeds-index "INDEX.md lists the skill the repo already had"
else
  bad sync-seeds-index "INDEX.md does not mention demo-skill"
fi

# A script it writes has to still start with its shebang, or nothing runs it.
if [ "$(head -n1 "$PROJECT/.claude/skills/evals/run-evals.sh")" = "#!/usr/bin/env bash" ]; then
  ok sync-keeps-shebang "the marker did not displace the shebang"
else
  bad sync-keeps-shebang "line 1 is not the shebang"
fi

# And what it writes has to pass its own checks.
if bash "$PROJECT/.claude/skills/evals/run-evals.sh" >/dev/null 2>&1; then
  ok sync-evals-pass "the laid-down eval suite passes on the laid-down pack"
else
  bad sync-evals-pass "the laid-down eval suite fails on the pack it was written for"
fi

# --- 2. second sync is a no-op ----------------------------------------------
before="$(find "$PROJECT" -type f -newermt '@0' -printf '%p %T@\n' | sort)"
second="$(bash "$SYNC" "$PROJECT" 2>&1)"
after="$(find "$PROJECT" -type f -newermt '@0' -printf '%p %T@\n' | sort)"
if [ "$before" = "$after" ] && printf '%s' "$second" | grep -q '0 added, 0 updated'; then
  ok sync-second-run-noop "nothing added, nothing updated, no file rewritten"
else
  bad sync-second-run-noop "the second sync touched something: $second"
fi

# --- 3. a project-edited file survives ---------------------------------------
printf '\n## A rule this project added itself\n' >> "$PROJECT/AGENTS.md"
edited="$(cat "$PROJECT/AGENTS.md")"
third="$(bash "$SYNC" "$PROJECT" 2>&1)"
if [ "$(cat "$PROJECT/AGENTS.md")" = "$edited" ]; then
  if printf '%s' "$third" | grep -q 'kept  AGENTS.md'; then
    ok sync-keeps-project-edit "the edited file survived and the sync said so"
  else
    bad sync-keeps-project-edit "the edited file survived but the sync did not report it"
  fi
else
  bad sync-keeps-project-edit "the sync overwrote a file the project had edited"
fi

# A file the project wrote from scratch, with no marker at all, is likewise
# never touched.
printf 'project owns this\n' > "$PROJECT/.claude/skills/RULE-MAP.md"
bash "$SYNC" "$PROJECT" >/dev/null 2>&1
if [ "$(cat "$PROJECT/.claude/skills/RULE-MAP.md")" = "project owns this" ]; then
  ok sync-keeps-unmarked "a file with no template marker is left alone"
else
  bad sync-keeps-unmarked "the sync overwrote an unmarked project file"
fi

# --- 4. a repo with no skills at all -----------------------------------------
# Most repos the daily sync reaches have no skills yet. What it lays down there
# has to pass its own eval on the very PR that introduces it, or every one of
# those repos gets a red workflow the moment it is synced.
EMPTY="$TMP/empty"
mkdir -p "$EMPTY"
bash "$SYNC" "$EMPTY" >/dev/null 2>&1
if empty_out="$(bash "$EMPTY/.claude/skills/evals/run-evals.sh" 2>&1)"; then
  ok sync-empty-repo-evals-pass "the laid-down eval passes on a repo with no skills"
else
  bad sync-empty-repo-evals-pass "a skill-less repo fails its own eval: $empty_out"
fi

# --- 5. a check name the repo already uses -----------------------------------
# The app repo declares its pr-title check inside another workflow file. Writing
# a second file that declares the same job name would give one check name two
# definitions, and branch protection would follow whichever GitHub reported
# last. The sync has to leave that one alone.
TAKEN="$TMP/taken"
mkdir -p "$TAKEN/.github/workflows"
cat > "$TAKEN/.github/workflows/pr-size.yml" <<'YAML'
name: pr-size
jobs:
  pr-size:
    runs-on: ubuntu-latest
  pr-title:
    name: pr-title
    runs-on: ubuntu-latest
YAML
taken_out="$(bash "$SYNC" "$TAKEN" 2>&1)"
if [ ! -f "$TAKEN/.github/workflows/pr-title.yml" ] \
   && printf '%s' "$taken_out" | grep -q "already declares a 'pr-title' check"; then
  ok sync-skips-taken-check-name "a check name the repo already uses is not redefined"
else
  bad sync-skips-taken-check-name "the sync wrote a second pr-title definition: $taken_out"
fi
# The workflow whose name is free is still written.
if [ -f "$TAKEN/.github/workflows/skills-evals.yml" ]; then
  ok sync-still-writes-free-workflow "the workflow with a free name is still laid down"
else
  bad sync-still-writes-free-workflow "skills-evals.yml was not written"
fi

printf '\n%d behavioural check(s) failed\n' "$fails"
[ "$fails" -eq 0 ]
