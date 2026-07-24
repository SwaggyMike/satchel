
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
    local rec=0; recover_sync_repo || rec=$?
    if [ "$rec" -ne 0 ]; then
      cat "$reg_log" >&2; rm -f "$reg_log"
      die "Sync Repo pull hit a conflict Satchel cannot merge — resolve it in $SYNC_DIR with normal git, then run 'satchel sync' again"
    fi
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
  local rec=0
  if sync_needs_recovery; then
    recover_sync_repo || rec=$?
    case "$rec" in
      1) die "an unfinished Git operation in $SYNC_DIR could not be repaired automatically — resolve it there with normal git, then run 'satchel sync' again" ;;
      2) die "a conflicting change in $SYNC_DIR could not be merged automatically.
       The repository is clean again and nothing local was lost; reconcile it with normal git, then run 'satchel sync' again" ;;
    esac
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
  # Satchel-owned registries are merged automatically; anything else stops here
  # and is left for the user to resolve with plain git.
  # Keep Git's own conflict narration back until it is known to matter: an
  # auto-merged registry is routine, and printing "Resolve all conflicts
  # manually" for something Satchel just resolved sends the user to do work
  # that is already done. Show the real output only when it is still their job.
  local pull_log; pull_log="$(mktemp)"
  if has_upstream && ! git_sync pull --rebase >"$pull_log" 2>&1; then
    rec=0; recover_sync_repo || rec=$?
    if [ "$rec" -ne 0 ]; then
      cat "$pull_log" >&2; rm -f "$pull_log"
      die "pull hit a conflict Satchel cannot merge — resolve it in $SYNC_DIR with normal git, then run 'satchel sync' again"
    fi
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

# ---------------------------------------------------- automatic conflict repair
#
# Satchel's shared registries are rewritten wholesale by whichever machine
# touches them, so two machines changing different entries between syncs is the
# normal case, not an exceptional one. Left alone that produces a conflicted
# rebase, and every later command on that machine dies parsing the markers.
# These files have known structure, so merge them mechanically instead of
# asking the user to resolve a rebase by hand in a hidden state directory.
#
# Merge rule for both shapes: keep every key from both sides, and let the local
# side win a genuine tie. Losing a remote entry is the only unrecoverable
# outcome, and a union never does that.

merge_conflicted_json() { # merge_conflicted_json <repo-relative-path> → 0 when merged
  local rel="$1" ours theirs merged rc=0
  ours="$(mktemp)"; theirs="$(mktemp)"; merged="$(mktemp)"
  # Stage 2 is the branch being rebased onto (what the remote already has);
  # stage 3 is the local commit being replayed.
  git_sync show ":2:$rel" > "$ours" 2>/dev/null || rc=1
  git_sync show ":3:$rel" > "$theirs" 2>/dev/null || rc=1
  if [ "$rc" -eq 0 ] && jq -e . "$ours" >/dev/null 2>&1 && jq -e . "$theirs" >/dev/null 2>&1 \
     && jq -s '.[0] * .[1]' "$ours" "$theirs" > "$merged" 2>/dev/null; then
    cp -- "$merged" "$SYNC_DIR/$rel"
    git_sync add -- "$rel"
  else
    rc=1
  fi
  rm -f "$ours" "$theirs" "$merged"
  return "$rc"
}

merge_conflicted_env() { # merge_conflicted_env <repo-relative-path> → 0 when merged
  local rel="$1" ours theirs merged rc=0 key seen=$'\n' line
  ours="$(mktemp)"; theirs="$(mktemp)"; merged="$(mktemp)"
  git_sync show ":2:$rel" > "$ours" 2>/dev/null || rc=1
  git_sync show ":3:$rel" > "$theirs" 2>/dev/null || rc=1
  if [ "$rc" -eq 0 ]; then
    # Local lines first so a locally-set value wins; remote-only keys follow.
    while IFS= read -r line; do
      case "$line" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
      key="${line%%=*}"
      [[ "$seen" != *$'\n'"$key"$'\n'* ]] || continue
      seen+="$key"$'\n'
      printf '%s\n' "$line" >> "$merged"
    done < <(cat "$theirs" "$ours")
    cp -- "$merged" "$SYNC_DIR/$rel"
    chmod 600 "$SYNC_DIR/$rel"
    git_sync add -- "$rel"
  fi
  rm -f "$ours" "$theirs" "$merged"
  return "$rc"
}

