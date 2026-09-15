#!/usr/bin/env bash
# sync-project.sh <checkout> [--dry-run] [--quiet]
#
# Lay the standard agent layout into a project repo, and keep it there.
# Called by create-agent.sh --sync-project, by create-agent.sh --pr-repo, and
# by `agent-template update` for every PR_REPO it knows about.
#
# What it lays down, when the file is missing:
#   .claude/skills/INDEX.md           seeded with the skills already present
#   .claude/skills/RULE-MAP.md        empty table, ready to fill
#   .claude/skills/VERSION            the pack version, 1.0.0 to start
#   .claude/skills/evals/run-evals.sh + exempt.txt
#   .github/workflows/skills-evals.yml
#   .github/workflows/pr-title.yml
#   .claude/hooks/board-write-guard.sh
#   AGENTS.md                         the shared conventions
#   board.yml                         the supervisor's column map
#
# Idempotent, and it never overwrites a file a project has edited. Every file
# it writes carries a header line naming the template version AND the sha256 of
# the body underneath it. On a re-sync:
#
#   header hash matches the body   -> template-owned and untouched, rewritten
#   header present, hash differs   -> the project edited it, left alone
#   no header                      -> the project's own file, left alone
#
# A bare "the marker is present" rule would clobber an edited file that still
# carried the marker, which is the one thing this must never do.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
CORE_ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
TEMPLATE_DIR="$CORE_ROOT/project-template"
VERSION="$(head -n1 "$CORE_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')"
VERSION="${VERSION:-unknown}"

MARKER_TEXT="agent-template: owned"
DRY_RUN="no"
QUIET="no"
TARGET=""

die() { printf 'ERROR: %s\n  Do this next: %s\n' "$1" "${2:-}" >&2; exit 1; }
say() { [ "$QUIET" = "yes" ] || printf '%s\n' "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN="yes"; shift ;;
    --quiet)   QUIET="yes"; shift ;;
    -h|--help) sed -n '2,30p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown flag $1" "run $SELF --help" ;;
    *)  TARGET="$1"; shift ;;
  esac
done

[ -n "$TARGET" ] || die "no project given" \
  "run: sync-project.sh /path/to/checkout, or sync-project.sh org/name"

# org/name rather than a path: clone it, sync, and leave a pull request. This
# is the explicit human-run form. `agent-template update` uses the path form on
# checkouts that already exist, because a daily timer pushing to every repo it
# knows about, unattended, is worse than leaving a clean diff behind.
OPEN_PR="no"
CLONE_TMP=""
case "$TARGET" in
  */*/*|/*|.*|~*) : ;;
  */*)
    if [ ! -d "$TARGET" ]; then
      command -v gh >/dev/null 2>&1 || die "gh is not installed, so $TARGET cannot be cloned" \
        "install gh, or clone the repo yourself and pass the checkout path"
      CLONE_TMP="$(mktemp -d)"
      gh repo clone "$TARGET" "$CLONE_TMP/repo" -- -q \
        || die "could not clone $TARGET" "check the name and that gh auth status is good"
      REMOTE_REPO="$TARGET"
      TARGET="$CLONE_TMP/repo"
      OPEN_PR="yes"
    fi ;;
esac

[ -d "$TARGET" ] || die "no directory at $TARGET" \
  "clone the repo first, then point --sync-project at the checkout"
[ -d "$TEMPLATE_DIR" ] || die "no project-template at $TEMPLATE_DIR" \
  "the create-agent template is missing project-template/; reinstall the template"
TARGET="$(cd "$TARGET" && pwd)"

# ---------- the ownership marker ----------
# The comment syntax differs per file type, so the marker is rendered per file
# and stripped the same way.
marker_prefix() {
  case "$1" in
    *.md)                 printf '<!-- ' ;;
    *.sh|*.yml|*.yaml|*.txt) printf '# ' ;;
    *)                    printf '# ' ;;
  esac
}
marker_suffix() {
  case "$1" in
    *.md) printf ' -->' ;;
    *)    printf '' ;;
  esac
}

