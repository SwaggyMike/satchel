
# ------------------------------------------------------------ mcp registry

MCP_FILE="$SYNC_DIR/mcp.json"
SYNC_TOKENS_FILE="$SYNC_DIR/mcp-tokens.env"
MCP_RUNTIME_ENV_NAMES=()

mcp_name_valid() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

mcp_url_valid() {
  jq -en --arg url "$1" \
    '$url | length > 0 and (explode | all(. >= 32 and . != 34 and . != 92 and . != 127))' \
    >/dev/null
}

validate_mcp_state() {
  [ -f "$MCP_FILE" ] || return 0
  # Required fields are checked; unknown ones are ignored so a newer Satchel
  # elsewhere in the caravan cannot brick this machine (see validate_project_state).
  jq -e '
    type == "object"
    and has("servers")
    and (.servers | type == "object")
    and all(.servers | to_entries[];
      (.key | test("^[A-Za-z0-9_-]+$"))
      and (.value | type == "object")
      and (.value.url | type == "string"
        and length > 0
        and (explode | all(. >= 32 and . != 34 and . != 92 and . != 127)))
      and (.value.auth == "bearer" or .value.auth == "none"))
  ' "$MCP_FILE" >/dev/null \
    || die "invalid mcp.json — expected safely named servers with url and bearer/none auth fields"
}

token_for() { # token_for <name> → prints token or nothing (local overrides synced)
  local name="$1" line
  for f in "$LOCAL_TOKENS_FILE" "$SYNC_TOKENS_FILE"; do
    [ -f "$f" ] || continue
    line="$(grep -m1 "^${name}=" "$f" || true)"
    if [ -n "$line" ]; then printf '%s' "${line#*=}"; return 0; fi
  done
  return 0
}

set_token() { # set_token <name> <token> <file>
  local name="$1" token="$2" f="$3"
  touch "$f" && chmod 600 "$f"
  grep -v "^${name}=" "$f" > "$f.tmp" || true
  printf '%s=%s\n' "$name" "$token" >> "$f.tmp"
  mv "$f.tmp" "$f" && chmod 600 "$f"
}

# Probe an MCP URL and print a verdict word: ok:<code> | notfound | tls | plainhttp | down
# 404 means "host yes, path no"; a TLS-only failure means a self-signed cert;
# https that only answers as http means the wrong scheme was registered.
probe_mcp() {
  local url="$1" code
  code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" || code=000
  if [ "$code" = "000" ]; then
    code="$(curl -sk -m 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" || code=000
    if [ "$code" != "000" ]; then echo tls; return 0; fi
    case "$url" in
      https://*)
        code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://${url#https://}" 2>/dev/null)" || code=000
        [ "$code" != "000" ] && { echo plainhttp; return 0; }
        ;;
    esac
    echo down; return 0
  fi
  [ "$code" = "404" ] && { echo notfound; return 0; }
  echo "ok:$code"
}

report_mcp_probe() { # report_mcp_probe <name> <url> <verdict> <ok_fn> <bad_fn>
  local name="$1" url="$2" verdict="$3" ok_fn="$4" bad_fn="$5"
  case "$verdict" in
    ok:*)      "$ok_fn" "mcp '$name': endpoint is reachable" ;;
    notfound)  "$bad_fn" "mcp '$name': the host answers but nothing lives at that path — wrong URL? ($url)" ;;
    tls)       "$bad_fn" "mcp '$name': answers only with TLS verification off — self-signed certificate? agents may refuse it" ;;
    plainhttp) "$bad_fn" "mcp '$name': nothing speaks https there, but plain http answers — re-add with http:// instead" ;;
    *)         "$bad_fn" "mcp '$name': unreachable ($url)" ;;
  esac
}

mcp_names() {
  [ -f "$MCP_FILE" ] || return 0
  jq -r '.servers | keys[]' "$MCP_FILE" 2>/dev/null || true
}

# Codex doesn't take MCP bearer tokens inline; its config names an env var
# (bearer_token_env_var) and the session passes the token through it.
mcp_env_name() { # mcp_env_name <server-name> → SATCHEL_MCP_TOKEN_<NAME>
  printf 'SATCHEL_MCP_TOKEN_%s' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
}

# Remove the short-lived variables exported for Docker/Podman inheritance.
clear_codex_mcp_env() {
  local name
  for name in "${MCP_RUNTIME_ENV_NAMES[@]}"; do unset "$name"; done
  MCP_RUNTIME_ENV_NAMES=()
}

