# Satchel — Forensic Product Specification

**Purpose of this document.** This is an implementation-independent specification of what Satchel is
*intended* to do, extracted from the existing repository so that a separate engineering team can
rebuild it from scratch without access to the original source.

It is deliberately **not** a description of the current implementation, and it does not propose a
replacement architecture. Where current behavior appears accidental, contradictory, or unjustified,
it is recorded as such rather than promoted to a requirement.

---

## How this analysis was conducted, and how much to trust it

Evidence was weighted in this order, strongest first:

1. **Executed behavior.** Commands were run and their real output and exit codes captured. Several
   internal predicates were executed directly against fixtures to confirm or refute suspected defects
   rather than inferring them from reading.
2. **The test suite.** ~2,900 lines of tests encoding several hundred behavioral assertions. Tests
   are the strongest available evidence of *intent*, because someone deliberately wrote down what
   should happen.
3. **Documentation with reasoning attached.** A vocabulary document defining fourteen core terms
   (including explicit "avoid this word" guidance), and thirteen decision records that state not just
   what was chosen but what was rejected and why. Three of these supersede or refine earlier ones,
   which makes the direction of intent visible.
4. **Observable interface surface.** Help text, prompts, error messages, file formats, mount layout.
5. **Change history.** 123 commits across five days, including reverts and deliberate removals.
6. **Source reading.** Used last, and only to answer questions the above could not.

**A material caveat that shapes every confidence rating below.** No test in the suite ever launches a
real container. Every isolation guarantee the product makes — non-root execution, restricted
capabilities, read-only mounts, filesystem scoping — is verified only as *command-line argument
strings*, never against a running container. A separate script does check these properties for real,
but it is not part of the test run and must be executed by hand inside a live session. Consequently,
sandbox behavior is classified throughout as **intended and specified**, not **verified**.

**Confidence legend used in this document:**

| Mark | Meaning |
|---|---|
| **[C]** Confirmed | Executed, or asserted by a test, or both |
| **[SI]** Strongly inferred | Consistent across docs, tests, and behavior; no contradicting evidence |
| **[WI]** Weakly inferred | Supported by one source only |
| **[Q]** Questionable | Evidence conflicts, or the behavior contradicts a stated goal |
| **[A]** Apparently accidental | Behavior that looks like a side effect rather than a decision |

---

# 1. Product summary

## What it is

Satchel runs AI coding agents (currently two: Anthropic's Claude Code and OpenAI's Codex) inside
disposable Linux containers, and keeps the *context* those agents need — session-continuity notes,
tool credentials, reusable skills, machine-specific knowledge — synchronized across all of a person's
machines through a private Git repository that the user owns.

It is a thin orchestration layer over facilities that already exist on the target machines: a
container engine, Git, SSH, and plain files. It has no server, no daemon, no database, and no
hosted component. The user's own Git repository is the only shared state.

## Who it is for

A **single technical individual** running several personal Linux machines — a laptop, a desktop, a
home server or NAS — who uses AI coding agents across all of them. Evidence for the single-user
framing is direct and consistent: credentials are shared freely between machines because "anyone who
can read the repository already has your notes"; there is no multi-user model, no permissions system,
no account concept, and no conflict-resolution algorithm. The documentation describes the product as
"deliberately not production-grade: simple, readable, boring." **[C]**

The audience is explicitly self-hosting and comfortable with the command line. One platform — a
NAS-style appliance distribution whose root filesystem is rebuilt from flash storage on every reboot
— receives dedicated first-class support, which strongly indicates a home-lab target. **[C]**

## What problem it solves

Four distinct problems, which is worth stating plainly because they are separable and a rebuild
might reasonably choose a subset:

1. **Blast radius.** An AI agent with file access can damage a machine. Running it in a throwaway
   container scoped to one directory bounds the damage.
2. **Context loss between sessions.** Agent conversations do not persist. Every new session
   re-establishes what was being worked on. Satchel writes a short structured note at the end of each
   session and injects it into the next one — including on a different machine.
3. **Per-machine setup friction.** Tool servers, credentials, and reusable agent skills otherwise
   have to be configured separately on every machine. Satchel configures them once and distributes
   them.
4. **Honest self-description to the agent.** A distinctive and clearly deliberate goal: the agent is
   *told* what environment it is in, so it says "that file is outside the sandbox" instead of
   incorrectly reporting that the file does not exist. This appears in the vocabulary document, the
   generated instructions, the tests, and a decision record. **[C]**

## Primary workflows

1. **Install and enroll a machine** — one command; name the machine; connect the shared repository.
2. **Work** — type `claude` or `codex` in a project directory exactly as if using the tool natively.
3. **Continue** — the next session, anywhere, starts with a summary of where the last one left off.
4. **Configure once** — register a tool server or install a skill from inside any session; every
   machine has it afterward.
5. **Diagnose** — one command reports what is wrong with this machine's setup.

## Minimum viable product

Ordered by how much of the product's value each step unlocks. A rebuild could stop after step 3 and
still have something genuinely useful:

1. Launch an agent in a disposable container scoped to the current directory, forwarding a Git
   credential path so work can be pushed, and passing through the terminal faithfully.
2. Tell the agent, in its own native instruction format, what it can and cannot reach.
3. Write a structured note at session end and inject the most recent one at session start.
4. Synchronize those notes across machines through a user-supplied Git remote.
5. Attribute notes to the repository the work happened in, rather than to the directory the session
   was launched from.

Everything else — tool-server registry, shared skills, machine knowledge tiers, machine inventory,
health checking, version-drift reporting — is additive.

---

# 2. User-visible capabilities

## 2.1 Run an agent in a disposable, directory-scoped container

| | |
|---|---|
| **User goal** | Use an AI coding agent without giving it the whole machine |
| **Trigger** | `claude` / `codex` (installed command aliases), or the equivalent explicit invocation, from any directory |
| **Behavior** | Verify prerequisites; refuse unsafe locations; select a container engine; build the shared image if missing; prepare credentials; synchronize shared state; generate instructions for the agent; launch the agent interactively with the current directory mounted; on exit, write a continuity note and publish changes |
| **Output** | The agent's own interface, unmodified. Satchel itself prints nothing on a normal sandboxed launch |
| **Failure** | Missing prerequisites, no container engine, or an unresolvable directory abort before launch. Shared-state problems degrade to "no synchronization this run" and the session proceeds |
| **Persisted state** | Per-agent home (logins, conversation history) surviving between sessions; generated instruction file rewritten each launch |
| **External systems** | Container engine; container registry and package repositories on first build; the user's Git remote |
| **Evidence of intent** | This is the product's stated purpose; the silence of a normal launch is explicitly reasoned about in a decision record (agent interfaces immediately repaint the screen, so a routine banner only flashes); container arguments are asserted by tests **[C]** |

The container is deleted on exit. Extra arguments are passed through to the agent untouched, so the
wrapper is transparent in normal use. **[C]**

## 2.2 Host Session — deliberately unsandboxed

| | |
|---|---|
| **User goal** | Fix the machine itself, using the same agent and the same context |
| **Trigger** | An explicit flag, accepted either before or after the agent name; or by accepting the offer made when a sandboxed session is refused |
| **Behavior** | Sandbox off: runs as root, host filesystem mounted at a known path, host process namespace shared, host networking. The agent is told it is in this mode and that changes under the host path affect the real machine |
| **Output** | A visible warning before launch, then the agent |
| **Failure** | Same prerequisites as a normal session |
| **Evidence of intent** | Vocabulary document: "The container is packaging, not protection." A decision record states this is the one case warranting a pre-launch warning. Tests assert the mode marker, the process-namespace flag, and the warning text **[C]** |

