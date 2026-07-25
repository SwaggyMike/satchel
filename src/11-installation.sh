# The installed command's real path. A function rather than an inline
# `readlink -f "$0"` so tests that source the artifact can point it at a
# fixture instead of at the test script.
satchel_self() { readlink -f "${SATCHEL_SELF:-$0}"; }

shim_dir() {
  local self_dir
  self_dir="$(dirname "$(satchel_self)")"
  if [ -n "${SATCHEL_BIN:-}" ]; then printf '%s' "$SATCHEL_BIN"
  elif [ -d "$self_dir/.satchel" ]; then printf '%s' "$self_dir"
  elif [ -w /usr/local/bin ]; then printf '%s' "/usr/local/bin"
  else printf '%s' "$HOME/.local/bin"
  fi
}

# Both current marked shims and the original `exec satchel <agent>` wrappers
# belong to Satchel. Match the legacy form narrowly so unrelated executables
# that merely mention Satchel are never removed.
is_satchel_shim() {
  [ -f "$1" ] || return 1
  grep -qs '^# satchel shim$' "$1" \
    || grep -qsE '^exec[[:space:]]+satchel[[:space:]]+(claude|codex)([[:space:]]|$)' "$1"
}

# A generic Satchel marker is enough for status/install replacement, but not
# for deletion: another installation may own that shim. Current shims contain
# an exact, shell-escaped absolute command, so compare against the line this
# installation would generate rather than evaluating file content.
shim_owned_by_install() { # shim_owned_by_install <path> <agent> <satchel-path>
  local path="$1" agent="$2" self="$3" expected sibling sibling_real
  [ -f "$path" ] || return 1
  printf -v expected 'exec %q %s "$@"' "$self" "$agent"
  grep -Fqxs "$expected" "$path" && return 0

  # Older installers wrote the lexical sibling path. Accept that spelling
  # only while it resolves to this exact installed command; this handles
  # Fedora's /home → /var/home alias without trusting a generic marker.
  sibling="$(dirname "$path")/satchel"
  sibling_real="$(readlink -f "$sibling" 2>/dev/null || true)"
  [ "$sibling_real" = "$self" ] || return 1
  printf -v expected 'exec %q %s "$@"' "$sibling" "$agent"
  grep -Fqxs "$expected" "$path"
}

shim_status() { # shim_status <agent> → prints "linked <path>" or "not linked"
  local bin agent="$1" shim
  bin="$(shim_dir)"
  shim="$bin/$agent"
  if is_satchel_shim "$shim"; then
    printf 'linked → %s' "$shim"
  else
    printf 'not linked'
  fi
}

agent_launch_command() { # agent_launch_command <agent> → shim shorthand or explicit Satchel command
  local agent="$1" bin shim self resolved=""
  bin="$(shim_dir)"
  shim="$bin/$agent"
  self="$(readlink -f "$0")"
  resolved="$(command -v "$agent" 2>/dev/null || true)"
  if shim_owned_by_install "$shim" "$agent" "$self" \
    && [ -n "$resolved" ] \
    && [ "$(readlink -f "$resolved" 2>/dev/null || true)" = "$(readlink -f "$shim")" ]; then
    printf '%s' "$agent"
  else
    printf 'satchel %s' "$agent"
  fi
}

cmd_link() {
  local agents=("$@")
  [ "${#agents[@]}" -eq 0 ] && agents=(claude codex)
  local bin self agent shim linked=0
  bin="$(shim_dir)"
  self="$(readlink -f "$0")"
  mkdir -p "$bin"
  for agent in "${agents[@]}"; do
    shim="$bin/$agent"
    if is_satchel_shim "$shim"; then
      info "'$agent' is already linked ($shim)"
      continue
    fi
    if { [ -e "$shim" ] || [ -L "$shim" ]; }; then
      warn "skipping '$agent': $shim exists and is not a Satchel shim — remove it first or set SATCHEL_BIN"
      continue
    fi
    printf '#!/usr/bin/env bash\n# satchel shim\nexec %q %s "$@"\n' "$self" "$agent" > "$shim"
    chmod 755 "$shim"
    info "linked '$agent' → $shim"
    linked=1
  done
  if [ "$linked" -eq 1 ]; then
    info "if a linked command still resolves to an old path, run 'hash -r' or open a new shell"
  fi
  sync_unraid_boot_block
}

