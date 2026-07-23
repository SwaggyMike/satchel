
# ----------------------------------------------------------------- doctor

d_ok()   { printf '  %sok%s    %s\n' "$OUT_GREEN" "$OUT_RESET" "$*"; }
d_warn() { printf '  %swarn%s  %s\n' "$OUT_YELLOW" "$OUT_RESET" "$*"; }
d_fail() { printf '  %sFAIL%s  %s\n' "$OUT_RED$OUT_BOLD" "$OUT_RESET" "$*"; DOCTOR_PROBLEMS=$((DOCTOR_PROBLEMS + 1)); }

cmd_doctor() {
  DOCTOR_PROBLEMS=0
  out_header "satchel $SATCHEL_VERSION doctor — machine $MACHINE"

  local missing="" c
  for c in git jq curl ssh ssh-add ssh-agent; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
  if [ -z "$missing" ]; then d_ok "host tools: git, jq, curl, ssh, ssh-add, ssh-agent"; else d_fail "missing host tools:$missing"; fi

  local e=""
  if e="$(engine 2>/dev/null)" && "$e" info >/dev/null 2>&1; then
    d_ok "engine: $e"
  else
    d_fail "no working container engine — install/start docker or podman"
  fi

  if [ -n "$e" ] && "$e" image inspect "$IMAGE" >/dev/null 2>&1; then
    local av; av="$(image_agent_versions)"
    d_ok "image: built${av:+ ($av)}"
    if engine_mount_probe; then
      d_ok "bind mounts: engine can read Satchel's local state"
    else
      d_fail "bind mounts: engine cannot read Satchel's local state (unsupported nested-container setup?)"
    fi
  else
    d_warn "image not built yet — builds on first session, or run 'satchel update'"
  fi

  if have_pubkey; then d_ok "ssh key: present"; else d_warn "no ssh key — 'satchel key' makes one"; fi

  local blob
  blob="$(remote_script_blob)" || blob=""
  if [ -z "$blob" ]; then d_warn "update check: could not reach GitHub"
  elif [ "$blob" = "$(script_blob)" ]; then d_ok "script: up to date with GitHub main"
  else d_warn "script: GitHub main has a newer satchel - run 'satchel update'"; fi

  case "$(ssh_agent_state)" in
    ready) d_ok   "ssh-agent: keys loaded - sessions can push over SSH" ;;
    empty) d_warn "ssh-agent: reachable but no keys loaded - run 'ssh-add' so sessions can push over SSH" ;;
    dead)  d_warn "ssh-agent: SSH_AUTH_SOCK is set but no agent answered" ;;
    none)  d_warn "ssh-agent: not running - sessions cannot push over SSH" ;;
    off)   d_ok   "ssh forwarding: disabled (SATCHEL_SSH=0)" ;;
  esac

  local a
  for a in claude codex; do
    [ -d "$HOMES_DIR/$a" ] || continue
    if ! podman_rootless && [ -n "$(find "$HOMES_DIR/$a" ! -user "$SATCHEL_UID" -print -quit 2>/dev/null)" ]; then
      d_warn "$a home has internal files not owned by uid $SATCHEL_UID — the next $a session prepares them automatically"
    fi
  done

  if [ -z "$SYNC_URL" ]; then
    d_warn "sync not configured — 'satchel init' to join a caravan"
  elif ! sync_ready; then
    d_fail "SYNC_URL is set but there is no clone at $SYNC_DIR — rerun 'satchel init'"
  else
    if timeout 10 git -C "$SYNC_DIR" ls-remote origin HEAD >/dev/null 2>&1; then
      d_ok "sync remote reachable"
    else
      d_fail "sync remote unreachable: $SYNC_URL (network? key removed from the git host?)"
    fi
    if git_sync diff --quiet 2>/dev/null && git_sync diff --cached --quiet 2>/dev/null \
       && [ -z "$(git_sync status --porcelain 2>/dev/null)" ]; then
      d_ok "sync tree clean"
    else
      d_warn "uncommitted changes in the sync clone — next session end or 'satchel sync' commits them"
    fi
    if has_upstream; then
      local counts behind ahead
      counts="$(git_sync rev-list --left-right --count '@{u}...HEAD' 2>/dev/null || echo '0 0')"
      behind="${counts%%[[:space:]]*}"; ahead="${counts##*[[:space:]]}"
      if [ "$behind" -gt 0 ]; then d_warn "behind origin by $behind commit(s) — 'satchel sync' to pull"; else d_ok "up to date with origin"; fi
      [ "$ahead" -gt 0 ] && d_warn "ahead of origin by $ahead unpushed commit(s) — 'satchel sync' to push"
    else
      d_warn "no upstream yet — the first 'satchel sync' sets it"
    fi
  fi

  if [ -f "$MCP_FILE" ]; then
    local name url auth code
    while IFS=$'\t' read -r name url auth; do
      [ -n "$name" ] || continue
      if [ "$auth" = "bearer" ] && [ -z "$(token_for "$name")" ]; then
        d_warn "mcp '$name': no token on this machine — sessions will prompt for it"
      fi
      report_mcp_probe "$name" "$url" "$(probe_mcp "$url")" d_ok d_fail
    done < <(jq -r '.servers | to_entries[] | "\(.key)\t\(.value.url)\t\(.value.auth)"' "$MCP_FILE" 2>/dev/null)
  fi

  if [ "$DOCTOR_PROBLEMS" -eq 0 ]; then
    info "no problems found"
  else
    die "$DOCTOR_PROBLEMS problem(s) — fix the FAIL lines above"
  fi
}
