#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export SATCHEL_DIR="$tmp/state"
mkdir -p "$HOME" "$SATCHEL_DIR/sync/.git" "$SATCHEL_DIR/sync/machines/testbox"
printf 'MACHINE=testbox\nSYNC_URL=test\nSATCHEL_UID=1000\nSATCHEL_GID=1000\n' > "$SATCHEL_DIR/config"

source <(sed '$d' "$repo_dir/satchel")
load_config
ENGINE=docker

notes="$(baseline_notes_file)"
[ -z "$(baseline_marker_version)" ]
printf '<!-- satchel-machine-baseline version=1 generated=2026-07-22T00:00:00Z -->\n# Machine baseline\n' > "$notes"
[ "$(baseline_marker_version)" = 1 ]

mkdir -p "$tmp/claude/.claude" "$tmp/codex/.codex"
! baseline_authenticated claude "$tmp/claude"
touch "$tmp/claude/.claude/.credentials.json" "$tmp/codex/.codex/auth.json"
baseline_authenticated claude "$tmp/claude"
baseline_authenticated codex "$tmp/codex"

# Baseline refreshes launched by `satchel init` must perform the same agent-
# home ownership repair as ordinary sessions before Codex reads config.toml.
repaired=()
fix_home_ownership() { repaired+=("$1"); }
prepare_baseline_home "$tmp/codex"
[ "${repaired[0]}" = "$tmp/codex" ]
[ "${repaired[1]}" = "$SATCHEL_DIR/sync/machines/testbox" ]

compose_baseline_run_args claude "$tmp/claude"
[[ " ${RUN_ARGS[*]} " == *" /:/host:ro "* ]]
[[ " ${RUN_ARGS[*]} " == *"/machines/testbox:/home/satchel/machine"* ]]
[[ " ${RUN_ARGS[*]} " != *" --privileged "* ]]
[[ " ${RUN_ARGS[*]} " != *" --pid=host "* ]]
[[ " ${RUN_ARGS[*]} " != *"docker.sock"* ]]

old="$tmp/old" new="$tmp/new"
printf '# Notes\n- hostname: testbox\n' > "$old"
printf '# Notes\n- hostname: testbox\n- storage: zfs\n' > "$new"
baseline_secret_scan "$old" "$new"
printf '# Notes\n- hostname: testbox\n- api_token = abcdefghijklmnopqrstuvwxyz012345\n' > "$new"
! baseline_secret_scan "$old" "$new"
printf '# Notes\n- hostname: testbox\n- https://admin:correct-horse-battery-staple@example.test\n' > "$new"
! baseline_secret_scan "$old" "$new"

printf 'ok: machine baseline state, mounts, auth, and secret scan\n'
