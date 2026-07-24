
load_config() {
  # Precedence: built-in default < synced settings.env < local config.
  # shellcheck disable=SC1090
  [ -f "$SYNC_SETTINGS_FILE" ] && . "$SYNC_SETTINGS_FILE"
  # shellcheck disable=SC1090
  [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
  MACHINE="${MACHINE:-$(hostname -s)}"
  valid_machine_name "$MACHINE" \
    || die "unsafe machine name '$MACHINE' — use letters, numbers, dots, underscores, and hyphens, starting with a letter or number"
  local uid; uid="$(id -u)"
  # Never run agents as root inside the container; on root hosts (Unraid)
  # fall back to 1000:1000. Override with SATCHEL_UID/SATCHEL_GID in the config.
  if [ -z "$SATCHEL_UID" ]; then
    if [ "$uid" -eq 0 ]; then SATCHEL_UID=1000; SATCHEL_GID=1000
    else SATCHEL_UID="$uid"; SATCHEL_GID="$(id -g)"; fi
  fi
  SATCHEL_GID="${SATCHEL_GID:-$SATCHEL_UID}"
  # Satchel's own git runs unattended with stderr suppressed under a timeout,
  # so an interactive host-key prompt reads as "the remote is unreachable"
  # after a 20-second stall. That happens on every boot of a host that rebuilds
  # /root (Unraid), where known_hosts is gone. Accept-new records the key once.
  export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o StrictHostKeyChecking=accept-new}"
}

# A degraded Sync Repo must never stop an agent from running: every mount,
# read, and push is already guarded by sync_ready, so turning this one
# predicate off cleanly disables syncing for the rest of the run.
sync_ready() {
  [ "$SYNC_DEGRADED" -eq 0 ] || return 1
  [ -n "$SYNC_URL" ] && [ -d "$SYNC_DIR/.git" ]
}

degrade_sync() { # degrade_sync <reason> — stop syncing this run; the session continues
  [ "$SYNC_DEGRADED" -eq 0 ] || return 0
  SYNC_DEGRADED=1
  SYNC_BLOCK_REASON="$1"
  warn "Sync Repo unusable: $1"
  warn "this session runs normally, but nothing will sync — run 'satchel doctor' to see why"
  return 0
}

# Engine detection has two callers with different needs: a session must fail
# loudly without an engine, while reporting commands (status, settings) must
# still print everything else. Keep detection total and let select_engine own
# the failure, so a missing engine can never abort a read-only command.
detect_engine() { # prints docker|podman, or nothing; never exits
  if [ -n "${SATCHEL_ENGINE:-}" ]; then printf '%s' "$SATCHEL_ENGINE"
  elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then printf 'docker'
  elif command -v podman >/dev/null 2>&1; then printf 'podman'
  fi
}

select_engine() {
  [ -z "$ENGINE" ] || return 0
  ENGINE="$(detect_engine)"
  [ -n "$ENGINE" ] || die "neither docker nor podman is available"
}

engine() {
  select_engine
  printf '%s' "$ENGINE"
}

podman_rootless() {
  [ "$(engine)" = podman ] && [ "$(id -u)" -ne 0 ]
}

# SELinux hosts (Fedora & co): confined containers cannot touch bind-mounted
# host paths (user_home_t), so sessions die reading their own agent home.
# Relabeling with :z/:Z is wrong here - it rewrites labels on arbitrary host
# dirs (the project itself) and cannot cover the ssh-agent socket - so label
# separation is disabled for the session instead, the podman-documented way
# to mount host paths. The sandbox is unchanged: mount namespace,
# unprivileged uid, cap-drop, no-new-privileges.
selinux_active() {
  command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null
}

