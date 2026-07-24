#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export SATCHEL_DIR="$tmp/state"
mkdir -p \
  "$HOME" \
  "$SATCHEL_DIR/sync/.git" \
  "$SATCHEL_DIR/sync/skills/shared" \
  "$SATCHEL_DIR/sync/machines/testbox" \
  "$tmp/work/app"
printf 'MACHINE=testbox\nSYNC_URL=test\nSATCHEL_UID=1000\nSATCHEL_GID=1000\n' \
  > "$SATCHEL_DIR/config"

source <(sed '$d' "$repo_dir/satchel")
load_config
podman_rootless() { return 1; }
selinux_active() { return 1; }
SSH_STATE=none

# The unattended handoff writer gets only the conversation home. Its working
# directory exists inside the disposable image but the project is not mounted.
WITH_DIRS=("$tmp/work/extra")
HOST_MODE=1
mkdir -p "${WITH_DIRS[0]}" "$tmp/agent-home"
compose_handoff_run_args codex "$tmp/agent-home" "$tmp/work/app"
args=" ${RUN_ARGS[*]} "
[[ "$args" == *" $tmp/agent-home:/home/satchel "* ]]
[[ "$args" == *" -w $tmp/work/app "* ]]
[[ "$args" == *" --tmpfs $tmp/work/app:rw,nosuid,nodev,noexec,mode=1777 "* ]]
[[ "$args" != *" $tmp/work/app:$tmp/work/app "* ]]
[[ "$args" != *" $tmp/work/extra:"* ]]
[[ "$args" != *"/host"* ]]
[[ "$args" != *"SSH_AUTH_SOCK"* ]]
[[ "$args" != *"SATCHEL_SKILLS_DIR"* ]]
[[ "$args" != *"$SATCHEL_DIR/sync"* ]]
[[ "$args" != *"DISPLAY"* ]]
[[ "$args" == *" --cap-drop ALL "* ]]
[[ "$args" == *" --security-opt no-new-privileges "* ]]
grep -q -- 'claude --continue --strict-mcp-config --tools ""' "$repo_dir/src/53-handoffs.sh"
grep -q -- 'codex exec resume .*--ignore-user-config --ignore-rules' "$repo_dir/src/53-handoffs.sh"

# Model Podman's stricter workdir validation: a missing -w path fails unless
# the launch creates that exact destination as tmpfs first.
podman_like="$tmp/podman-like"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'workdir=""' \
  'tmpfs=""' \
  'prev=""' \
  'for arg in "$@"; do' \
  '  case "$prev" in' \
  '    -w) workdir="$arg" ;;' \
  '    --tmpfs) tmpfs="${arg%%:*}" ;;' \
  '  esac' \
  '  prev="$arg"' \
  'done' \
  '[ -d "$workdir" ] || [ "$tmpfs" = "$workdir" ]' \
  > "$podman_like"
chmod +x "$podman_like"
"$podman_like" run --rm "${RUN_ARGS[@]}" "$IMAGE" true

HOST_MODE=0
WITH_DIRS=()

# Ownership preparation refuses arbitrary project and host paths even when
# the selected engine would otherwise make the operation a no-op.
mkdir -p "$SATCHEL_DIR/home/claude" "$tmp/work/project-files"
ownership_path_allowed "$SATCHEL_DIR/home/claude"
ownership_path_allowed "$SATCHEL_DIR/sync/skills/shared"
! ownership_path_allowed "$tmp/work/project-files"
podman_rootless() { return 0; }
! (fix_home_ownership "$tmp/work/project-files" 2>/dev/null)
podman_rootless() { return 1; }

# Ownership detection uses portable find features and stops after the first
# mismatch instead of silently skipping repair on appliance hosts.
portable_bin="$tmp/portable-bin"
repair_engine="$tmp/repair-engine"
repair_log="$tmp/repair.log"
real_find="$(command -v find)"
mkdir -p "$portable_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'for arg in "$@"; do [ "$arg" != -printf ] || exit 64; done' \
  'exec "$REAL_FIND" "$@"' > "$portable_bin/find"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$REPAIR_LOG"\n' > "$repair_engine"
chmod 755 "$portable_bin/find" "$repair_engine"
old_path="$PATH"
PATH="$portable_bin:$PATH"
export PATH REAL_FIND="$real_find" REPAIR_LOG="$repair_log"
SATCHEL_UID=12345 SATCHEL_GID=12345 ENGINE="$repair_engine"
fix_home_ownership "$SATCHEL_DIR/home/claude"
PATH="$old_path"
export PATH
SATCHEL_UID=1000 SATCHEL_GID=1000 ENGINE=docker
grep -q 'chown -R 12345:12345 /satchel-data' "$repair_log"

