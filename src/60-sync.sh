
# ----------------------------------------------------------------- sync

validate_sync_state() {
  sync_ready || return 0
  validate_machine_state
  validate_mcp_state
  validate_project_state
}

sync_machine_registration() { # sync_machine_registration <machine-name>
  local name="$1"
  ensure_sync_identity
  validate_sync_state
  git_sync add -A
  git_sync diff --cached --quiet || git_sync commit -q -m "add machine $name"
  # An existing clone may be behind another machine. Integrate first so a
  # normal non-fast-forward is not misreported as a read-only deploy key.
  if has_upstream && ! git_sync pull --rebase; then
    die "Sync Repo pull hit a conflict — resolve it in $SYNC_DIR with normal git, then run 'satchel sync' again"
  fi
  # This remains the write-access check: a read-only deploy key fails here,
  # after remote history is known to be integrated.
  if git_sync push -u origin HEAD; then
    success "machine '$name' joined the caravan"
  else
    warn "Sync Repo push failed — the remote may be read-only or temporarily unreachable"
    warn "fix access or connectivity, then run 'satchel sync'"
    return 1
  fi
}

cmd_sync() {
  sync_ready || die "sync is not set up — run 'satchel init' first"
  ensure_sync_identity
  ensure_skill_library
  repair_skill_library 1
  report_skill_changes
  validate_sync_state
  prune_all_handoffs
  git_sync add -A
  if ! git_sync diff --cached --quiet; then
    git_sync commit -q -m "sync from $MACHINE"
    info "committed local changes"
  fi
  # Conflicts are surfaced, never auto-resolved: a failed rebase stops here
  # and leaves the repo for the user to resolve with plain git.
  if has_upstream && ! git_sync pull --rebase; then
    die "pull hit a conflict — resolve it in $SYNC_DIR with normal git, then run 'satchel sync' again"
  fi
  git_sync push -u origin HEAD
  info "synced with $SYNC_URL"
}

sync_needs_recovery() {
  local git_dir marker unmerged
  git_dir="$(git_sync rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    [ ! -e "$git_dir/$marker" ] || return 0
  done
  unmerged="$(git_sync diff --name-only --diff-filter=U 2>/dev/null)" || return 0
  [ -z "$unmerged" ] || return 0
  return 1
}

quiet_pull() { # best-effort, at session start; offline is fine
  sync_ready && has_upstream || return 0
  if sync_needs_recovery; then
    warn "Sync Repo has an unfinished Git operation — resolve it in $SYNC_DIR, then run 'satchel sync'"
    return 1
  fi
  local rc=0
  timeout 20 git -C "$SYNC_DIR" pull --rebase --autostash -q 2>/dev/null || rc=$?
  [ "$rc" -eq 130 ] && return 130
  if [ "$rc" -ne 0 ]; then
    if sync_needs_recovery; then
      warn "Sync Repo pull hit a conflict — resolve it in $SYNC_DIR, then run 'satchel sync'"
      return 1
    fi
    warn "could not reach the Sync Repo — continuing with what's local"
  fi
  return 0
}

quiet_push() { # quiet_push <message> — best-effort commit+push of the Sync Repo
  sync_ready || return 0
  ensure_sync_identity
  validate_sync_state
  git_sync add -A
  git_sync diff --cached --quiet && return 0
  git_sync commit -q -m "$1" || return 0
  if has_upstream && ! timeout 30 git -C "$SYNC_DIR" pull --rebase -q 2>/dev/null; then
    if sync_needs_recovery; then
      warn "Sync Repo pull conflicted — this session is committed locally; resolve it in $SYNC_DIR, then run 'satchel sync'"
    else
      warn "could not reach the Sync Repo — this session is committed locally; run 'satchel sync' when back online"
    fi
    return 0
  fi
  timeout 30 git -C "$SYNC_DIR" push -q -u origin HEAD 2>/dev/null \
    || warn "could not push the Sync Repo — the change is committed locally; run 'satchel sync' when back online"
}

# Announce when GitHub main carries a newer script than the one running.
# Compared by git blob hash of the file itself, not by remembered commit,
# so hand-installed copies (dev machines) are judged correctly. At most one
# probe per day, stamped before the probe so an offline day costs one
# failed curl, not one per session; never fatal, never blocks a session.
script_blob() { git hash-object "$(readlink -f "$0")" 2>/dev/null; }

remote_script_blob() {
  timeout 5 curl -fsSL "https://api.github.com/repos/$SATCHEL_REPO/contents/satchel?ref=main" 2>/dev/null \
    | jq -r '.sha // empty'
}

update_check() {
  local stamp="$SATCHEL_DIR/update-check" now last remote rc=0
  now="$(date +%s)"
  if [ -f "$stamp" ]; then
    last="$(tr -cd 0-9 < "$stamp")" || last=""
  else
    last=""
  fi
  [ $((now - ${last:-0})) -lt 86400 ] && return 0
  printf '%s' "$now" > "$stamp"
  remote="$(remote_script_blob)" || rc=$?
  [ "$rc" -eq 130 ] && return 130
  [ "$rc" -eq 0 ] || remote=""
  [ -n "$remote" ] && [ "$remote" != "$(script_blob)" ] \
    && info "a newer satchel is on GitHub - run 'satchel update' when convenient"
  return 0
}