# Sessions get the host ssh-agent socket, not key files: the agent inside can
# ask the host to sign (so git push works) but can never read or copy a key.
# ADR 0005 has the tradeoff; SATCHEL_SSH=0 turns it off.
#
# A socket alone proves nothing: it can point at a dead agent, or a live one
# with no identities loaded (common over SSH: the forwarded agent answers but
# ssh-add was never run on the client). ssh_agent_state probes once with
# ssh-add (exit 0 = identities loaded, 1 = agent reachable but empty,
# anything else = nothing answering) so launch messages and the session
# preamble describe what git push will actually do.
SSH_STATE=""
TEMP_SSH_AGENT_PID=""
TEMP_SSH_AGENT_DIR=""

standard_private_keys() {
  local key
  for key in id_ed25519 id_ecdsa id_rsa; do
    [ -f "$HOME/.ssh/$key" ] && printf '%s\n' "$HOME/.ssh/$key"
  done
}

stop_temporary_ssh_agent() {
  [ -n "$TEMP_SSH_AGENT_PID" ] || return 0
  kill "$TEMP_SSH_AGENT_PID" 2>/dev/null || true
  if [ -n "$TEMP_SSH_AGENT_DIR" ]; then
    rm -f -- "$TEMP_SSH_AGENT_DIR/agent.sock"
    rmdir -- "$TEMP_SSH_AGENT_DIR" 2>/dev/null || true
  fi
  TEMP_SSH_AGENT_PID=""
  TEMP_SSH_AGENT_DIR=""
  SSH_AUTH_SOCK=""
  export SSH_AUTH_SOCK
}

start_temporary_ssh_agent() {
  local out sock pid key rc=0
  local keys=()
  while IFS= read -r key; do keys+=("$key"); done < <(standard_private_keys)
  [ ${#keys[@]} -gt 0 ] || return 1
  TEMP_SSH_AGENT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/satchel-ssh-agent.XXXXXX")"
  sock="$TEMP_SSH_AGENT_DIR/agent.sock"
  out="$(ssh-agent -a "$sock" -s 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rmdir -- "$TEMP_SSH_AGENT_DIR" 2>/dev/null || true
    TEMP_SSH_AGENT_DIR=""
    [ "$rc" -eq 130 ] && return 130
    return 1
  fi
  pid="$(printf '%s\n' "$out" | sed -n 's/^SSH_AGENT_PID=\([0-9][0-9]*\);.*/\1/p')"
  if [ -z "$pid" ]; then
    rmdir -- "$TEMP_SSH_AGENT_DIR" 2>/dev/null || true
    TEMP_SSH_AGENT_DIR=""
    return 1
  fi
  TEMP_SSH_AGENT_PID="$pid"
  SSH_AUTH_SOCK="$sock"
  export SSH_AUTH_SOCK
  rc=0
  ssh-add -q "${keys[@]}" || rc=$?
  if [ "$rc" -eq 0 ]; then
    # Root-run hosts launch normal sessions as SATCHEL_UID. This socket belongs
    # only to the current session, so grant that exact user access to it.
    if [ "$(id -u)" -eq 0 ] && [ "$HOST_MODE" -eq 0 ]; then
      if ! chown "$SATCHEL_UID:$SATCHEL_GID" "$TEMP_SSH_AGENT_DIR" "$sock"; then
        stop_temporary_ssh_agent
        return 1
      fi
    fi
    SSH_STATE=ready
    return 0
  fi
  stop_temporary_ssh_agent
  [ "$rc" -eq 130 ] && return 130
  return 1
}

pause_without_ssh() {
  warn "$1"
  if [ -t 0 ]; then
    local reply
    read -r -p "$(prompt_text "Press Enter to continue without SSH, or Ctrl-C to stop: ")" reply
  fi
}

ssh_agent_state() {
  if [ "${SATCHEL_SSH:-1}" = 0 ]; then printf 'off'; return 0; fi
  if [ ! -S "${SSH_AUTH_SOCK:-}" ]; then printf 'none'; return 0; fi
  local rc=0
  ssh-add -l >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) printf 'ready' ;;
    1) printf 'empty' ;;
    *) printf 'dead' ;;
  esac
}

