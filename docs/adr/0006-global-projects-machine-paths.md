# ADR 0006: Global Git projects, machine-local paths

ADR 0011 refines the storage model below: `repositories.json` is now the only
origin authority, `project.json` is removed, and machine caches store only a
Project ID.

The Sync Repo represents one user's portable Satchel state. Project identity
and tracking decisions must therefore be global, while checkout paths remain
machine-local. Arbitrary directories do not have a stable fleet-wide identity;
portable Git origins do.

## Decision

- A Project is an explicitly tracked Git repository. Ordinary directories
  never prompt and cannot be enrolled.
- `repositories.json` stores credential-free normalized network-origin
  identities and their global `tracked` or `ignored` decision. Common SSH and
  HTTPS spellings of the same forge repository normalize to one identity.
- `projects/<id>/project.json` records stable Project identity.
  `projects/<id>/handoffs/` contains timestamped handoffs, bounded to the
  active-file limit defined by ADR 0008.
- `machines/<machine>/projects.json` is a cache mapping absolute checkout
  paths to Projects. Satchel recursively discovers repositories inside the
  launch directory and `--with` roots, before and after a session, and rebuilds
  mappings by origin. It does not follow symlinks or scan the host in a Host
  Session.
- An unknown network-origin repository prompts only when session-end handoff
  analysis identifies substantive continuation-worthy work in it. A yes
  tracks the origin globally; a no ignores it globally. Merely discovering,
  listing, or casually reading a repository does not prompt.
- Work in ignored repositories and ordinary directories remains eligible for
  the machine handoff. It never receives a repository-specific handoff.
- `satchel track [id]` is the explicit escape hatch for Git repositories with
  no origin or a local/NFS origin. Such checkouts are linked on another machine
  by explicitly giving the existing Project ID.
- The nearest enclosing repository owns work when repositories are nested.
  Multiple visible checkouts with the same normalized origin are one Project
  and receive one combined handoff.
- `satchel untrack [id]` changes a portable origin to globally ignored, removes
  all machine path mappings, and removes the active Project and its handoffs.
  Sync Repo Git history remains the recovery path.
- `satchel status` shows tracked Project IDs and origins plus an ignored count;
  `satchel status --ignored` expands the ignored identities.
- `profile.md` and `preferences.md` at the Sync Repo root hold global personal
  context. `skills/shared/` remains the global Skill Library.

Legacy registry migration, recovery drafts, concurrent-session reconciliation,
encrypted credential distribution, and project-specific skill installation
are deliberately out of scope for this change.
