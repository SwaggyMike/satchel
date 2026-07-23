# ADR 0006: Global projects, machine-local paths

The Sync Repo represents one user's portable Satchel state. Projects must
therefore be global, while filesystem paths and enrollment decisions belong
to the machine on which those paths exist.

## Decision

- A directory is not a Project until the user explicitly opts in. A Git repo
  is useful identity, but is neither required nor sufficient for enrollment.
- `projects/<id>/project.json` records stable identity and an optional Git
  remote. `projects/<id>/handoffs/` contains timestamped handoffs, bounded to
  the latest ten active files by ADR 0008.
- `machines/<machine>/projects.json` maps absolute local paths to `tracked` or
  `rejected`. A tracked root covers descendants; a rejection applies only to
  the exact path.
- After a meaningful session in an unknown directory, Satchel asks once. A no
  is remembered. `satchel track` and `satchel untrack` change the decision.
- When a Git remote matches an existing project, enrollment links the new
  machine path to that project. Non-Git moves are linked explicitly by giving
  `satchel track` the existing project ID.
- `profile.md` and `preferences.md` at the Sync Repo root hold global personal
  context. `skills/shared/` remains the global Skill Library.

Recovery drafts, concurrent-session reconciliation, encrypted credential
distribution, and project-specific skill installation are deliberately out
of scope for this change.
