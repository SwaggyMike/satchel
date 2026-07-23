# Satchel

A single generated Bash artifact for running AI coding agents (Claude Code, Codex) in disposable Docker containers on home-lab Linux machines, with session handoffs and settings synced between machines via a private git remote. Its development source is organized by subsystem under `src/`. Deliberately not production-grade: simple, readable, boring.

## Language

**Satchel**:
The Satchel program itself — one generated Bash artifact, installed as the `satchel` command.
_Avoid_: daemon, service, platform

**Shim**:
A tiny wrapper command named `claude` or `codex` on the host PATH that execs `satchel claude` / `satchel codex`, so using Satchel feels identical to using the real CLI.
_Avoid_: alias, symlink

**Session**:
A single run of an agent CLI inside a throwaway Docker container, scoped to one directory (plus any extra directories named with repeatable `--with` flags, for work that spans repos). The container is deleted when the session ends. Work is attributed to the nearest enclosing tracked Project, regardless of where the session was launched.
_Avoid_: workspace, environment

**Project**:
A Git repository the user explicitly chose to track. `repositories.json` is the sole authority for canonical network-origin identity and the global tracked/ignored decision; `projects/<id>/` holds only handoffs, while checkout paths are machine-local caches pointing to that global ID. Folder names never establish identity. Unknown repos prompt only after substantive work. `satchel track` can explicitly link a repo with a local or missing origin, but ordinary directories are never Projects.
_Avoid_: every working directory, every repository (ignored and unknown repos are not Projects)

**Sync Repo**:
The user-owned private git repository (cloned at `~/.satchel/sync/`) that carries handoffs, tool settings, the repository registry, the MCP Registry, and the Skill Library between machines. Its origin may be a hosted remote, an SSH bare repo, or a local bare repo on a consistently available NFS share. Agent login credentials and transcripts never enter it.
_Avoid_: cloud, backend, server

**MCP Registry**:
The single synced file listing the user's MCP servers (name, URL, token). At session start, satchel materializes it into each agent's native config format. Registered once, preconfigured everywhere.
_Avoid_: integrations list, connectors

**Skill Library**:
The folder of user-installed agent skills carried whole in the Sync Repo, shared by both agents. Satchel mounts it into every session as that agent's own skills directory (`~/.claude/skills`, `~/.codex/skills`), exposes the exact path as `SATCHEL_SKILLS_DIR`, and explains the contract in the generated session instructions. Installing or removing a skill is just writing or deleting a complete folder there from inside any session. At session end Satchel validates the library, locally quarantines malformed attempts while restoring any previous valid copy, and syncs valid changes to every host. Agent-owned runtime skills such as Codex's `.system` tree remain local and unsynced. A newly installed skill is relied on from the next session, when agent-native discovery runs again.
_Avoid_: plugins, marketplace

**Handoff**:
A short markdown summary (goal, done, in-flight, next steps, gotchas) written automatically after a meaningful session, and injected into the next session's starting context — including on another machine. The unattended writer resumes only the local agent conversation; it receives no project, Host Session, SSH, clipboard, MCP-tool, skill, or machine-state access. Satchel files its returned note afterward. Filing follows the attribution rule: one handoff per tracked Project the session actually worked in, written to `projects/<id>/handoffs/`, no matter how the session was launched (parent directory, `--with` extras, Host Session). Work outside every tracked Project (fixing the machine itself, mostly) goes to `machines/<name>/handoffs/`, scoped to that machine. A session that can see several projects gets a list of them and reads the relevant handoff on demand from the read-only `/home/satchel/projects` mount, rather than having every project's context inlined. Each scope retains its latest ten handoff files; older versions remain in Git history. Semantic continuity, as opposed to literal transcript replay or an incident archive.
_Avoid_: summary, checkpoint, state file

**Machine Notes**:
Concise current operational truth about one machine (`machines/<name>/notes.md` in the Sync Repo): enduring rules, sharp edges, and machine-wide unresolved risks that materially affect future work. Mounted read-write into every session on that machine and injected into the session preamble at `/home/satchel/machine/notes.md` (an absolute path on purpose: Host Sessions run as root, where `~` resolves wrong). Notes are organized by topic, updated in place, and have a 750-word soft ceiling. Resolved incidents and ordinary unfinished work do not belong here. Complements Handoffs: the handoff is the baton for current work, notes are the small set of facts useful before relevance is known.

**Machine Inventory**:
A broad, dated system reference (`machines/<name>/inventory.md`) produced by Machine Baseline onboarding or refresh and replaced in place. It is mounted at `/home/satchel/machine/inventory.md`; sessions receive its path and generation time, not its contents, and read it on demand when hardware, storage, services, or other system detail matters. Point-in-time observations must be rechecked before operational decisions.

**Machine Guide**:
A substantial reusable, machine-specific procedure under `machines/<name>/guides/<topic>.md`, mounted into sessions under `/home/satchel/machine/guides/`. There is one current guide per topic, updated in place and loaded only when relevant. A guide exists only for a repeatable procedure, persistent setup, or expensive machine-specific trap — never merely because troubleshooting happened once.

**Machine Baseline**:
An optional first inventory, offered on the first normal agent launch after that agent authenticates. The chosen agent sees the host at `/host` through a read-only bind mount and proposes a replace-in-place Machine Inventory, concise Machine Notes, and any justified Machine Guides for human approval. It can write only the synced machine directory (plus its ordinary local agent state). A versioned marker on the inventory's first line records successful completion. Refreshes preserve valid notes and guides while deleting stale or incident-only material.
_Avoid_: journal, log (notes are kept short and current, not appended forever)

**Host Session**:
A session with sandboxing deliberately off: the host's `/` mounted read-write, root inside the container, host PID namespace. Invoked by explicit flag (`--host`), or by answering yes when satchel refuses a sandboxed session in a home directory or `/`. The container is packaging, not protection.
_Avoid_: privileged mode, admin mode