## 2.3 Multi-directory sessions

Additional directories can be mounted alongside the primary one, for work spanning repositories that
influence each other. Paths are resolved before validation, so a symbolic link cannot be used to
escape the boundary. Home directories, the filesystem root, and Satchel's own state are refused.
**[C]** — asserted by tests.

Alternatively, launching from a parent directory containing several repositories achieves the same
thing, and Satchel discovers repositories beneath the mounted roots both before and after the
session, so newly cloned repositories are classified correctly. **[C]**

## 2.4 Session continuity notes ("handoffs")

| | |
|---|---|
| **User goal** | Resume work without re-explaining it, including on a different machine |
| **Trigger** | Automatic at session end, when the session actually produced a conversation |
| **Behavior** | An unattended, heavily restricted agent process resumes the just-finished conversation and returns a five-section summary: goal, what was done, what is in flight, next steps, and gotchas. Satchel — not the agent — validates, scopes, names, and files the result. At the next session start, the most recent note for the current scope is injected into the agent's instructions |
| **Output** | A progress message naming the interrupt key that skips it |
| **Failure** | Every failure mode is non-fatal and preserves the previous note: writer error, wrong format, timeout, explicit skip, or "nothing worth handing off" |
| **Persisted state** | Timestamped note files per scope, bounded to the most recent 100 |
| **Evidence of intent** | Vocabulary defines it as "semantic continuity, as opposed to literal transcript replay or an incident archive"; a decision record explains why the retention bound was raised from 10 to 100; tests cover the failure paths individually **[C]** |

The writer's isolation is unusually strict and clearly deliberate: it receives only the agent's own
conversation directory. It cannot read the project, the host, the credential socket, the clipboard,
tool servers, skills, or machine knowledge. An empty temporary filesystem is mounted at the original
working directory purely so the agent can locate the right conversation without exposing any project
content. **[C]** — asserted by tests, and stated in two decision records.

## 2.5 Project identity and work attribution

| | |
|---|---|
| **User goal** | Notes filed against the repository the work happened in, not the folder the session started in |
| **Trigger** | Automatic classification; explicit enrollment commands; a post-session prompt for unknown repositories |
| **Behavior** | Repositories are identified by a normalized, credential-free form of their network origin, so that different URL spellings of the same repository are one identity across all machines. Each identity carries one global decision: tracked or ignored. Work is attributed to the nearest enclosing tracked repository. Multiple checkouts of one origin are one project |
| **Failure** | A repository with no portable origin cannot be auto-identified; it can be enrolled explicitly, and linked on another machine by naming the existing identifier |
| **Persisted state** | Global origin→decision registry; per-machine cache of local checkout locations; per-project note directories |
| **Evidence of intent** | Two decision records, the second explicitly collapsing three sources of identity into one after the duplication caused drift; extensive test coverage of normalization, uniqueness, and validation **[C]** |

Prompting is deliberately rare: it happens only after a session, only for a repository with a
portable origin and no existing decision, only when the note-writing step judged the work
substantive, and only when a terminal is attached. Merely opening or reading a repository does not
prompt. **[C]** — though see §7.6: the prompt defaults to *yes*, and declining is permanent.

## 2.6 Machine knowledge, in three tiers

A deliberate separation by lifetime, introduced after an earlier single-file design mixed durable
facts with incident history and grew the startup context:

- **Notes** — small, current, operational truth. Loaded in full into every session. Soft ceiling of
  750 words, warned about but never enforced.
- **Inventory** — a broad, dated system reference. The session receives its location and generation
  date, never its contents, and reads it on demand.
- **Guides** — substantial reusable procedures, one per topic, listed by title only.

Sessions can read *other* machines' knowledge read-only, but write only their own. **[C]** — the
tiering, the rationale, and the read-only cross-machine visibility each have a decision record, and
the loading behavior is asserted by tests.

## 2.7 Machine baseline onboarding

Offered once, on the first normal launch after an agent authenticates. If accepted, the agent
inspects the real machine through a read-only mount and proposes an inventory, concise notes, and any
justified guides — showing them for approval before writing. Choices are yes / not now / never;
the default is "not now", explicitly because the access is privileged. **[C]**

Accepting makes the inspection the entire command; the originally requested session does not start,
and the user is told to run it again. **[C]** — asserted by tests and stated in a decision record.

Satchel audits the result afterward rather than gating the write: it verifies an inventory was
actually produced and scans newly added lines for credential-shaped content, suppressing
synchronization if either check fails — without ever printing the suspected value. **[C]**

## 2.8 Shared skill library

One library of agent "skills" (folders of instructions and supporting files), shared by both agents
and every machine, mounted read-write into each session at the agent's *native* skills location so
that no translation layer is needed.

Skills are installed by asking an agent to write the folder; there is no install command, by design.
On session exit, Satchel validates the library's packaging — real directory, safe name, required
manifest file present, no embedded repository metadata, no symbolic links escaping the bundle — and
quarantines anything malformed locally rather than synchronizing it, restoring the last valid version
where one exists. Validation deliberately does not interpret content. **[C]**

Removal is a first-class command with an interactive picker; the named selection is the
authorization, and repository history is the recovery path. **[C]**

## 2.9 Tool-server (MCP) registry

Servers are registered once with a name, an HTTP endpoint, and whether they need a bearer token.
The registry synchronizes; tokens synchronize by default with a documented, deliberate opt-out. At
session start the registry is materialized into each agent's own configuration format. **[C]**

The threat model is stated explicitly: the repository is private and reached over the user's own
keys, so anyone who can read it already has the user's notes. Agent login credentials and
conversation transcripts never synchronize — that line is drawn hard and enforced structurally by
keeping them outside the synchronized tree. **[C]**

One security measure is notably careful: for the agent that supports it, token *values* are never
placed in configuration or in the container's command line; only the variable name is passed, so
secrets do not appear in the host process list. **[C]** — asserted by tests.

## 2.10 Cross-machine synchronization

The user supplies any Git remote — a hosted private repository, a bare repository over SSH, or a
bare repository on a network mount. Satchel pulls at session start and pushes at session end.

The governing rule is stated repeatedly and is the product's most important reliability property:
**the session is the product; synchronization is bookkeeping, and no state of the shared repository
may prevent an agent from starting.** On conflict, Satchel never merges. It backs out to a clean
tree, keeps the local commit, says so, and continues — the user reconciles once with ordinary Git.
**[C]** — this is a decision record written after a reproducible failure cascade that locked a
machine out of running an agent entirely, and it is covered by tests.

Validation checks only the fields actually read and tolerates unknown ones, so a newer version on one
machine cannot break older machines. **[C]** — this too was written after the opposite behavior
caused a cross-machine outage.

## 2.11 Supporting capabilities