body_hash() { # body_hash <file-with-no-header>  : sha256 of stdin
  sha256sum | cut -d' ' -f1
}

# render <relative path> : the file's body, after any placeholder substitution.
render() {
  local rel="$1"
  case "$rel" in
    .claude/skills/INDEX.md) render_index ;;
    board.yml)               render_board ;;
    *)                       cat "$TEMPLATE_DIR/$rel" ;;
  esac
}

# The index is seeded with whatever skills the repo already has, so a repo that
# already carries skills gets a true index rather than an empty one.
render_index() {
  local rows="" d name
  for d in "$TARGET"/.claude/skills/*/; do
    [ -f "$d/SKILL.md" ] || continue
    name="$(basename "$d")"
    rows="$rows| $name | describe when this skill fires | .claude/skills/$name/SKILL.md |
"
  done
  # A repo with no skills yet gets a header-only table. An empty placeholder row
  # would be a row naming no path, which the laid-down eval reads as a broken
  # row rather than as an empty pack.
  # A literal placeholder line replaced by the rows; printf %s keeps the rows'
  # own newlines intact.
  awk -v rows="$rows" '{ if ($0 == "__SKILL_ROWS__") printf "%s", rows; else print }' \
    "$TEMPLATE_DIR/.claude/skills/INDEX.md"
}

render_board() {
  sed -e "s|__AGENT_SLUG__|${AGENT_SLUG:-}|" \
      -e "s|__BOARD_ADAPTER__|${BOARD_ADAPTER:-}|" \
      -e "s|__BOARD_ID__|${BOARD_ID:-}|" \
      "$TEMPLATE_DIR/board.yml"
}

added=0; updated=0; kept=0; unchanged=0
report_kept=""

sync_one() { # sync_one <relative path>
  local rel="$1" dest="$TARGET/$rel" body hash header first existing_hash existing_body
  # VERSION carries no marker: it is one line that has to stay machine-readable
  # (the runner reads it with head -n1), and once a repo owns a skill pack the
  # version of that pack is the repo's to bump, not the template's.
  if [ "$rel" = ".claude/skills/VERSION" ]; then
    if [ -f "$dest" ]; then unchanged=$((unchanged + 1)); return 0; fi
    added=$((added + 1))
    [ "$DRY_RUN" = "yes" ] && return 0
    mkdir -p "$(dirname "$dest")"
    cat "$TEMPLATE_DIR/$rel" > "$dest"
    return 0
  fi
  body="$(render "$rel")"
  hash="$(printf '%s\n' "$body" | body_hash)"
  header="$(marker_prefix "$rel")$MARKER_TEXT v$VERSION sha256:$hash$(marker_suffix "$rel")"

  if [ -f "$dest" ]; then
    case "$rel" in
      *.sh) first="$(sed -n 2p "$dest")" ;;
      *)    first="$(head -n1 "$dest")" ;;
    esac
    case "$first" in
      *"$MARKER_TEXT"*) ;;
      *)
        # No marker: the project wrote this file itself. Never touch it.
        kept=$((kept + 1)); report_kept="$report_kept
    kept  $rel (project file, no template marker)"
        return 0 ;;
    esac
    existing_hash="$(printf '%s' "$first" | sed -n 's/.*sha256:\([0-9a-f]\{64\}\).*/\1/p')"
    case "$rel" in
      *.sh) existing_body="$( { head -n1 "$dest"; tail -n +3 "$dest"; } | body_hash)" ;;
      *)    existing_body="$(tail -n +2 "$dest" | body_hash)" ;;
    esac
    if [ "$existing_hash" != "$existing_body" ]; then
      # Marked, but the body no longer matches what the template wrote: the
      # project edited it. Leave it, and say so.
      kept=$((kept + 1)); report_kept="$report_kept
    kept  $rel (edited since the template wrote it)"
      return 0
    fi
    if [ "$existing_hash" = "$hash" ]; then
      unchanged=$((unchanged + 1))
      return 0
    fi
    updated=$((updated + 1))
  else
    added=$((added + 1))
  fi

  [ "$DRY_RUN" = "yes" ] && return 0
  mkdir -p "$(dirname "$dest")"
  case "$rel" in
    *.sh)
      # A shebang must stay on line 1, so a script carries its marker on line 2
      # and the body hash covers the shebang along with the rest.
      { printf '%s\n' "$body" | head -n1
        printf '%s\n' "$header"
        printf '%s\n' "$body" | tail -n +2
      } > "$dest"
      chmod +x "$dest" ;;
    *)
      { printf '%s\n' "$header"; printf '%s\n' "$body"; } > "$dest" ;;
  esac
}

