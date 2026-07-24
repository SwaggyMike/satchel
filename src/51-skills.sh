session_skills_dir() {
  case "$1" in
    claude) printf '/home/satchel/.claude/skills' ;;
    codex)  printf '/home/satchel/.codex/skills' ;;
    *)      return 1 ;;
  esac
}

ensure_skill_library() {
  sync_ready || return 0
  local shared="$SYNC_DIR/skills/shared" ignore="$SYNC_DIR/.gitignore"
  mkdir -p "$shared"
  touch "$shared/.gitkeep" "$ignore"
  grep -Fqx '/skills/shared/.system/' "$ignore" \
    || printf '\n/skills/shared/.system/\n' >> "$ignore"
}

skill_name_valid() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

skill_validation_error() { # skill_validation_error <path> → prints reason
  local path="$1" name link target
  name="$(basename "$path")"
  if ! skill_name_valid "$name"; then
    printf 'directory name must start with a letter or number and use only letters, numbers, dots, underscores, and hyphens'
    return 0
  fi
  if [ "$name" = skills-lock.json ]; then
    if [ ! -f "$path" ] || [ -L "$path" ]; then
      printf 'skills-lock.json must be a real file'
      return 0
    fi
    if ! jq -e . "$path" >/dev/null 2>&1; then
      printf 'skills-lock.json must contain valid JSON'
      return 0
    fi
    return 1
  fi
  if [ ! -d "$path" ] || [ -L "$path" ]; then
    printf 'each top-level entry must be a real directory'
    return 0
  fi
  if [ ! -f "$path/SKILL.md" ]; then
    printf 'SKILL.md is missing'
    return 0
  fi
  if [ -n "$(find -P "$path" -mindepth 1 -name .git -print -quit 2>/dev/null)" ]; then
    printf 'nested .git metadata would sync as an incomplete embedded repository'
    return 0
  fi
  while IFS= read -r -d '' link; do
    target="$(readlink -f "$link" 2>/dev/null || true)"
    case "$target" in
      "$path"|"$path"/*) ;;
      *)
        printf 'symlink %s points outside the skill directory or is broken' "${link#"$path"/}"
        return 0
        ;;
    esac
  done < <(find -P "$path" -type l -print0 2>/dev/null)
  return 1
}

quarantine_skill_path() { # quarantine_skill_path <path> <reason> → prints destination
  local path="$1" reason="$2" name now out n=2 unexpected_file=0
  name="$(basename "$path")"
  if [ "$name" != skills-lock.json ] && [ -f "$path" ] && [ ! -L "$path" ]; then
    unexpected_file=1
  fi
  now="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$SKILL_QUARANTINE_DIR"
  out="$SKILL_QUARANTINE_DIR/$now--$name"
  while [ -e "$out" ] || [ -L "$out" ]; do
    out="$SKILL_QUARANTINE_DIR/$now--$name-$n"; n=$((n + 1))
  done
  mv -- "$path" "$out"
  if [ "$unexpected_file" -eq 1 ]; then
    warn "unexpected Skill Library file '$name' was quarantined; it may be installer metadata rather than a skill: $reason"
  else
    warn "Skill Library entry '$name' was quarantined: $reason"
  fi
  warn "preserved at $out (local only; not synced)"
  printf '%s' "$out"
}

restore_committed_skill() { # restore_committed_skill <name>
  local name="$1" rel="skills/shared/$1"
  git_sync rev-parse --verify HEAD >/dev/null 2>&1 || return 1
  git_sync cat-file -e "HEAD:$rel" 2>/dev/null || return 1
  git_sync restore --source=HEAD --worktree -- "$rel"
}

repair_skill_library() { # repair_skill_library <restore-previous:0|1>
  sync_ready || return 0
  local restore_previous="$1" shared="$SYNC_DIR/skills/shared"
  local path name reason restored_reason
  local paths=()
  ensure_skill_library
  while IFS= read -r -d '' path; do paths+=("$path"); done \
    < <(find -P "$shared" -mindepth 1 -maxdepth 1 -print0)
  for path in "${paths[@]}"; do
    name="$(basename "$path")"
    case "$name" in .gitkeep|.system) continue ;; esac
    reason="$(skill_validation_error "$path" || true)"
    [ -n "$reason" ] || continue
    quarantine_skill_path "$path" "$reason" >/dev/null
    if [ "$restore_previous" -eq 1 ] && restore_committed_skill "$name"; then
      restored_reason="$(skill_validation_error "$path" || true)"
      if [ -z "$restored_reason" ]; then
        if [ "$name" = skills-lock.json ]; then
          info "restored the previous valid skills-lock.json"
        else
          info "restored the previous valid copy of skill '$name'"
        fi
      else
        quarantine_skill_path "$path" "the previously committed copy is also invalid: $restored_reason" >/dev/null
      fi
    fi
  done
  return 0
}

report_skill_changes() {
  sync_ready || return 0
  local shared_rel=skills/shared path rel name
  local installed=() updated=() removed=() seen=$'\n'
  local changed=()
  if git_sync rev-parse --verify HEAD >/dev/null 2>&1; then
    while IFS= read -r -d '' path; do changed+=("$path"); done \
      < <(git_sync diff --name-only -z HEAD -- "$shared_rel")
  fi
  while IFS= read -r -d '' path; do changed+=("$path"); done \
    < <(git_sync ls-files --others --exclude-standard -z -- "$shared_rel")
  for path in "${changed[@]}"; do
    rel="${path#"$shared_rel"/}"; name="${rel%%/*}"
    [ -n "$name" ] && [[ "$name" != .* ]] || continue
    [ "$name" != skills-lock.json ] || continue
    [[ "$seen" != *$'\n'"$name"$'\n'* ]] || continue
    seen+="$name"$'\n'
    if git_sync cat-file -e "HEAD:$shared_rel/$name" 2>/dev/null; then
      if [ -e "$SYNC_DIR/$shared_rel/$name" ] || [ -L "$SYNC_DIR/$shared_rel/$name" ]; then
        updated+=("$name")
      else
        removed+=("$name")
      fi
    else
      installed+=("$name")
    fi
  done
  [ ${#installed[@]} -eq 0 ] || info "skills installed: $(IFS=', '; printf '%s' "${installed[*]}")"
  [ ${#updated[@]} -eq 0 ] || info "skills updated: $(IFS=', '; printf '%s' "${updated[*]}")"
  [ ${#removed[@]} -eq 0 ] || info "skills removed: $(IFS=', '; printf '%s' "${removed[*]}")"
}

# The handoff and Satchel runtime contract reach the agent through its global
# memory file inside the satchel-owned home (~/.claude/CLAUDE.md,
# ~/.codex/AGENTS.md). Rewritten at every session start, so it always reflects
# the current project and session mode — the agent can't know on its own that
# /etc belongs to a disposable container, or that a Host Session's real /etc
# lives under /host.
