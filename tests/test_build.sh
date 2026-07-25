#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_dir/tests/lib.sh"
tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT

mkdir -p "$tmp/scripts"
cp -R "$repo_dir/src" "$tmp/src"
cp "$repo_dir/scripts/build.sh" "$tmp/scripts/build.sh"
cp "$repo_dir/satchel" "$tmp/satchel"

# A clean checkout's committed artifact matches its ordered source modules.
bash "$tmp/scripts/build.sh" --check

# Drift is rejected, a normal build repairs it, and the result remains an
# executable, syntactically valid, self-contained artifact.
printf '\n# test-only drift\n' >> "$tmp/src/51-skills.sh"
refute bash "$tmp/scripts/build.sh" --check
bash "$tmp/scripts/build.sh"
bash "$tmp/scripts/build.sh" --check
[ -x "$tmp/satchel" ]
bash -n "$tmp/satchel"
grep -q 'test-only drift' "$tmp/satchel"

set +e
bash "$tmp/scripts/build.sh" unexpected >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ]

printf 'ok: modular source build and drift detection\n'
