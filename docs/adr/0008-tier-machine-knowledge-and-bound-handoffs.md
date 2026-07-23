# ADR 0008: Tier machine knowledge and bound handoffs

Machine Baseline version 1 wrote a broad inventory into `notes.md`, and every
session loaded that whole file. Later troubleshooting could append incident
narratives to the same place. The result mixed current operational context,
dated observations, reusable procedures, and history; important warnings
became harder to find as startup context grew.

## Decision

- `machines/<machine>/notes.md` is small, topical, current operational context.
  It is loaded into every session and has a 750-word soft ceiling. A fact
  qualifies only when it remains true after the task, is machine-specific or
  unusually important, and would prevent meaningful wasted work, mistakes, or
  harm later.
- `machines/<machine>/inventory.md` is the broad dated baseline. A refresh
  replaces the one current file. Sessions learn its path and timestamp but
  load its contents only when relevant.
- `machines/<machine>/guides/<topic>.md` holds substantial reusable procedures.
  There is one current guide per topic, updated in place. Notes may carry a
  short warning or pointer; resolved one-time incidents create no guide.
- Machine-wide unresolved risks may remain in notes until resolved. Ordinary
  unfinished work stays in the latest handoff. Project behavior stays in the
  project's own documentation.
- “Save” or “remember” means preserve the useful substance concisely in the
  appropriate tier. Exact text is preserved only when the user explicitly
  requests it. Agents may record a clearly qualifying fact proactively, must
  default to saving nothing when uncertain, and report knowledge-file changes
  in their final response.
- Handoff directories retain the latest ten files per project or machine.
  Older handoffs remain recoverable from Git history; the active tree is not
  an incident archive.
- Normal sandboxed launches are silent. Only exceptional or dangerous states,
  notably Host Sessions, produce a pre-launch warning; agent TUIs immediately
  replace routine banner output anyway.

The numeric limits are guardrails, not data-loss rules. Essential information
is consolidated or moved to an on-demand guide rather than discarded merely
to satisfy a count.
