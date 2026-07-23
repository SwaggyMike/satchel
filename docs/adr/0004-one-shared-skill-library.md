# One shared skill library, mounted into both agents

Supersedes [ADR 0003](0003-skills-as-mounted-per-agent-libraries.md): the Sync Repo now carries a single `skills/shared/` folder, and satchel mounts it into every session as that agent's native skills directory — `~/.claude/skills` for Claude, `~/.codex/skills` for Codex. Installing a skill once, from any session on any machine, makes it available to both agents caravan-wide after a sync.

## Why revisit 0003

Two of its premises expired:

- "Codex has no native skills system" — no longer true. Codex (v0.145 verified) reads `${CODEX_HOME:-$HOME/.codex}/skills`, discovers `SKILL.md` folders in the same format Claude uses, and its bundled skill-authoring docs cover the same frontmatter (including `disable-model-invocation`). The planned "codex materializer" is now just a bind mount.
- The reliability argument ("auto-sharing exposes an agent to skills never tried there") assumed the split would be maintained. In practice it produced the opposite failure: skills installed into whichever subfolder felt right silently reached no agent at all, twice. For a single user running the same skill set everywhere, the split created unreliability instead of preventing it.

## Decision

- One tree: `sync/skills/shared/`. The per-agent `skills/claude/` and `skills/codex/` folders are gone; existing content migrates with `git mv skills/claude skills/shared`.
- Both session types mount the tree read-write at the agent's native path. No copies, no materializer, no second source of truth.
- The generated `CLAUDE.md` / `AGENTS.md` names that path as Satchel's authoritative installation target, requires complete skill bundles rather than lone `SKILL.md` files, and explains that session-end sync carries changes caravan-wide.
- Sessions expose `SATCHEL_SESSION=1` and the agent-native path in `SATCHEL_SKILLS_DIR` so installers can detect the same contract mechanically instead of guessing from generic agent-home conventions.
- Only user-installed skill directories sync. Codex materializes its
  version-specific `.system` tree beneath the same native path; the Sync Repo
  ignores that runtime-owned directory so different Codex versions cannot
  repeatedly replace one another's bundled skills.
- Session exit validates the library's packaging boundary: each visible
  top-level entry is a safely named directory with `SKILL.md`, contains no
  nested `.git`, and has no broken or escaping symlinks. Invalid attempts move
  to the machine-local Satchel quarantine; when updating a previously committed
  skill, the committed valid copy is restored. Validation deliberately does
  not interpret prose or try to prove every file reference.
- The Skill Library and current Machine Knowledge directory are the only
  Sync Repo paths mounted read-write. Satchel repairs ownership of those exact
  paths before and after sessions so root-run hosts and Host Sessions cannot
  make later sandboxed sessions unable to write.
- Agent-native skill discovery occurs at startup. Installation is durable immediately, but a fresh session is the boundary at which the newly installed skill can be assumed to appear automatically.
- A skill that misbehaves on one agent is handled inside the skill (frontmatter like `disable-model-invocation`), not by library placement. Codex ignores skill metadata it can't use per-skill; it does not fail the library.

## Consequences

- `satchel status` lists one skill set, not per-agent columns.
- Valid installs, updates, and removals sync without another confirmation and
  are reported at session exit. Quarantined attempts never sync, are never
  deleted automatically, and remain visible through `satchel status`.
- An agent may surface a skill that was only ever tested on the other one. Accepted: same format, same user, and the failure mode is a visible misfire rather than the silent absence the split caused.
- If per-agent curation is ever genuinely needed, it returns as an explicit exclusion mechanism, not as the default layout.
- Migration is a one-time `git mv` in the sync repo (any one machine), then `satchel update` everywhere; nothing else moves.
