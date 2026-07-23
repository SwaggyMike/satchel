shim_dir() {
  local self_dir
  self_dir="$(dirname "$(readlink -f "$0")")"
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
  done
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

remove_unraid_boot_block() {
  local go=/boot/config/go begin='# >>> satchel boot persistence >>>'
  local end='# <<< satchel boot persistence <<<' tmp
  [ -f /etc/unraid-version ] && [ -f "$go" ] || return 0
  grep -qsF "$begin" "$go" || return 0
  if ! grep -qsF "$end" "$go"; then
    warn "the Satchel block in $go has no closing marker — leaving it untouched"
    return 0
  fi
  tmp="$(mktemp)"
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { skip=1; next }
    $0 == end   { skip=0; next }
    !skip       { print }
  ' "$go" > "$tmp"
  if cp -- "$tmp" "$go" 2>/dev/null; then
    :
  elif command -v sudo >/dev/null 2>&1; then
    sudo cp -- "$tmp" "$go"
  else
    rm -f "$tmp"
    die "could not remove Satchel's boot-persistence block from $go"
  fi
  rm -f "$tmp"
  info "removed Satchel boot persistence from $go"
}

remove_satchel_image() {
  local e=""
  if [ -n "${SATCHEL_ENGINE:-}" ] && command -v "$SATCHEL_ENGINE" >/dev/null 2>&1; then
    e="$SATCHEL_ENGINE"
  elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    e=docker
  elif command -v podman >/dev/null 2>&1; then
    e=podman
  fi
  [ -n "$e" ] || return 0
  "$e" image inspect "$IMAGE" >/dev/null 2>&1 || return 0
  if "$e" image rm "$IMAGE" >/dev/null 2>&1; then
    info "removed container image $IMAGE"
  else
    warn "could not remove container image $IMAGE; remove it later with '$e image rm $IMAGE'"
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

cmd_uninstall() {
  local purge=0 yes=0 arg self install_dir state home_real p target agent ahead
  local shim_root seen_key scope seen_shims=$'\n'
  for arg in "$@"; do
    case "$arg" in
      --purge) purge=1 ;;
      --yes|-y) yes=1 ;;
      *) die "usage: satchel uninstall [--purge] [--yes]" ;;
    esac
  done

  self="$(readlink -f "$0")"
  installed_satchel_path "$self" \
    || die "$self does not look like an installed Satchel command — refusing to remove a checkout or arbitrary script"
  install_dir="$(dirname "$self")"
  state="$(readlink -f "$SATCHEL_DIR")"
  home_real="$(readlink -f "$HOME")"

  if [ "$yes" -eq 0 ] && [ "$purge" -eq 0 ]; then
    scope="$(choose_uninstall_scope "$state")"
    case "$scope" in
      keep) yes=1 ;;
      purge) purge=1 ;;
      *) info "cancelled"; return 0 ;;
    esac
  fi

  if [ "$purge" -eq 1 ]; then
    case "$state" in
      /|"$home_real"|"$install_dir") die "refusing to purge unsafe state path $state" ;;
    esac
    if [ ! -f "$state/config" ] && [ ! -f "$state/install-path" ] \
       && [ ! -d "$state/sync" ] && [ ! -d "$state/home" ]; then
      die "$state does not look like a Satchel state directory — refusing to purge it"
    fi
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