# Mount the socket when an agent is actually answering on it. An empty agent
# still gets mounted: keys the user ssh-adds on the host mid-session become
# usable inside immediately. A dead socket gets nothing - mounting it could
# only produce confusing in-container errors.
ssh_forwarding() {
  case "${SSH_STATE:=$(ssh_agent_state)}" in
    ready|empty) return 0 ;;
    *) return 1 ;;
  esac
}

# Session-start preflight: say up front what git-over-SSH will do, instead of
# letting the first push inside the sandbox fail mysteriously.
ssh_preflight() { # ssh_preflight [agent] — agent only sharpens the guidance
  local agent="${1:-claude}"
  local state="${SSH_STATE:=$(ssh_agent_state)}" key rc=0
  local keys=()
  while IFS= read -r key; do keys+=("$key"); done < <(standard_private_keys)

  # A root-owned host socket cannot normally be reached by a normal UID-1000
  # session. Prefer a temporary socket whose ownership Satchel controls.
  local shared_agent_refused=0
  if [ "$(id -u)" -eq 0 ] && [ "$HOST_MODE" -eq 0 ] && [ "$state" != off ]; then
    case "$state" in ready|empty) shared_agent_refused=1 ;; esac
    state=none
    SSH_STATE=none
  fi
  # Say why a working agent was set aside. Otherwise the fallback message below
  # claims there is no agent at all, which contradicts what the user can see.
  if [ "$shared_agent_refused" -eq 1 ] && [ ${#keys[@]} -eq 0 ]; then
    warn "this host's ssh-agent belongs to root and cannot be shared with a uid-$SATCHEL_UID session"
    warn "save a standard key at \$HOME/.ssh/id_ed25519 for Satchel to load, or use 'satchel --host $agent' when you need root's agent"
  fi

  case "$state" in
    empty)
      if [ ${#keys[@]} -gt 0 ]; then
        rc=0
        ssh-add -q "${keys[@]}" || rc=$?
        [ "$rc" -eq 130 ] && return 130
        if [ "$rc" -eq 0 ]; then
          SSH_STATE=ready
          return 0
        fi
      fi
      pause_without_ssh "ssh-agent has no usable standard key — git push over SSH will not work in this session; load a key with ssh-add, or set SATCHEL_SSH=0 if SSH is not needed"
      ;;
    dead|none)
      if [ ${#keys[@]} -gt 0 ]; then
        rc=0
        start_temporary_ssh_agent || rc=$?
        [ "$rc" -eq 130 ] && return 130
        [ "$rc" -ne 0 ] || return 0
      fi
      SSH_STATE="$state"
      pause_without_ssh "no usable ssh-agent or standard key — git push over SSH will not work in this session; start/load an agent, or set SATCHEL_SSH=0 if SSH is not needed"
      ;;
  esac
  return 0
}

running_inside_container() {
  [ -e /.dockerenv ] || [ -e /run/.containerenv ]
}

engine_mount_probe() {
  local e probe rc=0
  e="$(engine)"
  mkdir -p "$SATCHEL_DIR" 2>/dev/null || return 1
  probe="$(mktemp -d "$SATCHEL_DIR/.mount-probe.XXXXXX" 2>/dev/null)" || return 1
  if ! printf 'satchel mount probe\n' > "$probe/marker"; then
    rmdir -- "$probe" 2>/dev/null || true
    return 1
  fi
  local label=()
  if selinux_active; then label=(--security-opt label=disable); fi
  "$e" run --rm --label "$MANAGED_CONTAINER_LABEL" "${label[@]}" \
    -v "$probe:/probe:ro" "$IMAGE" test -f /probe/marker \
    >/dev/null 2>&1 || rc=$?
  case "$probe" in "$SATCHEL_DIR"/.mount-probe.*) rm -rf -- "$probe" ;; esac
  return "$rc"
}

require_supported_engine_mounts() {
  running_inside_container || return 0
  engine_mount_probe && return 0
  die "the container engine cannot see Satchel's local files.
       Satchel is already running inside a container whose Docker/Podman daemon uses a different filesystem (common in Home Assistant apps).
       This nested-container setup is not supported; run Satchel on the Linux host or use the appliance's native agent app."
}
