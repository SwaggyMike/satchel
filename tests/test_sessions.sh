#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_dir/tests/lib.sh"
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

# Normal and Host Sessions expose their safety boundary mechanically. Helper
# containers are intentionally excluded from this normal-Session contract.
compose_run_args codex "$tmp/agent-home" "$tmp/work/app"
args=" ${RUN_ARGS[*]} "
[[ "$args" == *" SATCHEL_SESSION=1 "* ]]
[[ "$args" == *" SATCHEL_SESSION_MODE=sandbox "* ]]
[[ "$args" != *" SATCHEL_SESSION_MODE=host "* ]]
[[ "$args" != *" --pid=private "* ]]
[[ "$args" != *" --pid=host "* ]]
docker_pid_like="$tmp/docker-pid-like"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'for arg in "$@"; do' \
  '  case "$arg" in' \
  '    --pid=host|--pid=container:*) ;;' \
  '    --pid=*) exit 64 ;;' \
  '  esac' \
  'done' \
  'exit 0' \
  > "$docker_pid_like"
chmod +x "$docker_pid_like"
"$docker_pid_like" run --rm "${RUN_ARGS[@]}" "$IMAGE" true
HOST_MODE=1
compose_run_args codex "$tmp/agent-home" "$tmp/work/app"
args=" ${RUN_ARGS[*]} "
[[ "$args" == *" SATCHEL_SESSION_MODE=host "* ]]
[[ "$args" != *" SATCHEL_SESSION_MODE=sandbox "* ]]
[[ "$args" == *" --pid=host "* ]]
[[ "$args" != *" --pid=private "* ]]
"$docker_pid_like" run --rm "${RUN_ARGS[@]}" "$IMAGE" true
HOST_MODE=0

# Ownership preparation refuses arbitrary project and host paths even when
# the selected engine would otherwise make the operation a no-op.
mkdir -p "$SATCHEL_DIR/home/claude" "$tmp/work/project-files"
ownership_path_allowed "$SATCHEL_DIR/home/claude"
ownership_path_allowed "$SATCHEL_DIR/sync/skills/shared"
refute ownership_path_allowed "$tmp/work/project-files"
podman_rootless() { return 0; }
refute fix_home_ownership "$tmp/work/project-files"
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

# On a root-run host the session deliberately runs as an unprivileged uid the
# host's files do not belong to. Say so, because an agent hitting EACCES will
# otherwise reach for chmod or sudo — neither of which can help from inside the
# container. Machines without that mismatch must not pay for the explanation.
own_home="$tmp/own-home"; mkdir -p "$own_home"
ownership_note() { write_memory_file claude "$own_home" "" "$tmp/work/app"; cat "$own_home/.claude/CLAUDE.md"; }

HOST_MODE=0
id() { case "${1:-}" in -u) printf '0' ;; *) command id "$@" ;; esac; }
grep -q "runs as uid $SATCHEL_UID" <(ownership_note)
grep -q "chown -R $SATCHEL_UID:$SATCHEL_GID" <(ownership_note)
grep -q 'cannot be fixed from inside' <(ownership_note)

# A Host Session runs as root, so there is no mismatch to explain.
HOST_MODE=1
refute grep -q 'cannot be fixed from inside' <(ownership_note)
HOST_MODE=0

# A root host that also runs sessions as root has nothing to explain either.
saved_session_uid="$SATCHEL_UID"; SATCHEL_UID=0
refute grep -q 'cannot be fixed from inside' <(ownership_note)
SATCHEL_UID="$saved_session_uid"

# An ordinary non-root host never sees it at all.
unset -f id
refute grep -q 'cannot be fixed from inside' <(ownership_note)

# Synced registries reject path-special machine entries and malformed MCP
# records before a session or sync can consume them.
mkdir -p "$SATCHEL_DIR/sync/machines/..bad"
refute validate_machine_state
rmdir "$SATCHEL_DIR/sync/machines/..bad"
machine_environment="$SATCHEL_DIR/sync/machines/testbox/environment.json"
printf '{"satchel":"2.0.0","commit":"abc","engine":"docker","agents":"claude 1","future":true}\n' \
  > "$machine_environment"