cmd_unlink() {
  local agents=("$@")
  [ "${#agents[@]}" -eq 0 ] && agents=(claude codex)
  local bin self agent shim
  bin="$(shim_dir)"
  self="$(readlink -f "$0")"
  for agent in "${agents[@]}"; do
    shim="$bin/$agent"
    if ! [ -e "$shim" ] && ! [ -L "$shim" ]; then
      info "'$agent' is not linked (no file at $shim)"
      continue
    fi
    if ! shim_owned_by_install "$shim" "$agent" "$self"; then
      if is_satchel_shim "$shim"; then
        warn "skipping '$agent': $shim belongs to another or ambiguous Satchel installation"
      else
        warn "skipping '$agent': $shim is not a Satchel shim — not touching it"
      fi
      continue
    fi
    rm -f "$shim"
    info "unlinked '$agent' (removed $shim)"
    # Unraid's boot script recreates /usr/local/bin links from flash; drop the
    # stale one now so an unlinked shim does not come back after a reboot. Only
    # a link back into the shim just removed, and never fatally: an unwritable
    # /usr/local/bin is somebody else's business.
    if [ -L "/usr/local/bin/$agent" ] \
       && [ "$(readlink -f "/usr/local/bin/$agent" 2>/dev/null || true)" = "$(readlink -f "$shim" 2>/dev/null || printf '%s' "$shim")" ]; then
      rm -f "/usr/local/bin/$agent" 2>/dev/null || true
    fi
  done
  sync_unraid_boot_block
}

remove_file_for_uninstall() { # exact file/symlink only; sudo fallback
  local path="$1"
  if rm -f -- "$path" 2>/dev/null; then return 0; fi
  command -v sudo >/dev/null 2>&1 || die "could not remove $path (permission denied; rerun as its owner or with sudo)"
  sudo rm -f -- "$path"
}

remove_tree_for_uninstall() { # validated exact state tree only; sudo fallback
  local path="$1"
  if rm -rf -- "$path" 2>/dev/null; then return 0; fi
  command -v sudo >/dev/null 2>&1 || die "could not remove $path (permission denied; rerun as its owner or with sudo)"
  sudo rm -rf -- "$path"
}

validate_state_removal_path() { # validate_state_removal_path <state> <install-dir>
  local state="$1" install_dir="$2" home_real
  home_real="$(readlink -f "$HOME")"
  case "$state" in
    /|"$home_real"|"$install_dir") die "refusing to remove unsafe state path $state" ;;
  esac
  if [ ! -f "$state/config" ] && [ ! -f "$state/install-path" ] \
     && [ ! -d "$state/sync" ] && [ ! -d "$state/home" ]; then
    die "$state does not look like a Satchel state directory — refusing to remove it"
  fi
}

installed_satchel_path() { # true only for an installer-owned script location
  local self="$1" recorded="" self_dir candidate
  self_dir="$(dirname "$self")"
  if [ -s "$INSTALL_PATH_FILE" ]; then
    recorded="$(readlink -f "$(cat "$INSTALL_PATH_FILE")" 2>/dev/null || true)"
    [ "$recorded" = "$self" ] && return 0
  fi
  for candidate in /usr/local/bin/satchel "$HOME/.local/bin/satchel"; do
    [ "$(readlink -f "$candidate" 2>/dev/null || true)" = "$self" ] && return 0
  done
  [ -d "$self_dir/.satchel" ] \
    && [ "$(readlink -f "$self_dir/.satchel")" = "$(readlink -f "$SATCHEL_DIR")" ] \
    && { [ -f "$self_dir/.satchel/script-sha" ] \
         || grep -qs '^MACHINE=' "$self_dir/.satchel/config"; }
}

is_unraid() { [ -f "$UNRAID_MARKER" ]; }
unraid_go_file() { printf '%s/go' "$UNRAID_BOOT_DIR"; }
unraid_key_dir() { printf '%s/ssh/root' "$UNRAID_BOOT_DIR"; }

