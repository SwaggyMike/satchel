
# --------------------------------------------------------------- sessions

RUN_ARGS=()

announce_session_mode() {
  # Normal sandboxing is the expected success path. Agent TUIs immediately
  # replace the terminal screen, so a routine pre-launch banner only flashes.
  # Host mode is materially dangerous and remains an explicit warning.
  [ "$HOST_MODE" -eq 1 ] || return 0
  warn "HOST SESSION - no sandbox, you are root. The machine's real files are under /host; bare paths like /etc are the container's throwaway copies"
}

# Pasting an image (Ctrl+V) means reading the host clipboard from inside the
# container: claude shells out to wl-paste/xclip (baked into the image),
# codex speaks the protocols itself. Both need the compositor socket.
# Wayland is preferred and mounted at a fixed absolute path — libwayland
# accepts an absolute WAYLAND_DISPLAY, so no XDG_RUNTIME_DIR is needed
# inside. Headless hosts (no socket) simply get nothing, as before.
# ADR 0007 has the tradeoff; SATCHEL_CLIPBOARD=0 turns it off.
compose_clipboard_args() { # appends to RUN_ARGS
  [ "${SATCHEL_CLIPBOARD:-1}" = 0 ] && return 0
  local sock=""
  case "${WAYLAND_DISPLAY:-}" in
    "") ;;
    /*) sock="$WAYLAND_DISPLAY" ;;
    *)  [ -n "${XDG_RUNTIME_DIR:-}" ] && sock="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ;;
  esac
  if [ -n "$sock" ] && [ -S "$sock" ]; then
    RUN_ARGS+=(-v "$sock:/run/satchel/wayland-0" -e WAYLAND_DISPLAY=/run/satchel/wayland-0)
    return 0
  fi
  if [ -n "${DISPLAY:-}" ] && [ -d /tmp/.X11-unix ]; then
    RUN_ARGS+=(-v /tmp/.X11-unix:/tmp/.X11-unix -e "DISPLAY=$DISPLAY")
    if [ -n "${XAUTHORITY:-}" ] && [ -f "$XAUTHORITY" ]; then
      RUN_ARGS+=(-v "$XAUTHORITY:/run/satchel/Xauthority:ro" -e XAUTHORITY=/run/satchel/Xauthority)
    fi
  fi
  return 0
}

compose_run_args() { # compose_run_args <agent> <home> <project>
  local agent="$1" home="$2" project="$3" skills_dir
  skills_dir="$(session_skills_dir "$agent")"
  # DISABLE_AUTOUPDATER: agent CLIs live in the image; self-updates in a
  # throwaway container can only fail or evaporate — 'satchel update' is the way.
  RUN_ARGS=(--label "$MANAGED_CONTAINER_LABEL" -e HOME=/home/satchel
    -e "TERM=${TERM:-xterm-256color}" -e DISABLE_AUTOUPDATER=1 -e SATCHEL_SESSION=1)
  RUN_ARGS+=(-v "$home:/home/satchel")
  # Machine Notes: durable facts about this machine, curated by agents
  # mid-session (same mechanism as the Skill Library - rw mount, synced by
  # the session-end push). Every session on the machine sees them.
  if sync_ready; then
    mkdir -p "$SYNC_DIR/machines/$MACHINE"
    RUN_ARGS+=(-v "$SYNC_DIR/machines/$MACHINE:/home/satchel/machine")
    # Project handoffs, read-only: a session that can see several tracked
    # projects reads the relevant one's handoff on demand instead of having
    # every project's context stuffed into its preamble. Writes stay
    # satchel's job at session end.
    mkdir -p "$SYNC_DIR/projects"
    RUN_ARGS+=(-v "$SYNC_DIR/projects:/home/satchel/projects:ro")
    # Sibling machines' knowledge, read-only: "the fix for X lives in
    # apollo's notes" is a legitimate cross-machine read. Writes still go
    # only through this machine's own /home/satchel/machine mount.
    RUN_ARGS+=(-v "$SYNC_DIR/machines:/home/satchel/machines:ro")
  fi
  if [ "$agent" = claude ] && sync_ready; then
    mkdir -p "$SYNC_DIR/skills/shared" "$home/.claude"
    RUN_ARGS+=(-v "$SYNC_DIR/skills/shared:$skills_dir" -e "SATCHEL_SKILLS_DIR=$skills_dir")
  fi
  if [ "$agent" = codex ]; then
    compose_codex_mcp_env
    if sync_ready; then
      mkdir -p "$SYNC_DIR/skills/shared" "$home/.codex"
      RUN_ARGS+=(-v "$SYNC_DIR/skills/shared:$skills_dir" -e "SATCHEL_SKILLS_DIR=$skills_dir")
    fi
  fi
  if ssh_forwarding; then
    RUN_ARGS+=(-v "$SSH_AUTH_SOCK:/run/ssh-agent.sock" -e SSH_AUTH_SOCK=/run/ssh-agent.sock)
    # accept-new: first contact with a git host records its key in the agent
    # home (a persistent mount) instead of dying on a prompt no tool call can
    # answer; later sessions verify against that record.
    RUN_ARGS+=(-e "GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=accept-new")
  fi
  compose_clipboard_args
  RUN_ARGS+=(-v "$project:$project" -w "$project")
  # Host Sessions skip the extras: everything is already under /host, and a
  # real repo at a bare path would contradict "bare paths are throwaway".
  local w
  if [ "$HOST_MODE" -eq 0 ]; then
    for w in "${WITH_DIRS[@]}"; do
      [ "$w" = "$project" ] && continue
      RUN_ARGS+=(-v "$w:$w")
    done
  fi
  if [ "$HOST_MODE" -eq 1 ]; then
    # Host Session: the container is packaging, not protection (CONTEXT.md).
    # No --init here: it needs a private PID namespace, and --pid=host shares
    # the host's — the host's own init reaps zombies instead.
    RUN_ARGS+=(--privileged --pid=host --network=host --user 0:0 -v /:/host)
  else
    RUN_ARGS+=(--init --user "$SATCHEL_UID:$SATCHEL_GID" --cap-drop ALL --security-opt no-new-privileges)
    if selinux_active; then RUN_ARGS+=(--security-opt label=disable); fi
    # keep-id invents a passwd entry when SATCHEL_UID is absent from the image
  # (custom UIDs); template its home to the agent home so ssh agrees with
  # $HOME there too. Ignored when the UID already exists in the image.
  if podman_rootless; then RUN_ARGS+=(--userns=keep-id --passwd-entry '$USERNAME:*:$UID:$GID::/home/satchel:/bin/bash'); fi
  fi
  return 0
}

# A Host Session runs as root in the container, and a root-run host creates
# files as root before a normal UID-1000 session. Normalize only Satchel's
# documented writable state. Success is routine and silent; failures explain
# the exact internal path without implying that project or host files changed.
ownership_path_allowed() {
  local target state claude_home codex_home skills machine
  [ -e "$1" ] && [ ! -L "$1" ] || return 1
  target="$(readlink -f "$1")"
  state="$(readlink -f "$SATCHEL_DIR")"
  claude_home="$state/home/claude"
  codex_home="$state/home/codex"
  skills="$state/sync/skills/shared"
  machine="$state/sync/machines/$MACHINE"
  case "$target" in
    "$claude_home"|"$codex_home"|"$skills"|"$machine") return 0 ;;
    *) return 1 ;;
  esac
}

fix_home_ownership() { # fix_home_ownership <Satchel-managed-path>
  ownership_path_allowed "$1" \
    || die "refusing ownership repair outside Satchel-managed writable state: $1"
  podman_rootless && return 0
  local count
  count="$(find "$1" ! -user "$SATCHEL_UID" -printf . 2>/dev/null | wc -c)"
  [ "$count" -gt 0 ] || return 0
  local label=()
  if selinux_active; then label=(--security-opt label=disable); fi
  if "$(engine)" run --rm --label "$MANAGED_CONTAINER_LABEL" --user 0:0 \
      "${label[@]}" -v "$1:/satchel-data" "$IMAGE" \
      chown -R "$SATCHEL_UID:$SATCHEL_GID" /satchel-data; then
    :
  else
    warn "could not prepare Satchel's internal data at $1 for the normal session user"
  fi
}

fix_synced_write_ownership() {
  sync_ready || return 0
  mkdir -p "$SYNC_DIR/skills/shared" "$SYNC_DIR/machines/$MACHINE"
  fix_home_ownership "$SYNC_DIR/skills/shared"
  fix_home_ownership "$SYNC_DIR/machines/$MACHINE"
}

# The sandbox promise is "the container sees only the project directory" —
# which is void if the project directory IS your home (SSH keys, tokens,
# logins) or an ancestor of it. Host Sessions mount / on purpose, so no guard.
session_mount_guard() {
  [ "$HOST_MODE" -eq 1 ] && return 0
  local project home state bad=0 where="your home directory"
  project="$(readlink -f "${2:-$PWD}" 2>/dev/null)" \
    || die "could not resolve session directory ${2:-$PWD}"
  home="$(readlink -f "$HOME")"
  state="$(readlink -f "$SATCHEL_DIR" 2>/dev/null || printf '%s' "$SATCHEL_DIR")"
  if [ "$project" = "/" ]; then
    bad=1; where="/"
  else
    case "$home" in "$project"|"$project"/*) bad=1; where="your home directory" ;; esac
    if [ "$bad" -eq 0 ]; then
      case "$state" in "$project"|"$project"/*) bad=1; where="Satchel's private state directory" ;; esac
      case "$project" in "$state"|"$state"/*) bad=1; where="Satchel's private state directory" ;; esac
    fi
  fi
  if [ "$UNSAFE_HOME" -eq 1 ] && [ "$where" != "Satchel's private state directory" ]; then
    return 0
  fi
  [ "$bad" -eq 1 ] || return 0
  # A sandboxed session here would mount everything that matters (SSH keys,
  # MCP tokens, logins) while still claiming to be a sandbox. Offer the
  # honest mode instead - deliberately default-No, so a reflexive Enter
  # still refuses.
  if [ -t 0 ]; then
    local reply
    read -r -p "$(prompt_text "starting in $where - continue as a Host Session (no sandbox, full machine access)? [y/N] ")" reply
    if [[ "$reply" == [yY]* ]]; then HOST_MODE=1; return 0; fi
    info "cd into a project directory, or run 'satchel --unsafe-home $1' for a sandboxed session here"
    exit 1
  fi
  if [ "$where" = "Satchel's private state directory" ]; then
    die "refusing to mount Satchel's private state directory into a session"
  fi
  die "refusing to start a session in $PWD — that would mount your entire home directory (SSH keys, MCP tokens, logins) read-write into the sandbox.
       cd into a project directory, or run 'satchel --unsafe-home $1' if you really mean it."
}

# --with mounts extra project directories into the session, for work that
# spans repos. Same promise as the primary mount: never a home directory
# or /, no matter the flags. Paths are normalized so the mount, the
# preamble, and the in-session paths all agree.
with_dirs_guard() {
  local i w home state
  home="$(readlink -f "$HOME")"
  state="$(readlink -f "$SATCHEL_DIR" 2>/dev/null || printf '%s' "$SATCHEL_DIR")"
  for i in "${!WITH_DIRS[@]}"; do
    w="$(readlink -f "${WITH_DIRS[$i]}" 2>/dev/null)" || w=""
    [ -n "$w" ] && [ -d "$w" ] || die "--with ${WITH_DIRS[$i]}: not a directory"
    [ "$w" = / ] && die "--with ${WITH_DIRS[$i]}: refusing to mount /"
    case "$home" in
      "$w"|"$w"/*) die "--with $w: refusing to mount your home directory (SSH keys, MCP tokens, logins)" ;;
    esac
    case "$state" in
      "$w"|"$w"/*) die "--with $w: refusing to mount Satchel's private state directory" ;;
    esac
    case "$w" in
      "$state"|"$state"/*) die "--with $w: refusing to mount Satchel's private state directory" ;;
    esac
    WITH_DIRS[$i]="$w"
  done
  return 0
}

cmd_session() {
  local agent="$1"; shift
  # Satchel's own flags also work after the agent name, so the shims feel like
  # the real CLIs: 'claude --host' == 'satchel --host claude'. Neither agent
  # has flags by these names, so plucking them out is unambiguous.
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --host)        HOST_MODE=1 ;;
      --unsafe-home) UNSAFE_HOME=1 ;;
      --with)        [ -n "${2:-}" ] || die "--with needs a directory"
                     WITH_DIRS+=("$2"); shift ;;
      *)             args+=("$1") ;;
    esac
    shift
  done
  set -- "${args[@]}"
  need_cmd git; need_cmd jq
  local project slug home
  project="$(readlink -f "$PWD" 2>/dev/null)" || die "could not resolve session directory $PWD"
  session_mount_guard "$agent" "$project"
  with_dirs_guard
  ensure_image
  require_supported_engine_mounts
  home="$HOMES_DIR/$agent"
  mkdir -p "$home"

  if ! sync_ready; then
    warn "sync is not set up (run 'satchel init') — session is sandboxed but nothing will sync"
  fi
  quiet_pull
  if sync_ready; then
    validate_sync_state
    ensure_skill_library
    repair_skill_library 0
  fi
  prune_all_handoffs
  update_check
  refresh_project_paths "$project"
  slug="$(project_for_path "$project")"

  # Authentication normally happens inside an agent's first session. On the
  # next launch, offer a safe machine baseline before continuing into the
  # exact session the user originally requested.
  case "${1:-}" in
    --version|-v|--help|-h) ;;
    *) maybe_offer_baseline "$agent" "$home" ;;
  esac

  # First-run convenience: agents want a git identity for project commits.
  [ ! -f "$home/.gitconfig" ] && [ -f "$HOME/.gitconfig" ] && cp "$HOME/.gitconfig" "$home/.gitconfig"

  materialize_mcp "$agent" "$home"
  # Probe the ssh-agent once, before anything reads SSH_STATE: the launch
  # warning and the memory-file preamble must describe the same agent.
  # Install cleanup first so Ctrl-C during a passphrase prompt cannot leave a
  # temporary agent behind.
  trap 'stop_temporary_ssh_agent' EXIT
  ssh_preflight
  local temporary_agent=0
  if [ -n "$TEMP_SSH_AGENT_PID" ]; then
    temporary_agent=1
  else
    trap - EXIT
  fi
  # Written even without sync: the "where you are running" note must reach
  # the agent regardless; latest_handoff just finds nothing in that case.
  write_memory_file "$agent" "$home" "$slug" "$project"

  # This is the final host-side write boundary before the agent starts.
  # Root-run hosts may have just materialized config and memory as root.
  fix_home_ownership "$home"
  fix_synced_write_ownership
  compose_run_args "$agent" "$home" "$project"
  local tty=() ; [ -t 0 ] && tty=(-it)
  announce_session_mode

  # A handoff is only worth writing if a conversation actually happened —
  # detected as new transcript files in the agent home during the session.
  # Trivial runs (--version, instant quits) must not overwrite a good handoff.
  local tdir stamp
  case "$agent" in
    claude) tdir="$home/.claude/projects" ;;
    codex)  tdir="$home/.codex/sessions" ;;
  esac
  stamp="$(mktemp)"

  # Codex's own sandbox (bubblewrap) cannot create namespaces inside the
  # container, and the container IS the sandbox here — so codex runs with its
  # sandbox off, same spirit as claude --dangerously-skip-permissions inside
  # satchel. User-passed -c flags come later on the command line and win.
  local launch=("$agent")
  if [ "$agent" = codex ]; then
    launch=(codex -c 'sandbox_mode="danger-full-access"' -c check_for_update_on_startup=false)
  fi

  local rc=0
  "$(engine)" run --rm "${tty[@]}" "${RUN_ARGS[@]}" "$IMAGE" "${launch[@]}" "$@" || rc=$?

  # Normalize now, before the handoff writer (sandboxed, running as the user)
  # needs to read the transcripts the root session just wrote. Synced
  # read-write mounts get the same repair on every engine/session mode:
  # root-run hosts need it before safe sessions, and Docker Host Sessions can
  # otherwise leave root-owned skills or machine knowledge behind.
  if [ "$HOST_MODE" -eq 1 ]; then fix_home_ownership "$home"; fi
  fix_synced_write_ownership

  if sync_ready; then
    if [ -z "${SATCHEL_NO_HANDOFF:-}" ] \
       && [ -d "$tdir" ] && [ -n "$(find "$tdir" -type f -newer "$stamp" -print -quit 2>/dev/null)" ]; then
      # Re-scan because a session may have cloned or initialized repositories.
      # Unknown repos are offered only if handoff analysis identifies
      # substantive work in them; ordinary directories never prompt.
      refresh_project_paths "$project"
      slug="$(project_for_path "$project")"
      generate_handoff "$agent" "$slug" "$project"
      slug="$(project_for_path "$project")"
    fi
    repair_skill_library 1
    fix_synced_write_ownership
    report_skill_changes
    # Push regardless of the handoff: a session may have installed skills or
    # edited synced files even without a handoff to write.
    if [ -z "$SYNC_BLOCK_REASON" ]; then
      warn_machine_notes_size
      quiet_push "session: ${slug:-untracked} on $MACHINE"
    else
      warn "automatic sync skipped: $SYNC_BLOCK_REASON; review machine notes, then run 'satchel sync'"
    fi
  fi
  rm -f "$stamp"
  # Keep the temporary agent through the host-side Sync Repo push, then tear
  # it down. The handoff worker never receives its socket.
  if [ "$temporary_agent" -eq 1 ]; then
    stop_temporary_ssh_agent
    trap - EXIT
  fi
  return "$rc"
}
