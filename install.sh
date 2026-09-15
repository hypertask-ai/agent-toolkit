#!/usr/bin/env bash
# install.sh: put this template on a machine.
#
# This repo is the canonical copy. What ends up in ~/.claude/skills and
# ~/.local/bin is an installed copy, never the source of truth: edit here, then
# run this again. Re-running is safe and overwrites the installed copy.
#
# Usage:
#   ./install.sh [--dest DIR] [--bin DIR] [--dry-run] [-h|--help]
#
# Examples:
#   ./install.sh --dry-run          # show what would be copied where
#   ./install.sh                    # install for the current user
#
# It also clones or fast-forwards the shared company skills pack to
# ~/projects/company-skills, because every bot reads that pack before its own.
# SKIP_COMPANY_SKILLS=yes to leave it alone; COMPANY_SKILLS_DIR / _REPO to
# point it elsewhere.
#
# Failure contract: ERROR: <what happened>. Do this next: <one step>, non-zero.

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SRC="$(dirname "$SELF")"
DEST="$HOME/.claude/skills/create-agent"
BIN="${AGENT_BIN_DIR:-$HOME/.local/bin}"
SYSTEMD_USER_DIR="${AGENT_SYSTEMD_DIR:-$HOME/.config/systemd/user}"
DRY_RUN="no"

fail() { printf 'ERROR: %s. Do this next: %s\n' "$1" "$2" >&2; exit 1; }

# ---------- the shared company skills pack ----------
# Every bot reads a company pack before its own, so the pack has to exist on
# every host the template is installed on, not only the one where somebody
# remembered to clone it. Clone it if missing, fast-forward if present, and
# warn rather than fail if the host cannot reach GitHub: a stale pack still
# runs, a missing install does not.
COMPANY_SKILLS_REPO="${COMPANY_SKILLS_REPO:-git@github.com:hypertask-ai/company-skills.git}"
COMPANY_SKILLS_DIR="${COMPANY_SKILLS_DIR:-$HOME/projects/company-skills}"

sync_company_skills() {
  if [ "${SKIP_COMPANY_SKILLS:-no}" = "yes" ]; then
    echo "company pack: skipped (SKIP_COMPANY_SKILLS=yes)"
    return 0
  fi
  if [ -d "$COMPANY_SKILLS_DIR/.git" ]; then
    if git -C "$COMPANY_SKILLS_DIR" pull --ff-only -q 2>/dev/null; then
      echo "company pack: up to date at $COMPANY_SKILLS_DIR"
    else
      echo "WARNING: could not fast-forward $COMPANY_SKILLS_DIR (local changes, or no network). Using the copy that is there." >&2
    fi
  else
    mkdir -p "$(dirname "$COMPANY_SKILLS_DIR")"
    if git clone -q "$COMPANY_SKILLS_REPO" "$COMPANY_SKILLS_DIR" 2>/dev/null; then
      echo "company pack: cloned to $COMPANY_SKILLS_DIR"
    else
      echo "WARNING: could not clone $COMPANY_SKILLS_REPO to $COMPANY_SKILLS_DIR. Bots on this host will run on their own pack only." >&2
    fi
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    --bin) BIN="$2"; shift 2 ;;
    --dry-run) DRY_RUN="yes"; shift ;;
    -h|--help) sed -n '2,16p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown argument $1" "run ./install.sh --help" ;;
  esac
done

for item in SKILL.md MAINTAINER.md VERSION CHANGELOG.md scripts adapters evals; do
  [ -e "$SRC/$item" ] || fail "$SRC/$item is missing" \
    "run install.sh from inside the template folder in the repo"
done

echo "source: $SRC"
echo "skill:  $DEST"
echo "docs:   $DEST/MAINTAINER.md"
echo "bin:    $BIN/agent-board-poll -> $DEST/scripts/agent-board-poll"
echo "bin:    $BIN/agent-template -> $DEST/scripts/agent-template"
echo "bin:    $BIN/agent-template-weekly -> $DEST/scripts/agent-template-weekly"
echo "version: $(cat "$SRC/VERSION")"

if [ "$DRY_RUN" = "yes" ]; then
  echo "company pack: would sync $COMPANY_SKILLS_REPO -> $COMPANY_SKILLS_DIR"
  echo "(dry run: nothing copied)"
  exit 0
fi

