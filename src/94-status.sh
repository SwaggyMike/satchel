
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
  e="$(engine 2>/dev/null || true)"
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
    local s list=""
    for s in "$SYNC_DIR/skills/shared"/*/; do
      [ -d "$s" ] && list="$list$(basename "$s"), "
    done
    printf '  %s\n' "${list:-(none), }" | sed 's/, $//'
    if [ -d "$SKILL_QUARANTINE_DIR" ]; then
      local quarantined=0
      for s in "$SKILL_QUARANTINE_DIR"/*; do
        [ -e "$s" ] || [ -L "$s" ] || continue
        quarantined=$((quarantined + 1))
      done
      [ "$quarantined" -eq 0 ] \
        || printf '  quarantined locally: %s (%s)\n' "$quarantined" "$SKILL_QUARANTINE_DIR"
    fi
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