| Capability | Goal | Notes |
|---|---|---|
| **Credential forwarding** | Push from inside a session | Forwards a signing socket, never key files. Probes whether an identity is actually loaded and tells the agent the truth. Can start a temporary agent from a standard key, prompting on the host **[C]** |
| **Clipboard forwarding** | Paste screenshots into an agent | Forwards the desktop compositor socket, preferring the more restrictive protocol; headless machines unaffected **[C]** |
| **Health check** | "What is wrong with this machine?" | ~19 checks: tooling, engine, image, a real mount probe, credentials, repository reachability and divergence, cross-machine version drift, platform persistence, tool-server reachability **[C]** |
| **Status** | See the whole fleet at a glance | Machines, projects with origins and note counts, ignored count, servers, skills, quarantine, unpushed work **[C]** |
| **Login import** | Skip logging in again | Copies the host's existing agent credentials into Satchel's own agent home **[C]** |
| **Self-update** | Stay current | Resolves the branch to an exact revision (to defeat CDN caching), downloads, syntax-checks, replaces atomically, then rebuilds the image using the *new* artifact **[C]** |
| **Machine retirement** | Remove a machine from the fleet | Deletes only that machine's directory; history retains it **[C]** |
| **Install / uninstall / command redirection** | Lifecycle | Single-command install; opt-out redirection of the agent commands; uninstall distinguishes program-only from full local removal and never touches the remote **[C]** |
| **Platform persistence** | Survive reboot on RAM-backed root filesystems | Relocatable install plus a marked block in the platform's boot script restoring command links and the sync key **[C]** |

---

# 3. Interfaces

## 3.1 Command-line surface

Two invocation styles exist and are equivalent: a redirected command that shadows the agent's own
name, and an explicit subcommand. The redirect is what makes the product feel transparent.

**Session commands**

| Command | Purpose |
|---|---|
| `<agent>` / `<tool> <agent>` | Run an agent in the current directory |
| `--host` | Unsandboxed machine-troubleshooting session |
| `--unsafe-home` | Permit a session in a home directory (normally refused) |
| `--with <dir>` | Mount an additional directory; repeatable |
| `track [id]` / `untrack [id]` | Explicitly enroll or globally ignore the enclosing repository |

Flags are accepted **before or after** the agent name, which is a real usability decision. **[C]**

**Fleet and configuration commands**

`init`, `sync`, `status [--ignored]`, `skills [list|remove [name]]`, `key [--persist]`,
`retire [machine]`, `doctor`, `mcp list|add|remove`, `settings [<KEY> <value> [--local]]`,
`import <agent>`, `image [--rebuild]`, `update`, `link [agent]`, `unlink [agent]`, `uninstall
[--purge] [--yes]`, `version`, `help`.

**Conventions, verified by execution:**

- Exit `0` on success; exit `1` for every fatal error. Bare invocation prints help and exits `0`.
- Diagnostics (`info`, `warning`, `error`) and all interactive prompts go to **stderr**; report bodies
  go to **stdout**. **[C]**
- The health check exits `1` if any check *fails*, but prints "no problems found" when there are only
  warnings. **[C]** — verified by running it.

## 3.2 What the agent sees inside a session

This is the product's most important interface, because it is the contract between Satchel and the
agent. A generated instruction file is written in each agent's **native** user-level memory format,
so it loads without any special mechanism, and is rewritten from scratch every launch with a header
declaring it managed. Its contents:

1. **Where you are running** — sandbox or host mode; what is and is not reachable; the instruction to
   say "outside the sandbox" rather than "does not exist".
2. **Credential reality** — one of three precise statements: pushing works; the socket is forwarded
   but carries no identity, so pushing fails until the user loads one; or no authentication is
   available. It never claims pushing works when no identity is loaded. **[C]** — asserted by tests
   per state.
3. **Ownership mismatch warning** — only when the host runs as a different user than the session,
   including the exact corrective command, and stating it cannot be fixed from inside.
4. **Skill library contract** — the exact path, that it is shared across agents and machines, what a
   complete bundle must contain, and that a new session is required before a new skill is discovered.
5. **Machine notes** — inlined in full, followed by curation policy.
6. **Pointers, not contents** — inventory by path and date; guides by title; sibling machines
   read-only.
7. **Global profile and preferences.**
8. **Visible projects** — a table of contents with the attribution rule, not every project's context.
9. **The previous note for this scope**, with provenance, and the instruction to continue from it.

All paths in this file are absolute, deliberately: a host session runs as root, where a home-relative
path resolves somewhere else. **[C]** — asserted by tests.

**Environment exposed to the agent:** a runtime marker, a mode marker (`sandbox` or `host`), and the
skill library path — so that skill installers can detect the contract mechanically rather than
guessing. Plus a home path, terminal type, an auto-updater suppressor, and conditionally the
credential socket, display variables, and per-server token variable *names*. **[C]**

**Mount layout (conceptual):** agent home read-write; this machine's knowledge read-write; all
projects' notes read-only; all machines' knowledge read-only; skill library read-write; the project
at its real path; extra directories at their real paths; and, only in host mode, the host filesystem
at a distinct path.

## 3.3 Configuration

Five settings, all currently machine-local: engine override, credential forwarding on/off, clipboard
forwarding on/off, and the user/group identity used inside containers.

Layering is: built-in default, then a shared file, then a machine-local file. **Both layers are
executed as shell, not parsed** — see §7.2.

Installer-time environment variables control the install directory, the state directory, and whether
the command redirects are created. Several internal variables exist purely as test seams.

## 3.4 Files the user may edit

The synchronized repository is intended to be user-editable with ordinary tools — this is a stated
design goal ("plain files and plain git"). Machine notes, inventory, guides, the global profile and
preferences, the origin registry, and the server registry are all hand-editable, with validation
applied on read. Quarantined skill attempts and rescued incomplete clones are left in place for the
user to inspect and are never automatically deleted.

## 3.5 External systems

| System | Use | Failure policy |
|---|---|---|
| Container engine | Everything | Fatal for sessions; reporting commands degrade |
| User's Git remote | All synchronization | Degrade, never block a session |
| Source hosting API | Update check, revision resolution, changelog | Best-effort; silent or warning |
| Container registry + package repositories | Image build | Fatal to the build only |
| Registered tool servers | Reachability probing | Advisory on add; **counts as a failure** in the health check (see §7.9) |
| Desktop compositor | Clipboard | Absent on headless machines; nothing mounted |
| Credential agent | Signing for pushes | Warn and continue, or start a temporary one |

**No signature or checksum verification exists anywhere.** Both installation and self-update trust
the transport and check only that the downloaded script parses. **[C]**

---

# 4. Data requirements

Described as information the product logically needs, not as the current storage layout.

## 4.1 Entities

**Machine** — a named participant. Needs: a stable name; a knowledge set (notes, inventory, guides);
a cache of where projects are checked out locally; its own notes for work outside any project; a
published record of what software versions it is running, for drift detection; and a marker recording
that baseline onboarding was declined permanently.

**Repository decision** — the global authority for identity. Needs: a canonical, credential-free
origin identity; a decision (tracked or ignored); and, when tracked, the project it belongs to.
Invariants: the identity must already be in canonical form; one project per identity; and a project
may not be claimed by two identities.

**Project** — a tracked repository's shared identity. Needs: a stable identifier and an ordered set
of continuity notes. It requires **no other attributes** — an earlier design stored identity in three
places and the duplication caused drift during migration, so it was collapsed to one. Folder names
suggest identifiers but never establish identity.

**Checkout binding** — machine-local, disposable: which local path corresponds to which project.
Must be rebuildable from scratch by re-reading origins.

**Continuity note** — needs a scope (a project, or a machine), an origin machine, a creation time, and
a body with five required sections. Ordering must be reliable without parsing the body.