FILES="
AGENTS.md
board.yml
.claude/skills/INDEX.md
.claude/skills/RULE-MAP.md
.claude/skills/VERSION
.claude/skills/evals/run-evals.sh
.claude/skills/evals/exempt.txt
.claude/hooks/board-write-guard.sh
.github/workflows/skills-evals.yml
.github/workflows/pr-title.yml
"

# The index is seeded from the skills already on disk, so the skills directory
# has to exist before it is rendered.
mkdir -p "$TARGET/.claude/skills"

# A workflow the template lays down declares a check by name. A repo that
# already declares a check with that name, from a different file, would end up
# with two checks answering to one name: branch protection and any automerge
# gate then watch whichever one GitHub reported last. So before writing a
# workflow, look for its job name in the workflows the repo already has, and
# skip it if somebody got there first.
check_name_taken() { # check_name_taken <job name> <this workflow's filename>
  local job="$1" self="$2" f
  for f in "$TARGET"/.github/workflows/*.yml "$TARGET"/.github/workflows/*.yaml; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "$self" ] && continue
    grep -qE "^[[:space:]]{2}$job:[[:space:]]*$" "$f" && return 0
  done
  return 1
}

for rel in $FILES; do
  [ -n "$rel" ] || continue
  [ -f "$TEMPLATE_DIR/$rel" ] || die "template is missing $rel" \
    "reinstall the create-agent template"
  case "$rel" in
    .github/workflows/*.yml)
      job="$(basename "$rel" .yml)"
      if [ ! -f "$TARGET/$rel" ] && check_name_taken "$job" "$(basename "$rel")"; then
        kept=$((kept + 1)); report_kept="$report_kept
    kept  $rel (this repo already declares a '$job' check elsewhere)"
        continue
      fi
      ;;
  esac
  sync_one "$rel"
done

say "sync-project v$VERSION -> ${REMOTE_REPO:-$TARGET}"
say "  $added added, $updated updated, $unchanged already current, $kept left alone${report_kept}"
[ "$DRY_RUN" = "yes" ] && say "  (dry run: nothing was written)"

if [ "$OPEN_PR" = "yes" ] && [ "$DRY_RUN" != "yes" ]; then
  if [ $((added + updated)) -eq 0 ]; then
    say "  $REMOTE_REPO is already aligned; no pull request needed"
  else
    branch="agent-template-sync-$VERSION"
    git -C "$TARGET" checkout -q -b "$branch"
    git -C "$TARGET" add -A AGENTS.md board.yml .claude .github
    git -C "$TARGET" -c user.name="agent-template" \
        -c user.email="agent-template@users.noreply.github.com" \
        commit -q -m "agent-template $VERSION: the standard agent layout

Lays down .claude/skills/ (index, rule map, version, evals), AGENTS.md,
board.yml, the pr-title check and the board-write guard. Files a project has
edited are left alone."
    git -C "$TARGET" push -q -u origin "$branch"
    gh pr create --repo "$REMOTE_REPO" --head "$branch" \
      --title "agent-template $VERSION: the standard agent layout" \
      --body "Laid down by \`sync-project.sh\`: $added added, $updated updated, $kept left alone. Template-owned files carry a header naming the template version and a hash of their body; a file the project has edited is never overwritten." \
      || say "  WARNING: branch $branch pushed, but opening the pull request failed. Open it by hand."
  fi
fi
[ -n "$CLONE_TMP" ] && rm -rf "$CLONE_TMP"
exit 0
