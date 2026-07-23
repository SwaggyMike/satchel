
# ------------------------------------------------------ machine baseline

machine_dir()             { printf '%s/machines/%s' "$SYNC_DIR" "$MACHINE"; }
baseline_notes_file()     { printf '%s/notes.md' "$(machine_dir)"; }
baseline_inventory_file() { printf '%s/inventory.md' "$(machine_dir)"; }
baseline_skip_file()      { printf '%s/.baseline-skip' "$(machine_dir)"; }

validate_machine_state() {
  valid_machine_name "$MACHINE" || die "unsafe machine name '$MACHINE'"
  [ -d "$SYNC_DIR/machines" ] || return 0
  local entry name
  while IFS= read -r -d '' entry; do
    [ -d "$entry" ] && [ ! -L "$entry" ] \
      || die "invalid machine entry: $entry"
    name="$(basename "$entry")"
    valid_machine_name "$name" \
      || die "unsafe machine directory '$name' in the Sync Repo"
  done < <(find -P "$SYNC_DIR/machines" -mindepth 1 -maxdepth 1 -print0)
}

warn_machine_notes_size() {
  local notes words
  notes="$(baseline_notes_file)"
  [ -f "$notes" ] || return 0
  words="$(wc -w < "$notes")"
  [ "$words" -le "$MACHINE_NOTES_WORD_LIMIT" ] || \
    warn "machine notes are $words words (soft limit: $MACHINE_NOTES_WORD_LIMIT); consolidate or move detail into guides"
}

baseline_marker_version() {
  local f
  # Version 2 keeps the marker with the dated inventory it describes. Read
  # the old notes location as a migration fallback so existing machines are
  # reported as v1 instead of being mistaken for never-onboarded machines.
  for f in "$(baseline_inventory_file)" "$(baseline_notes_file)"; do
    [ -f "$f" ] || continue
    sed -n '1s/^<!-- satchel-machine-baseline version=\([0-9][0-9]*\) generated=[^ ]* -->$/\1/p' "$f"
    return 0
  done
}

baseline_generated_at() {
  local f
  for f in "$(baseline_inventory_file)" "$(baseline_notes_file)"; do
    [ -f "$f" ] || continue
    sed -n '1s/^<!-- satchel-machine-baseline version=[0-9][0-9]* generated=\([^ ]*\) -->$/\1/p' "$f"
    return 0
  done
}

baseline_authenticated() { # baseline_authenticated <claude|codex> <agent-home>
  case "$1" in
    # A logged-in claude home has .claude/.credentials.json (OAuth) or auth
    # material inside .claude.json (API key, or the OAuth account record).
    # Plain existence of .claude.json proves nothing — materialize_mcp
    # writes one before any login.
    claude)
      [ -f "$2/.claude/.credentials.json" ] && return 0
      [ -f "$2/.claude.json" ] || return 1
      jq -e '(.oauthAccount // .primaryApiKey // "") | length > 0' "$2/.claude.json" >/dev/null 2>&1
      ;;
    codex)  [ -f "$2/.codex/auth.json" ] ;;
  esac
}

baseline_added_lines() { # baseline_added_lines <old-file> <new-file>
  diff -u "$1" "$2" 2>/dev/null | sed -n '/^+++ /d; /^+/s/^+//p' || true
}

baseline_secret_scan() { # baseline_secret_scan <old-file> <new-file>
  local added
  added="$(baseline_added_lines "$1" "$2")"
  [ -z "$added" ] && return 0
  # Deliberately conservative and scoped only to newly-added lines. Do not
  # echo matches: a warning must never become another place a secret leaks.
  if printf '%s\n' "$added" | grep -Eiq \
    -- 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|(^|[^A-Za-z])(password|passwd|secret|token|api[_-]?key)[[:space:]]*[:=][[:space:]]*[^[:space:]<]|https?://[^/@[:space:]]+:[^/@[:space:]]+@|Bearer[[:space:]]+[A-Za-z0-9._~+/-]{16,}'; then
    return 1
  fi
  if printf '%s\n' "$added" | grep -Eq -- '(^|[^A-Fa-f0-9])[A-Fa-f0-9]{48,}([^A-Fa-f0-9]|$)|(^|[^A-Za-z0-9+/])[A-Za-z0-9+/]{64,}={0,2}([^A-Za-z0-9+/]|$)'; then
    return 1
  fi
  return 0
}

machine_knowledge_files() { # machine_knowledge_files <machine-dir> → relative paths
  local dir="$1" f
  [ -f "$dir/notes.md" ] && printf 'notes.md\n'
  [ -f "$dir/inventory.md" ] && printf 'inventory.md\n'
  if [ -d "$dir/guides" ]; then
    while IFS= read -r f; do printf '%s\n' "${f#"$dir/"}"; done \
      < <(find "$dir/guides" -type f -name '*.md' -print | sort)
  fi
}