**Tool server** — a name, an endpoint, and whether it needs a token. The secret is a separate
concern, stored apart from the registry so that the sync/local choice is a one-line change.

**Skill** — a named bundle whose only structural requirement is a manifest file at its root. The
product must not interpret its content. One reserved metadata file may accompany the library and
must not be treated as a skill or rewritten.

**Settings** — a small catalog of typed knobs with a declared scope, a default, and help text.

## 4.2 Lifecycle and retention

- Continuity notes: created per session, never modified, bounded to the most recent 100 per scope,
  with history as the archive. The bound exists because the active set is continuation state, not an
  incident archive; 10 proved too few to read back as a record of how a project got here. **[C]**
- Machine knowledge: updated in place, never appended as history. Resolved incidents are meant to be
  *forgotten*.
- Inventory: replaced wholesale on refresh.
- Projects: created on enrollment, destroyed on untracking — which deletes their notes. History is
  the only recovery path, and this is stated to the user.
- Quarantined skills and rescued clone contents: never automatically deleted, and never synchronized.

## 4.3 Concurrency and consistency

The current design has **no locking of any kind**, and this is the weakest part of the data model.
Single-file writes are staged and renamed, which protects against torn reads on one machine but says
nothing across machines.

Known consequences a rebuild must decide about explicitly:

- Two machines editing different entries of the same registry file between synchronizations is the
  *ordinary* case, not an exception, and produces a textual conflict. **[C]** — stated in a decision
  record.
- Two concurrent sessions on one machine share one agent home, can overwrite each other's checkout
  cache, and can produce identical note filenames (one-second granularity, no uniquifier), silently
  destroying one note. **[SI]**
- Project identifiers are minted by checking local existence only, so two machines can independently
  mint the same identifier for different repositories, and nothing detects the collision afterward.
  **[SI]**

An entry-per-file layout is explicitly identified in the existing decision record as the right shape
if conflicts ever become common, and as *simpler* than merging rather than an addition to it. A
rebuild should treat that as a strong hint.

---

# 5. Behavioral workflows

## 5.1 First-time setup

**Preconditions:** Linux, a container engine, basic tooling, and a private Git remote the user
controls.

1. User runs the install command. Prerequisites are checked; the install directory is chosen by a
   documented priority; on a RAM-backed-root platform the user is asked for a persistent directory
   instead, and refused non-interactively with an exact rerun command.
2. The program is downloaded (at a resolved exact revision), syntax-checked, and installed.
3. Command redirects for both agents are offered; existing non-Satchel commands of the same name are
   never overwritten — they are skipped with an explanation.
4. If the directory is not on the search path, the exact corrective line is printed. Nothing is
   modified automatically.
5. Setup chains directly into enrollment: name the machine, supply the remote.
6. If the remote is unreachable, the public key is displayed and the user is offered a retry loop.
7. The shared tree is seeded, the machine is registered by an initial push (which doubles as a
   write-access check), the platform boot block is offered, and the shared image is built.

**Result:** a machine that can immediately run `claude` or `codex`.
**Failure paths:** a partially-populated destination is *preserved* under a recovery path rather than
deleted; re-running with a different remote is refused before anything changes.

## 5.2 A normal session, end to end

**Preconditions:** an initialized machine; the current directory is not a home directory, the
filesystem root, or Satchel's own state.

1. Prerequisites verified; the directory resolved and validated.
2. Engine selected and cached for the whole session — deliberately, so cleanup does not re-probe
   after a force-quit briefly breaks detection.
3. Image built if missing (minutes, with a message).
4. Interrupt handling installed *before* any network work, so an interrupt during credential setup
   cannot strand a temporary agent.
5. Credential preflight: probe; optionally load a standard key or start a temporary agent; if none is
   available, explain the concrete consequence and pause for acknowledgement.
6. Pull shared state (time-bounded, best-effort). Validation failures degrade synchronization rather
   than aborting.
7. Prune notes past the retention bound; check for updates at most once a day.
8. Discover repositories under the mounted roots and resolve the session's project.
9. Possibly offer baseline onboarding — which, if accepted, *replaces* this session.
10. Seed the agent's Git identity without overwriting existing values; declare mounted directories
    trusted for Git.
11. Materialize the tool-server registry into the agent's native format.
12. Generate the instruction file.
13. Compose mounts and environment; repair ownership of Satchel-managed writable paths only.
14. Launch the agent; the terminal is handed over.
15. On exit: interrupts fully ignored so cleanup cannot be killed; ownership normalized.
16. If a conversation actually occurred, run the restricted note-writer, validate, scope, and file the
    result.
17. Validate and report skill changes; publish this machine's runtime versions; commit and push.
18. Exit with the **agent's** status code.

**Failure and recovery:** unreachable remote → warn, continue, push next time. Conflict → back out
to a clean tree, keep the local commit, report, continue. Note-writer failure of any kind → keep the
previous note, never fail the session. Repeated interrupts during exit → ignored through cleanup; a
different interrupt key deliberately skips only the note.

## 5.3 Attributing work to projects

1. During the session the agent may work in several repositories, or clone new ones.
2. After the session, repositories under the mounted roots are re-discovered.
3. If more than one scope is in play, the note-writer is asked to produce delimited per-scope
   sections, including one for each unknown repository.
4. Each well-formed section is filed under its scope. Unknown scopes are dropped with a warning.
   Duplicate scopes are merged rather than overwritten.
5. For an unknown repository with a portable origin, and only with a terminal attached, the user is
   asked once whether to track it. Yes enrolls it globally; **no ignores it globally and permanently**.
6. Without a terminal, the work is folded into the machine's own notes and **no decision is recorded**,
   so the question can still be asked later.

## 5.4 Recovering from a conflicted shared repository

1. A conflicting change is detected at session start or end.
2. Satchel abandons the in-progress operation and returns the clone to a clean tree. The local commit
   remains on the branch — only its integration is postponed.
3. The user is told, in plain language, that another machine changed the same file, that Satchel
   backed out rather than guess, and that nothing local was lost.
4. Synchronization is disabled for the rest of the run; the session proceeds normally.
5. The health check continues to report the unreconciled state until the user resolves it with
   ordinary Git.

The critical property: **the clone is never left mid-operation waiting for the user**, because that
state previously made the next session refuse to start.

---

# 6. Requirement confidence

## Confirmed — implement these

| Requirement | Basis |
|---|---|
| Directory-scoped disposable container session | Executed; tests; docs |
| Transparent command redirection with pass-through arguments | Executed; tests |
| Refusal to run sandboxed in a home directory, the root, or Satchel's own state | Tests; executed the guard directly |
| Explicit unsandboxed mode with a visible warning | Tests; decision record |
| Generated native-format instructions describing the real environment | Tests assert content per state |
| Truthful credential status in those instructions (three distinct states) | Tests assert each |
| Five-section continuity note, written by a restricted process, filed by the tool | Tests |
| Note-writer isolation: conversation home only, empty working directory | Tests; two decision records |
| Every note-writer failure preserves the previous note | Tests, per failure mode |
| Origin-based global project identity, normalized and credential-free | Tests including credential stripping |
| Nearest-enclosing-repository attribution | Tests |
| Retention bound of 100 notes per scope, ordered by filename | Tests; decision record |
| Never merge shared-state conflicts; back out cleanly, keep local work | Tests; decision record |
| No shared-state condition blocks a session | Decision record; tests (with one exception, §7.1) |
| Validate only fields actually read; tolerate unknown ones | Tests explicitly assert forward compatibility |
| Skill library packaging validation with local quarantine and restore | Tests, per rejection reason |
| Tool-server secrets never in configuration files or process arguments (where supported) | Tests |
| Three-tier machine knowledge with distinct loading behavior | Tests |
| Baseline onboarding: propose-then-approve, audited afterward, defaults to "not now" | Tests |
| Ownership repair restricted to an exact allowlist | Tests including refusal cases |
| Container ownership label as the sole proof before deleting anything | Tests |
| Uninstall preserves unrecognized and ambiguous commands | Tests |
| Boot-script rewriting: stage-and-rename, keep a known-good backup, refuse unparseable content | Tests |
| Exit-code convention; stderr/stdout split | Executed |

