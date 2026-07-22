#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export SATCHEL_DIR="$tmp/state"
mkdir -p "$HOME" "$SATCHEL_DIR"
printf 'MACHINE=testbox\nSYNC_URL=%s/origin.git\n' "$tmp" > "$SATCHEL_DIR/config"

# Load functions without invoking main.
source <(sed '$d' "$repo_dir/satchel")
load_config

# A real clone with a local bare origin, so quiet_push can actually push.
git init -q --bare -b main "$tmp/origin.git"
git init -q -b main "$SYNC_DIR"
git_sync remote add origin "$tmp/origin.git"
ensure_sync_identity
touch "$SYNC_DIR/seed"
git_sync add -A && git_sync commit -q -m init && git_sync push -qu origin main

count() { git_sync rev-list --count HEAD; }
origin_head() { git -C "$tmp/origin.git" rev-parse main; }

# First session commit: nothing to roll into.
touch "$SYNC_DIR/one"; quiet_push "session: sample on testbox"
[ "$(count)" = 2 ]

# Second session within the hour, same marker: folded into the previous
# commit, and the force-push kept origin in step.
touch "$SYNC_DIR/two"; quiet_push "session: sample on testbox"
[ "$(count)" = 2 ]
[ "$(origin_head)" = "$(git_sync rev-parse HEAD)" ]
grep -q two <(git_sync show --stat --format= HEAD)

# A different marker never rolls up.
touch "$SYNC_DIR/three"; quiet_push "session: other on testbox"
[ "$(count)" = 3 ]

# An old marker never rolls up: age out the last commit and re-sync origin.
git_sync commit -q --amend --no-edit --date "2 hours ago"
git_sync push -qf origin main
touch "$SYNC_DIR/four"; quiet_push "session: other on testbox"
[ "$(count)" = 4 ]

# Non-session commits never roll up, even back to back.
touch "$SYNC_DIR/five"; quiet_push "add machine testbox"
touch "$SYNC_DIR/six"; quiet_push "add machine testbox"
[ "$(count)" = 6 ]

# Divergence: another machine pushed since our last sync. The amend must be
# abandoned and the session land as a plain commit on top of theirs.
touch "$SYNC_DIR/seven"; quiet_push "session: roll on testbox"
other="$tmp/other"
git clone -q "$tmp/origin.git" "$other"
git -C "$other" -c user.name=o -c user.email=o@o commit -q --allow-empty -m "session: sample on elsewhere"
git -C "$other" push -q origin main
touch "$SYNC_DIR/eight"; quiet_push "session: roll on testbox"   # same subject, fresh: tries to amend
grep -q elsewhere <(git_sync log --oneline)
grep -q eight <(git_sync show --stat --format= HEAD)
! grep -q seven <(git_sync show --stat --format= HEAD)
[ "$(origin_head)" = "$(git_sync rev-parse HEAD)" ]

# Re-running init on a stale clone must integrate another machine's commit
# before pushing its own registration, rather than misdiagnosing the normal
# non-fast-forward rejection as a read-only deploy key.
git -C "$other" pull -q --rebase
git -C "$other" -c user.name=o -c user.email=o@o commit -q --allow-empty -m "remote before re-init"
git -C "$other" push -q origin main
touch "$SYNC_DIR/nine"
sync_machine_registration testbox
grep -q "remote before re-init" <(git_sync log --oneline)
grep -q nine <(git_sync show --stat --format= HEAD)
[ "$(origin_head)" = "$(git_sync rev-parse HEAD)" ]

printf 'ok: sync commit rollup\n'