baseline_added_knowledge_lines() { # baseline_added_knowledge_lines <old-dir> <new-dir>
  local old="$1" new="$2" rel
  while IFS= read -r rel; do
    if [ -f "$old/$rel" ]; then
      baseline_added_lines "$old/$rel" "$new/$rel"
    else
      cat "$new/$rel"
    fi
  done < <({ machine_knowledge_files "$old"; machine_knowledge_files "$new"; } | sort -u)
}

baseline_secret_scan_tree() { # baseline_secret_scan_tree <old-dir> <new-dir>
  local added
  added="$(baseline_added_knowledge_lines "$1" "$2")"
  [ -z "$added" ] && return 0
  local old new
  old="$(mktemp)"; new="$(mktemp)"
  : > "$old"; printf '%s\n' "$added" > "$new"
  local rc=0
  baseline_secret_scan "$old" "$new" || rc=$?
  rm -f "$old" "$new"
  return "$rc"
}

compose_baseline_run_args() { # compose_baseline_run_args <agent> <home>
  local agent="$1" home="$2"
  RUN_ARGS=(--init --label "$MANAGED_CONTAINER_LABEL" -e HOME=/home/satchel
    -e "TERM=${TERM:-xterm-256color}" -e DISABLE_AUTOUPDATER=1)
  RUN_ARGS+=(-v "$home:/home/satchel")
  if [ "$agent" = codex ]; then compose_codex_mcp_env; fi
  compose_clipboard_args
  mkdir -p "$SYNC_DIR/machines/$MACHINE"
  RUN_ARGS+=(-v "$SYNC_DIR/machines/$MACHINE:/home/satchel/machine")
  RUN_ARGS+=(-v "/:/host:ro" -w /home/satchel)
  RUN_ARGS+=(--user "$SATCHEL_UID:$SATCHEL_GID" --cap-drop ALL --security-opt no-new-privileges)
  if selinux_active; then RUN_ARGS+=(--security-opt label=disable); fi
  # keep-id invents a passwd entry when SATCHEL_UID is absent from the image
  # (custom UIDs); template its home to the agent home so ssh agrees with
  # $HOME there too. Ignored when the UID already exists in the image.
  if podman_rootless; then RUN_ARGS+=(--userns=keep-id --passwd-entry '$USERNAME:*:$UID:$GID::/home/satchel:/bin/bash'); fi
}

prepare_baseline_home() { # repair files a previous root Host Session may have left behind
  mkdir -p "$1"
  fix_home_ownership "$1"
  # Satchel itself may run as root on Unraid while safe sessions run as uid
  # 1000. Keep the one synced directory this session may edit writable too.
  mkdir -p "$SYNC_DIR/machines/$MACHINE"
  fix_home_ownership "$SYNC_DIR/machines/$MACHINE"
}

