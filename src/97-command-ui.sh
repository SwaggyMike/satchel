
# ------------------------------------------------------------------- help

cmd_help() {
  out_header "Satchel $SATCHEL_VERSION — AI coding agents in disposable containers."
  cat <<EOF
usage: satchel [--host] <command> [args]

sessions
  satchel claude [args]        run Claude Code in a throwaway container, in \$PWD
  satchel codex [args]         same for Codex
  --host                     Host Session: sandbox off, host / at /host, root
                             (troubleshooting the machine itself — see CONTEXT.md)
  --unsafe-home              allow a session in \$HOME or above (mounts it ALL,
                             SSH keys and tokens included — normally refused)
  --with <dir>               mount an extra directory alongside the project
                             (repeatable - for repos that influence each other)
                             flags work before or after the agent name:
                             'satchel --host claude' == 'claude --host'
  satchel track [id]           track the enclosing Git repo as a project
  satchel untrack [id]         globally ignore a project; id works without a checkout

caravan
  satchel init                 name this machine, connect the Sync Repo
  satchel sync                 commit, pull, push the Sync Repo
  satchel status [--ignored]   caravan roster, projects, handoffs, MCP, skills
  satchel key                  show this machine's SSH public key (makes one if needed)
  satchel retire [machine]     remove a machine from the caravan (picks from a list)
  satchel doctor               check this machine's whole setup and say what's wrong

setup
  satchel link [claude|codex]  redirect claude/codex commands through satchel
  satchel unlink [claude|codex] remove the redirects (use the native CLIs directly)
  satchel uninstall             remove Satchel, its shims and image; preserve local state
                               (--purge also deletes local state; --yes skips confirmation)
  satchel import claude|codex  copy this host's agent login into satchel's sessions
  satchel mcp list|add|remove  manage the MCP Registry (synced to every machine);
                             bare 'add' or 'remove' walks through it interactively
  satchel settings             show every setting; 'satchel settings <KEY> <value>'
                             sets it caravan-wide (--local: this machine only)

  satchel image                build the shared agent image if it is missing
  satchel update               self-update from git main + rebuild the image
  satchel version

Skills: ask an agent to install one mid-session. Satchel tells it the exact
read-write Skill Library path (also in SATCHEL_SKILLS_DIR), and session-end
sync carries the complete skill folder to every machine and both agents.
EOF
}

cmd_track() {
  sync_ready || die "sync is not set up — run 'satchel init' first"
  [ $# -le 1 ] || die "usage: satchel track [project-id]"
  local id; id="$(enroll_project "$PWD" "${1:-}")"
  quiet_push "track project $id"
  info "tracking '$id' at $(git_root_for_path "$PWD")"
}

untrack_project() { # untrack_project <project-id>
  local id="$1" identity dir f
  validate_project_state
  valid_project_id "$id" || die "invalid or unsafe project id '$id'"
  dir="$SYNC_DIR/projects/$id"
  [ -d "$dir" ] || die "unknown project id '$id' (run satchel status)"
  identity="$(origin_for_project "$id")"
  [ -z "$identity" ] || ignore_repository "$identity"

  # A Project is global: remove every checkout cache, then remove its active
  # handoffs. Sync Repo history remains the recovery path.
  for f in "$SYNC_DIR"/machines/*/projects.json; do
    [ -f "$f" ] || continue
    jq --arg id "$id" '.paths |= with_entries(select(.value.project != $id))' \
      "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
  rm -rf -- "$dir"
  validate_project_state
}

cmd_untrack() {
  sync_ready || die "sync is not set up — run 'satchel init' first"
  [ $# -le 1 ] || die "usage: satchel untrack [project-id]"
  local id="${1:-}" root
  if [ -z "$id" ]; then
    root="$(git_root_for_path "$PWD")"
    [ -n "$root" ] || die "$PWD is not inside a Git repository; pass a project id"
    local identity; identity="$(project_identity "$root")"
    [ -z "$identity" ] || id="$(project_for_identity "$identity")"
    [ -n "$id" ] || id="$(project_for_path "$root")"
  fi
  [ -n "$id" ] || die "this repository is not a tracked project"
  untrack_project "$id"
  quiet_push "ignore project $id"
  info "project '$id' is ignored across the caravan; active handoffs removed"
}
