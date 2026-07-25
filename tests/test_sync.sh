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

# Skill removal uses the same ordinary commit-and-push path immediately,
# instead of waiting for a later session boundary.
ensure_skill_library
mkdir -p "$SYNC_DIR/skills/shared/removable"
printf '%s\n' '---' 'name: removable' 'description: removable' '---' \
  > "$SYNC_DIR/skills/shared/removable/SKILL.md"
quiet_push "skills command baseline"
cmd_skills remove removable >/dev/null 2>&1
[ ! -e "$SYNC_DIR/skills/shared/removable" ]
[ "$(git_sync log -1 --format=%s)" = "skills: remove removable" ]
[ "$(origin_head)" = "$(git_sync rev-parse HEAD)" ]
! git -C "$tmp/origin.git" ls-tree -r --name-only main \
  | grep -q '^skills/shared/removable/'

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

# A conflict must never leave the clone mid-rebase: every later command would
# then die parsing conflict markers, and the session would refuse to start.
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
pull_output="$(quiet_pull 2>&1)" || rc=$?
[ "$rc" -eq 0 ]                                  # startup continues
! sync_needs_recovery                            # and the clone is clean again
[ -z "$(git_sync diff --name-only --diff-filter=U)" ]
grep -q 'backed out rather than guess' <<< "$pull_output"
grep -q '^local$' "$SYNC_DIR/conflict"           # local work survives
[ "$(git_sync log -1 --format=%s)" = "local conflict" ]
git_sync reset -q --hard origin/main

# The recovery guard used to sit behind has_upstream. An interrupted rebase
# detaches HEAD, so '@{u}' stops resolving and the guard was skipped in exactly
# the state it exists for — the session then died parsing conflict markers.
printf 'local2\n' > "$SYNC_DIR/conflict"
git_sync commit -qam "local conflict 2"
git -C "$other" pull -q --rebase
printf 'remote2\n' > "$other/conflict"
git -C "$other" -c user.name=o -c user.email=o@o commit -qam "remote conflict 2"
git -C "$other" push -q
git_sync pull --rebase >/dev/null 2>&1 || true
sync_needs_recovery
! git_sync rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1   # HEAD really is detached
rc=0
quiet_pull >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ]
! sync_needs_recovery
git_sync reset -q --hard origin/main

# Two machines editing the same shared registry between syncs conflicts. Satchel
# does not try to merge it: it backs out to a clean tree, keeps the local
# commit, and tells the user. The session must survive either way — that is the
# property that matters, not automatic resolution.
printf '{"github.com/me/base":{"status":"ignored"}}\n' > "$SYNC_DIR/repositories.json"
git_sync add repositories.json
git_sync commit -q -m "registry base"
git_sync push -q
git -C "$other" pull -q --rebase
printf '{"github.com/me/base":{"status":"ignored"},"github.com/me/alpha":{"status":"ignored"}}\n' \
  > "$SYNC_DIR/repositories.json"
git_sync commit -qam "local tracks alpha"
printf '{"github.com/me/base":{"status":"ignored"},"github.com/me/beta":{"status":"ignored"}}\n' \
  > "$other/repositories.json"
git -C "$other" -c user.name=o -c user.email=o@o commit -qam "remote tracks beta"
git -C "$other" push -q
rc=0
pull_output="$(quiet_pull 2>&1)" || rc=$?
[ "$rc" -eq 0 ]                                  # startup is never blocked
! sync_needs_recovery                            # and never left mid-rebase
[ -z "$(git_sync diff --name-only --diff-filter=U)" ]
grep -q 'backed out rather than guess' <<< "$pull_output"
grep -q 'nothing local was lost' <<< "$pull_output"
jq -e '.["github.com/me/alpha"]' "$SYNC_DIR/repositories.json" >/dev/null  # local kept
[ "$(git_sync log -1 --format=%s)" = "local tracks alpha" ]
git_sync reset -q --hard origin/main

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

# A conflict during session finalization keeps the handoff commit
# and leaves the clone usable, so the NEXT session still starts normally.
printf 'base\n' > "$SYNC_DIR/finalize-conflict"
quiet_push "finalize conflict base"
git -C "$other" pull -q --rebase
printf 'local\n' > "$SYNC_DIR/finalize-conflict"
printf 'remote\n' > "$other/finalize-conflict"
git -C "$other" -c user.name=o -c user.email=o@o commit -qam "remote finalize conflict"
git -C "$other" push -q
push_output="$(quiet_push "session: finalize conflict" 2>&1)"
! sync_needs_recovery
grep -q 'committed locally' <<< "$push_output"
grep -q '^local$' "$SYNC_DIR/finalize-conflict"
[ "$(git_sync log -1 --format=%s)" = "session: finalize conflict" ]
git_sync reset -q --hard origin/main

# A rejected push (read-only remote) must keep the commit and say so, rather
# than reporting success or losing the session's work.
git_sync reset -q --hard origin/main
printf 'x\n' > "$SYNC_DIR/rejected"
timeout() { case "$*" in *push*) return 1 ;; *) shift 2; "$@" ;; esac; }
push_output="$(quiet_push "session: rejected push" 2>&1)"
unset -f timeout
grep -q 'committed locally' <<< "$push_output"
[ "$(git_sync log -1 --format=%s)" = "session: rejected push" ]
git_sync reset -q --hard origin/main

# cmd_sync is the command every warning tells the user to run; it had no test.
printf 'y\n' > "$SYNC_DIR/explicit"
cmd_sync >/dev/null 2>&1
[ "$(origin_head)" = "$(git_sync rev-parse HEAD)" ]
git -C "$other" pull -q --rebase
[ -f "$other/explicit" ]

# A degraded Sync Repo disables syncing without pretending it is unconfigured.
SYNC_DEGRADED=0
degrade_sync "test reason" >/dev/null 2>&1
[ "$SYNC_DEGRADED" -eq 1 ]
! sync_ready
quiet_push "must be a no-op" >/dev/null 2>&1
SYNC_DEGRADED=0
sync_ready

printf 'ok: sync commits, conflict backout, and recovery\n'
