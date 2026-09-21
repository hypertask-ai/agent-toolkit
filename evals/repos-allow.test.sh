#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TEMPLATE="$TMP/template"
CHECKOUT="$TMP/app"
CONF_DIR="$TMP/home/.config/hypertask-agents"
cp -a "$ROOT" "$TEMPLATE"
mkdir -p "$CHECKOUT"
(
  cd "$CHECKOUT"
  git init -q -b production
  touch README.md
  git add README.md
  git -c user.name=test -c user.email=test@example.com commit -qm init
  git remote add origin git@github.com:example/generated-app.git
  git update-ref refs/remotes/origin/production HEAD
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/production
  git switch -qc work
)
printf '# key,path,github slug,base branch,memory cap,pull request labels...\napp,%s,,,,full-ci\n' "$CHECKOUT" > "$TEMPLATE/repos.allow"

HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" AGENT_CONFIG_DIR="$CONF_DIR" \
  SKIP_TEMPLATE_EVALS=yes SKIP_COMPANY_SKILLS=yes \
  AGENT_TEMPLATE_INSTALL_STATE="$TMP/state/install-state" \
  bash "$TEMPLATE/install.sh" --dest "$TMP/installed" --bin "$TMP/bin" --no-host-notes \
  > "$TMP/install.out" 2> "$TMP/install.err"

expected="app,$CHECKOUT,example/generated-app,production,,full-ci"
if [ "$(sed -n '2p' "$CONF_DIR/repos.allow")" = "$expected" ] \
   && [ "$(sed -n '2p' "$TMP/installed/repos.allow")" = "$expected" ] \
   && ! grep -q 'example/generated-app\|production' "$TEMPLATE/repos.allow"; then
  printf 'PASS %-36s %s\n' install-generates-repo-identity \
    'origin slug and origin/HEAD branch are discovered at install time'
else
  printf 'FAIL %-36s expected=%s actual=%s stderr=%s\n' install-generates-repo-identity \
    "$expected" "$(cat "$CONF_DIR/repos.allow" 2>/dev/null || true)" "$(cat "$TMP/install.err")"
  exit 1
fi

printf '# existing host policy\napp,%s,example/generated-app,production,3G\n' "$CHECKOUT" > "$CONF_DIR/repos.allow"
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" AGENT_CONFIG_DIR="$CONF_DIR" \
  SKIP_TEMPLATE_EVALS=yes SKIP_COMPANY_SKILLS=yes \
  AGENT_TEMPLATE_INSTALL_STATE="$TMP/state/install-state" \
  bash "$TEMPLATE/install.sh" --dest "$TMP/installed" --bin "$TMP/bin" --no-host-notes \
  > "$TMP/update.out" 2> "$TMP/update.err"

expected="app,$CHECKOUT,example/generated-app,production,3G,full-ci"
if [ "$(sed -n '2p' "$CONF_DIR/repos.allow")" = "$expected" ] \
   && [ "$(sed -n '2p' "$TMP/installed/repos.allow")" = "$expected" ]; then
  printf 'PASS %-36s %s\n' install-adds-repo-label-defaults \
    'an update adds configured labels without replacing host repository policy'
else
  printf 'FAIL %-36s expected=%s actual=%s stderr=%s\n' install-adds-repo-label-defaults \
    "$expected" "$(cat "$CONF_DIR/repos.allow" 2>/dev/null || true)" "$(cat "$TMP/update.err")"
  exit 1
fi
