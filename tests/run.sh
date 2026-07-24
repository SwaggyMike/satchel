#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

for required_command in git jq ssh-add ssh-agent ssh-keygen; do
  command -v "$required_command" >/dev/null \
    || { printf 'missing test dependency: %s\n' "$required_command" >&2; exit 1; }
done

bash scripts/build.sh --check
bash -n satchel
bash -n install.sh
bash -n scripts/build.sh
bash -n scripts/session-smoke.sh
for source_file in src/[0-9][0-9]-*.sh; do
  bash -n "$source_file"
done
# Whitespace hygiene applies to what is staged or committed, not to whatever
# the developer happens to have open: an unrelated dirty edit must not stop the
# suite from running at all.
git diff --cached --check

# Every file runs. Aborting on the first failure used to hide whole subsystems
# (a failure in test_skills.sh silently skipped test_sync.sh and
# test_update_check.sh), and a bare 'set -e' death printed nothing at all.
passed=0
failed=0
failed_files=()
for test_file in tests/test_*.sh; do
  printf 'RUN %-32s' "$test_file"
  if output="$(bash "$test_file" 2>&1)"; then
    printf 'ok\n'
    passed=$((passed + 1))
  else
    printf 'FAIL\n'
    printf '%s\n' "$output" | sed 's/^/    | /'
    failed=$((failed + 1))
    failed_files+=("$test_file")
  fi
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  printf 'failing: %s\n' "${failed_files[*]}"
  exit 1
fi