## Strongly inferred

- **Single-user product.** No multi-user concept anywhere; the credential-sharing rationale depends
  on it.
- **The agent's honest self-description is a core feature**, not a nicety — it recurs in vocabulary,
  instructions, tests, and a decision record.
- **Both agents are meant to be equal citizens**, though coverage is asymmetric in practice.
- **The synchronized repository is meant to be hand-editable** with ordinary Git.
- **Simplicity is an explicit constraint**, with a stated complexity ceiling: if a feature cannot be
  written sanely within the chosen constraints, that is a signal the feature is too complex, not that
  the constraints should change.

## Weakly inferred

- **Unrestricted outbound network in sandboxed sessions** appears intentional (tool servers are
  reached by local-network URL) but is stated nowhere and is not disclosed to the user or the agent.
- **The daily update check** as a nagging mechanism rather than a security control.
- **Cross-machine version-drift reporting** — the decision record candidly notes it was built to
  diagnose a problem that turned out to be something else, and is retained "on its own merits."

## Questionable

- **Fleet-wide settings.** Documented in three places and surfaced in live help text, but no setting
  is declared with that scope, so the code path cannot execute. Verified by inspection and by running
  the command. Either the feature or its documentation is wrong.
- **The escape offered when a session is refused.** Being refused a sandboxed session in a home
  directory offers a *host session* instead — root, privileged, whole filesystem writable. The
  offered remedy is strictly more dangerous than what was refused.
- **A guidance message recommends a configuration the design forbids** — running the session as root,
  directly contradicting an in-code design constraint.
- **Read-only reporting commands start containers** to read version strings, and a cache built
  specifically to avoid that cost exists but is not used by them.

## Apparently accidental

- Sync status, divergence counts, and baseline state print under a "Commands:" heading, because no
  separate heading was ever introduced.
- Under a piped-input install, a path probe can resolve to the filesystem root, so a file at a
  specific root path would be installed in preference to downloading.
- A scope-relevant field is written into every note's header and never read by anything.
- One agent's note-writer runs with tool access disabled; the other's does not — the container's empty
  mount set is the only thing enforcing parity.
- Two independent implementations of platform detection, one of which ignores the override that
  exists specifically to make it testable.

---

# 7. Problems in current product behavior

Ordered by user-visible severity. Each was verified rather than inferred where feasible; the method
is stated.

### 7.1 A stated core guarantee does not hold — tool-server validation can block a session **[C]**

The product's most emphatic promise is that no state of the shared repository may prevent an agent
from starting; the session path was rewritten specifically to degrade instead of aborting. But
tool-server materialization runs *after* that degradation and still applies strict validation, so a
malformed registry file — for example one carrying conflict markers after exactly the cross-machine
conflict the guarantee was written about — aborts the session anyway. This reproduces the original
failure cascade through a different door.

### 7.2 Shared configuration is executed as code on every machine **[C]**

The shared settings file is sourced as shell on *every* invocation of *every* command, before any
validation — including trivial ones like printing the version. Anyone who can write the shared
repository executes arbitrary code as the invoking user (often root on the server platform) on every
other machine. It is also the one registry file not covered by validation. Currently mitigated only
by the fact that nothing writes the file (see §7.4).

### 7.3 The sandbox-escape flag bypasses the protection meant to survive it — **verified by execution**

Running with the "allow a session here" override from the filesystem root is **permitted**
(return code 0), mounting the entire filesystem — including Satchel's own private state, which holds
SSH material, tool-server tokens, and agent logins — into what still calls itself a sandbox. The same
override is correctly *refused* when run directly inside the state directory.

The cause: the root case is handled in a branch that never evaluates the state-directory checks, and
the override is then gated on a *string label* comparison rather than on the condition that detected
the problem. I confirmed this by executing the guard against fixtures: root + override returned 0;
state directory + override was refused; home + override returned 0 (its documented purpose).

### 7.4 A documented capability cannot be exercised — **verified**

Fleet-wide settings are promised in help text, in the settings command's own footer, and in the
README. No setting is declared with that scope, so the write path is unreachable and the "this
machine only" flag is a no-op that silently does nothing different. Verified two ways: the catalog
contains five entries, all machine-scoped; and the live command prints every row tagged as
machine-scoped directly above the text promising fleet-wide behavior.

### 7.5 Destructive-path validation accepts unintended targets — **verified by execution**

The guard protecting the "delete everything local" path refuses the filesystem root, the home
directory, and the install directory, then accepts *any* directory containing any one of four common
names — including a `home` subdirectory. I executed it against a decoy directory containing only an
empty `home` subdirectory: **accepted (return code 0)**. On distributions where such a layout exists
at a system path, a misconfigured state directory could direct a privilege-escalating recursive
delete at it. This is the advertised safety net for the product's most destructive operation, and it
does not hold.

### 7.6 Work can be silently lost through inconsistent project attribution **[C]**

Two directional searches disagree. The session's project is found by walking *upward* to the nearest
enclosing tracked repository. The list of scopes the note-writer is permitted to file under is built
by matching *downward* from the launch directory. Launch inside a subdirectory of a tracked
repository while any unknown repository is also visible, and the session's own project is never added
to the permitted list — so the note attributed to it is discarded as an unknown scope. The user is
told the handoff succeeded. Confirmed by reading both searches directly.

Related losses in the same area: a section missing one required heading is dropped with **no message
at all**; filing 1 of 3 scopes is reported as complete success.

### 7.7 The tracking prompt is not neutral, and defaults to the more permanent answer **[C]**

The post-session question defaults to **yes**, so a reflexive keypress enrolls a repository across
every machine. Declining is not "not now" — it writes a permanent, fleet-wide *ignored* decision,
and ignored repositories are never offered again. There is no "ask me later" option interactively
(though that is exactly what the non-interactive path does).

### 7.8 Unattended use fails silently **[C]**

Under strict error handling, a prompt reading from closed input terminates the command with status 1
and **no message**. This affects setup, retirement, tool-server management, and skill removal. Only
one prompt in the product guards against it. Separately, a registered token-requiring server with no
stored token causes session startup itself to prompt — so an unattended session dies before launching,
with no output.

### 7.9 Health-check severity is miscalibrated **[C]**

A sleeping home server makes the health check report a *problem* and exit non-zero, while "no
credential key", "image not built", and "behind the remote" are mere warnings. The command also
prints "no problems found" after emitting a screenful of warnings. Verified by execution: it exits 1
on failures and 0 otherwise, regardless of warning count.

### 7.10 Silent configuration data loss for one agent **[C]**

