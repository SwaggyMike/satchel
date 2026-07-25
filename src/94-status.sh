
# ----------------------------------------------------------------- status

cmd_status() {
  local show_ignored=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --ignored) show_ignored=1 ;;
      *) die "unknown status option '$1'" ;;
    esac
    shift
  done
  out_header "Satchel $SATCHEL_VERSION on $MACHINE"
  local e img="not built"
  # detect_engine, not engine: a reporting command must still print the rest of
  # the report on a host with no container engine.
  e="$(detect_engine)"
  if [ -n "$e" ] && "$e" image inspect "$IMAGE" >/dev/null 2>&1; then
    img="built"
    local av; av="$(image_agent_versions)"
    [ -n "$av" ] && img="built ($av)"
  fi
  printf '  engine: %s, image: %s\n' "${e:-none}" "$img"

  printf '\n'; out_section 'Commands:'
  printf '  %-10s %s\n' "claude" "$(shim_status claude)"
  printf '  %-10s %s\n' "codex" "$(shim_status codex)"

  if ! sync_ready; then
    printf '  sync: not set up (run satchel init)\n'
  else
    validate_sync_state
    printf '  sync: %s\n' "$SYNC_URL"
    printf '  last sync commit: %s\n' "$(git_sync log -1 --format='%h %s (%cr)' 2>/dev/null || echo none)"
    # Syncing fails open now: a session never stops because the Sync Repo is
    # unhappy. The cost is that work can quietly pile up unpushed, so the
    # command people actually run has to surface it — not just doctor. Silent
    # when there is nothing to say.
    if has_upstream; then
      local counts behind ahead
      counts="$(git_sync rev-list --left-right --count '@{u}...HEAD' 2>/dev/null || echo '0 0')"
      behind="${counts%%[[:space:]]*}"; ahead="${counts##*[[:space:]]}"
      [ "$ahead" -eq 0 ] \
        || printf '  %sunpushed: %s commit(s) — run satchel sync%s\n' "$OUT_YELLOW" "$ahead" "$OUT_RESET"
      [ "$behind" -eq 0 ] \
        || printf '  %sbehind origin by %s commit(s) — run satchel sync%s\n' "$OUT_YELLOW" "$behind" "$OUT_RESET"
    fi
    local bv; bv="$(baseline_marker_version)"
    if [ -z "$bv" ]; then
      if [ -f "$(baseline_skip_file)" ]; then
        printf '  machine baseline: not built (reminder disabled)\n'
      else
        printf '  machine baseline: missing (offered after an authenticated agent launch)\n'
      fi
    elif [ "$bv" -lt "$BASELINE_VERSION" ]; then
      printf '  machine baseline: version %s; version %s is available (run satchel init to refresh)\n' "$bv" "$BASELINE_VERSION"
    else
      printf '  machine baseline: version %s\n' "$bv"
    fi
    printf '\n'; out_section 'Caravan:'
    local m mh f
    for m in "$SYNC_DIR"/machines/*/; do
      [ -d "$m" ] || continue
      mh=0
      for f in "$m"handoffs/*.md; do [ -f "$f" ] && mh=$((mh + 1)); done
      printf '  %s%s\n' "$(basename "$m")" "$([ "$mh" -gt 0 ] && printf ', %s machine handoff(s)' "$mh")"
    done
    printf '\n'; out_section 'Projects:'
    local p f date count origin
    for p in "$SYNC_DIR"/projects/*/; do
      [ -d "$p" ] || continue
      f="$(latest_handoff "$(basename "$p")")"
      date=""; count=0
      [ -n "$f" ] && date="$(sed -n "1s/.*date=\([^ ]*\).*/\1/p" "$f")"
      for f in "$p"handoffs/*.md; do [ -f "$f" ] && count=$((count + 1)); done
      origin="$(origin_for_project "$(basename "$p")")"
      [ -n "$origin" ] || origin="local or no origin"
      printf '  %-22s %-38s %s handoff(s)%s\n' "$(basename "$p")" "$origin" "$count" "${date:+, latest $date}"
    done
    local ignored=0 registry
    registry="$(repository_registry_file)"
    [ -f "$registry" ] && ignored="$(jq '[.[] | select(.status == "ignored")] | length' "$registry")"
    printf '  ignored repositories: %s%s\n' "$ignored" "$([ "$show_ignored" -eq 0 ] && [ "$ignored" -gt 0 ] && printf ' (use satchel status --ignored to list)')"
    if [ "$show_ignored" -eq 1 ] && [ "$ignored" -gt 0 ]; then
      jq -r 'to_entries[] | select(.value.status == "ignored") | "    " + .key' "$registry"
    fi
    local names; names="$(mcp_names | paste -sd, - | sed 's/,/, /g')"
    printf '\n%sMCP servers:%s %s\n' "$OUT_BOLD$OUT_BLUE" "$OUT_RESET" "${names:-(none)}"
    out_section 'Skills:'
    local list quarantined
    list="$(skill_names | paste -sd, - | sed 's/,/, /g')"
    printf '  %s\n' "${list:-(none)}"
    quarantined="$(skill_quarantine_count)"
    [ "$quarantined" -eq 0 ] \
      || printf '  quarantined locally: %s (%s)\n' "$quarantined" "$SKILL_QUARANTINE_DIR"
  fi

  # Plugins are per-host by design (ADR 0003) — say what lives only here.
  if [ -d "$HOME/.claude/plugins" ]; then
    local p plist=""
    for p in "$HOME"/.claude/plugins/*/; do
      [ -d "$p" ] || continue
      case "$(basename "$p")" in cache|marketplaces) continue ;; esac
      plist="$plist$(basename "$p"), "
    done
    if [ -n "$plist" ]; then
      printf '\nClaude plugins on this host only (not synced): %s\n' "${plist%, }"
    fi
  fi
  return 0
}