BOOT_BLOCK_BEGIN='# >>> satchel boot persistence >>>'
BOOT_BLOCK_END='# <<< satchel boot persistence <<<'

# Unraid rebuilds /usr/local/bin and /root/.ssh from the flash-backed go script
# at every boot, so Satchel's command links and sync key have to be restored
# there. This function is the ONLY place that content is spelled out: it was
# previously duplicated in install.sh and in the README, and the copies had
# already drifted apart by one line.
unraid_boot_block_body() { # unraid_boot_block_body <satchel-path> <shim>...
  local self="$1"; shift
  printf 'ln -sf %s' "$self"
  local s; for s in "$@"; do printf ' %s' "$s"; done
  printf ' /usr/local/bin/\n'
  printf 'mkdir -p /root/.ssh && chmod 700 /root/.ssh\n'
  printf 'cp %s/id_ed25519* /root/.ssh/ 2>/dev/null && chmod 600 /root/.ssh/id_ed25519\n' "$(unraid_key_dir)"
  printf 'cp %s/known_hosts /root/.ssh/ 2>/dev/null\n' "$(unraid_key_dir)"
}

unraid_owned_shims() { # prints this installation's shim paths, one per line
  local self bin agent
  self="$(satchel_self)"; bin="$(shim_dir)"
  for agent in claude codex; do
    shim_owned_by_install "$bin/$agent" "$agent" "$self" && printf '%s\n' "$bin/$agent"
  done
  return 0
}

unraid_go_backup() { printf '%s.satchel-bak' "$(unraid_go_file)"; }

# The go script is what starts Unraid's web UI at boot, so a half-written or
# malformed one costs the user a trip to the flash drive with another PC.
# Nothing here is allowed to install content that does not parse.
boot_script_sane() { # boot_script_sane <file>
  [ -s "$1" ] || return 1
  [ "$(grep -cF "$BOOT_BLOCK_BEGIN" "$1")" -le 1 ] || return 1
  [ "$(grep -cF "$BOOT_BLOCK_END" "$1")" -le 1 ] || return 1
  # An unresolved satchel path would emit `ln -sf  /usr/local/bin/`, which is
  # a broken command sitting in a boot script.
  if grep -qE '^ln -sf[[:space:]]+/usr/local/bin/[[:space:]]*$' "$1"; then return 1; fi
  bash -n "$1" 2>/dev/null
}

# Swap in a staged file that already sits in the same directory, so the change
# is a rename on the flash rather than a truncate-then-write of the real file:
# there is no window in which go is partially written. Keep the last version
# that parsed, so a bad edit is always one cp away from being undone.
install_go_file() { # install_go_file <staged-file> <go-file>
  local staged="$1" go="$2" backup
  if ! boot_script_sane "$staged"; then
    rm -f -- "$staged"
    warn "refusing to install a malformed $go — leaving the existing one untouched"
    return 1
  fi
  backup="$(unraid_go_backup)"
  if [ -f "$go" ] && boot_script_sane "$go"; then
    cp -- "$go" "$backup" 2>/dev/null || true
  fi
  if mv -f -- "$staged" "$go" 2>/dev/null; then return 0; fi
  if command -v sudo >/dev/null 2>&1 && sudo mv -f -- "$staged" "$go"; then return 0; fi
  rm -f -- "$staged"
  return 1
}

stage_beside_go() { # stage_beside_go <go-file> → prints a temp path in the same directory
  mktemp "$1.satchel-tmp.XXXXXX" 2>/dev/null
}