When rebuilding its managed configuration block, the tool rescues configuration the agent wrote
inside that block — but only starting from the first section header. Bare key-value lines written
before any header are discarded with no warning, and rescued sections are relocated to the end of the
file, silently reordering user configuration.

### 7.11 Full-tree staging plus writable mounts can propagate destruction **[C]**

Session-end publishing stages the entire tree. The agent has read-write access to the skill library
and this machine's knowledge. An agent that deletes or corrupts content there has that deletion
committed and pushed to every machine, with a report printed *after* the fact and no confirmation or
threshold. Recovery is manual history archaeology.

### 7.12 Secret scanning is applied inconsistently **[C]**

The baseline path refuses to publish machine knowledge that looks like it contains credentials. But
that same directory is mounted read-write in *every ordinary session*, and the ordinary session-end
publish applies no scan at all. The protection is present exactly where an approval step already
exists, and absent where writes are unsupervised.

### 7.13 Common legitimate workflows are quarantined **[C]**

The most natural way to install a skill — cloning it — leaves repository metadata behind, which is a
rejection reason. The bundle is moved out of the library and, at session end, reverted to the
previously committed version. The user sees two lines in a stream of exit output. There is no
override, no allowlist, and no restore command; recovery is entirely manual.

### 7.14 Platform persistence has a silent-failure path with a green light **[C]**

Three key types are backed up to persistent storage, but the restore step handles only one of them.
The health check globs all three when reporting success. A machine whose only key is one of the other
two gets a backup that is never restored — and is told the backup is fine.

### 7.15 Additional confirmed problems

- **Update can hijack the uninstall authorization.** Self-update records whatever path it ran from as
  the authoritative installed path, with no ownership validation — and that record is the primary
  proof uninstall uses to decide it may delete something.
- **Explicitly requested project identifiers are silently ignored** when the origin is already
  tracked; the user is told a different name than the one requested.
- **Engine misconfiguration is unvalidated** — a typo becomes "command not found" on every operation,
  and is reported back as a configured value.
- **Boolean settings recognize only the literal `0`** — `false`, `no`, and `off` all mean *enabled*.
- **Removing a non-existent tool server reports success.**
- **The synchronize command hangs indefinitely** on an unreachable remote while every other network
  path is time-bounded, and fails loudly on push where every other path degrades to a warning.
- **Extra directories are silently ignored in host mode** — validated, capable of aborting the
  command, then never mounted, with no message.
- **This machine's knowledge is mounted twice with opposite permissions**, and the instructions tell
  the agent the read-only copy cannot be changed — false for its own entry.
- **Quarantine and recovery directories grow without bound** and are never reported as needing
  attention beyond a count.
- **Accepting baseline onboarding consumes the requested session even when it fails.**
- **Persistent trust declarations accumulate forever** for directories that no longer exist.

---

# 8. Features that should not be automatically recreated

Each requires explicit approval before inclusion.

| # | Feature | Why it should be re-justified |
|---|---|---|
| 1 | **Fleet-wide settings** | Documented in three places; cannot currently execute. Nobody has ever used it. Decide whether it is wanted at all before rebuilding it |
| 2 | **Cross-machine version-drift reporting** | The decision record states it was built on an assumption that proved wrong, and admits it is useful only at three or more machines. Its own alternative — "compare by hand" — is called the correct answer for a small fleet |
| 3 | **The host-session offer as an escape from a refused sandbox** | Answering a safety refusal by offering strictly more privilege. If a home-directory session is needed, the narrow override already exists |
| 4 | **Three-tier machine knowledge** | Genuinely well-reasoned, but it is three concepts, two loading strategies, a word limit, a version marker, and a migration path. Consider starting with one tier and splitting when the pain is real |
| 5 | **Baseline onboarding** | A large feature — privileged inspection, secret scanning, version markers, a three-way prompt, suppression markers, refresh flow — whose output is a file the user could write themselves. It also has the most convoluted control flow in the product (it replaces the session you asked for) |
| 6 | **The rescue-and-relocate configuration rewriter** | Complex, silently lossy (§7.10), and exists to coexist with one agent's habit of appending to its own configuration. A separate managed file, or an include, may remove the need entirely |
| 7 | **The daily update check** | Network call on session start, a stamp file, and interrupt propagation, to print a message. Weigh against letting the health check own it |
| 8 | **Redundant read-time container starts** | Reporting commands start containers to read version strings while an existing cache goes unused. Recreate the cache, not the container start |
| 9 | **Repeated ownership repair** | Runs three times per session over the same trees. One well-placed repair is likely sufficient |
| 10 | **Recovery directories that are never cleaned or surfaced** | Preservation is right; silent unbounded accumulation is not |
| 11 | **Two note-writer command shapes** | The two agents are invoked with materially different isolation flags. Specify the *guarantee* and derive both invocations from it |
| 12 | **The undocumented note-suppression variable** | Appears in no help, no documentation, no settings catalog. Either make it a real setting or drop it |
| 13 | **Ordering by filename with a one-second timestamp** | Works, but relies on an implicit encoding and cannot distinguish two notes in the same second — a real collision case |
| 14 | **Retention of exactly 100** | The bound is justified; the number is not. Make it a setting or justify it |
| 15 | **The reserved lock-metadata carve-out** | An exception to the "everything is a skill directory" rule for a file the product refuses to interpret. Confirm a real installer needs it |
| 16 | **The four-root, dedup-keyed command sweep on uninstall** | The most intricate logic in the product, existing to handle one distribution's symlinked home directory |
| 17 | **Sharing one agent home across concurrent sessions** | Not a feature — an unexamined consequence. Decide deliberately whether concurrent sessions are supported |

---

# 9. Open decisions

**9.1 Is concurrent use supported at all?**
*Why it matters:* determines whether locking, unique note identifiers, and per-session agent homes are
required. *Evidence:* no locking exists; several silent-loss paths follow directly; single-user
framing suggests it was never considered. *Simplest default:* explicitly support one session per
machine at a time, detect and refuse a second, and revisit only if that is painful.

**9.2 Should shared configuration be executable?**
*Why:* §7.2 is a remote code execution path across every machine. *Evidence:* executed as shell for
convenience; the capability that would populate it does not work. *Default:* a strict key-value format,
parsed and never executed.

**9.3 Should conflicts be prevented structurally instead of reported?**
*Why:* the current design guarantees conflicts on shared registries, since every machine rewrites whole
files. *Evidence:* the decision record identifies entry-per-file as the right shape and *simpler* than
merging, deferred only because it needs a coordinated migration — a constraint a rebuild does not have.
*Default:* adopt entry-per-file from day one.

**9.4 How much sandbox should the sandbox provide?**
*Why:* it currently bounds the filesystem and the user identity, but not the network, and mounts any
directory the user happens to be in — including system directories — read-write. *Evidence:* no network
restriction, no disclosure of that fact. *Default:* state the boundary precisely in user-facing
documentation and in the agent's instructions; decide network policy explicitly.

**9.5 Should the tool own credential distribution?**
*Why:* synchronizing plaintext tokens is a deliberate, well-argued decision resting entirely on the
repository being private, and history retains rotated secrets forever. *Evidence:* a decision record
argues it convincingly for this threat model; the stated opt-out requires the user to hand-write an
ignore rule that no code creates. *Default:* keep it, but make the opt-out a real command and warn at
registration rather than only at removal.