mkdir -p "$DEST" "$BIN"
rm -rf "$DEST/scripts" "$DEST/adapters" "$DEST/evals"
cp -a "$SRC/SKILL.md" "$DEST/SKILL.md"
cp -a "$SRC/MAINTAINER.md" "$DEST/MAINTAINER.md"
# The version travels with the installed copy, because that is what
# `agent-template feedback` reports and what a bug report has to name.
cp -a "$SRC/VERSION" "$DEST/VERSION"
cp -a "$SRC/CHANGELOG.md" "$DEST/CHANGELOG.md"
cp -a "$SRC/scripts" "$SRC/adapters" "$SRC/evals" "$DEST/"
chmod 755 "$DEST/scripts/create-agent.sh" "$DEST/scripts/agent-board-poll" \
          "$DEST/scripts/agent-template" "$DEST/scripts/agent-template-weekly" \
          "$DEST/evals/run-evals.sh"

# A symlink, so the installed runner and the installed skill can never drift
# apart, and so the runner still finds its adapters through readlink -f.
ln -sfn "$DEST/scripts/agent-board-poll" "$BIN/agent-board-poll"
ln -sfn "$DEST/scripts/agent-template" "$BIN/agent-template"
ln -sfn "$DEST/scripts/agent-template-weekly" "$BIN/agent-template-weekly"

bash "$DEST/scripts/create-agent.sh" --help >/dev/null \
  || fail "the installed create-agent.sh does not run" \
          "check bash and python3 are present, then re-run install.sh"
"$BIN/agent-board-poll" --help >/dev/null \
  || fail "the installed agent-board-poll does not run" \
          "check that $BIN is on PATH and the symlink resolves"
"$BIN/agent-template" --help >/dev/null \
  || fail "the installed agent-template does not run" \
          "check that $BIN is on PATH and the symlink resolves"
bash "$DEST/evals/run-evals.sh" >/dev/null \
  || fail "the installed eval cases do not pass" \
          "run $DEST/evals/run-evals.sh and read the failing case ids"

# The shared agent-board-poll@ unit pair is refreshed on every install, not
# only when a new agent is provisioned, so a fix to the unit (like the
# missing PATH that made every tick fail with "the hypertask CLI is not on
# PATH") reaches every host on the next install.sh, not only new agents.
# systemd --user may not have a session bus on every host (a bare CI runner,
# a container): warn and move on instead of failing the whole install.
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$DEST/scripts/lib/core.sh"
  core_write_poll_units "$SYSTEMD_USER_DIR" "$BIN"

  # agent-template-update.timer is how a bot host stays in sync with this
  # template on its own, without anyone explaining the fix to it by hand:
  # once a day it pulls AGENT_TEMPLATE_REPO, reinstalls, and brings any
  # old-schema conf forward. Refreshed on every install.sh run so a fix to
  # the schedule or the unit reaches every host, and re-enabling here is
  # what makes that refresh idempotent whether or not the timer already
  # exists on this machine.
  cat > "$SYSTEMD_USER_DIR/agent-template-update.service" <<EOF
[Unit]
Description=Bring this host's agent confs and units up to date with the template

[Service]
# Type=oneshot: systemd refuses to start a second run while one is active,
# and agent-template update's own re-exec guard covers the rest.
Type=oneshot
Environment=HOME=%h
Environment=PATH=%h/.local/bin:%h/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$BIN/agent-template update
EOF
  cat > "$SYSTEMD_USER_DIR/agent-template-update.timer" <<EOF
[Unit]
Description=Daily agent-template update

[Timer]
OnCalendar=*-*-* 06:30:00
Persistent=true
AccuracySec=1m
Unit=agent-template-update.service

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now agent-template-update.timer
  echo "poll units: $SYSTEMD_USER_DIR/agent-board-poll@.service + .timer (refreshed, daemon-reload done)"
  echo "update timer: agent-template-update.timer, daily 06:30 local ($(systemctl --user list-timers agent-template-update.timer --no-pager 2>/dev/null | sed -n '2p'))"
else
  echo "WARNING: no systemd --user session here: skipped refreshing agent-board-poll@.service/.timer and agent-template-update.timer" >&2
fi

sync_company_skills

echo "installed. Next: run create-agent.sh --help, or agent-board-poll --once --dry-run <slug>"
echo "corrections: agent-template feedback --what ... --got ... --expected ..."
