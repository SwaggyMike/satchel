
# ------------------------------------------------------------------- init

# Satchel generates and shows this machine's SSH key; pasting it into the git
# host stays manual — satchel never talks to a git host's API.
have_pubkey() { compgen -G "$HOME/.ssh/*.pub" >/dev/null; }

generate_key() {
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  ssh-keygen -q -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "satchel@$MACHINE"
  # Unraid wipes /root/.ssh at every boot; keep a copy on flash so the
  # /boot/config/go block written by install.sh can restore it. The flash is
  # unencrypted FAT — acceptable for a key scoped to the private sync repo.
  if [ -f /etc/unraid-version ] && [ -d /boot/config ]; then
    mkdir -p /boot/config/ssh/root
    cp "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ed25519.pub" /boot/config/ssh/root/
    info "Unraid: key copied to /boot/config/ssh/root so it survives reboots"
  fi
}

print_pubkeys() { # print_pubkeys "context message"
  info "$1"
  local pub
  for pub in "$HOME"/.ssh/*.pub; do
    [ -f "$pub" ] && sed 's/^/    /' "$pub" >&2
  done
  return 0
}

cmd_key() {
  if ! have_pubkey; then
    info "no SSH key on this machine — generating one"
    generate_key
  fi
  print_pubkeys "this machine's public key — add it to your git host (profile SSH keys, or the repo's deploy keys with write access):"
}

prepare_sync_clone_destination() {
  # An interrupted or older setup can leave ordinary files at sync/ without
  # a Git repository. `git clone` only says "destination ... is not empty";
  # retrying cannot help, and reporting that as an SSH failure sends the user
  # toward the wrong fix. Preserve uncertain content locally, then clone into
  # a clean path. Never follow or replace a symlink.
  [ -e "$SYNC_DIR" ] || [ -L "$SYNC_DIR" ] || return 0
  [ ! -L "$SYNC_DIR" ] \
    || die "$SYNC_DIR is a symlink — refusing to replace it; move it aside and rerun 'satchel init'"
  [ -d "$SYNC_DIR" ] \
    || die "$SYNC_DIR exists but is not a directory — move it aside and rerun 'satchel init'"
  [ ! -d "$SYNC_DIR/.git" ] || return 0
  if [ -z "$(find "$SYNC_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    rmdir -- "$SYNC_DIR"
    return 0
  fi

  local recovery stamp destination suffix=0
  recovery="$SATCHEL_DIR/recovery"
  mkdir -p "$recovery"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  destination="$recovery/sync-$stamp"
  while [ -e "$destination" ] || [ -L "$destination" ]; do
    suffix=$((suffix + 1))
    destination="$recovery/sync-$stamp-$suffix"
  done
  mv -- "$SYNC_DIR" "$destination"
  warn "preserved incomplete Sync Repo files at $destination"
}

# When cloning over SSH fails, say what the user can actually do about it.
# ssh-add exit codes: 0 = agent has keys, 1 = agent empty, 2 = no agent.
ssh_key_hint() {
  case "$1" in ssh://*|git@*) ;; *) return 0 ;; esac
  printf '\n' >&2
  local agent_rc=0
  ssh-add -l >/dev/null 2>&1 || agent_rc=$?
  case "$agent_rc" in
    0) info "the SSH clone failed; if the error above says 'Permission denied', the git host may not know the loaded key (or the repo path may be wrong)" ;;
    1) info "the SSH clone failed and your ssh-agent has no keys loaded — run 'ssh-add' if the error above is an authentication failure" ;;
  esac
  if have_pubkey; then
    print_pubkeys "this machine's public key — add it to your git host (profile SSH keys, or the repo's deploy keys with write access):"
  elif confirm_yes "this machine has no SSH key — generate one now?"; then
    generate_key
    print_pubkeys "done. add this public key to your git host:"
  fi
  return 0
}

cmd_init() {
  need_cmd git; need_cmd jq; select_engine
  mkdir -p "$SATCHEL_DIR" && chmod 700 "$SATCHEL_DIR"

  local name url existing_url was_initialized=0
  sync_ready && was_initialized=1
  read -r -p "$(prompt_text "machine name [$MACHINE]: ")" name
  name="$(slugify "${name:-$MACHINE}")"
  valid_machine_name "$name" \
    || die "machine name must start with a letter or number and contain only letters, numbers, dots, underscores, and hyphens"
  read -r -p "$(prompt_text "sync repo URL (private git repo; empty to skip sync for now)${SYNC_URL:+ [$SYNC_URL]}: ")" url
  url="${url:-$SYNC_URL}"
  if [ -n "$url" ] && [ -d "$SYNC_DIR/.git" ]; then
    existing_url="$(git -C "$SYNC_DIR" remote get-url origin 2>/dev/null)" \
      || die "existing Sync Repo clone has no origin: $SYNC_DIR"
    [ "$existing_url" = "$url" ] \
      || die "Sync Repo URL does not match the existing clone ($existing_url); move the clone aside before switching remotes"
  fi

  {
    printf '# Satchel config — plain bash, sourced by satchel.\n'
    printf "# See and change settings with 'satchel settings'; this file is the\n"
    printf '# machine-local layer (it wins over the synced settings.env).\n'
    printf 'MACHINE=%q\n' "$name"
    printf 'SYNC_URL=%q\n' "$url"
    local row k scope def help
    for row in "${SETTINGS_SPEC[@]}"; do
      IFS='|' read -r k scope def help <<< "$row"
      [ "$scope" = machine ] && printf '# %s=%s  # %s\n' "$k" "$def" "$help"
    done
  } > "$CONFIG_FILE"
  MACHINE="$name"; SYNC_URL="$url"

  local key_shown=0
  if [ -n "$url" ]; then
    # Local paths that aren't git repos yet: offer to create a bare repo on
    # the spot — handy for NFS mounts and other shared filesystems where
    # there's no hosted git service to click "create repo" in.
    case "$url" in
      ssh://*|git@*|https://*|http://*) ;;
      *)
        local resolved; resolved="$(readlink -f "$url" 2>/dev/null || printf '%s' "$url")"
        if [ ! -d "$resolved" ] || { [ -d "$resolved" ] && [ -z "$(ls -A "$resolved" 2>/dev/null)" ]; }; then
          if [ ! -d "$resolved" ] && [ ! -d "$(dirname "$resolved")" ]; then
            die "parent directory of $resolved does not exist"
          fi
          if confirm_yes "no git repo at $resolved — create one?"; then
            mkdir -p "$resolved"
            git init --bare "$resolved"
            info "created bare git repo at $resolved"
          fi
        elif [ -d "$resolved" ] && ! git -C "$resolved" rev-parse --git-dir >/dev/null 2>&1; then
          if confirm_yes "directory $resolved exists but is not a git repo — initialize a bare repo there?"; then
            git init --bare "$resolved"
            info "created bare git repo at $resolved"
          fi
        fi
        ;;
    esac
    # Clone failures loop in place: show SSH guidance when relevant, let the
    # user fix the concrete Git error above, then retry. Never "go rerun init".
    while [ ! -d "$SYNC_DIR/.git" ]; do
      prepare_sync_clone_destination
      git clone "$url" "$SYNC_DIR" && break
      ssh_key_hint "$url"
      key_shown=1
      if ! confirm_yes "fixed the clone error above? retry?"; then
        warn "skipping sync for now — sessions work, nothing syncs; run 'satchel init' when ready"
        url=""
        break
      fi
    done
  fi
  if [ -n "$url" ]; then
    mkdir -p "$SYNC_DIR/machines/$name" "$SYNC_DIR/projects" "$SYNC_DIR/skills/shared"
    [ -f "$SYNC_DIR/machines/$name/projects.json" ] || printf '{"paths":{}}\n' > "$SYNC_DIR/machines/$name/projects.json"
    [ -f "$SYNC_DIR/repositories.json" ] || printf '{}\n' > "$SYNC_DIR/repositories.json"
    ensure_skill_library
    [ -f "$SYNC_DIR/profile.md" ] || printf '# Profile\n' > "$SYNC_DIR/profile.md"
    [ -f "$SYNC_DIR/preferences.md" ] || printf '# Preferences\n' > "$SYNC_DIR/preferences.md"
    [ -f "$SYNC_TOKENS_FILE" ] && chmod 600 "$SYNC_TOKENS_FILE"
    sync_machine_registration "$name" || true
  else
    if [ "$key_shown" -eq 0 ]; then
      if ! have_pubkey && confirm_yes "no SSH key on this machine — generate one now so it's ready for a sync repo later?"; then
        generate_key
      fi
      if have_pubkey; then
        print_pubkeys "this machine's public key — add it to your git host now, and connecting a sync repo later is one 'satchel init' away:"
      fi
    fi
    warn "no sync repo — sessions work, but handoffs/MCP/skills stay on this machine"
  fi

  cmd_image
  [ "$was_initialized" -eq 0 ] || offer_baseline_refresh
  success "done. try: cd <a project> && $(agent_launch_command claude)"
}
