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
maybe_offer_baseline() { :; }
materialize_mcp() { printf 'materialize\n' >> "$events"; }
ssh_preflight() { SSH_STATE=none; }
write_memory_file() { mkdir -p "$2/.codex"; printf 'memory\n' >> "$events"; }
fix_home_ownership() { printf 'ownership:%s\n' "$1" >> "$events"; }
fix_synced_write_ownership() { printf 'synced-ownership\n' >> "$events"; }
engine() { printf '%s' "$fake_engine"; }
generate_handoff() { printf 'handoff\n' >> "$events"; }
report_skill_changes() { :; }
warn_machine_notes_size() { :; }
quiet_push() { printf 'push\n' >> "$events"; }

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

printf 'ok: session boundaries, validation, and lifecycle\n'
