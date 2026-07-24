#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export SATCHEL_DIR="$tmp/state"
mkdir -p "$HOME" "$SATCHEL_DIR"

source <(sed '$d' "$repo_dir/satchel")
MACHINE=testbox
SATCHEL_UID=1000
SATCHEL_GID=1000

# Empty leftovers are removed without ceremony.
mkdir -p "$SYNC_DIR"
prepare_sync_clone_destination
[ ! -e "$SYNC_DIR" ]

# Uncertain content is preserved instead of deleted, and the original path is
# made available for a clean clone.
mkdir -p "$SYNC_DIR"
printf 'unfinished\n' > "$SYNC_DIR/partial-file"
output="$(prepare_sync_clone_destination 2>&1)"
[ ! -e "$SYNC_DIR" ]
recovered="$(find "$SATCHEL_DIR/recovery" -mindepth 1 -maxdepth 1 -type d -name 'sync-*' -print -quit)"
[ -n "$recovered" ]
grep -q '^unfinished$' "$recovered/partial-file"
grep -q 'preserved incomplete Sync Repo files' <<< "$output"

# A symlink is never followed, moved, or replaced.
mkdir -p "$tmp/external"
ln -s "$tmp/external" "$SYNC_DIR"
! (prepare_sync_clone_destination 2>/dev/null)
[ -L "$SYNC_DIR" ]
[ -d "$tmp/external" ]
rm "$SYNC_DIR"

# End-to-end init recovers a partial destination and successfully clones the
# requested repository rather than entering the SSH-key retry loop.
origin="$tmp/origin.git"
git init -q --bare "$origin"
mkdir -p "$SYNC_DIR"
printf 'keep me\n' > "$SYNC_DIR/old-state"
engine() { printf 'test-engine'; }
select_engine() { ENGINE=test-engine; }
cmd_image() { :; }
sync_machine_registration() { :; }
offer_baseline_refresh() { :; }
cmd_init <<< $'office\n'"$origin"$'\n' >/dev/null 2>&1
[ -d "$SYNC_DIR/.git" ]
[ "$(git -C "$SYNC_DIR" remote get-url origin)" = "$origin" ]
[ -n "$(find "$SATCHEL_DIR/recovery" -type f -name old-state -print -quit)" ]

# Re-running init with a different URL fails before changing either the local
# config or the existing clone. Remote migration stays an explicit operation.
other_origin="$tmp/other-origin.git"
git init -q --bare "$other_origin"
cp "$CONFIG_FILE" "$tmp/config-before-mismatch"
! (cmd_init <<< $'office\n'"$other_origin"$'\n' >/dev/null 2>&1)
cmp "$tmp/config-before-mismatch" "$CONFIG_FILE"
[ "$(git -C "$SYNC_DIR" remote get-url origin)" = "$origin" ]

printf 'ok: init recovery and Sync Repo origin validation\n'