resolve_sync_conflicts() { # → 0 when every conflicted path was merged
  local path rc=0 any=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    any=1
    case "$path" in
      repositories.json|mcp.json|machines/*/projects.json|skills/shared/skills-lock.json)
        merge_conflicted_json "$path" || rc=1 ;;
      settings.env|mcp-tokens.env)
        merge_conflicted_env "$path" || rc=1 ;;
      *) rc=1 ;;
    esac
  done < <(git_sync diff --name-only --diff-filter=U 2>/dev/null)
  [ "$any" -eq 1 ] || return 1
  return "$rc"
}

# Recover from an interrupted or conflicted Sync Repo operation without human
# git surgery. Auto-merge what Satchel owns and continue; otherwise abandon the
# operation, which is always safe — the local commit stays on the branch and
# only the integration is postponed.
#
#   0 = merged and integrated; the branch advanced and is safe to push
#   2 = abandoned back to a clean tree; local work intact but not integrated
#   1 = still broken; caller should degrade
recover_sync_repo() {
  local git_dir
  sync_needs_recovery || return 0
  git_dir="$(git_sync rev-parse --absolute-git-dir 2>/dev/null)" || return 1

  if resolve_sync_conflicts; then
    if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
      if GIT_EDITOR=true git_sync rebase --continue >/dev/null 2>&1 && ! sync_needs_recovery; then
        info "merged a concurrent Sync Repo change automatically"
        return 0
      fi
    elif [ -e "$git_dir/MERGE_HEAD" ]; then
      if GIT_EDITOR=true git_sync commit -q --no-edit >/dev/null 2>&1 && ! sync_needs_recovery; then
        info "merged a concurrent Sync Repo change automatically"
        return 0
      fi
    fi
  fi

  # Could not merge. Abandon the in-progress operation so the machine keeps
  # working; nothing local is lost, and 'satchel sync' retries once the
  # conflicting file is understood.
  git_sync rebase --abort >/dev/null 2>&1 \
    || git_sync merge --abort >/dev/null 2>&1 \
    || git_sync cherry-pick --abort >/dev/null 2>&1 \
    || git_sync revert --abort >/dev/null 2>&1 || true
  git_sync reset -q --hard >/dev/null 2>&1 || true
  sync_needs_recovery && return 1
  return 2
}

# Pull at session start. This is best-effort by definition: being offline,
# behind, or even mid-conflict must never stop the agent from starting, so the
# only non-zero return is an actual user interrupt.
unmergeable_conflict_warning() {
  warn "a concurrent Sync Repo change could not be merged automatically and was left for you"
  warn "nothing local was lost; resolve $SYNC_DIR with normal git, then run 'satchel sync'"
  return 0
}

quiet_pull() {
  sync_ready || return 0
  local rec=0
  # Recovery is checked before has_upstream on purpose: an interrupted rebase
  # detaches HEAD, so '@{u}' does not resolve and the old ordering skipped this
  # check in exactly the state it exists to catch.
  if sync_needs_recovery; then
    recover_sync_repo || rec=$?
    case "$rec" in
      1) degrade_sync "an unfinished Git operation in $SYNC_DIR could not be repaired automatically"; return 0 ;;
      2) unmergeable_conflict_warning; return 0 ;;
    esac
  fi
  has_upstream || return 0
  local rc=0
  timeout 20 git -C "$SYNC_DIR" pull --rebase --autostash -q >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 130 ] && return 130
  if [ "$rc" -ne 0 ]; then
    if sync_needs_recovery; then
      rec=0; recover_sync_repo || rec=$?
      case "$rec" in
        1) degrade_sync "a Sync Repo conflict in $SYNC_DIR could not be merged automatically" ;;
        2) unmergeable_conflict_warning ;;
      esac
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
      local rec=0
      recover_sync_repo || rec=$?
      case "$rec" in
        1) degrade_sync "a Sync Repo conflict in $SYNC_DIR could not be merged automatically"
           warn "this session is committed locally and is not lost"
           return 0 ;;
        2) unmergeable_conflict_warning
           # Abandoning left the branch behind the remote, so there is nothing
           # safe to push yet. The commit is on the branch and survives.
           warn "this session is committed locally and is not lost"
           return 0 ;;
      esac
    else
      warn "could not reach the Sync Repo — this session is committed locally; run 'satchel sync' when back online"
      return 0
    fi
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