# Synced registries reject path-special machine entries and malformed MCP
# records before a session or sync can consume them.
mkdir -p "$SATCHEL_DIR/sync/machines/..bad"
! (validate_machine_state 2>/dev/null)
rmdir "$SATCHEL_DIR/sync/machines/..bad"
printf '{"servers":{"ok":{"url":"https://example.test","auth":"none","extra":true}}}\n' \
  > "$SATCHEL_DIR/sync/mcp.json"
! (validate_mcp_state 2>/dev/null)
printf '{"servers":{"ok":{"url":"https://example.test","auth":"none"}}}\n' \
  > "$SATCHEL_DIR/sync/mcp.json"
validate_mcp_state

# A real lightweight probe verifies that the selected engine can read the
# exact host directory. A nested environment turns probe failure into a clear
# refusal rather than a stream of Docker mount errors.
probe_engine="$tmp/probe-engine"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'prev=""' \
  'for arg in "$@"; do' \
  '  if [ "$prev" = -v ] && [[ "$arg" == *:/probe:ro ]]; then' \
  '    source="${arg%:/probe:ro}"' \
  '    test -f "$source/marker"' \
  '    exit' \
  '  fi' \
  '  prev="$arg"' \
  'done' \
  'exit 1' \
  > "$probe_engine"
chmod +x "$probe_engine"
engine() { printf '%s' "$probe_engine"; }
engine_mount_probe
[ -z "$(find "$SATCHEL_DIR" -maxdepth 1 -name '.mount-probe.*' -print -quit)" ]

engine_mount_probe() { return 1; }
running_inside_container() { return 1; }
require_supported_engine_mounts
running_inside_container() { return 0; }
nested_output=""
if nested_output="$(require_supported_engine_mounts 2>&1)"; then
  printf 'nested mount failure was not rejected\n' >&2
  exit 1
fi
grep -q 'nested-container setup' <<< "$nested_output"

# Local-state deletion shares uninstall's exact target checks.
validate_state_removal_path "$(readlink -f "$SATCHEL_DIR")" "$tmp/install"
! (validate_state_removal_path "$(readlink -f "$tmp/work")" "$tmp/install" 2>/dev/null)

# Session startup propagates an interrupted best-effort pull immediately.
ensure_image() { :; }
require_supported_engine_mounts() { :; }
quiet_pull() { return 130; }
rc=0
(cd "$tmp/work/app" && cmd_session codex) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 130 ]

# Full session lifecycle: materialize first, prepare ownership at the final
# host-write boundary, launch, detect the new transcript, write a handoff, and
# sync. The fake engine records launch arguments and creates that transcript.
events="$tmp/events"
fake_engine="$tmp/fake-engine"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "run\n" >> "$SATCHEL_TEST_EVENTS"' \
  'home=""' \
  'prev=""' \
  'for arg in "$@"; do' \
  '  if [ "$prev" = -v ] && [[ "$arg" == *:/home/satchel ]]; then' \
  '    home="${arg%:/home/satchel}"' \
  '  fi' \
  '  prev="$arg"' \
  'done' \
  'mkdir -p "$home/.codex/sessions"' \
  'touch "$home/.codex/sessions/new.jsonl"' \
  'touch "$SATCHEL_TEST_EVENTS.session-ended"' \
  > "$fake_engine"
chmod +x "$fake_engine"
export SATCHEL_TEST_EVENTS="$events"

ensure_image() { :; }
require_supported_engine_mounts() { :; }
quiet_pull() { :; }
validate_sync_state() { :; }
ensure_skill_library() { :; }
repair_skill_library() { :; }
prune_all_handoffs() { :; }
update_check() { :; }
refresh_project_paths() { :; }
project_for_path() { printf 'sample'; }
materialize_mcp() { printf 'materialize\n' >> "$events"; }
ssh_preflight() { SSH_STATE=none; }
write_memory_file() { mkdir -p "$2/.codex"; printf 'memory\n' >> "$events"; }
fix_home_ownership() { printf 'ownership:%s\n' "$1" >> "$events"; }
fix_synced_write_ownership() {
  printf 'synced-ownership\n' >> "$events"
  if [ -f "$events.session-ended" ]; then
    bash -c 'trap -p INT' > "$events.post-session-int"
    ps -o pgid= -p "$BASHPID" | tr -d ' ' > "$events.ownership-pgid"
    cleanup_engine=""
    cleanup_engine="$(engine)" || true
    printf 'cleanup-engine:%s\n' "$cleanup_engine" >> "$events"
  fi
}
# Model a Docker probe that works before the interactive session but fails
# briefly after its CLI was force-exited. Engine selection must have been
# cached in this shell before then, rather than repeated inside $(engine).
select_engine() {
  if [ -z "$ENGINE" ]; then
    [ ! -f "$events.session-ended" ] || return 1
    ENGINE="$fake_engine"
  fi
}
engine() {
  select_engine
  printf '%s' "$ENGINE"
}
generate_handoff() { printf 'handoff\n' >> "$events"; }
report_skill_changes() { :; }
warn_machine_notes_size() { :; }
quiet_push() {
  printf 'push\n' >> "$events"
  ps -o pgid= -p "$BASHPID" | tr -d ' ' > "$events.sync-pgid"
}

