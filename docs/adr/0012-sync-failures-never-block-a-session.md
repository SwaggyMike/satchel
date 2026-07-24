# 12. Sync failures never block a session

Date: 2026-07-24

## Status

Accepted. Refines [ADR 0002](0002-mcp-tokens-in-sync-repo.md) and
[ADR 0011](0011-one-authoritative-project-registry.md).

## Context

The Sync Repo is a shared mutable store written by every machine in the
caravan. Satchel's registries — `repositories.json`, `mcp.json`, `settings.env`,
`mcp-tokens.env` — are rewritten wholesale by whichever machine touches them,
so two machines changing *different* entries between syncs is the ordinary
case, not an exception. Git sees adjacent edits to the same region and
conflicts.

That produced a failure cascade we could reproduce deterministically:

1. Machine A tracks a repo; machine B tracks a different one. B's session-end
   `git pull --rebase` conflicts on `repositories.json`.
2. `quiet_push` warned and returned, leaving the clone mid-rebase.
3. A rebase detaches HEAD, so `@{u}` stops resolving. `quiet_pull` checked
   `has_upstream` *before* `sync_needs_recovery`, so its recovery guard was
   skipped in precisely the state it existed to catch.
4. Startup continued to `validate_sync_state`, `jq` parsed the conflict
   markers, and the strict validator called `die`.

The result: `claude` would not start on that machine until the user hand-resolved
a rebase inside `~/.satchel/sync`. A bookkeeping repo for handoff notes had
become a hard blocker on running an agent.

A second, related failure: the validators required exact key sets
(`(.value | keys) == ["project", "status"]`). Any field added by a newer
Satchel on one machine made every command on every older machine `die`.

## Decision

**The session is the product; syncing is bookkeeping.** No Sync Repo condition
may prevent an agent from starting.

Three changes enforce that:

1. **Degrade, don't die.** `degrade_sync` turns `sync_ready` off for the rest
   of the run. Every mount, read, and push already guards on that one
   predicate, so a broken Sync Repo cleanly stops syncing while the session
   proceeds. Sessions use `validate_sync_state_soft`, which runs the strict
   validators in a subshell and converts a fatal exit into a degraded run.
   `satchel sync` and `satchel status` keep the strict, fatal behavior — there
   the user asked about the repo itself.

2. **Merge what Satchel owns.** `recover_sync_repo` union-merges conflicts in
   the known registries: JSON objects via `jq -s '.[0] * .[1]'`, env files by
   key with the local value winning a tie. A union can never drop a remote
   entry, which is the only unrecoverable outcome. Anything Satchel does not
   own is abandoned back to a clean tree — never left mid-rebase — and the
   local commit stays on the branch. `recover_sync_repo` returns 0 (merged and
   integrated), 2 (abandoned, clean, not integrated), or 1 (still broken).

3. **Validate what is read, ignore what is not.** Required fields are still
   enforced; unknown keys are accepted. A newer Satchel elsewhere in the
   caravan can add a field without bricking older machines.

## Consequences

- Conflicts on shared registries resolve without user action, and both
  machines converge on the union.
- A machine can no longer be locked out of running an agent by the Sync Repo.
- Ties are resolved in favour of the local machine. For `settings.env` that
  means a caravan-wide setting changed on two machines in the same window
  keeps the local value until the next explicit `satchel settings`.
- Abandoning an unmergeable conflict leaves that machine behind the remote
  until a human reconciles it. This is reported every session, and the local
  commit is never lost.
- The union merge only applies to files Satchel writes. Skills and handoffs are
  ordinary files; conflicts there are still the user's to resolve, which is
  correct — Satchel cannot know which version of a skill is wanted.

## Alternatives considered

**One file per registry entry** (`repositories/<hash>.json`) would make
conflicts structurally impossible for adds and removes, which is stronger than
merging after the fact. It was rejected for now only because it requires a
migration across every machine in a caravan simultaneously — the exact
cross-machine flag day this ADR exists to prevent. It remains the better
long-term shape, and the union merge is forward-compatible with it.

**A git merge driver** via `.gitattributes` was rejected because a union merge
of JSON produces invalid JSON, and the driver would have to be installed in
every clone — machine-local configuration that new machines would silently
lack.
