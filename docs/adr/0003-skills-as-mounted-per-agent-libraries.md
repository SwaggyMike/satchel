# Skills sync as per-agent libraries mounted from the Sync Repo

> **Superseded by [ADR 0004](0004-one-shared-skill-library.md)** for the library layout — Codex gained a native skills system, and the per-agent split caused installs to silently reach no agent. The library is now one shared tree. The plugins-stay-per-host decision below still stands.

Skills get the MCP Registry's promise — set up once, every host has it — with one deliberate narrowing: per agent, not across agents. The Sync Repo carries a `skills/` folder with one subfolder per agent (`skills/claude/`, `skills/codex/`), and satchel mounts the agent's subfolder into each session *as* that agent's skills directory. There is no install command and no detection: installing a skill means a folder appearing there (usually by asking the agent mid-session), uninstalling means deleting it, and `sync` carries the change fleet-wide. In v1 only Claude Code is wired up, natively at `~/.claude/skills/`; Codex has no native skills system, so its materializer is deferred until a first real skill is wanted there.

## Considered Options

- **Lockfile + source pin** (sync a manifest, reinstall from source per host): only works for skills that live in a fetchable repo; a locally-authored skill would need a publishing step first — the exact friction this feature removes.
- **Auto-detect host skill dirs**: on inspection every skill on the reference machine is manager-owned (GSD suite, plugin marketplace), so mirroring `~/.claude/skills/` means satchel fighting other installers over the same files. Also moot: sessions never see the host's `~/.claude` anyway.
- **One shared cross-agent library**: install once, both agents see it. Rejected on reliability grounds — a skill is only as reliable as it is on the agent where someone actually uses it, and auto-sharing exposes an agent to skills never tried there. Cross-agent sharing is instead one explicit copy between subfolders, which is also the moment you'd test it.
- **Sync the plugin system too**: Claude's plugin registry pins absolute host paths (`/home/<user>/...`) and version-numbered cache dirs, and plugins can carry hooks and MCP config. Syncing it means reimplementing the plugin manager per host. Plugins stay per-host; to fleet-share a plugin's skill, vendor that skill into the library as a plain folder.

## Consequences

- Vendored third-party skills are copies; updating one is a manual re-import. A `satchel skill update` can exist later if that ever hurts.
- Plugin installs don't travel. `satchel status` notes plugins that exist on this machine only, so the answer to "where did it go" is one status call away — but there is no nagging at sync time.
- Codex sessions have no skills until the Codex materializer is built (likely a per-session generated index of skill names, descriptions, and paths — never stored, so no second source of truth).
- Token cost per skill is its description line in Claude's context, since skill bodies lazy-load on trigger. Keep the library curated: vendor the skills you use, not whole suites.
- Skills are prompt text, not secrets; nothing here touches the credentials line drawn in ADR 0002.
