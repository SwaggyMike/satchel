
# --------------------------------------------------------------- handoffs

HANDOFF_MARK='<!-- satchel-handoff'

# Sessions outside any tracked project (Host Sessions fixing the machine
# itself, mostly) still produce context worth keeping - it is kept per
# machine instead of per project: machines/<name>/handoffs/. An empty
# project id selects that machine scope.
latest_handoff() { # latest_handoff <project-id> → prints newest handoff
  local slug="$1" dir best="" f
  if [ -n "$slug" ]; then dir="$SYNC_DIR/projects/$slug/handoffs"
  else dir="$SYNC_DIR/machines/$MACHINE/handoffs"; fi
  # file_handoff derives sortable filenames from the same UTC timestamp written
  # into the header. Treat the filename as the durable ordering key everywhere:
  # a truncated header must not make a retained newer handoff invisible.
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    best="$f"
  done
  [ -n "$best" ] && printf '%s' "$best"
  return 0
}

# Agent-native path where Satchel mounts the one shared Skill Library.
# Keep the mount, runtime environment, and generated instructions on this
# single source of truth.
