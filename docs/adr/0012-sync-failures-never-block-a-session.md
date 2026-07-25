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

2. **Back out, never guess.** `recover_sync_repo` abandons the in-progress
   operation and returns the clone to a clean tree. The local commit stays on
   the branch, so nothing is lost — only its integration is postponed, and the
   user reconciles once with plain git. It returns 0 (clean again) or 1 (still
   broken).

3. **Validate what is read, ignore what is not.** Required fields are still
   enforced; unknown keys are accepted. A newer Satchel elsewhere in the
   caravan can add a field without bricking older machines.

## Consequences

- A machine can no longer be locked out of running an agent by the Sync Repo.
- A conflict leaves that machine behind the remote until a human reconciles it.
  This is reported every session, and the local commit is never lost.
- Satchel never resolves a conflict on the user's behalf, so it can never pick
  the wrong side silently.

## Alternatives considered

**Automatic union merging** of the registries Satchel owns (`jq -s '.[0] * .[1]'`
for JSON, key-wise for env files) was implemented and then **removed**. It
worked, but it solved a conflict the user had not actually been hitting, and it
was the single largest complexity addition in that change — a merge algorithm
plus a three-valued recovery result, inside a tool whose stated intent is to
stay simple and boring. Backing out preserves the property that matters (the
session is never blocked, the clone is never left mid-rebase) for a fraction of
the code. Reinstate it only with evidence that conflicts are frequent enough to
be worth an algorithm.

**One file per registry entry** (`repositories/<hash>.json`) would make
conflicts structurally impossible for adds and removes. It remains the right
shape if conflicts ever become common, and it is simpler than merging rather
than an addition to it. Not done now because it needs a migration across every
machine at once — the cross-machine flag day this ADR exists to prevent.

**A git merge driver** via `.gitattributes` was rejected because it would have
to be installed in every clone — machine-local configuration that new machines
would silently lack.