write_unraid_boot_block() { # write_unraid_boot_block <go-file>
  local go="$1" tmp self shim shims=()
  self="$(satchel_self)"
  # Never write a link line with no target into a boot script.
  if [ -z "$self" ] || [ ! -e "$self" ]; then
    warn "could not resolve the installed satchel command — not touching $go"
    return 1
  fi
  while IFS= read -r shim; do shims+=("$shim"); done < <(unraid_owned_shims)
  tmp="$(stage_beside_go "$go")" || {
    warn "could not stage a replacement beside $go — not touching it"
    return 1
  }
  {
    [ ! -f "$go" ] || awk -v begin="$BOOT_BLOCK_BEGIN" -v end="$BOOT_BLOCK_END" '
      $0 == begin { skip=1; next } $0 == end { skip=0; next } !skip { print }' "$go"
    printf '%s\n' "$BOOT_BLOCK_BEGIN"
    unraid_boot_block_body "$self" ${shims[@]+"${shims[@]}"}
    printf '%s\n' "$BOOT_BLOCK_END"
  } > "$tmp"
  install_go_file "$tmp" "$go" || return 1
  # Make this boot look like the next one will.
  ln -sf "$self" ${shims[@]+"${shims[@]}"} /usr/local/bin/ 2>/dev/null || true
  return 0
}

