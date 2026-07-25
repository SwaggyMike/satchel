
# ----------------------------------------------------------------- sync

validate_sync_state() {
  sync_ready || return 0
  validate_machine_state
  validate_mcp_state
  validate_project_state
}

# Session path: invalid synced state must never stop an agent from starting.
# The strict validators die on purpose (they are right for 'satchel sync' and
# 'satchel status'), so run them in a subshell and turn a fatal exit into a
# degraded, still-usable session.
validate_sync_state_soft() {
  sync_ready || return 0
  local err rc=0
  err="$( validate_sync_state 2>&1 )" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  degrade_sync "${err##*satchel: error: }"
  return 0
}

sync_machine_registration() { # sync_machine_registration <machine-name>
  local name="$1"
  ensure_sync_identity
  validate_sync_state
  git_sync add -A
  git_sync diff --cached --quiet || git_sync commit -q -m "add machine $name"
  # An existing clone may be behind another machine. Integrate first so a
  # normal non-fast-forward is not misreported as a read-only deploy key.
  local reg_log; reg_log="$(mktemp)"
  if has_upstream && ! git_sync pull --rebase >"$reg_log" 2>&1; then
    recover_sync_repo || true
    cat "$reg_log" >&2; rm -f "$reg_log"
    die "the Sync Repo has a change that conflicts with this machine's — reconcile $SYNC_DIR with normal git, then run 'satchel sync'"
  fi
  rm -f "$reg_log"
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
  if sync_needs_recovery; then
    recover_sync_repo \
      || die "an unfinished Git operation in $SYNC_DIR could not be repaired automatically — resolve it there with normal git, then run 'satchel sync' again"
    die "another machine changed the same file; Satchel backed out rather than guess.
       The repository is clean again and nothing local was lost — reconcile $SYNC_DIR with normal git, then run 'satchel sync' again"
  fi
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
  # Capture Git's narration so a successful rebase stays quiet, and show it only
  # when the user actually has to act on it.
  local pull_log; pull_log="$(mktemp)"
  if has_upstream && ! git_sync pull --rebase >"$pull_log" 2>&1; then
    recover_sync_repo || true
    cat "$pull_log" >&2; rm -f "$pull_log"
    die "another machine changed the same file; Satchel backed out rather than guess.
       Nothing local was lost — reconcile $SYNC_DIR with normal git, then run 'satchel sync' again"
  fi
  rm -f "$pull_log"
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

# Recover from an interrupted or conflicted Sync Repo operation without human
# git surgery. Satchel deliberately does not try to merge: it abandons the
# operation and returns the clone to a clean tree. That is always safe, because
# the local commit stays on the branch — only its integration is postponed —
# and it keeps this path small enough to reason about.
#
#   0 = clean again; local work intact but not integrated with the remote
#   1 = still broken; the caller should degrade
recover_sync_repo() {
  sync_needs_recovery || return 0
  git_sync rebase --abort >/dev/null 2>&1 \
    || git_sync merge --abort >/dev/null 2>&1 \
    || git_sync cherry-pick --abort >/dev/null 2>&1 \
    || git_sync revert --abort >/dev/null 2>&1 || true
  # A rebase started with --autostash restores pre-existing tracked edits when
  # aborted. Do not reset afterward merely to make the tree look clean: those
  # edits can be the only surviving copy of work from an interrupted session.
  # If aborting did not clear the operation or its unmerged entries, the check
  # below fails and the caller degrades syncing instead of deleting anything.
  sync_needs_recovery && return 1
  return 0
}

# Pull at session start. This is best-effort by definition: being offline,
# behind, or even mid-conflict must never stop the agent from starting, so the
# only non-zero return is an actual user interrupt.
conflict_left_for_user() {
  warn "another machine changed the same Sync Repo file; Satchel backed out rather than guess"
  warn "nothing local was lost — reconcile $SYNC_DIR with normal git, then run 'satchel sync'"
  return 0
}

handle_sync_conflict() { # shared by pull and push: recover, then say what happened
  if recover_sync_repo; then
    conflict_left_for_user
  else
    degrade_sync "an unfinished Git operation in $SYNC_DIR could not be repaired automatically"
  fi
  return 0
}

quiet_pull() {
  sync_ready || return 0
  # Recovery is checked before has_upstream on purpose: an interrupted rebase
  # detaches HEAD, so '@{u}' does not resolve and the old ordering skipped this
  # check in exactly the state it exists to catch.
  if sync_needs_recovery; then
    handle_sync_conflict
    return 0
  fi
  has_upstream || return 0
  local rc=0
  timeout 20 git -C "$SYNC_DIR" pull --rebase --autostash -q >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 130 ] && return 130
  if [ "$rc" -ne 0 ]; then
    if sync_needs_recovery; then
      handle_sync_conflict
      return 0
    fi
    warn "could not reach the Sync Repo — continuing with what's local"
  fi
  return 0
}

quiet_push() { # quiet_push <message> — best-effort commit+push of the Sync Repo
  sync_ready || return 0
  ensure_sync_identity
  validate_sync_state_soft
  sync_ready || return 0
  git_sync add -A
  git_sync diff --cached --quiet && return 0
  git_sync commit -q -m "$1" || return 0
  if has_upstream && ! timeout 30 git -C "$SYNC_DIR" pull --rebase -q >/dev/null 2>&1; then
    if sync_needs_recovery; then
      handle_sync_conflict
      # Backing out left the branch behind the remote, so there is nothing safe
      # to push yet. The session's commit is on the branch and survives.
      warn "this session is committed locally and is not lost"
    else
      warn "could not reach the Sync Repo — this session is committed locally; run 'satchel sync' when back online"
    fi
    return 0
  fi
  timeout 30 git -C "$SYNC_DIR" push -q -u origin HEAD 2>/dev/null \
    || warn "could not push the Sync Repo — the change is committed locally; run 'satchel sync' when back online"
  return 0
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
