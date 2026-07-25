# 13. Publish each machine's runtime environment

Date: 2026-07-25

## Status

Accepted.

## Context

Nothing in Satchel's image is pinned:

```dockerfile
FROM docker.io/library/node:22-bookworm-slim
RUN npm install -g @anthropic-ai/claude-code @openai/codex
```

Every machine builds that image itself, whenever it happens to run
`satchel update`. Two machines in the same caravan can therefore run materially
different agent versions — and different Satchel commits — with no signal at
all. The symptom is "it works on the other box", which is expensive to diagnose
because nothing in the tool can answer "are these machines running the same
thing?"

`satchel status` reports the local machine only, so answering that question
meant visiting each machine and comparing by eye.

## Decision

Each machine writes `machines/<name>/environment.json` when a session ends:

```json
{"satchel":"2.0.0","commit":"7179842","engine":"docker","agents":"claude 2.1.217, codex 0.145.0"}
```

`satchel doctor` reads every machine's file and reports drift against the local
one. Agent versions come from a cache written at image build time, so
publishing costs no container start.

The check distinguishes three states, which matters more than it sounds: no
peers, peers that have not reported yet, and peers that reported and agree.
The first implementation collapsed the middle case into the last and printed a
reassuring "no version drift detected" from an empty data set — a check whose
whole purpose is surfacing differences, reporting green because it had no data.

## Consequences

- One small synced file per machine. It is rewritten only when its content
  changes, so ordinary sessions produce no commit churn.
- The feature only *reports*. It never updates anything, never blocks, and
  nothing else in Satchel reads the file.
- A machine that has updated but not yet run a session reports stale values.
  Bounded by one session, and the "have not reported" state makes the gap
  visible rather than silent.
- This is additional long-lived synced state, which AGENTS.md requires an ADR
  for. This document is that ADR — written after the fact, because the original
  change added the state without one.

## Alternatives considered

**Pin the image** (base digest plus exact npm versions) would prevent drift
instead of reporting it, which is strictly better in principle. Rejected for
now because picking up new agent versions is the main reason to run
`satchel update`; pinning makes that a Satchel release decision rather than a
rebuild, and Satchel is a personal tool without a release process.

**Do nothing and compare by hand** — run `satchel status` on each machine. This
is what the feature replaces. It works, and it is the correct answer for a
one-machine caravan; the cost only becomes real at three or more.

## Note on provenance

This was built while investigating a report of "errors when using it between
different systems", on the assumption that version drift was a likely cause.
That assumption was wrong — the reported flakiness was Unraid-specific. The
feature is retained on its own merits, not because it addressed that report.