**9.6 Is the second agent a first-class target?**
*Why:* it changes how much abstraction is warranted. *Evidence:* both are supported and share the skill
library, but test coverage, isolation flags, and configuration handling are noticeably asymmetric.
*Default:* commit to both as equal, and specify shared guarantees rather than per-agent behavior.

**9.7 What actually counts as "substantive work"?**
*Why:* it gates the single most user-visible automatic decision — whether to prompt about a repository.
*Evidence:* the judgment is delegated entirely to a language model, and **nothing tests it**. *Default:*
define an explicit, inspectable rule (for example, commits or file modifications within the repository
during the session).

**9.8 Should the tracking prompt be able to say "not now"?**
*Why:* declining is currently permanent and fleet-wide, and yes is the default (§7.7). *Evidence:* the
non-interactive path already implements exactly the "no decision recorded" behavior. *Default:* three
options, defaulting to "not now".

**9.9 Should there be integrity verification for distribution?**
*Why:* installation and self-update execute downloaded code with no verification beyond a syntax check.
*Evidence:* no signature or checksum anywhere; trust rests entirely on transport plus a repository name.
*Default:* publish and verify a checksum at minimum.

**9.10 Is the RAM-backed-root platform a supported target or the primary one?**
*Why:* it accounts for a disproportionate share of complexity — relocatable installs, boot-script
rewriting with backup and parse-gating, flash key persistence, root-versus-session identity handling.
*Evidence:* explicit first-class support and a request not to abstract for a second platform until one
exists. *Default:* keep support, keep it isolated, and confirm it is still needed.

**9.11 Should reporting commands ever fail?**
*Why:* a command whose purpose is explaining a broken machine currently aborts partway through on some
kinds of broken machine. *Evidence:* the design intent is explicit and tested for the engine case, but
not applied to shared-state validation. *Default:* reporting commands never abort; they report what they
cannot read.

**9.12 Retention: 100 notes per scope — why?**
*Why:* it is durable state that grows with every session. *Evidence:* the bound is well argued; the value
is not. *Default:* keep a bound, make it configurable, and pick the number from real usage.

---

# 10. Clean-room specification

*Self-contained. No reference to any existing implementation. Terms used here are defined here.*

## 10.1 Product definition

A command-line tool that runs AI coding agents inside disposable containers on the user's own Linux
machines, and synchronizes session-continuity notes, tool-server configuration, reusable agent skills,
and machine-specific knowledge between those machines through a private Git repository the user
supplies and controls.

**Design constraints, in priority order:**

1. **The session is the product.** No condition of the shared repository, and no failure of any
   synchronization step, may prevent an agent from starting.
2. **Never guess about the user's data.** Do not merge conflicts, do not delete uncertain data, do not
   resolve ambiguity silently. Preserve and report.
3. **Tell the agent the truth** about what it can reach and what it can do.
4. **Prefer plain files, ordinary Git, and each agent's native conventions** over tool-specific
   abstractions.
5. **Fail loudly when the user asked about the system; degrade quietly when the user asked for work.**

## 10.2 Vocabulary

- **Session** — one run of an agent in one container, scoped to one primary directory and optional
  additional directories.
- **Machine** — one enrolled computer, with a stable name.
- **Fleet** — all machines sharing one Shared Repository.
- **Shared Repository** — the user-owned private Git repository carrying all synchronized state.
- **Project** — a Git repository the user explicitly chose to track, identified globally by its
  normalized origin.
- **Note** — a short structured summary written at the end of a session and injected at the start of
  the next one for the same scope.
- **Skill** — a self-contained folder of agent instructions and supporting files.
- **Tool Server** — an external service the agent can call, registered once and configured everywhere.

## 10.3 Required functionality

### R1 — Run a session

Launch the requested agent in a container scoped to the current directory. Pass all unrecognized
arguments through unchanged. Exit with the agent's own exit status. Delete the container on exit.

*Acceptance:*
- Running the agent through the tool and running it natively produce the same interactive experience.
- The agent's exit status is the tool's exit status.
- After exit, no container from that session remains.
- The primary directory is writable from inside; nothing outside declared mounts is present.
- A normal launch prints nothing before the agent's interface appears.

### R2 — Refuse unsafe scopes

Refuse a sandboxed session whose scope would be a home directory, the filesystem root, or the tool's
own state directory. Resolve all paths fully before checking, so symbolic links cannot bypass the
check. Provide one explicit override — which must **never** grant access to the tool's own state,
under any combination of arguments or directories.

*Acceptance:*
- Refused for a home directory, the root, a symlink to a home directory, and the state directory.
- With the override: a home directory is permitted; **the root is refused; the state directory is
  refused**; any scope containing the state directory is refused.
- Without an attached terminal, refusal is fatal and explains why.

### R3 — Unsandboxed mode

Provide an explicitly requested mode with the sandbox off and the host filesystem available at a
documented path. Warn visibly before launch. Mark the mode in the environment and in the agent's
instructions.

*Acceptance:* the mode marker is `host`; the warning appears before launch; the host filesystem is
reachable at the documented path and nowhere else; the agent's instructions state that changes there
affect the real machine.

### R4 — Describe the environment to the agent

Before each session, generate instructions in the agent's own native format stating: the mode; what is
reachable and what is not; the exact credential capability; the location and rules of the skill
library; this machine's notes in full; pointers (not contents) to larger references; and the most
recent note for the current scope.

*Acceptance:*
- Regenerated every session; declares itself managed.
- All paths absolute.
- Credential status is one of exactly three states and never claims pushing works when no identity is
  loaded.
- With no shared repository configured, it does not claim a skill library exists.
- Instructs the agent to say a path is *outside its view* rather than that it does not exist.

### R5 — Session continuity notes

At the end of a session that produced a conversation, generate a note with exactly five sections —
goal, done, in flight, next steps, gotchas — and file it under the correct scope. Inject the most
recent note for that scope at the next session start.

The generating process must receive **only** what it needs to read the conversation: no project
contents, no host access, no credentials, no clipboard, no tool servers, no skills, no machine
knowledge. The tool, not the agent, validates and files the result.

*Acceptance:*
- A session with no conversation produces no note and does not overwrite the previous one.
- Generator failure, malformed output, timeout, or explicit skip each leave the previous note intact
  and never fail the session.
- A dedicated interrupt skips only note generation.
- The generating container has exactly one durable mount.
- The next session's instructions contain the note, its origin machine, and its date.

### R6 — Project identity and attribution

Identify repositories by a normalized, credential-free origin. Common equivalent spellings of the same
repository must produce one identity. Maintain one global decision per identity: tracked or ignored.
Attribute work to the nearest enclosing tracked repository. Multiple checkouts of one origin are one
project.

*Acceptance:*
- Equivalent URL spellings yield one identity; embedded credentials and query strings never appear in
  stored identity.
- Different repositories with the same folder name receive distinct identifiers.
- An identifier already in use by a different origin is rejected, not merged.
- Work in a subdirectory is attributed to the enclosing project.
- **A session's own project is always eligible to receive that session's note**, regardless of where
  the session was launched within it. *(This is the explicit fix for §7.6.)*

### R7 — Ask before tracking, and make the answer reversible

Ask at most once per repository, only after a session, only for a repository with a portable origin and
no existing decision, only when the work was substantive by a **documented, inspectable rule**, and
only with a terminal attached.

*Acceptance:*
- Reading or opening a repository never prompts.
- Three options are offered — track, ignore, decide later — and **the default is "decide later"**.
- "Decide later" records nothing; "ignore" is fleet-wide and is stated as such before it takes effect.
- Without a terminal, nothing is recorded and the work is attributed to the machine.

