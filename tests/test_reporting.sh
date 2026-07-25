#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_dir/tests/lib.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export HOME="$tmp/home"
export SATCHEL_DIR="$tmp/state"
mkdir -p "$HOME" "$SATCHEL_DIR/sync/projects" "$SATCHEL_DIR/sync/machines/testbox" \
  "$SATCHEL_DIR/sync/skills/shared"
printf 'MACHINE=testbox\nSYNC_URL=\n' > "$SATCHEL_DIR/config"

source <(sed '$d' "$repo_dir/satchel")
load_config

# A host with no container engine is an ordinary state: a machine that has not
# installed Docker yet, or one where the daemon is simply stopped. Reporting
# commands exist to explain such a machine, so they must never abort on it.
#
# The original defect was subtle: `e="$(engine 2>/dev/null || true)"` looks
# guarded, but die's `exit` terminates the command substitution before `|| true`
# can run, so the assignment returned 1 and `set -e` killed the command. That
# made `satchel status` print one line and exit 1.
detect_engine() { printf ''; }
select_engine() { die "neither docker nor podman is available"; }
ENGINE=""

rc=0
status_out="$(cmd_status 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "cmd_status exited $rc with no container engine"
grep -q 'Satchel .* on testbox' <<< "$status_out" || fail "status lost its header"
grep -q 'engine: none' <<< "$status_out" || fail "status did not report a missing engine"
grep -q 'Commands:' <<< "$status_out" || fail "status stopped before the shim section"

rc=0
settings_out="$(cmd_settings 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "cmd_settings exited $rc with no container engine"
grep -q 'SATCHEL_ENGINE' <<< "$settings_out" || fail "settings stopped before SATCHEL_ENGINE"
grep -q 'SATCHEL_GID' <<< "$settings_out" || fail "settings table was truncated early"

# With an engine present the same commands must still name it.
detect_engine() { printf 'docker'; }
status_out="$(cmd_status 2>&1)" || fail "cmd_status failed with an engine present"
grep -q 'engine: docker' <<< "$status_out" || fail "status did not report the detected engine"

# select_engine still fails loudly for the paths that genuinely require one.
unset -f select_engine
detect_engine() { printf ''; }
ENGINE=""
rc=0
( select_engine ) >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "select_engine must still fail when no engine exists"

printf 'ok: reporting commands survive a host with no container engine\n'