# Offered once, during init. Previously install.sh asked and wrote its own copy
# of the block, which is how the two versions drifted.
ensure_unraid_boot_block() {
  is_unraid && [ -d "$UNRAID_BOOT_DIR" ] || return 0
  local go; go="$(unraid_go_file)"
  if grep -qsF "$BOOT_BLOCK_BEGIN" "$go"; then
    sync_unraid_boot_block
    return 0
  fi
  case "$(readlink -f "$SATCHEL_DIR")" in
    /usr/local/bin/*|/root/*) return 0 ;;   # nothing here survives a reboot anyway
  esac
  [ -t 0 ] || { warn "unraid: add boot persistence to $go so Satchel survives reboots (see the README)"; return 0; }
  info "unraid: / is rebuilt at every boot, so Satchel's command links and sync key need restoring"
  confirm_yes "add boot persistence to $go?" || return 0
  if write_unraid_boot_block "$go"; then
    info "added Satchel boot persistence to $go"
  else
    warn "could not write Satchel's boot-persistence block to $go"
  fi
  return 0
}

# Keeps an existing block in step with link/unlink, so a shim added later does
# not vanish at the next reboot and an unlinked one is not recreated forever.
sync_unraid_boot_block() {
  local go; go="$(unraid_go_file)"
  is_unraid && [ -f "$go" ] || return 0
  grep -qsF "$BOOT_BLOCK_BEGIN" "$go" || return 0
  grep -qsF "$BOOT_BLOCK_END" "$go" \
    || { warn "the Satchel block in $go has no closing marker — leaving it untouched"; return 0; }
  if write_unraid_boot_block "$go"; then
    info "refreshed Satchel boot persistence in $go"
  else
    warn "could not update Satchel's boot-persistence block in $go"
  fi
  return 0
}

remove_unraid_boot_block() {
  local go begin="$BOOT_BLOCK_BEGIN" end="$BOOT_BLOCK_END" tmp
  go="$(unraid_go_file)"
  is_unraid && [ -f "$go" ] || return 0
  grep -qsF "$begin" "$go" || return 0
  if ! grep -qsF "$end" "$go"; then
    warn "the Satchel block in $go has no closing marker — leaving it untouched"
    return 0
  fi
  tmp="$(stage_beside_go "$go")" \
    || die "could not stage a replacement beside $go; Satchel's boot block was left in place"
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { skip=1; next }
    $0 == end   { skip=0; next }
    !skip       { print }
  ' "$go" > "$tmp"
  install_go_file "$tmp" "$go" \
    || die "could not remove Satchel's boot-persistence block from $go"
  info "removed Satchel boot persistence from $go"
}

remove_satchel_image() {
  local e="" id state output
  if [ -n "${SATCHEL_ENGINE:-}" ] && command -v "$SATCHEL_ENGINE" >/dev/null 2>&1; then
    e="$SATCHEL_ENGINE"
  elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    e=docker
  elif command -v podman >/dev/null 2>&1; then
    e=podman
  fi
  [ -n "$e" ] || return 0
  "$e" image inspect "$IMAGE" >/dev/null 2>&1 || return 0

  # --rm normally handles session cleanup. If the engine was interrupted,
  # remove only stopped containers carrying Satchel's ownership label. Active
  # sessions and legacy/unrecognized containers are preserved deliberately.
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    state="$("$e" inspect --format '{{.State.Status}}' "$id" 2>/dev/null || true)"
    case "$state" in
      exited|created|configured|initialized|dead|stopped)
        if output="$("$e" container rm "$id" 2>&1)"; then
          info "removed stopped Satchel container $id"
        else
          warn "could not remove stopped Satchel container $id: ${output:-unknown engine error}"
        fi
        ;;
      running|paused|restarting)
        warn "left active Satchel container $id untouched"
        ;;
      *)
        warn "left Satchel container $id untouched because its state could not be verified"
        ;;
    esac
  done < <("$e" ps -a --filter "label=$MANAGED_CONTAINER_LABEL" --format '{{.ID}}' 2>/dev/null || true)

  if output="$("$e" image rm "$IMAGE" 2>&1)"; then
    info "removed container image $IMAGE"
  else
    warn "could not remove container image $IMAGE: ${output:-unknown engine error}"
    if [ "$e" = podman ]; then
      warn "inspect blockers with '$e ps -a --external --filter ancestor=$IMAGE'"
    else
      warn "inspect blockers with '$e ps -a --filter ancestor=$IMAGE'"
    fi
  fi
}

choose_uninstall_scope() {
  local state="$1" reply
  printf '%s\n' \
    'What should Satchel uninstall?' \
    '' \
    '  1) Program only — remove command, shims, and image; keep local data for reinstall' \
    "  2) Everything local — also permanently delete $state" \
    '     Deletes local logins, tokens, transcripts, configuration, and the Sync Repo clone.' \
    '     The upstream private Sync Repo is NOT deleted. Uncommitted or unpushed work is lost.' \
    '  3) Cancel' >&2
  read -r -p "$(prompt_text 'Choice [3]: ')" reply || reply=""
  case "$reply" in
    1) printf 'keep' ;;
    2) printf 'purge' ;;
    *) printf 'cancel' ;;
  esac
}

offer_uninstall_retirement() {
  sync_ready || return 0
  [ -d "$SYNC_DIR/machines/$MACHINE" ] || return 0
  printf '%s\n' \
    '' \
    "Retire '$MACHINE' from the caravan too?" \
    "This removes only machines/$MACHINE/ from the upstream private Sync Repo:" \
    'machine notes, inventory, guides, path cache, and machine handoffs.' \
    'Projects, Project handoffs, shared skills, MCP settings, other machines,' \
    'and the upstream repository itself are untouched. Git history retains the folder.' >&2
  if confirm "retire '$MACHINE' from the caravan?"; then
    if ! retire_machine_from_caravan "$MACHINE" 1; then
      warn "retirement failed — uninstall stopped before removing anything"
      return 1
    fi
  fi
  return 0
}

cmd_uninstall() {
  local purge=0 yes=0 interactive=1 arg self install_dir state p target agent ahead
  local shim_root seen_key scope seen_shims=$'\n'
  for arg in "$@"; do
    case "$arg" in
      --purge) purge=1 ;;
      --yes|-y) yes=1 ;;
      *) die "usage: satchel uninstall [--purge] [--yes]" ;;
    esac
  done
  [ "$yes" -eq 0 ] || interactive=0

  self="$(readlink -f "$0")"
  installed_satchel_path "$self" \
    || die "$self does not look like an installed Satchel command — refusing to remove a checkout or arbitrary script"
  install_dir="$(dirname "$self")"
  state="$(readlink -f "$SATCHEL_DIR")"

  if [ "$yes" -eq 0 ] && [ "$purge" -eq 0 ]; then
    scope="$(choose_uninstall_scope "$state")"
    case "$scope" in
      keep) yes=1 ;;
      purge) purge=1 ;;
      *) info "cancelled"; return 0 ;;
    esac
  fi

  if [ "$purge" -eq 1 ]; then
    validate_state_removal_path "$state" "$install_dir"
    if [ -d "$state/sync/.git" ] && [ -n "$(git -C "$state/sync" status --porcelain 2>/dev/null)" ]; then
      warn "the local Sync Repo has uncommitted changes; --purge will delete them"
    fi
    if git -C "$state/sync" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
      ahead="$(git -C "$state/sync" rev-list --count '@{u}..HEAD' 2>/dev/null || printf '0')"
      [ "$ahead" -eq 0 ] || warn "the local Sync Repo has $ahead unpushed commit(s); --purge will delete them"
    elif git -C "$state/sync" rev-parse HEAD >/dev/null 2>&1; then
      warn "the local Sync Repo has no upstream; --purge may delete commits that exist only here"
    fi
    warn "--purge permanently deletes local agent logins, transcripts, tokens, and the Sync Repo clone at $state"
    [ "$yes" -eq 1 ] || confirm "uninstall Satchel and permanently delete that state?" \
      || { info "cancelled"; return 0; }
  else
    info "local state will be preserved at $state (Sync Repo clone, agent logins, and transcripts)"
    [ "$yes" -eq 1 ] || confirm "uninstall the Satchel command and its Claude/Codex shims?" \
      || { info "cancelled"; return 0; }
  fi

  # Retirement mutates the shared Sync Repo and is offered only during the
  # human-guided flow; --yes never expands into a global caravan change.
  [ "$interactive" -eq 0 ] || offer_uninstall_retirement || return 1

  remove_unraid_boot_block

  # Unraid may have restored the command symlink into /usr/local/bin. Remove
  # only a link resolving back into this exact installation.
  for p in /usr/local/bin/satchel "$HOME/.local/bin/satchel"; do
    [ -L "$p" ] || continue
    target="$(readlink -f "$p" 2>/dev/null || true)"
    [ "$target" = "$self" ] || continue
    remove_file_for_uninstall "$p"
    info "removed link $p"
  done

  # Sweep known command locations before the installation directory: symlinked
  # wrappers must still have live targets when is_satchel_shim inspects them.
  # The predicate accepts only current marked shims and exact legacy wrappers.
  for shim_root in /usr/local/bin "$HOME/.local/bin" "$(shim_dir)" "$install_dir"; do
    for agent in claude codex; do
      p="$shim_root/$agent"
      # Deduplicate regular files reached through aliased parent directories,
      # but keep a symlink and its target distinct so both can be removed.
      seen_key="$p"
      if [ -f "$p" ] && [ ! -L "$p" ]; then
        seen_key="$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")"
      fi
      [[ "$seen_shims" != *$'\n'"$seen_key"$'\n'* ]] || continue
      seen_shims+="$seen_key"$'\n'
      if shim_owned_by_install "$p" "$agent" "$self"; then
        remove_file_for_uninstall "$p"
        info "removed shim $p"
      elif is_satchel_shim "$p"; then
        warn "left ambiguous Satchel shim $p untouched; remove it manually if it is obsolete"
      fi
    done
  done

  remove_satchel_image
  [ "$purge" -eq 0 ] || remove_tree_for_uninstall "$state"
  remove_file_for_uninstall "$self"
  if [ "$purge" -eq 1 ]; then
    success "Satchel and its local state were removed; the remote Sync Repo was not deleted"
  else
    success "Satchel was removed; state remains at $state for a future reinstall"
  fi
}

# The settings catalog — single source of truth for 'satchel settings', the
# config template, and what the setter accepts. Fields: KEY|scope|default|help.
# 'pref' settings sync caravan-wide via settings.env in the Sync Repo; 'machine'
# settings describe this box and stay in the local config.
SETTINGS_SPEC=(
  "SATCHEL_HANDOFF_MODEL_CLAUDE|pref|haiku|model that writes handoffs: haiku, sonnet, opus, fable, or a full model name; '' = the agent's default"
  "SATCHEL_HANDOFF_MODEL_CODEX|pref||same for codex; '' = the agent's default"
  "SATCHEL_ENGINE|machine||force docker or podman (default: auto-detect)"
  "SATCHEL_SSH|machine|1|forward the host's ssh-agent into sessions so git push works (0 = off)"
  "SATCHEL_CLIPBOARD|machine|1|forward the desktop clipboard socket so pasting images works (0 = off)"
  "SATCHEL_UID|machine||user id inside session containers (default: your uid; 1000 if root)"
  "SATCHEL_GID|machine||group id inside session containers (default: SATCHEL_UID)"
)
SYNC_SETTINGS_FILE="$SYNC_DIR/settings.env"
