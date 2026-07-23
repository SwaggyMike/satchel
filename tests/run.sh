#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

for required_command in git jq ssh-agent; do
  command -v "$required_command" >/dev/null \
    || { printf 'missing test dependency: %s\n' "$required_command" >&2; exit 1; }
done

bash -n satchel
bash -n install.sh
git diff --check
git diff --cached --check

for test_file in tests/test_*.sh; do
  printf 'RUN %s\n' "$test_file"
  bash "$test_file"
done
