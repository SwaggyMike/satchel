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

# Every completed session is one ordinary, recoverable Git commit.
touch "$SYNC_DIR/one"; quiet_push "session: sample on testbox"
[ "$(count)" = 2 ]
touch "$SYNC_DIR/two"; quiet_push "session: sample on testbox"
[ "$(count)" = 3 ]
[ "$(origin_head)" = "$(git_sync rev-parse HEAD)" ]
grep -q two <(git_sync show --stat --format= HEAD)

# Commit subjects do not affect that behavior.
touch "$SYNC_DIR/three"; quiet_push "session: other on testbox"
[ "$(count)" = 4 ]

# Non-session changes use the same plain commit path.
touch "$SYNC_DIR/four"; quiet_push "add machine testbox"
touch "$SYNC_DIR/five"; quiet_push "add machine testbox"
[ "$(count)" = 6 ]

other="$tmp/other"
git clone -q "$tmp/origin.git" "$other"

# An interrupted launch can leave a legitimate machine path-cache change
# uncommitted. The next quiet pull preserves it while integrating remote work.
git -C "$other" pull -q --rebase
git -C "$other" -c user.name=o -c user.email=o@o commit -q --allow-empty -m "remote before dirty pull"
git -C "$other" push -q origin main
printf 'local cache\n' > "$SYNC_DIR/local-dirty"
quiet_pull
grep -q 'remote before dirty pull' <(git_sync log --oneline)
grep -q '^local cache$' "$SYNC_DIR/local-dirty"
[ -n "$(git_sync status --porcelain -- local-dirty)" ]

# Offline startup remains best-effort, but a real rebase conflict must stop
# startup instead of leaving Satchel to operate in a half-rebased Sync Repo.
rm "$SYNC_DIR/local-dirty"
printf 'base\n' > "$SYNC_DIR/conflict"
git_sync add conflict
git_sync commit -q -m "conflict base"
git_sync push -q
git -C "$other" pull -q --rebase
printf 'local\n' > "$SYNC_DIR/conflict"
git_sync commit -qam "local conflict"
printf 'remote\n' > "$other/conflict"
git -C "$other" -c user.name=o -c user.email=o@o commit -qam "remote conflict"
git -C "$other" push -q
rc=0
quiet_pull >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ]
sync_needs_recovery
[ -n "$(git_sync diff --name-only --diff-filter=U)" ]
git_sync rebase --abort
git_sync reset -q --hard origin/main
! sync_needs_recovery

# A clean repository with an unavailable remote still starts from local state.
timeout() { return 1; }
quiet_pull >/dev/null 2>&1
unset -f timeout

# A user interrupt is not an offline pull. It must stop session startup rather
# than print a warning and continue through later initialization.
timeout() { return 130; }
rc=0
quiet_pull >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 130 ]
unset -f timeout

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

# A conflict during session-finalization stops before push and clearly leaves
# the new handoff commit recoverable in the local Sync Repo.
printf 'base\n' > "$SYNC_DIR/finalize-conflict"
quiet_push "finalize conflict base"
git -C "$other" pull -q --rebase
printf 'local\n' > "$SYNC_DIR/finalize-conflict"
printf 'remote\n' > "$other/finalize-conflict"
git -C "$other" -c user.name=o -c user.email=o@o commit -qam "remote finalize conflict"
git -C "$other" push -q
push_output="$(quiet_push "session: finalize conflict" 2>&1)"
sync_needs_recovery
grep -q 'committed locally' <<< "$push_output"
git_sync rebase --abort
grep -q '^local$' "$SYNC_DIR/finalize-conflict"
[ "$(git_sync log -1 --format=%s)" = "session: finalize conflict" ]

printf 'ok: sync commits and recovery\n'