### R8 — Synchronization that cannot block work

Pull at session start, publish at session end, both time-bounded. Never merge a conflict: return the
local clone to a clean state, keep local work, report plainly, and continue. Never leave the clone
mid-operation. Validate only the fields actually read; accept unknown ones.

*Acceptance:*
- Every reachable failure state — unreachable, conflicted, malformed, interrupted, absent — still
  allows a session to start.
- After a conflict, local work is intact and the clone is clean.
- A file containing fields from a newer version validates and is not rewritten to remove them.
- Commands that ask *about* the repository fail loudly; session paths degrade quietly.
- Unpublished work is reported until it is published.

### R9 — Shared skill library

Maintain one library shared by all agents and machines, mounted read-write into every session at each
agent's native location. Expose its path in the environment. Validate packaging only — never
interpret content. Quarantine invalid bundles locally, restore the last valid version where one
exists, and never synchronize or delete a quarantined item.

*Acceptance:*
- A skill installed in one session on one machine is available to both agents on every machine after
  the next synchronization.
- Each rejection reason quarantines rather than deletes, and reports the reason and location.
- Runtime-owned agent content is never synchronized.
- Removal by name deletes and publishes immediately; history is the recovery path.

### R10 — Tool-server registry

Register a server once by name, endpoint, and whether it requires a token. Materialize it into each
agent's native configuration at session start. Never place secret values into command lines or
process listings. Provide a supported choice between shared and machine-only secret storage.

*Acceptance:*
- A server registered on one machine is configured on every machine after synchronization.
- Secrets never appear in process arguments.
- Removing a server removes its stored secrets from every local location.
- **A missing secret never blocks or prompts during session startup** — it warns and configures
  without authentication. *(Explicit fix for §7.8.)*
- Rebuilding managed configuration never discards or reorders user-authored content. *(Explicit fix
  for §7.10.)*

### R11 — Machine knowledge

Maintain per-machine notes that are loaded into every session, and support larger references loaded
on demand. Sessions may read other machines' knowledge but write only their own.

*Acceptance:* notes appear in full in the instructions; larger references appear as a path and date;
another machine's knowledge is readable and not writable; the machine's own knowledge is presented
once, consistently, with accurate permissions.

### R12 — Health check

One command that reports, per check, whether the machine's setup is sound: tooling, container engine,
image, real mount capability, credentials, shared-repository reachability and divergence, and
tool-server reachability.

*Acceptance:*
- Exits non-zero only for conditions the user must fix locally.
- **A transient remote outage is a warning, not a failure.** *(Fix for §7.9.)*
- Never claims success when warnings were emitted; summarizes both counts.
- Runs to completion on a badly broken machine and never aborts partway.

### R13 — Status

One command reporting: machines in the fleet; tracked projects with origins and note counts; a count of
ignored repositories, expandable on request; registered servers; installed skills; quarantined items;
and unpublished work.

*Acceptance:* completes on a machine with no engine and no shared repository; never aborts on malformed
shared state — reports it instead.

### R14 — Install, redirect, uninstall

Single-command installation. Optional redirection of the agent commands through the tool. Uninstall
must distinguish removing the program from removing local data, must never touch the remote
repository, and must never delete anything it cannot prove it created.

*Acceptance:*
- An existing command not created by this tool is never overwritten or deleted; it is reported and left
  alone.
- Interactive uninstall defaults to cancel and states before any choice that the remote is not deleted
  and that unpublished work would be lost.
- Full removal requires a separate explicit confirmation.
- **The path validated for deletion must be proven to be this tool's own state — by a positive marker
  it wrote itself, not by resemblance to a directory layout.** *(Explicit fix for §7.5.)*
- Running containers are never stopped; unrecognized containers are never removed.

### R15 — Safe writes to files the tool does not own

When modifying any file owned by the user or the operating system, stage the replacement on the same
filesystem, verify it is well-formed, keep the previous known-good version, and install by rename —
never by truncate-and-write. Refuse to install content that does not verify.

*Acceptance:* an interrupted write never leaves a partial file; malformed content is refused and the
original is byte-identical; a recoverable previous version exists afterward.

## 10.4 Optional functionality

Valuable, but not required for a coherent product. Each should be separately approved.

| Feature | Note |
|---|---|
| Multi-directory sessions | Clear value for cross-repository work; adds validation surface |
| Clipboard forwarding | High user value, narrow mechanism |
| Guided machine inventory | See §8.5 — large; the same file can be written by hand |
| Cross-machine version drift reporting | Only useful at three or more machines, by its own analysis |
| RAM-backed-root platform support | Substantial complexity; keep isolated |
| Credential import from the host | Convenience only |
| Self-update | Requires integrity verification (§9.9) if retained |
| Update notification | Consider folding into the health check |
| Fleet-wide settings | Do not build until a setting actually needs it (§7.4) |

## 10.5 Explicitly out of scope

Multi-user support, access control, a hosted service, a daemon, a database, automatic conflict
resolution, agent-version pinning, and any mechanism that interprets skill *content* rather than skill
*packaging*.

## 10.6 Cross-cutting acceptance criteria

1. **No shared-repository state prevents a session from starting.** Verify against: unreachable,
   conflicted, malformed, interrupted mid-operation, absent, and containing unknown fields — *including
   malformed tool-server configuration.*
2. **No unattended path prompts or exits silently.** Every command run without a terminal either
   completes or fails with an explanatory message and a non-zero status.
3. **Nothing is deleted without proven ownership.** Every destructive operation names a specific target
   the tool can prove it created, or a target the user named exactly.
4. **Isolation properties are verified against a running container**, not against command arguments —
   user identity, capabilities, namespaces, read-only mounts, and absent mounts must be asserted from
   inside a live session in the automated test run.
5. **Documented behavior exists.** Every capability described in user-facing documentation or help text
   is reachable and covered by a test.
6. **Secrets never reach process listings, command lines, or logs.**
7. **User-authored content is never silently discarded or reordered** when the tool rewrites a file it
   shares with another program.
8. **Every warning names a concrete next action.**

---

## Appendix — What the existing product gets genuinely right

Worth preserving as intent, independent of implementation:

- **"The session is the product; synchronization is bookkeeping."** A clear, correct priority that
  most tools of this kind get wrong, arrived at after a real failure.
- **Never merging conflicts.** Backing out and reporting is the right call for a single-user tool, and
  the decision record honestly documents removing a working merge implementation because it solved a
  problem the user did not have.
- **Telling the agent the truth about its environment**, including the precise credential state. This
  is a real insight: an agent that knows it is sandboxed gives better answers than one that concludes
  the user's files are missing.
- **Validating what you read and ignoring what you do not** — the property that keeps one machine's
  upgrade from breaking the fleet.
- **Preserve rather than delete** for anything uncertain, applied consistently to malformed skills and
  interrupted setup.
- **Proving ownership before deleting**, via a label the tool itself applies.
- **Refusing to install a boot script that does not parse**, with a known-good backup — appropriate
  care for a file that can render a machine unbootable.
- **An honest vocabulary document**, including which words to avoid. Rare, and clearly load-bearing.
- **Decision records that state what was rejected and why**, including one that documents a feature
  built on an assumption that turned out to be wrong and was kept for different reasons. That kind of
  honesty is exactly what makes a rewrite possible.
