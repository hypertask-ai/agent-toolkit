#!/usr/bin/env bash
# Runner checks use an isolated copied suite, so a deliberate crash cannot stop the real suite.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { printf 'PASS %-36s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL %-36s %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/evals" "$TMP/scripts"
cp "$ROOT/evals/run-evals.sh" "$TMP/evals/run-evals.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/scripts/triage.sh"
printf '# no correction cases\n' > "$TMP/evals/cases.jsonl"
for test_file in agent-chat.test.py reply-formatting.test.py agent-kick.test.py \
                 ticket-ack.test.py agent-events.test.py; do
  printf 'print("stub passed")\n' > "$TMP/evals/$test_file"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/evals/agent-pause.test.sh"
cat > "$TMP/evals/command-policy.test.sh" <<'EOF'
#!/usr/bin/env bash
exit 23
EOF
cat > "$TMP/evals/identity-shim.test.sh" <<'EOF'
#!/usr/bin/env bash
printf 'PASS continued-after-crash runner continued after the crashing file\n'
EOF
chmod +x "$TMP/evals/run-evals.sh" "$TMP/evals/command-policy.test.sh" \
  "$TMP/evals/identity-shim.test.sh" "$TMP/scripts/triage.sh"

set +e
EVAL_TEST_TIMEOUT_SECONDS=0 bash "$TMP/evals/run-evals.sh" > "$TMP/output" 2>&1
status=$?
set -e
if [ "$status" -eq 1 ] \
   && grep -q '^FAIL command-policy.test.sh exited 23$' "$TMP/output" \
   && grep -q '^PASS continued-after-crash ' "$TMP/output" \
   && grep -q '^8 subtest file(s) run, 1 failed$' "$TMP/output" \
   && grep -q '^failing subtest files: command-policy.test.sh$' "$TMP/output"; then
  ok crashing-subtest-reported "a crashing file is named and later files plus the summary still run"
else
  bad crashing-subtest-reported "status=$status output=$(cat "$TMP/output")"
fi

subtests=8
for test_file in conf-data.test.sh conf-sinks.test.sh; do
  printf '#!/usr/bin/env bash\nprintf "PASS %s stub passed\\n"\n' "$test_file" > "$TMP/evals/$test_file"
  chmod +x "$TMP/evals/$test_file"
  subtests=$((subtests + 1))
  set +e
  EVAL_TEST_TIMEOUT_SECONDS=0 bash "$TMP/evals/run-evals.sh" > "$TMP/output" 2>&1
  status=$?
  set -e
  if [ "$status" -eq 1 ] \
     && grep -q "^PASS $test_file stub passed$" "$TMP/output" \
     && grep -q "^$subtests subtest file(s) run, 1 failed$" "$TMP/output" \
     && grep -q '^failing subtest files: command-policy.test.sh$' "$TMP/output"; then
    ok "$test_file-wired" "the copied runner runs each available conf check after a crash"
  else
    bad "$test_file-wired" "status=$status output=$(cat "$TMP/output")"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
