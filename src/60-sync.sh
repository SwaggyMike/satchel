
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

quiet_pull() { # best-effort, at session start; offline is fine
  sync_ready && has_upstream || return 0
  timeout 20 git -C "$SYNC_DIR" pull --rebase -q 2>/dev/null \
    || warn "could not pull the Sync Repo (offline, or uncommitted changes in it) — continuing with what's local"
}

# One "session:" commit per session buries the Sync Repo's history in noise.
# When the previous commit is the identical session marker (same machine and
# project) from under an hour ago, the new sync is folded into it instead of
# minting another commit. The hour is anchored on the author date, which
# --amend preserves, so back-to-back sessions collapse into hourly commits
# rather than one endlessly-sliding chain. Handoffs still push immediately.
sync_rollup_ok() { # sync_rollup_ok <message>
  case "$1" in session:*) ;; *) return 1 ;; esac
  [ "$(git_sync log -1 --format=%s 2>/dev/null)" = "$1" ] || return 1
  local at; at="$(git_sync log -1 --format=%at)"
  [ $(( $(date +%s) - at )) -lt 3600 ]
}

quiet_push() { # quiet_push <message> — best-effort commit+push of the Sync Repo
  sync_ready || return 0
  ensure_sync_identity
  validate_sync_state
  git_sync add -A
  git_sync diff --cached --quiet && return 0
  if sync_rollup_ok "$1"; then
    local pre; pre="$(git_sync rev-parse HEAD)"
    if git_sync commit -q --amend --no-edit 2>/dev/null; then
      timeout 30 git -C "$SYNC_DIR" push -q --force-with-lease origin HEAD 2>/dev/null && return 0
      # Another machine pushed meanwhile (or we are offline): undo the
      # amend and fall through to a plain commit so nothing of theirs can
      # be overwritten. reset --soft keeps this session's changes staged.
      git_sync reset -q --soft "$pre"
    fi
  fi
  git_sync commit -q -m "$1" || return 0
  has_upstream && { timeout 30 git -C "$SYNC_DIR" pull --rebase -q 2>/dev/null || true; }
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
  local stamp="$SATCHEL_DIR/update-check" now last remote
  now="$(date +%s)"
  last="$(tr -cd 0-9 < "$stamp" 2>/dev/null)" || last=""
  [ $((now - ${last:-0})) -lt 86400 ] && return 0
  printf '%s' "$now" > "$stamp"
  remote="$(remote_script_blob)" || remote=""
  [ -n "$remote" ] && [ "$remote" != "$(script_blob)" ] \
    && info "a newer satchel is on GitHub - run 'satchel update' when convenient"
  return 0
}
