
# --------------------------------------------------------------- settings

settings_source() { # settings_source <key> → local | synced | default
  if [ -f "$CONFIG_FILE" ] && grep -q "^$1=" "$CONFIG_FILE"; then echo local
  elif [ -f "$SYNC_SETTINGS_FILE" ] && grep -q "^$1=" "$SYNC_SETTINGS_FILE"; then echo synced
  else echo default; fi
}

write_setting() { # write_setting <file> <key> <value>
  local f="$1" k="$2" v="$3"
  touch "$f"
  { grep -v "^$k=" "$f" || true; printf '%s=%q\n' "$k" "$v"; } > "$f.tmp"
  mv "$f.tmp" "$f"
}

cmd_settings() {
  local key="${1:-}" row k scope def help
  if [ -z "$key" ]; then
    printf '%smachine:%s %s    %ssync repo:%s %s    (change via satchel init / satchel retire)\n\n' \
      "$OUT_BOLD$OUT_BLUE" "$OUT_RESET" "$MACHINE" "$OUT_BOLD$OUT_BLUE" "$OUT_RESET" \
      "${SYNC_URL:-none}"
    printf '%s%-28s %-22s %-8s %s%s\n' "$OUT_BOLD$OUT_BLUE" 'SETTING' 'VALUE' 'FROM' 'WHAT IT DOES' "$OUT_RESET"
    for row in "${SETTINGS_SPEC[@]}"; do
      IFS='|' read -r k scope def help <<< "$row"
      local val="${!k-}" src
      src="$(settings_source "$k")"
      if [ "$src" = default ]; then
        case "$k" in
          SATCHEL_ENGINE) val="$(detect_engine)"; val="${val:-none found}"; src="detected" ;;
          SATCHEL_UID|SATCHEL_GID) : ;;                      # resolved in load_config
          *) val="$def" ;;
        esac
      fi
      printf '%-28s %-22s %-8s %s\n' "$k" "${val:-''}" "$src" "$help ${scope:+[$scope]}"
    done
    printf "\nchange one:  satchel settings <SETTING> <value>\n"
    printf "             preference settings apply to the whole caravan; add --local to pin\n"
    printf "             just this machine, or set '' as the value to clear one\n"
    return 0
  fi

  [ $# -ge 2 ] || die "usage: satchel settings [<SETTING> <value> [--local]]"
  local value="$2" local_flag="${3:-}"
  local found=""
  for row in "${SETTINGS_SPEC[@]}"; do
    IFS='|' read -r k scope def help <<< "$row"
    [ "$k" = "$key" ] && { found="$scope"; break; }
  done
  [ -n "$found" ] || die "unknown setting '$key' — run 'satchel settings' to see them"

  if [ "$found" = pref ] && [ "$local_flag" != "--local" ]; then
    if ! sync_ready; then
      warn "sync is not set up — saving '$key' locally instead"
      write_setting "$CONFIG_FILE" "$key" "$value"
    else
      write_setting "$SYNC_SETTINGS_FILE" "$key" "$value"
      quiet_push "settings: $key on $MACHINE"
      info "'$key' set for the whole caravan"
    fi
  else
    write_setting "$CONFIG_FILE" "$key" "$value"
    info "'$key' set for this machine only"
  fi
}
