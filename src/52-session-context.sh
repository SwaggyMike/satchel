write_memory_file() { # write_memory_file <agent> <home> <slug> <project>
  local agent="$1" home="$2" slug="$3" project="$4" target handoff from w context="" skills_dir session_mode=sandbox
  [ "$HOST_MODE" -eq 1 ] && session_mode=host
  case "$agent" in
    claude) target="$home/.claude/CLAUDE.md" ;;
    codex)  target="$home/.codex/AGENTS.md" ;;
  esac
  skills_dir="$(session_skills_dir "$agent")"
  mkdir -p "$(dirname "$target")"
  # Path-based attribution: which tracked projects can this session reach?
  local vis_paths=() vis_ids=() vp vi
  while IFS=$'\t' read -r vp vi; do vis_paths+=("$vp"); vis_ids+=("$vi"); done < <(visible_projects "$project")
  # A launch over exactly one tracked project reads like a session on that
  # project: inline its handoff instead of pointing at a list of one.
  if [ -z "$slug" ] && [ ${#vis_ids[@]} -eq 1 ]; then slug="${vis_ids[0]}"; fi
  handoff="$(latest_handoff "$slug")"
  [ -s "$SYNC_DIR/profile.md" ] && context="$(tail -n +2 "$SYNC_DIR/profile.md")"
  if [ -s "$SYNC_DIR/preferences.md" ]; then
    context="${context}${context:+$'\n\n'}$(tail -n +2 "$SYNC_DIR/preferences.md")"
  fi
  {
    printf '# Managed by Satchel — rewritten at every session start; do not edit.\n\n'
    printf '## Where you are running\n\n'
    if [ "$HOST_MODE" -eq 1 ]; then
      cat <<'EOF'
This is a Satchel Host Session: you run as root in a container with the real
machine's filesystem available at /host with its real mount permissions. The
container's own system directories (/etc, /usr, /var, ...) belong to the
disposable container, NOT to the machine. When the user names an absolute path
outside the project (e.g. /etc/fstab), they mean the machine's file — read and
edit it at /host/etc/fstab. A change successfully made under /host changes the
real machine.
EOF
    else
      cat <<EOF
This is a sandboxed Satchel session inside a disposable container. The project
directory ($project) and the Satchel-managed state described below are mounted
from the real machine; other paths (/etc, /usr, the user's home, ...) belong
to the container and are thrown away when the session ends. If the user asks
about a file outside the project directory, you cannot see the machine's copy
— say it is outside the sandbox rather than reporting it does not exist.
(Reaching the machine itself takes a Host Session: restart with --host.)
EOF
      if [ ${#WITH_DIRS[@]} -gt 0 ]; then
        printf '\nAlso mounted read-write at their real paths, as part of this working set (--with):\n'
        for w in "${WITH_DIRS[@]}"; do printf -- '- %s\n' "$w"; done
      fi
      # Only on a root-run host (Unraid & co), where the session deliberately
      # runs as an unprivileged uid the host's files do not belong to. An agent
      # that hits EACCES there will otherwise reach for chmod or sudo, neither
      # of which can help from inside the container.
      if [ "$(id -u)" -eq 0 ] && [ "$SATCHEL_UID" != 0 ]; then
        cat <<EOF

This session runs as uid $SATCHEL_UID, while the mounted files belong to the
host's root. A write can therefore fail with a permission error even when the
path is correct. That is host ownership and cannot be fixed from inside this
container; report it instead, and note that the user's fix is
\`chown -R $SATCHEL_UID:$SATCHEL_GID <path>\` on the host.
EOF
      fi
      case "${SSH_STATE:=$(ssh_agent_state)}" in
        ready) cat <<'EOF'

The host's ssh-agent is forwarded into this session, so git over SSH signs with
the identities loaded in it; no key files exist in the container. The host's
~/.ssh/config is NOT mounted, so per-host IdentityFile, User, and Port settings
from it do not apply here — a remote that relies on one of those may fail even
though other remotes work. `ssh-add -l` shows what is actually available.
"Permission denied (publickey)" means the needed key is not in the forwarded
agent; only the user can fix that on the host, so ask rather than debugging
credentials in here.
EOF
          ;;
        empty) cat <<'EOF'

The host's ssh-agent socket is forwarded into this session, but the agent
had no identities loaded at session start. git push/pull over SSH will fail
with "Permission denied (publickey)" until the user runs ssh-add on the
host; a key they add becomes usable here immediately, no restart needed.
The host's ~/.ssh/config is not mounted either, so per-host key selection from
it does not apply. If a push fails that way, ask the user to run ssh-add
instead of debugging credentials inside the container.
EOF
          ;;
        *) cat <<'EOF'

No ssh-agent reaches this session, so git over SSH cannot authenticate.
Commit locally and let the user push from the host, or use HTTPS remotes.
EOF
          ;;
      esac
    fi
    if sync_ready; then
      cat <<EOF

## Satchel Skill Library

You are running inside Satchel. Its shared Skill Library is mounted read-write
at $skills_dir. This is the Sync Repo's \`skills/shared/\` tree, not disposable
container state or an agent-local library: Claude and Codex sessions on every
machine use the same tree.

When the user asks to install a skill, put one complete skill directory
directly under $skills_dir. Preserve the whole bundle — \`SKILL.md\` and every
referenced \`references/\`, \`scripts/\`, and \`assets/\` file. Do not install a
second copy elsewhere or use a generic agent-only destination. Do not leave a
nested \`.git\` directory in a skill; download/copy the complete working tree
without repository metadata. The runtime also exposes \`SATCHEL_SESSION=1\`,
\`SATCHEL_SESSION_MODE=$session_mode\`, and \`SATCHEL_SKILLS_DIR=$skills_dir\`
so installers can detect this contract.

Satchel pulled the Sync Repo before this session and commits and pushes Skill
Library changes when the session exits, even when no handoff is written. It
validates user-installed skill bundles first; malformed attempts are preserved
in a machine-local quarantine and a previous valid version is restored.
Codex-owned \`.system\` skills stay local and are not synced. If the best-effort
push cannot reach the remote, the change remains in the local Sync Repo and
\`satchel sync\` retries it. Start a new session before relying on a newly
installed skill being discovered automatically.
EOF
      printf '\n## Machine Notes (%s)\n\n' "$MACHINE"
      if [ -s "$SYNC_DIR/machines/$MACHINE/notes.md" ]; then
        cat "$SYNC_DIR/machines/$MACHINE/notes.md"
        printf '\n'
      fi
      cat <<EOF
Machine knowledge shared with every session on $MACHINE lives under
/home/satchel/machine/. Keep /home/satchel/machine/notes.md as concise,
current operational context,
not history: save a fact there only when it remains true after the current
task, is machine-specific or unusually important, and would prevent meaningful
wasted work, mistakes, or harm later. Organize by topic and merge existing
entries instead of appending incidents. Remove resolved or obsolete material.
Keep machine-wide unresolved risks in notes; ordinary unfinished work belongs
in the handoff. The soft limit for notes.md is $MACHINE_NOTES_WORD_LIMIT words;
consolidate or move detail before exceeding it.

Detailed, repeatable machine procedures belong in guides/<topic>.md, one
current guide per topic. Project behavior belongs in that project's docs.
Resolved one-time fixes belong nowhere. When the user says to save or remember
something, preserve the useful substance concisely in the appropriate place;
only preserve exact wording when they explicitly ask for it. You may save a
clearly qualifying fact without being asked, but default to saving nothing
when uncertain. Mention any machine-knowledge changes in your final response.
Paths under /host apply only in Host Sessions.

Other machines' notes, guides, and inventories are readable under
/home/satchel/machines/<machine>/ — consult them when work references
another machine. They are read-only here; only a session on that machine
can change them.
EOF
      local inventory="$SYNC_DIR/machines/$MACHINE/inventory.md" generated="" guide title
      if [ -s "$inventory" ]; then
        generated="$(baseline_generated_at)"
        printf '\nThe dated machine inventory is available on demand at /home/satchel/machine/inventory.md%s. Read it when hardware, services, storage, or other system details matter; do not treat point-in-time observations as current without rechecking.\n' "${generated:+ (generated $generated)}"
      fi
      if compgen -G "$SYNC_DIR/machines/$MACHINE/guides/*.md" >/dev/null; then
        printf '\nAvailable on-demand machine guides:\n\n'
        for guide in "$SYNC_DIR/machines/$MACHINE"/guides/*.md; do
          title="$(sed -n 's/^# //p' "$guide" | head -n 1)"
          printf -- '- /home/satchel/machine/guides/%s%s\n' "$(basename "$guide")" "${title:+ — $title}"
        done
      fi
      local note_words=0
      [ -f "$SYNC_DIR/machines/$MACHINE/notes.md" ] \
        && note_words="$(wc -w < "$SYNC_DIR/machines/$MACHINE/notes.md")"
      if [ "$note_words" -gt "$MACHINE_NOTES_WORD_LIMIT" ]; then
        printf '\nThe machine notes are currently %s words, over the %s-word soft limit. Consolidate or move detail into guides before adding more.\n' "$note_words" "$MACHINE_NOTES_WORD_LIMIT"
      fi
      if [ "$HOST_MODE" -eq 0 ]; then
        cat <<'EOF'
Notes may mention machine paths that are not mounted in this session; those
are true facts about the machine, but the files are unreachable here - say
they are outside the sandbox rather than claiming they do not exist.
EOF
      fi
    fi
    printf '\n'
    if [ -n "$context" ]; then
      printf '## Global context\n\n'
      printf '%s\n\n' "$context"
    fi
    # Table of contents, not inlined context: the agent reads the handoff of
    # the project the user actually turns to, instead of starting every
    # session with all of them in its head.
    local vt=0 k
    for k in "${!vis_ids[@]}"; do [ "${vis_ids[$k]}" != "$slug" ] && vt=$((vt + 1)); done
    if [ "$vt" -gt 0 ]; then
      printf '## Tracked projects in this session\n\n'
      printf 'Work inside each of these directories belongs to that tracked project:\n\n'
      for k in "${!vis_ids[@]}"; do
        [ "${vis_ids[$k]}" = "$slug" ] && continue
        printf -- '- %s: %s\n' "${vis_ids[$k]}" "$(session_path "${vis_paths[$k]}")"
      done
      cat <<'EOF'

Each project's retained handoffs are under /home/satchel/projects/<id>/handoffs/ (read-only;
the file with the newest date in its first line is the latest). When the user
turns to one of these projects, read its latest handoff first. At session end
Satchel files a separate handoff for each project you worked in; work outside
every tracked project is filed under this machine instead. When repositories
are nested, the nearest enclosing repository owns the work.
EOF
      printf '\n'
    fi
    if [ -n "$handoff" ]; then
      from="$(sed -n "1s/.*machine=\([^ ]*\).*date=\([^ ]*\).*/machine \1, \2/p" "$handoff")"
      if [ -n "$slug" ]; then
        printf '## Handoff from the previous session on this project (%s)\n\n' "$from"
      else
        printf '## Handoff from the previous session on this machine outside any project (%s)\n\n' "$from"
      fi
      tail -n +2 "$handoff"
      printf '\nContinue from this handoff unless the user redirects you.\n'
    else
      if [ -n "$slug" ]; then
        printf 'No handoff exists for this project yet. One is written automatically when a meaningful session ends.\n'
      else
        printf 'This directory is not a tracked project. After substantive work in an unknown Git repository with a portable origin, Satchel asks whether to track that repository. Ordinary directories, ignored repositories, and explicitly local work use this machine handoff instead.\n'
      fi
    fi
  } > "$target"
  return 0
}