# Passing NAME=value directly to Docker/Podman discloses bearer tokens in the
# host process list. Export the value in Satchel's launch process and give the
# engine only -e NAME; each separate Satchel process owns its variables, so
# concurrent sessions cannot overwrite one another.
compose_codex_mcp_env() { # appends to RUN_ARGS
  local n t name
  clear_codex_mcp_env
  while IFS= read -r n; do
    t="$(token_for "$n")"
    if [ -n "$t" ]; then
      name="$(mcp_env_name "$n")"
      printf -v "$name" '%s' "$t"
      export "$name"
      MCP_RUNTIME_ENV_NAMES+=("$name")
      RUN_ARGS+=(-e "$name")
    fi
  done < <(mcp_names)
}

cmd_mcp() {
  sync_ready || die "sync is not set up — run 'satchel init' first"
  validate_mcp_state
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list)
      [ -f "$MCP_FILE" ] || { info "no MCP servers registered"; return 0; }
      jq -r '.servers | to_entries[] | "\(.key)\t\(.value.url)\t\(.value.auth)"' "$MCP_FILE" \
        | while IFS=$'\t' read -r name url auth; do
            local has="no token"
            [ -n "$(token_for "$name")" ] && has="token on this machine"
            printf '  %s%-20s%s %s  (%s, %s)\n' "$OUT_BOLD$OUT_BLUE" "$name" "$OUT_RESET" "$url" "$auth" "$has"
          done
      ;;
    add)
      local name="${1:-}" url="${2:-}" auth="bearer"
      # Bare 'satchel mcp add' walks through it; args skip the questions.
      if [ -z "$name" ]; then
        read -r -p "$(prompt_text "  server name (e.g. homeassistant): ")" name
        [ -n "$name" ] || { info "cancelled"; return 0; }
      fi
      if [ -z "$url" ]; then
        read -r -p "$(prompt_text "  server URL (e.g. http://host:8123/api/mcp): ")" url
        [ -n "$url" ] || { info "cancelled"; return 0; }
        if ! confirm_yes "  does it need a bearer token?"; then auth="none"; fi
      fi
      [ "${3:-}" = "--no-auth" ] && auth="none"
      mcp_name_valid "$name" || die "server name must be [a-zA-Z0-9_-]"
      mcp_url_valid "$url" \
        || die "server URL cannot contain quotes, backslashes, or control characters"
      [ -f "$MCP_FILE" ] || printf '{ "servers": {} }\n' > "$MCP_FILE"
      jq --arg n "$name" --arg u "$url" --arg a "$auth" \
        '.servers[$n] = {url: $u, auth: $a}' "$MCP_FILE" > "$MCP_FILE.tmp"
      mv "$MCP_FILE.tmp" "$MCP_FILE"
      if [ "$auth" = "bearer" ] && [ -z "$(token_for "$name")" ]; then
        prompt_token "$name"
      fi
      quiet_push "mcp: add $name"
      info "registered '$name' for the whole caravan"
      report_mcp_probe "$name" "$url" "$(probe_mcp "$url")" info warn
      ;;
    remove)
      local name="${1:-}"
      if [ -z "$name" ]; then
        [ -f "$MCP_FILE" ] || die "no MCP servers registered"
        local names=()
        while IFS= read -r n; do names+=("$n"); done < <(mcp_names)
        [ "${#names[@]}" -gt 0 ] || die "no MCP servers registered"
        info "registered servers:"
        for i in "${!names[@]}"; do
          printf '  %s%d)%s %s\n' "$ERR_BOLD$ERR_BLUE" "$((i + 1))" "$ERR_RESET" "${names[$i]}" >&2
        done
        local choice
        read -r -p "$(prompt_text "remove which server? [1-${#names[@]}, empty to cancel]: ")" choice
        [ -n "$choice" ] || { info "cancelled"; return 0; }
        printf '%s' "$choice" | grep -Eq '^[0-9]+$' && [ "$choice" -ge 1 ] && [ "$choice" -le "${#names[@]}" ] \
          || die "not a valid choice: $choice"
        name="${names[$((choice - 1))]}"
      fi
      mcp_name_valid "$name" || die "server name must be [a-zA-Z0-9_-]"
      [ -f "$MCP_FILE" ] && { jq --arg n "$name" 'del(.servers[$n])' "$MCP_FILE" > "$MCP_FILE.tmp"; mv "$MCP_FILE.tmp" "$MCP_FILE"; }
      for f in "$LOCAL_TOKENS_FILE" "$SYNC_TOKENS_FILE"; do
        [ -f "$f" ] && { grep -v "^${name}=" "$f" > "$f.tmp" || true; mv "$f.tmp" "$f"; chmod 600 "$f"; }
      done
      quiet_push "mcp: remove $name"
      info "removed '$name' (if its token was ever synced it remains in git history — rotate it at the source if that matters)"
      ;;
    *) die "usage: satchel mcp [list|add|remove]" ;;
  esac
}