validate_machine_state
printf '{"satchel":2,"commit":"abc","engine":"docker","agents":"claude 1"}\n' \
  > "$machine_environment"
refute validate_machine_state
rm "$machine_environment"
# An unknown field is accepted on purpose, so a newer Satchel elsewhere in the
# caravan cannot brick this machine (tests/test_mcp.sh covers that contract).
# This assertion used to demand the opposite and never fired, because a leading
# `!` is exempt from set -e.
printf '{"servers":{"ok":{"url":"https://example.test","auth":"none","extra":true}}}\n' \
  > "$SATCHEL_DIR/sync/mcp.json"
validate_mcp_state
# A record missing a field Satchel actually reads is still rejected.
printf '{"servers":{"ok":{"auth":"none"}}}\n' > "$SATCHEL_DIR/sync/mcp.json"
refute validate_mcp_state
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
refute validate_state_removal_path "$(readlink -f "$tmp/work")" "$tmp/install"

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
startup_order="$tmp/startup-order"
quiet_pull() {
  [ -n "${RECORD_STARTUP_ORDER:-}" ] && printf 'pull\n' >> "$startup_order"
  return 0
}
validate_sync_state() { :; }
ensure_skill_library() { :; }
repair_skill_library() { :; }
prune_all_handoffs() { :; }
update_check() { :; }
refresh_project_paths() { :; }
project_for_path() { printf 'sample'; }
materialize_mcp() { printf 'materialize\n' >> "$events"; }
ssh_preflight() {
  [ -n "${RECORD_STARTUP_ORDER:-}" ] && printf 'ssh\n' >> "$startup_order"
  SSH_STATE=none
}
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
RECORD_STARTUP_ORDER=1
export RECORD_STARTUP_ORDER
: > "$startup_order"
(cd "$tmp/work/app" && cmd_session codex)
ssh_line="$(grep -n '^ssh$' "$startup_order" | head -n1 | cut -d: -f1)"
pull_line="$(grep -n '^pull$' "$startup_order" | head -n1 | cut -d: -f1)"
[ "$ssh_line" -lt "$pull_line" ]
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
# The task waits for the test to release it rather than for a fixed sleep, so
# the signals always land while it is genuinely running. A timing-based version
# races: if the task finishes first the process group is gone, 'kill' fails,
# and 'set -e' ends the test with no output at all.
interrupt_task() {
  trap 'printf "interrupted\n" > "$events.interrupt-result"; exit 99' INT
  : > "$events.interrupt-started"
  for _ in $(seq 1 200); do
    [ -f "$events.interrupt-release" ] && break
    sleep 0.05
  done
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
for _ in $(seq 1 200); do
  [ -f "$events.interrupt-started" ] && break
  sleep 0.05
done
[ -f "$events.interrupt-started" ] || { printf 'FAIL: interrupt task never started\n' >&2; exit 1; }
kill -INT -- "-$interrupt_runner"
kill -INT -- "-$interrupt_runner"
kill -INT -- "-$interrupt_runner"
: > "$events.interrupt-release"
wait "$interrupt_runner"
[ "$test_had_monitor" -eq 1 ] || set +m
[ "$(cat "$events.interrupt-rc")" = 0 ]
grep -q '^complete$' "$events.interrupt-result"

# On a root-run host (Unraid) the session runs as SATCHEL_UID while project
# files belong to root. Git refuses to touch a repository owned by another
# user, so every git command inside the session fails with "dubious ownership"
# until the mounted roots are declared safe.
# The git identity must still reach the agent home after safe.directory has
# created a .gitconfig there. Keying off the file's existence meant a machine
# that gained a ~/.gitconfig after its first session never got an identity, and
# every commit inside a session failed with "Author identity unknown".
id_home="$tmp/id-home"; mkdir -p "$id_home"
printf '[user]\n\tname = Test User\n\temail = test@example.com\n' > "$HOME/.gitconfig"
declare_session_safe_directories "$id_home" "$tmp/work/app"   # creates .gitconfig first
seed_agent_git_identity "$id_home"
[ "$(git config --file "$id_home/.gitconfig" user.email)" = "test@example.com" ]
[ "$(git config --file "$id_home/.gitconfig" user.name)" = "Test User" ]
git config --file "$id_home/.gitconfig" --get-all safe.directory | grep -qF "$tmp/work/app"
# An identity already set in the agent home is never overwritten by the host's.
git config --file "$id_home/.gitconfig" user.email "kept@example.com"
seed_agent_git_identity "$id_home"
[ "$(git config --file "$id_home/.gitconfig" user.email)" = "kept@example.com" ]
# A partial identity is still unusable for commits. Preserve the value already
# chosen in the agent home, but fill the missing half from the host.
partial_home="$tmp/partial-id-home"; mkdir -p "$partial_home"
git config --file "$partial_home/.gitconfig" user.email "partial@example.com"
seed_agent_git_identity "$partial_home"
[ "$(git config --file "$partial_home/.gitconfig" user.email)" = "partial@example.com" ]
[ "$(git config --file "$partial_home/.gitconfig" user.name)" = "Test User" ]
# A fresh home with no prior config still gets the whole host config copied.
fresh_home="$tmp/fresh-home"; mkdir -p "$fresh_home"
seed_agent_git_identity "$fresh_home"
[ "$(git config --file "$fresh_home/.gitconfig" user.email)" = "test@example.com" ]
rm -f "$HOME/.gitconfig"

safe_home="$tmp/safe-home"
mkdir -p "$safe_home" "$tmp/work/extra"
declare_session_safe_directories "$safe_home" "$tmp/work/app" "$tmp/work/extra"
grep -Fq "$tmp/work/app" "$safe_home/.gitconfig"
grep -Fq "$tmp/work/extra" "$safe_home/.gitconfig"
# Rewritten every session start, so it must not accumulate duplicates.
declare_session_safe_directories "$safe_home" "$tmp/work/app" "$tmp/work/extra"
[ "$(grep -Fc "$tmp/work/app" "$safe_home/.gitconfig")" = 1 ]
# An existing user gitconfig copied in at first run is preserved.
printf '[user]\n\tname = someone\n' > "$tmp/pre-home-gitconfig"
mkdir -p "$tmp/pre-home"; cp "$tmp/pre-home-gitconfig" "$tmp/pre-home/.gitconfig"
declare_session_safe_directories "$tmp/pre-home" "$tmp/work/app"
grep -q 'name = someone' "$tmp/pre-home/.gitconfig"
grep -Fq "$tmp/work/app" "$tmp/pre-home/.gitconfig"

# A project the session user cannot write is worth one clear sentence at
# launch, instead of the agent discovering it one failed edit at a time.
writable_dir="$tmp/work/app"
chmod 755 "$writable_dir"
saved_uid="$SATCHEL_UID"; saved_gid="$SATCHEL_GID"
SATCHEL_UID="$(stat -c %u "$writable_dir")"; SATCHEL_GID="$(stat -c %g "$writable_dir")"
session_can_write "$writable_dir"
SATCHEL_UID=4242; SATCHEL_GID=4242
refute session_can_write "$writable_dir"          # not owner, not group, not world-writable
chmod 777 "$writable_dir"
session_can_write "$writable_dir"            # world-writable is enough
chmod 755 "$writable_dir"

# The warning itself only applies to root-run hosts in a sandboxed session.
id() { case "${1:-}" in -u) printf '0' ;; *) command id "$@" ;; esac; }
HOST_MODE=0
unwritable_out="$(warn_unwritable_mounts "$writable_dir" 2>&1)"
grep -q 'not writable by it' <<< "$unwritable_out"
grep -Fq "chown -R 4242:4242 $writable_dir" <<< "$unwritable_out"
HOST_MODE=1
[ -z "$(warn_unwritable_mounts "$writable_dir" 2>&1)" ]   # Host Sessions run as root
HOST_MODE=0
unset -f id
[ -z "$(warn_unwritable_mounts "$writable_dir" 2>&1)" ]   # non-root hosts never warn
SATCHEL_UID="$saved_uid"; SATCHEL_GID="$saved_gid"

printf 'ok: session boundaries, validation, and lifecycle\n'
