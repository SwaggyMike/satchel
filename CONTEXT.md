# Satchel

A single bash script for running AI coding agents (Claude Code, Codex) in disposable Docker containers on home-lab Linux machines, with session handoffs and settings synced between machines via a private git remote. Deliberately not production-grade: simple, readable, boring.

## Language

**Satchel**:
The Satchel program itself — one bash script, installed as the `satchel` command.
_Avoid_: daemon, service, platform

**Shim**:
A tiny wrapper command named `claude` or `codex` on the host PATH that execs `satchel claude` / `satchel codex`, so using Satchel feels identical to using the real CLI.
_Avoid_: alias, symlink

**Session**:
A single run of an agent CLI inside a throwaway Docker container, scoped to one directory (plus any extra directories named with repeatable `--with` flags, for work that spans repos). The container is deleted when the session ends. A directory becomes a Project only after the user opts in; work is attributed to whichever tracked Project's directory it happened in, regardless of where the session was launched.
_Avoid_: workspace, environment

**Project**:
A directory the user explicitly chose to track. Project identity and handoffs are global across the fleet; each machine keeps only its local path mapping. A Git remote links checkouts automatically when present, but Git is not required.
_Avoid_: every working directory, repository (not every repository is tracked)

**Sync Repo**:
The user-owned private git repository (cloned at `~/.satchel/sync/`) that carries handoffs, tool settings, the MCP Registry, and the Skill Library between machines. Agent login credentials and transcripts never enter it.
_Avoid_: cloud, backend, server

**MCP Registry**:
The single synced file listing the user's MCP servers (name, URL, token). At session start, satchel materializes it into each agent's native config format. Registered once, preconfigured everywhere.
_Avoid_: integrations list, connectors

**Skill Library**:
The folder of agent skills carried whole in the Sync Repo, shared by both agents. Satchel mounts it into every session as that agent's own skills directory (`~/.claude/skills`, `~/.codex/skills`) — installing or removing a skill is just writing or deleting a folder there, from inside any session, and sync makes the change available to both agents on every host.
_Avoid_: plugins, marketplace

**Handoff**:
A short markdown summary (goal, done, in-flight, next steps, gotchas) written automatically after a meaningful session, and injected into the next session's starting context — including on another machine. Filing follows the attribution rule: one handoff per tracked Project the session actually worked in, written to `projects/<id>/handoffs/`, no matter how the session was launched (parent directory, `--with` extras, Host Session). Work outside every tracked Project (fixing the machine itself, mostly) goes to `machines/<name>/handoffs/`, scoped to that machine. A session that can see several projects gets a list of them and reads the relevant handoff on demand from the read-only `~/projects` mount, rather than having every project's context inlined. Semantic continuity, as opposed to literal transcript replay.
_Avoid_: summary, checkpoint, state file

**Machine Notes**:
Curated current truth about one machine (`machines/<name>/notes.md` in the Sync Repo): the blessed way to do machine-specific tasks, quirks, conventions. Mounted read-write into every session on that machine (`~/machine/notes.md`) and injected into the session preamble; agents record durable facts as they discover them and fix or delete entries that turn out stale. Complements Handoffs: the handoff is the baton for the current work, notes are what stays true between sessions.
_Avoid_: journal, log (notes are kept short and current, not appended forever)

**Host Session**:
A session with sandboxing deliberately off: the host's `/` mounted read-write, root inside the container, host PID namespace. Invoked by explicit flag (`--host`), or by answering yes when satchel refuses a sandboxed session in a home directory or `/`. The container is packaging, not protection.
_Avoid_: privileged mode, admin mode