prompt_token() { # ADR 0002: offer synced (default) or local-only storage
  local name="$1" token where
  printf '\n' >&2
  read -r -s -p "$(prompt_text "  token for '$name' (input is hidden; Enter to skip): ")" token; printf '\n' >&2
  [ -n "$token" ] || { warn "no token given — '$name' will be configured without auth headers"; return 0; }
  printf '  %s1)%s synced — available on every machine\n' "$ERR_BOLD$ERR_BLUE" "$ERR_RESET" >&2
  printf '  %s2)%s local — this machine only\n' "$ERR_BOLD$ERR_BLUE" "$ERR_RESET" >&2
  read -r -p "$(prompt_text "  store token where? [1]: ")" where
  printf '\n' >&2
  if [ "$where" = "2" ]; then
    set_token "$name" "$token" "$LOCAL_TOKENS_FILE"
    info "token saved on this machine only"
  else
    set_token "$name" "$token" "$SYNC_TOKENS_FILE"
    info "token saved to the Sync Repo (private; see docs/adr/0002)"
  fi
}

# Materialize the registry into each agent's native config inside its satchel
# home. The registry is the source of truth: the managed section is rebuilt
# every session start. Claude takes tokens inline in .claude.json; codex only
# takes an env var name (bearer_token_env_var), so the session passes the
# token through an inherited environment variable whose value is absent from
# container-engine argv. Either way the agent-native materialization never
# syncs.
materialize_mcp() {
  local agent="$1" home="$2"
  [ -f "$MCP_FILE" ] || return 0
  validate_mcp_state
  local servers="{}" block="" name url auth token
  while IFS=$'\t' read -r name url auth; do
    token="$(token_for "$name")"
    if [ "$auth" = "bearer" ] && [ -z "$token" ]; then
      prompt_token "$name"
      token="$(token_for "$name")"
    fi
    case "$agent" in
      claude)
        if [ -n "$token" ]; then
          servers="$(jq -n --argjson s "$servers" --arg n "$name" --arg u "$url" --arg t "$token" \
            '$s + {($n): {type:"http", url:$u, headers:{Authorization:("Bearer " + $t)}}}')"
        else
          servers="$(jq -n --argjson s "$servers" --arg n "$name" --arg u "$url" \
            '$s + {($n): {type:"http", url:$u}}')"
        fi
        ;;
      codex)
        block="${block}[mcp_servers.${name}]"$'\n'"url = \"${url}\""$'\n'
        if [ -n "$token" ]; then
          block="${block}bearer_token_env_var = \"$(mcp_env_name "$name")\""$'\n'
        fi
        ;;
    esac
  done < <(jq -r '.servers | to_entries[] | "\(.key)\t\(.value.url)\t\(.value.auth)"' "$MCP_FILE")

  case "$agent" in
    claude)
      local cfg="$home/.claude.json"
      [ -f "$cfg" ] || printf '{}\n' > "$cfg"
      jq --argjson s "$servers" '.mcpServers = $s' "$cfg" > "$cfg.tmp" && mv -f "$cfg.tmp" "$cfg"
      ;;
    codex)
      # The managed block is rebuilt each session; everything outside it is
      # untouched. Codex writes learned project trust and per-tool approval
      # tables immediately before a trailing comment, which can put them
      # inside our marker when it ends the file. Rescue any non-base table
      # found there, then place the managed block before the first table so
      # future Codex-owned tables stay outside it.
      local cfg="$home/.codex/config.toml"
      mkdir -p "$home/.codex"
      touch "$cfg"
      : > "$cfg.rescued"
      if ! awk -v rescued="$cfg.rescued" '
        $0 == "# >>> satchel mcp >>>" {
          if (opened || inside) exit 2
          opened=1; inside=1; keep=0; next
        }
        $0 == "# <<< satchel mcp <<<" {
          if (!inside || closed) exit 2
          closed=1; inside=0; keep=0; next
        }
        inside {
          if ($0 ~ /^\[mcp_servers\.[A-Za-z0-9_-]+\][[:space:]]*$/) {
            keep=0; next
          }
          if ($0 ~ /^\[/) keep=1
          if (keep) print > rescued
          next
        }
        { print }
        END { if (inside || opened != closed) exit 2 }
      ' "$cfg" > "$cfg.tmp"; then
        rm -f "$cfg.tmp" "$cfg.rescued"
        die "Codex config has malformed Satchel MCP markers; leaving it unchanged: $cfg"
      fi
      {
        awk '/^\[/{ exit } { print }' "$cfg.tmp"
        printf '# >>> satchel mcp >>>\n# managed by satchel — rebuilt every session start\n%s# <<< satchel mcp <<<\n' "$block"
        awk 'seen || /^\[/{ seen=1; print }' "$cfg.tmp"
        cat "$cfg.rescued"
      } > "$cfg.new"
      mv -f "$cfg.new" "$cfg"
      rm -f "$cfg.tmp" "$cfg.rescued"
      ;;
  esac
}