run_machine_baseline() { # run_machine_baseline <agent> <home>
  local agent="$1" home="$2" inventory machine before prompt rc=0
  prepare_baseline_home "$home"
  machine="$(machine_dir)"; inventory="$(baseline_inventory_file)"
  mkdir -p "$machine"
  before="$(mktemp -d)"; cp -a "$machine/." "$before/"
  prompt="Satchel machine-baseline onboarding, version $BASELINE_VERSION. Inspect this machine conservatively and read-only. The real host filesystem is mounted at /host; the container's bare /etc, /var, and similar paths are disposable and are not the host. You cannot and must not change the host, install packages, restart services, or use control sockets.

First inspect, then show the user the exact content of every file you propose changing. Do not write anything until the user approves it. After approval, organize the machine knowledge as follows:

1. Replace /home/satchel/machine/inventory.md with a dated reference inventory covering identity and OS, hardware, storage and filesystems, networking, configured services, containers and major workloads, and administration/development tools. Distinguish live observations from configuration inferred from files when it matters. Put this exact machine-readable marker on line 1, substituting the current UTC time for TIMESTAMP:
<!-- satchel-machine-baseline version=$BASELINE_VERSION generated=TIMESTAMP -->
Use an initial structure of Identity and OS, Hardware, Storage and filesystems, Network, Services, Containers and workloads, and Development and administration tools, omitting empty sections.

2. Merge only concise, enduring operational knowledge into /home/satchel/machine/notes.md. A note qualifies only when it remains true after this task, is machine-specific or unusually important, and would prevent meaningful wasted work, mistakes, or harm in a future session. Organize by topic; describe current truth or a future condition, never the incident that revealed it. Merge or replace existing entries instead of appending a history. Keep machine-wide unresolved risks here until resolved. The file has a soft ceiling of $MACHINE_NOTES_WORD_LIMIT words: consolidate before exceeding it, but never discard essential information merely to hit the number.

3. If a qualifying reusable procedure needs substantial detail, put it in /home/satchel/machine/guides/<topic>.md and leave only a short pointer or warning in notes.md. Maintain one current guide per topic, updated in place; never create dated incident guides. Do not create a guide for an ordinary or resolved one-time fix.

Unfinished task state belongs in handoffs, project behavior belongs in that project's own documentation, and resolved one-time incidents belong nowhere. Preserve correct existing notes and guides, update verified stale facts, and delete obsolete or incident-only material during a refresh. Do not modify projects.json or handoffs.

Never record passwords, tokens, keys, cookies, complete environment dumps, credential-bearing URLs, or secret values. Do not paste raw command output."
  compose_baseline_run_args "$agent" "$home"
  local tty=() launch
  [ -t 0 ] && tty=(-it)
  case "$agent" in
    claude) launch=(claude "$prompt") ;;
    codex)  launch=(codex -c 'sandbox_mode="danger-full-access"' -c check_for_update_on_startup=false "$prompt") ;;
  esac
  warn "BASELINE INSPECTION - the real machine is visible at /host read-only; only the synced machine-knowledge directory is writable"
  "$(engine)" run --rm "${tty[@]}" "${RUN_ARGS[@]}" "$IMAGE" "${launch[@]}" || rc=$?

  if [ ! -f "$inventory" ] || { [ -f "$before/inventory.md" ] && cmp -s "$before/inventory.md" "$inventory" 2>/dev/null; }; then
    warn "machine baseline was not written; onboarding remains incomplete"
    [ "$rc" -eq 0 ] || warn "baseline agent exited with status $rc; continuing to the requested session"
    rm -rf "$before"; return 0
  fi
  if [ "$(baseline_marker_version)" != "$BASELINE_VERSION" ]; then
    SYNC_BLOCK_REASON="machine inventory changed without a valid baseline marker"
    warn "$SYNC_BLOCK_REASON; automatic sync is disabled until the machine knowledge is reviewed"
    rm -rf "$before"; return 0
  fi
  if ! baseline_secret_scan_tree "$before" "$machine"; then
    SYNC_BLOCK_REASON="the baseline machine knowledge contains a possible secret in newly-added content"
    warn "$SYNC_BLOCK_REASON; no suspected value was printed and automatic sync is disabled"
    rm -rf "$before"; return 0
  fi
  rm -rf "$before"
  warn_machine_notes_size
  quiet_push "machine baseline v$BASELINE_VERSION on $MACHINE"
  success "machine baseline saved to the private Sync Repo"
  return 0
}

maybe_offer_baseline() { # maybe_offer_baseline <agent> <home>
  local agent="$1" home="$2" choice skip
  [ "$HOST_MODE" -eq 0 ] || return 0
  sync_ready && [ -t 0 ] && baseline_authenticated "$agent" "$home" || return 0
  [ -z "$(baseline_marker_version)" ] || return 0
  skip="$(baseline_skip_file)"; [ -f "$skip" ] && return 0
  choice="$(choose_baseline)"
  case "$choice" in
    yes) run_machine_baseline "$agent" "$home" ;;
    never)
      printf 'suppressed at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$skip"
      quiet_push "skip machine baseline on $MACHINE"
      info "machine-baseline reminder disabled; remove ${skip#"$SYNC_DIR"/} to restore it"
      ;;
  esac
}

offer_baseline_refresh() {
  sync_ready && [ -t 0 ] || return 0
  local ca=0 co=0 agent="" question="take an initial baseline of this system now?"
  baseline_authenticated claude "$HOMES_DIR/claude" && ca=1
  baseline_authenticated codex "$HOMES_DIR/codex" && co=1
  [ "$ca" -eq 1 ] || [ "$co" -eq 1 ] || return 0
  [ -n "$(baseline_marker_version)" ] && question="refresh the existing baseline of this system now?"
  explain_machine_baseline
  confirm "$question" || return 0
  if [ "$ca" -eq 1 ] && [ "$co" -eq 1 ]; then
    local reply
    read -r -p "$(prompt_text "agent [claude/codex] [claude]: ")" reply
    case "$reply" in [cC]odex) agent=codex ;; *) agent=claude ;; esac
  # A silent single-agent pick looks like a wrong default; say why.
  elif [ "$ca" -eq 1 ]; then agent=claude; info "using claude — codex is not logged in on this machine"
  else agent=codex; info "using codex — claude is not logged in on this machine"
  fi
  ensure_image
  rm -f "$(baseline_skip_file)"
  run_machine_baseline "$agent" "$HOMES_DIR/$agent"
}
