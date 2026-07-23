
# ----------------------------------------------------------------- retire

rollback_retirement() { # rollback_retirement <pre-retirement-head> <machine>
  local before="$1" target="$2"
  git_sync reset -q --mixed "$before"
  git_sync restore -q --source="$before" --staged --worktree -- "machines/$target"
}

retire_machine_from_caravan() { # retire_machine_from_caravan <machine> [strict]
  local target="$1" strict="${2:-0}" before
  valid_machine_name "$target" || die "invalid or unsafe machine name '$target'"
  ensure_sync_identity

  if [ "$strict" -eq 1 ]; then
    if [ -n "$(git_sync status --porcelain)" ]; then
      warn "the Sync Repo has uncommitted changes — run 'satchel sync' before retiring '$target'"
      return 1
    fi
    if has_upstream && ! timeout 30 git -C "$SYNC_DIR" pull --rebase -q; then
      warn "could not update the Sync Repo — retirement was not attempted"
      return 1
    fi
    [ -d "$SYNC_DIR/machines/$target" ] \
      || { info "'$target' is already absent from the caravan"; return 0; }
    before="$(git_sync rev-parse HEAD)"
    if ! git_sync rm -rq -- "machines/$target" \
      || ! git_sync commit -q -m "retire $target"; then
      rollback_retirement "$before" "$target"
      warn "could not commit retirement of '$target'; local Sync Repo restored"
      return 1
    fi
    if ! timeout 30 git -C "$SYNC_DIR" push -q -u origin HEAD; then
      rollback_retirement "$before" "$target"
      warn "could not push retirement of '$target'; local Sync Repo restored"
      return 1
    fi
  else
    git_sync rm -rq -- "machines/$target"
    git_sync commit -q -m "retire $target"
    if has_upstream && ! git_sync pull --rebase -q; then
      die "pull hit a conflict — resolve it in $SYNC_DIR with normal git, then 'satchel sync'"
    fi
    git_sync push -q -u origin HEAD || warn "could not push — run 'satchel sync' when the remote is reachable"
  fi
  info "'$target' retired from the caravan"
}

cmd_retire() {
  sync_ready || die "sync is not set up — run 'satchel init' first"
  quiet_pull
  validate_sync_state
  local target="${1:-}"
  if [ -z "$target" ]; then
    local names=() m marker i
    for m in "$SYNC_DIR"/machines/*/; do
      [ -d "$m" ] || continue
      names+=("$(basename "$m")")
    done
    [ "${#names[@]}" -gt 0 ] || die "the caravan is empty — nothing to retire"
    info "caravan:"
    for i in "${!names[@]}"; do
      marker=""
      [ "${names[$i]}" = "$MACHINE" ] && marker=" (this machine)"
      printf '  %s%d)%s %s%s\n' "$ERR_BOLD$ERR_BLUE" "$((i + 1))" "$ERR_RESET" "${names[$i]}" "$marker" >&2
    done
    local choice
    read -r -p "$(prompt_text "retire which machine? [1-${#names[@]}, empty to cancel]: ")" choice
    [ -n "$choice" ] || { info "cancelled"; return 0; }
    printf '%s' "$choice" | grep -Eq '^[0-9]+$' && [ "$choice" -ge 1 ] && [ "$choice" -le "${#names[@]}" ] \
      || die "not a valid choice: $choice"
    target="${names[$((choice - 1))]}"
  fi
  valid_machine_name "$target" || die "invalid or unsafe machine name '$target'"
  [ -d "$SYNC_DIR/machines/$target" ] || die "no machine '$target' in the caravan"

  confirm "retire '$target' — delete its folder from the Sync Repo? (git history keeps it)" || { info "cancelled"; return 0; }
  retire_machine_from_caravan "$target"

  if [ "$target" = "$MACHINE" ]; then
    warn "that was this machine — its local state ($SATCHEL_DIR) still exists: config, agent logins, the sync clone"
    if confirm "delete the local state too? (agent logins in sessions will be lost)"; then
      local state install_dir
      state="$(readlink -f "$SATCHEL_DIR")"
      install_dir="$(dirname "$(readlink -f "$0")")"
      validate_state_removal_path "$state" "$install_dir"
      remove_tree_for_uninstall "$state"
      info "removed $SATCHEL_DIR — this machine is fully retired"
    fi
  fi
}