# Accepting the automatic baseline consumes this launch. Success returns to
# the shell with the agreed next step; failure and Ctrl-C preserve their
# statuses. None of them may reach normal session materialization or launch.
maybe_offer_baseline() {
  BASELINE_LAUNCH_OUTCOME=attempted
  BASELINE_LAUNCH_STATUS=0
}
: > "$events"
baseline_output="$(cd "$tmp/work/app" && cmd_session codex 2>&1)"
grep -q "machine inventory saved.*Run .*codex.*again" <<< "$baseline_output"
[ ! -s "$events" ]

maybe_offer_baseline() {
  BASELINE_LAUNCH_OUTCOME=attempted
  BASELINE_LAUNCH_STATUS=7
}
rc=0
(cd "$tmp/work/app" && cmd_session codex) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 7 ]
[ ! -s "$events" ]

maybe_offer_baseline() {
  BASELINE_LAUNCH_OUTCOME=attempted
  BASELINE_LAUNCH_STATUS=130
}
rc=0
(cd "$tmp/work/app" && cmd_session codex) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 130 ]
[ ! -s "$events" ]

# Deferring or disabling the offer leaves the requested session untouched.
maybe_offer_baseline() {
  BASELINE_LAUNCH_OUTCOME=continue
  BASELINE_LAUNCH_STATUS=0
}
ENGINE=""
ps -o pgid= -p "$BASHPID" | tr -d ' ' > "$events.session-pgid"
(cd "$tmp/work/app" && cmd_session codex)
first_materialize="$(grep -n '^materialize$' "$events" | head -n1 | cut -d: -f1)"
first_ownership="$(grep -n '^ownership:' "$events" | head -n1 | cut -d: -f1)"
run_line="$(grep -n '^run$' "$events" | head -n1 | cut -d: -f1)"
handoff_line="$(grep -n '^handoff$' "$events" | head -n1 | cut -d: -f1)"
push_line="$(grep -n '^push$' "$events" | head -n1 | cut -d: -f1)"
[ "$first_materialize" -lt "$first_ownership" ]
[ "$first_ownership" -lt "$run_line" ]
[ "$run_line" -lt "$handoff_line" ]
[ "$handoff_line" -lt "$push_line" ]
# Once the interactive engine exits, cleanup subprocesses must inherit an
# ignored SIGINT. A caught no-op handler protects only the Satchel shell:
# Bash resets it to default in children, so repeated Ctrl-C can otherwise
# kill ownership repair and leave the handoff writer unable to read Codex.
grep -Eq "trap -- '' (SIGINT|INT)" "$events.post-session-int"
grep -Fq "cleanup-engine:$fake_engine" "$events"
[ "$(cat "$events.ownership-pgid")" != "$(cat "$events.session-pgid")" ]
[ "$(cat "$events.sync-pgid")" != "$(cat "$events.session-pgid")" ]

# A cleanup program that installs its own INT handler still survives terminal
# Ctrl-C because the runner places it outside Satchel's foreground process
# group. This models both Docker ownership repair and Git Sync Repo writes.
interrupt_task() {
  trap 'printf "interrupted\n" > "$events.interrupt-result"; exit 99' INT
  : > "$events.interrupt-started"
  sleep 0.2
  printf 'complete\n' > "$events.interrupt-result"
}
case "$-" in *m*) test_had_monitor=1 ;; *) test_had_monitor=0 ;; esac
set -m
(
  set +m
  trap '' INT
  task_rc=0
  run_isolated_task protect interrupt_task || task_rc=$?
  printf '%s\n' "$task_rc" > "$events.interrupt-rc"
) &
interrupt_runner=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$events.interrupt-started" ] && break
  sleep 0.05
done
kill -INT -- "-$interrupt_runner"
kill -INT -- "-$interrupt_runner"
kill -INT -- "-$interrupt_runner"
wait "$interrupt_runner"
[ "$test_had_monitor" -eq 1 ] || set +m
[ "$(cat "$events.interrupt-rc")" = 0 ]
grep -q '^complete$' "$events.interrupt-result"

printf 'ok: session boundaries, validation, and lifecycle\n'
