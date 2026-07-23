
# ------------------------------------------------------------------- main

main() {
  load_config
  while :; do
    case "${1:-}" in
      --host)        HOST_MODE=1; shift ;;
      --unsafe-home) UNSAFE_HOME=1; shift ;;
      --with)        [ -n "${2:-}" ] || die "--with needs a directory"
                     WITH_DIRS+=("$2"); shift 2 ;;
      *) break ;;
    esac
  done
  [ -n "${SATCHEL_HOST:-}" ] && HOST_MODE=1
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    claude|codex)      cmd_session "$cmd" "$@" ;;
    init)              cmd_init "$@" ;;
    sync)              cmd_sync "$@" ;;
    status)            cmd_status "$@" ;;
    key)               cmd_key "$@" ;;
    retire)            cmd_retire "$@" ;;
    track)             cmd_track "$@" ;;
    untrack)           cmd_untrack "$@" ;;
    settings)          cmd_settings "$@" ;;
    doctor)            cmd_doctor "$@" ;;
    mcp)               cmd_mcp "$@" ;;
    link)              cmd_link "$@" ;;
    unlink)            cmd_unlink "$@" ;;
    uninstall)         cmd_uninstall "$@" ;;
    import)            cmd_import "$@" ;;
    image)             cmd_image "$@" ;;
    update)            cmd_update "$@" ;;
    version|--version) out_header "satchel $SATCHEL_VERSION" ;;
    help|--help|-h)    cmd_help ;;
    *)                 die "unknown command '$cmd' — try 'satchel help'" ;;
  esac
}

main "$@"
