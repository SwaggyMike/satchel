#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

plain="$(NO_COLOR=1 CLICOLOR_FORCE=1 TERM=xterm "$repo_dir/satchel" --help)"
if grep -q $'\033' <<< "$plain"; then
  printf 'FAIL: NO_COLOR output contains ANSI escapes\n' >&2
  exit 1
fi

default="$(env -u NO_COLOR TERM=xterm "$repo_dir/satchel" --help)"
if grep -q $'\033' <<< "$default"; then
  printf 'FAIL: piped output contains ANSI escapes by default\n' >&2
  exit 1
fi

colored="$(env -u NO_COLOR CLICOLOR_FORCE=1 TERM=xterm "$repo_dir/satchel" --help)"
if ! grep -q $'\033' <<< "$colored"; then
  printf 'FAIL: forced-color help output contains no ANSI color\n' >&2
  exit 1
fi

printf 'ok: output color behavior\n'
