# Satchel — Forensic Product Specification

**Purpose of this document.** This is an implementation-independent specification of what Satchel is
*intended* to do, extracted from the existing repository so that a separate engineering team can
rebuild it without access to the original source.

It is deliberately **not** a description of the current implementation, and it does not propose a
replacement architecture. Where current behavior appears accidental, contradictory, or unjustified, it
is recorded as such rather than promoted to a requirement.

---

## How this analysis was conducted, and how much to trust it

Evidence was weighted in this order, strongest first:

1. **Executed behavior.** Commands were run and their real output and exit codes captured. Internal
   predicates were executed directly against fixtures to confirm or refute suspected defects rather
   than inferring them from reading.
2. **The test suite.** Roughly 2,900 lines encoding several hundred behavioral assertions. Tests are
   the strongest available evidence of *intent*, because someone deliberately wrote down what should
   happen.
3. **Documentation with reasoning attached.** A vocabulary document defining the core terms (including
   explicit "avoid this word" guidance), and thirteen decision records that state not just what was
   chosen but what was rejected and why. Several supersede or refine earlier ones, which makes the
   direction of intent visible.
4. **Observable interface surface.** Help text, prompts, error messages, file formats, mount layout.
5. **Change history.** ~123 commits across five days, including reverts and deliberate removals.
6. **Source reading.** Used last, and only to answer questions the above could not.

**The whole test suite passes.** That matters for how to read §7: the problems listed there are not
failing tests. They are contradictions between stated guarantees and actual behavior, gaps where no
test exists, or behavior that works exactly as asserted and should still not be inherited.

**A material caveat that shapes every confidence rating below.** No test in the suite ever launches a
real container. Every isolation guarantee the product makes — non-root execution, restricted
capabilities, read-only mounts, filesystem scoping — is verified only as *command-line argument
strings*, never against a running container. A separate script does check these properties for real,
but it is not part of the test run and must be executed by hand inside a live session. Sandbox
behavior is therefore classified throughout as **intended and specified**, not **verified**.

**Confidence legend:**

| Mark | Meaning |
|---|---|
| **[C]** Confirmed | Executed against the real program, or asserted by a test, or both |
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
container engine, Git, SSH, and plain files. It has no server, no daemon, no database, and no hosted
component. The user's own Git repository is the only shared state.

The product's own word for the set of machines sharing one repository is **caravan**. This document
uses it, because it appears in help text, in status output, and in user-facing messages, and a rebuild
team will encounter it. (It is used consistently everywhere except one decision record that says
"fleet" — an isolated slip, not a competing term.) **[C]**

## Who it is for

A **single technical individual** running several personal Linux machines — a laptop, a desktop, a
home server or NAS — who uses AI coding agents across all of them. Evidence for the single-user
framing is direct and consistent: credentials are shared freely between machines because "anyone who
can read the repository already has your notes"; there is no multi-user model, no permissions system,
no account concept, and no conflict-resolution algorithm. **[C]**

The audience is explicitly self-hosting and comfortable with the command line: Git, SSH keys, Docker
or Podman, and hand-edited configuration files are all assumed. **Unraid** — a NAS-oriented Linux
distribution whose root filesystem is rebuilt from a flash drive on every reboot — receives dedicated
first-class support, which strongly indicates a home-lab target. **[C]**

Unraid is named explicitly throughout this document rather than generalized. It is an external
platform with real, verifiable constraints, not an internal abstraction, and a rebuild team cannot
scope, test, or correctly implement this support without knowing which distribution is meant. Its
contract is specified in §3.7.

## What problem it solves

Four distinct problems, worth stating plainly because they are separable and a rebuild might
reasonably choose a subset:

1. **Blast radius.** An AI agent with file access can damage a machine. Running it in a throwaway
   container scoped to one directory bounds the damage.
2. **Context loss between sessions.** Agent conversations do not persist across machines, and a new
   session re-establishes what was being worked on from scratch. Satchel writes a short structured
   note at the end of each session and injects it into the next one — including on a different
   machine.
3. **Per-machine setup friction.** Tool servers, credentials, and reusable agent skills otherwise have
   to be configured separately on every machine. Satchel configures them once and distributes them.
4. **Honest self-description to the agent.** A distinctive and clearly deliberate goal: the agent is
   *told* what environment it is in, so it says "that file is outside the sandbox" instead of
   incorrectly reporting that the file does not exist. This appears in the vocabulary document, the
   generated instructions, the tests, and a decision record. **[C]**

## What it does not promise

Stating this positively matters, because the word "sandbox" carries more meaning than the product
delivers and the gap is not disclosed to users:

- **It is not a defense against a hostile agent.** Sessions have **unrestricted outbound network
  access** — no destination filtering, no egress policy, and no resource limits. **[C]** — confirmed
  from the composed container arguments: the only network flag anywhere applies to the deliberately
  unsandboxed mode.
- **It forwards real authority by default.** A signing socket that can authenticate to any host the
  user's loaded keys reach, and a live desktop clipboard socket, are both on by default.
- **The agent has read-write access to durable shared state** — the skill library and this machine's
  knowledge — which is committed and pushed to every other machine at session end.

The defensible promise is: *unselected host paths are absent from the session, and the session runs
as an unprivileged user with dropped capabilities.* Everything beyond that is a delegated authority
the product should name plainly. See §7.1 and §9.4.

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

Everything else — tool-server registry, shared skills, machine-knowledge tiers, machine inventory,
health checking, version-drift reporting — is additive.

**One caveat on step 3.** In the current product, steps 3–5 are not separable: continuity notes, the
tool-server registry, and the skill library are all rooted in the synchronized repository, so a
machine configured *without* a remote gets none of them — not even locally. Setup nonetheless tells
the user these features "stay on this machine." A rebuild must choose deliberately whether local-only
operation is a supported mode (§9.2). **[C]**

---

# 2. User-visible capabilities

## 2.1 Run an agent in a disposable, directory-scoped container

| | |
|---|---|
| **User goal** | Use an AI coding agent without giving it the whole machine |
| **Trigger** | `claude` / `codex` (installed command redirects), or the equivalent explicit invocation, from any directory |
| **Behavior** | Verify prerequisites; refuse unsafe locations; select a container engine; build the shared image if missing; prepare credentials; synchronize shared state; generate instructions for the agent; launch the agent interactively with the current directory mounted read-write at its real absolute path; on exit, write a continuity note and publish changes |
| **Output** | The agent's own interface, unmodified. Satchel itself prints nothing on a normal sandboxed launch |
| **Failure** | Missing prerequisites, no container engine, an unresolvable directory, or a container engine that cannot bind-mount abort before launch. Shared-state problems degrade to "no synchronization this run" and the session proceeds |
| **Persisted state** | Per-agent home (logins, conversation history, host-key trust records) surviving between sessions; generated instruction file rewritten each launch |
| **External systems** | Container engine; container registry and package repositories on first build; the user's Git remote |
| **Evidence of intent** | The product's stated purpose; the silence of a normal launch is explicitly reasoned about in a decision record (agent interfaces immediately repaint the screen, so a routine banner only flashes); container arguments are asserted by tests **[C]** |

The container is deleted on exit. Extra arguments are passed through to the agent untouched, so the
wrapper is transparent in normal use. The session exits with the agent's own status code. **[C]**

A real bind-mount probe guards against nested-container environments where the engine's daemon cannot
see the caller's filesystem; the session refuses to start with a specific explanation rather than
launching into an empty mount. **[C]** — though the current probe tests only Satchel's own state
directory, not the working directory, and only fires when a container marker file is present.

## 2.2 Host Session — deliberately unsandboxed

| | |
|---|---|
| **User goal** | Fix the machine itself, using the same agent and the same context |
| **Trigger** | An explicit flag, accepted either before or after the agent name; or by accepting the offer made when a sandboxed session is refused |
| **Behavior** | Sandbox off: runs as root with full privileges, host filesystem mounted read-write at a known path, host process namespace and host networking shared. The agent is told it is in this mode and that changes under the host path affect the real machine |
| **Output** | A visible warning before launch, then the agent |
| **Failure** | Same prerequisites as a normal session. There is no rollback for host changes |
| **Evidence of intent** | Vocabulary document: "The container is packaging, not protection." A decision record states this is the one case warranting a pre-launch warning. Tests assert the mode marker, the process-namespace flag, and the warning text **[C]** |

## 2.3 Multi-directory sessions

Additional directories can be mounted read-write alongside the primary one, for work spanning
repositories that influence each other. Paths are resolved before validation, so a symbolic link
cannot be used to escape the boundary. Home directories, the filesystem root, and Satchel's own state
are refused. **[C]** — asserted by tests.

Alternatively, launching from a parent directory containing several repositories achieves the same
thing, and Satchel discovers repositories beneath the mounted roots both before and after the session,
so newly cloned repositories are classified correctly. **[C]**

## 2.4 Session continuity notes ("handoffs")

| | |
|---|---|
| **User goal** | Resume work without re-explaining it, including on a different machine |
| **Trigger** | Automatic at session end, when the session actually produced a conversation |
| **Behavior** | An unattended, heavily restricted agent process resumes the just-finished conversation and returns a five-section summary: goal, done, in flight, next steps, and gotchas. Satchel — not the agent — validates, scopes, names, and files the result. At the next session start, the most recent handoff for the current scope is injected into the agent's instructions |
| **Output** | A progress message naming the interrupt key that skips it |
| **Failure** | Every failure mode is non-fatal and preserves the previous handoff: writer error, wrong format, timeout, explicit skip, or "nothing worth handing off" |
| **Persisted state** | Timestamped handoff files per scope, bounded to the most recent 100 |
| **Evidence of intent** | Vocabulary defines it as "semantic continuity, as opposed to literal transcript replay or an incident archive"; a decision record explains why the retention bound was raised from 10 to 100; tests cover the failure paths individually **[C]** |

The writer's isolation is unusually strict and clearly deliberate: it receives only the agent's own
conversation directory. It cannot read the project, the host, the credential socket, the clipboard,
tool servers, skills, or machine knowledge. An empty temporary filesystem is mounted at the original
working directory purely so the agent can locate the right conversation without exposing any project
content. **[C]** — asserted by tests, and stated in two decision records.

Two properties of the current mechanism should be understood as costs, not features: the summary is
produced by a language model resuming a provider-side conversation, so it is nondeterministic and
depends on the provider staying available and the transcript format staying compatible; and
validation checks only that the five section headings are present — not their order, uniqueness, size,
or truthfulness. A stale handoff silently remaining "the latest" after a real session is the expected
failure mode. **[C]**

## 2.5 Project identity and work attribution

| | |
|---|---|
| **User goal** | Handoffs filed against the repository the work happened in, not the folder the session started in |
| **Trigger** | Automatic classification; explicit enrollment commands; a post-session prompt for unknown repositories |
| **Behavior** | Repositories are identified by a normalized, credential-free form of their network origin, so different URL spellings of the same repository are one identity across all machines. Each identity carries one global decision: tracked or ignored. Work is attributed to the nearest enclosing tracked repository. Multiple checkouts of one origin are one project |
| **Failure** | A repository with no portable origin cannot be auto-identified; it can be enrolled explicitly, and linked on another machine by naming the existing identifier. Changing a checkout's origin invalidates the cached mapping and forces a new decision |
| **Persisted state** | Global origin→decision registry; per-machine cache of local checkout locations; per-project handoff directories |
| **Evidence of intent** | Two decision records, the second explicitly collapsing three sources of identity into one after the duplication caused drift; extensive test coverage of normalization, uniqueness, and validation **[C]** |

Prompting is deliberately rare: it happens only after a session, only for a repository with a portable
origin and no existing decision, only when the note-writing step judged the work substantive, and only
when a terminal is attached. Merely opening or reading a repository does not prompt. **[C]** — though
see §7.7: the prompt defaults to *yes*, and declining is permanent and caravan-wide.

## 2.6 Machine knowledge, in three tiers

A deliberate separation by lifetime, introduced after an earlier single-file design mixed durable
facts with incident history and grew the startup context:

- **Machine notes** — small, current, operational truth. Loaded in full into every session. Soft
  ceiling of 750 words, warned about but never enforced.
- **Inventory** — a broad, dated system reference. The session receives its location and generation
  date, never its contents, and reads it on demand.
- **Guides** — substantial reusable procedures, one per topic, listed by title only.

Sessions can read *other* machines' knowledge read-only, but write only their own. **[C]** — the
tiering, the rationale, and the read-only cross-machine visibility each have a decision record, and
the loading behavior is asserted by tests.

## 2.7 Machine baseline onboarding

Offered once, on the first normal launch after an agent authenticates. If accepted, the agent inspects
the real machine through a read-only mount and proposes an inventory, concise notes, and any justified
guides — showing them for approval before writing. Choices are yes / not now / never; the default is
"not now", explicitly because the access is privileged. **[C]**

Accepting makes the inspection the entire command; the originally requested session does not start,
and the user is told to run it again. **[C]** — asserted by tests and stated in a decision record.

Satchel audits the result afterward rather than gating the write: it verifies an inventory was actually
produced and scans newly added lines for credential-shaped content, suppressing synchronization if
either check fails — without ever printing the suspected value. **[C]** The audit is genuinely
after-the-fact: see §7.11, where a rejected baseline's content stays in the working tree and is
published by the next ordinary session.

## 2.8 Shared skill library

One library of agent "skills" (folders of instructions and supporting files), shared by both agents and
every machine, mounted read-write into each session at the agent's *native* skills location so no
translation layer is needed.

Skills are installed by asking an agent to write the folder; there is no install command, by design.
On session exit, Satchel validates the library's packaging — real directory, safe name, required
manifest file present, no embedded repository metadata, no symbolic links escaping the bundle — and
quarantines anything malformed locally rather than synchronizing it, restoring the last valid version
where one exists. Validation deliberately does not interpret content. **[C]**

Removal is a first-class command with an interactive picker; the named selection is the authorization,
and repository history is the recovery path. **[C]**

Both agents see the *same* library with no filtering, marker, or opt-out. The decision record is
explicit that this is a deliberate trade — a skill that misfires on the agent it was not written for is
preferred to the silent absence caused by an earlier per-agent split, and per-agent curation "returns
as an explicit exclusion mechanism, not as the default layout" if ever needed. **[C]**

## 2.9 Tool-server (MCP) registry

Servers are registered once with a name, an HTTP endpoint, and whether they need a bearer token. The
registry synchronizes; tokens synchronize by default with a documented, deliberate opt-out. At session
start the registry is materialized into each agent's own configuration format. **[C]**

The threat model is stated explicitly: the repository is private and reached over the user's own keys,
so anyone who can read it already has the user's notes. Agent login credentials and conversation
transcripts never synchronize — that line is drawn hard and enforced structurally by keeping them
outside the synchronized tree. **[C]**

One security measure is notably careful: for the agent that supports it, token *values* are never
placed in configuration or in the container's command line; only the variable name is passed, so
secrets do not appear in the host process list. **[C]** — asserted by tests. That mechanism has a
serious flaw in its identity mapping, described in §7.4.

Endpoint reachability is probed on registration and in the health check. "Reachable" currently means
only that an HTTP request to the URL returned something other than a connection failure or a 404 —
there is no protocol exchange, so an endpoint answering 401, 403, or 500 reports as healthy. **[C]**

## 2.10 Personal context

Two hand-edited documents at the root of the shared repository — a profile and a set of preferences —
are injected verbatim into every session's generated instructions, on every machine. They are created
empty at enrollment. There is no command to view or edit them; hand-editing the synchronized clone is
the only path, which makes a real capability effectively undiscoverable. **[C]**

## 2.11 Cross-machine synchronization

The user supplies any Git remote — a hosted private repository, a bare repository over SSH, or a bare
repository on a network mount. Satchel pulls at session start and pushes at session end.

The governing rule is stated repeatedly and is the product's most important reliability property:
**the session is the product; synchronization is bookkeeping, and no state of the shared repository
may prevent an agent from starting.** On conflict, Satchel never merges. It backs out to a clean tree,
keeps the local commit, says so, and continues — the user reconciles once with ordinary Git. **[C]** —
this is a decision record written after a reproducible failure cascade that locked a machine out of
running an agent entirely, and it is covered by tests.

Validation checks only the fields actually read and tolerates unknown ones, so a newer version on one
machine cannot break older machines. **[C]** — this too was written after the opposite behavior caused
a cross-machine outage.

Commands that ask *about* the shared repository validate strictly and fail loudly; the session path
validates softly and degrades. That split is deliberate and correct in principle — see §7.2 and §7.14
for the two places it does not hold.

## 2.12 Supporting capabilities

| Capability | Goal | Notes |
|---|---|---|
| **Credential forwarding** | Push from inside a session | Forwards a signing socket, never key files. Probes whether an identity is actually loaded and tells the agent the truth. Can start a session-owned temporary agent from a standard key, prompting on the host. Host-key trust is accept-on-first-use, persisted per agent home **[C]** |
| **Clipboard forwarding** | Paste screenshots into an agent | Forwards the desktop compositor socket, preferring the more restrictive protocol; headless machines unaffected **[C]** |
| **Health check** | "What is wrong with this machine?" | ~19 checks: tooling, engine, image, a real mount probe, credentials, repository reachability and divergence, cross-machine version drift, platform persistence, tool-server reachability **[C]** |
| **Status** | See the whole caravan at a glance | Machines, projects with origins and handoff counts, ignored count, servers, skills, quarantine, unpushed work **[C]** |
| **Login import** | Skip logging in again | Copies the host's existing agent credentials into Satchel's own agent home; never synchronizes them **[C]** |
| **Self-update** | Stay current | Resolves the branch to an exact revision (to defeat CDN caching), downloads, syntax-checks, replaces atomically, then rebuilds the image using the *new* artifact **[C]** |
| **Machine retirement** | Remove a machine from the caravan | Deletes only that machine's directory, after confirmation; history retains it **[C]** |
| **Install / uninstall / command redirection** | Lifecycle | Single-command install; opt-out redirection of the agent commands; uninstall distinguishes program-only from full local removal and never touches the remote **[C]** |
| **Unraid persistence** | Survive reboot where the root filesystem is rebuilt from flash | Relocatable install onto array storage, plus a marked block in Unraid's user boot script restoring command links and the sync key **[C]** |

---

# 3. Interfaces

## 3.1 Command-line surface

Two invocation styles exist and are equivalent: a redirected command that shadows the agent's own name,
and an explicit subcommand. The redirect is what makes the product feel transparent.

**Session commands**

| Command | Purpose |
|---|---|
| `<agent>` / `<tool> <agent>` | Run an agent in the current directory |
| `--host` | Unsandboxed machine-troubleshooting session |
| `--unsafe-home` | Permit a session in a home directory (normally refused) |
| `--with <dir>` | Mount an additional directory; repeatable |
| `track [id]` / `untrack [id]` | Explicitly enroll, or globally ignore, the enclosing repository |

Flags are accepted **before or after** the agent name, which is a real usability decision. **[C]**

**Caravan and configuration commands**

`init`, `sync`, `status [--ignored]`, `skills [list|remove [name]]`, `key [--persist]`,
`retire [machine]`, `doctor`, `mcp list|add|remove`, `settings [<KEY> <value> [--local]]`,
`import <agent>`, `image [--rebuild]`, `update`, `link [agent]`, `unlink [agent]`,
`uninstall [--purge] [--yes]`, `version`, `help`.

**Conventions, verified by execution:**

- Exit `0` on success; exit `1` for every fatal error. Bare invocation prints help and exits `0`.
- Diagnostics (`info`, `warning`, `error`) and all interactive prompts go to **stderr**; report bodies
  go to **stdout**. **[C]**
- The health check exits `1` if any check *fails*, but prints "no problems found" when there are only
  warnings. **[C]** — verified by running it.

There are no API endpoints, web screens, webhooks, background workers, or daemon control interfaces.

Argument validation across this surface is weak and should not be reproduced as-is: the redirect
commands accept any name at all rather than only the two supported agents, several commands tolerate
misplaced arguments, and the documented way to clear a setting does not clear it (§7.15).

## 3.2 Settings

Five settings, all machine-local in practice:

| Setting | Default | Effect |
|---|---|---|
| Engine override | Auto-detect | Force Docker or Podman |
| Credential forwarding | Enabled | Forward or prepare a signing agent for sessions |
| Clipboard forwarding | Enabled | Forward a graphical clipboard/display socket |
| Session user ID | Host user, or 1000 when the host is root | User identity inside sandboxed containers |
| Session group ID | Same as session user | Group identity inside sandboxed containers |

Layering is: built-in default, then a shared file, then a machine-local file. A caravan-wide scope is
described in help text and documentation but no setting declares it, so that layer is unreachable —
see §7.5.

**Both layers are executed as shell, not parsed** — see §7.2. Boolean settings recognize only a
literal `0` as "off"; `false`, `no`, and `off` all mean *enabled*. Numeric settings are not checked for
being numeric, and the engine override is not checked for naming a real program.

Installer-time environment variables control the install directory, the state directory, and whether
the command redirects are created. Two further environment variables materially change behavior — one
enabling the unsandboxed mode, one suppressing handoff generation — but appear in no help text,
documentation, or settings catalog. They should be treated as leakage, not as a compatibility
contract. **[C]**

## 3.3 What the agent sees inside a session

This is the product's most important interface, because it is the contract between Satchel and the
agent. A generated instruction file is written in each agent's **native** user-level memory format, so
it loads without any special mechanism, and is rewritten from scratch every launch with a header
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
7. **Global profile and preferences**, inlined.
8. **Visible projects** — a table of contents with the attribution rule, not every project's context.
9. **The previous handoff for this scope**, with provenance, and the instruction to continue from it.

All paths in this file are absolute, deliberately: a host session runs as root, where a home-relative
path resolves somewhere else. **[C]** — asserted by tests.

**Environment exposed to the agent:** a runtime marker, a mode marker (`sandbox` or `host`), and the
skill library path — so skill installers can detect the contract mechanically rather than guessing.
Plus a home path, terminal type, an auto-updater suppressor, a Git-over-SSH setting that accepts
unknown host keys on first contact, and conditionally the credential socket, display variables, and
per-server token variable *names*. **[C]**

**Mount layout (conceptual):** agent home read-write; this machine's knowledge read-write; all
projects' handoffs read-only; all machines' knowledge read-only; skill library read-write; the project
at its real path; extra directories at their real paths; and, only in host mode, the host filesystem at
a distinct path. Note that this machine's knowledge therefore appears twice, at different paths with
opposite permissions, and the instructions never mention the aliasing (§7.15).

## 3.4 Configuration and files the user may edit

The synchronized repository is intended to be user-editable with ordinary tools — this is a stated
design goal ("plain files and plain git"). Machine notes, inventory, guides, the global profile and
preferences, the origin registry, and the server registry are all hand-editable, with validation
applied on read. Quarantined skill attempts and rescued incomplete clones are left in place for the
user to inspect and are never automatically deleted.

The specific file formats in use are *not* clean-room requirements. What is required is that shared
state remain inspectable, hand-repairable, and recoverable with tools the user already has.

## 3.5 Host files and sockets touched

Standard SSH public/private key locations and the known-hosts file; the host signing-agent socket; host
Git configuration, for author identity only; the agents' own native login files, during explicit import
only; the desktop compositor or X11 socket and authority file; the project and any explicitly named
extra directories; the entire host filesystem in an unsandboxed session; the command directory on the
executable search path; and, on Unraid, the boot script and a flash-backed key backup area.

## 3.6 External systems

| System | Use | Failure policy |
|---|---|---|
| Container engine | Everything | Fatal for sessions; reporting commands degrade |
| User's Git remote | All synchronization | Degrade, never block a session |
| Source hosting API | Update check, revision resolution, changelog | Best-effort; silent or warning |
| Container registry + package repositories | Image build | Fatal to the build only |
| Registered tool servers | Reachability probing | Advisory on add; **counts as a failure** in the health check (see §7.14) |
| Desktop compositor | Clipboard | Absent on headless machines; nothing mounted |
| Credential agent | Signing for pushes | Warn and continue, or start a temporary one |
| Agent providers | The agents themselves, and handoff generation | Handoff failure preserves the previous handoff |

**No signature or checksum verification exists anywhere.** Both installation and self-update trust the
transport and check only that the downloaded script parses. **[C]**

**Nothing in the container image is pinned.** The base image is a mutable tag, re-resolved on every
build; system packages come from a live index; both agent CLIs install at whatever version is current.
Each machine therefore builds a different runtime at a different time, and the product's response is
to *report* the resulting drift rather than prevent it. This is a documented, deliberate decision — the
rationale is that picking up new agent versions is the main reason to run an update — but it means
"the same Satchel version" does not imply the same behavior on two machines. **[C]**

## 3.7 Unraid platform contract

Unraid is the one operating system requiring behavior no other target needs. Everything below is a
property of **Unraid**, not of the current implementation, so a rebuild must satisfy it regardless of
design. All items **[C]** unless marked.

**The constraints that force the behavior:**

| Unraid property | Consequence |
|---|---|
| The root filesystem — including the standard command directory and root's home — is rebuilt from the flash drive at every boot | A default install disappears on reboot. Command links and SSH material must be restored at each boot |
| Persistent storage lives on the array, conventionally under a well-known mount point | State must be relocatable there, and state *not* on the array is silently destroyed |
| The flash drive is unencrypted FAT | Anything persisted there, including a private key, is stored in the clear. This is an accepted, documented trade-off |
| The user boot script also starts the web UI | A malformed edit costs the user a trip to the flash drive with another computer. It must never be truncated or left unparseable |
| Unraid runs as root; sandboxed sessions run as an unprivileged user | Project files owned by root are readable but not writable inside a session, and Git refuses to operate on them at all |
| A root-owned credential agent socket cannot serve an unprivileged peer | The host's agent cannot simply be forwarded; a session-scoped one must be started as the session's user |

**Required behavior:**

1. **Detect Unraid** by a marker file, and make the marker, the flash config directory, and the live
   command directory overridable — otherwise this behavior cannot be tested anywhere else. *(The
   current code honors these overrides in most places but hardcodes the path in the generated boot
   block — see §7.13.)*
2. **Refuse a default install.** Interactively, ask for a persistent directory. Non-interactively, fail
   with an exact rerun command rather than installing somewhere that will vanish.
3. **Verify the array is mounted** before creating the install directory, so the whole path is not
   silently created on the RAM disk.
4. **Offer to install a marked, delimited block** in the user boot script that restores the command
   links, the SSH key, and the known-hosts file. Never write outside the markers; never write a link
   line with no resolved target.
5. **Write that file safely** — stage on the same filesystem, verify it parses, keep the previous
   known-good copy, install by rename. Refuse anything that fails verification. Never repair a block
   with a missing terminator; report it and leave the file alone.
6. **Persist the SSH key and known-hosts file to flash, and restore whatever was persisted.** The
   backup and the restore must agree on which key it is — see §7.13, where they do not.
7. **Keep the boot block in step** with later changes to which commands are redirected.
8. **Remove the block on uninstall**, before anything else is removed.
9. **Report in the health check** whether state is on persistent storage (a failure if not), whether
   the boot block exists, and whether the key that is actually restored at boot is backed up.
10. **Explain the ownership mismatch** at launch when project files are root-owned, including the exact
    corrective command, and state that it cannot be fixed from inside the session.

**Explicit design constraint carried forward:** do not build a platform abstraction layer for a second
platform until a second platform exists. This is a stated rule in the existing development contract and
is worth preserving — the Unraid-specific content should live in exactly one place, but it should not
be generalized speculatively. **[C]**

---

# 4. Data requirements

Described as information the product logically needs, not as the current storage layout.

## 4.1 Entities

**Machine** — a named participant. Needs: a stable name; a knowledge set (notes, inventory, guides); a
cache of where projects are checked out locally; its own handoffs for work outside any project; a
published record of what software versions it is running, for drift detection; and a marker recording
that baseline onboarding was declined permanently.

**Repository decision** — the global authority for identity. Needs: a canonical, credential-free origin
identity; a decision (tracked or ignored); and, when tracked, the project it belongs to. Invariants:
the identity must already be in canonical form; one project per identity; and a project may not be
claimed by two identities.

**Project** — a tracked repository's shared identity. Needs: a stable identifier and an ordered set of
handoffs. It requires **no other attributes** — an earlier design stored identity in three places and
the duplication caused drift during migration, so it was collapsed to one. Folder names suggest
identifiers but never establish identity.

**Checkout binding** — machine-local, disposable: which local path corresponds to which project. Must
be rebuildable from scratch by re-reading origins, and invalidated when a checkout's origin changes.

**Handoff** — needs a scope (a project, or a machine), an origin machine, a creation time, and a body
with five required sections. Ordering must be reliable without parsing the body, and two handoffs for
the same scope must never be able to collide on a name.

**Personal context** — a global profile and a global preference document, user-authored, injected into
every session everywhere.

**Tool server** — a name, an endpoint, and whether it needs a token. The secret is a separate concern,
stored apart from the registry so that the sync/local choice is a one-line change. Each server's
credential channel must be distinguishable from every other server's (§7.4).

**Skill** — a named bundle whose only structural requirement is a manifest file at its root. The
product must not interpret its content. One reserved metadata file may accompany the library and must
not be treated as a skill or rewritten.

**Quarantine** — machine-local, never synchronized, never automatically deleted: rejected skill bundles
and rescued incomplete clones, retained for the user to inspect.

**Runtime report** — per machine, the versions it is running, published for cross-machine comparison.
Diagnostic only, and stale until that machine next runs a session.

**Settings** — a small catalog of typed knobs with a declared scope, a default, and help text.

## 4.2 Lifecycle and retention

- Handoffs: created per session, never modified, bounded to the most recent 100 per scope, with
  repository history as the archive. The bound exists because the active set is continuation state, not
  an incident archive; 10 proved too few to read back as a record of how a project got here. **[C]**
- Machine knowledge: updated in place, never appended as history. Resolved incidents are meant to be
  *forgotten*.
- Inventory: replaced wholesale on refresh.
- Projects: created on enrollment, destroyed on untracking — which deletes their handoffs on every
  machine. History is the only recovery path, and this is stated to the user.
- Quarantined skills and rescued clone contents: never automatically deleted, never synchronized, and
  never surfaced beyond a count.
- Agent logins and transcripts: machine-local until an explicit purge. Never synchronized.

**Retention has two layers and only one of them is specified.** Pruning bounds the *active* set;
repository history retains everything forever, including rotated tokens, deleted machines, and
untracked projects. There is no erasure path. A rebuild must decide whether "delete" ever means
"gone" — see §9.12.

## 4.3 Concurrency and consistency

The current design has **no locking of any kind**, and this is the weakest part of the data model.
Single-file writes are staged and renamed, which protects against torn reads on one machine but says
nothing across machines.

Known consequences a rebuild must decide about explicitly:

- Two machines editing different entries of the same registry file between synchronizations is the
  *ordinary* case, not an exception, and produces a textual conflict requiring hand reconciliation with
  Git. **[C]** — stated in a decision record.
- Two concurrent sessions on one machine share one agent home and one synchronized clone, can overwrite
  each other's checkout cache, and can produce identical handoff filenames (one-second granularity, no
  uniquifier), silently destroying one. **[C]**
- Project identifiers are minted by checking local existence only, so two machines can independently
  mint the same identifier for different repositories, and nothing detects the collision afterward.
  **[SI]**
- No transactional boundary spans agent-home mutation, handoff generation, commit, and push.

An entry-per-file layout is explicitly identified in the existing decision record as the right shape if
conflicts ever become common, and as *simpler* than merging rather than an addition to it. A rebuild
should treat that as a strong hint.

## 4.4 Import and export

Synchronization is the primary mechanism for moving state between machines. Agent login import copies
recognized host credentials into local state. Public key display is a manual export for registration
with a Git host. Everything in the shared repository is plain text and can be extracted by hand. There
is no backup, restore, archive, or migration command, and no supported path for importing state from a
different version of the product — see §9.13.

---

# 5. Behavioral workflows

## 5.1 First-time setup

**Preconditions:** Linux, a container engine, basic tooling, and — for the full product — a private Git
remote the user controls.

1. User runs the install command. Prerequisites are checked; the install directory is chosen by a
   documented priority; on Unraid the user is asked for a persistent directory instead, and refused
   non-interactively with an exact rerun command.
2. The program is downloaded at a resolved exact revision, syntax-checked, and installed.
3. Command redirects for both agents are offered; existing non-Satchel commands of the same name are
   never overwritten — they are skipped with an explanation.
4. If the directory is not on the search path, the exact corrective line is printed. Nothing is
   modified automatically.
5. Setup chains directly into enrollment: name the machine, supply the remote.
6. If the remote is unreachable, the public key is displayed and the user is offered a retry loop, or
   the choice to continue without synchronization.
7. The shared tree is seeded, the machine is registered by an initial push (which doubles as a
   write-access check), the Unraid boot block is offered where applicable, and the shared image is
   built.

**Result:** a machine that can immediately run `claude` or `codex`.

**Failure paths:** a partially-populated destination is *preserved* under a recovery path rather than
deleted; re-running with a different remote is refused before anything changes; an image-build failure
leaves the command installed and prints the exact retry.

**Two things this flow currently gets wrong** and a rebuild must not copy: enrollment can be re-run
(the product itself repeatedly tells users to), and doing so silently discards every setting the user
had chosen (§7.6); and the main program destination is overwritten without any ownership check, even
though the agent redirects beside it are carefully protected (§7.9).

## 5.2 A normal session, end to end

**Preconditions:** an initialized machine; the current directory is not a home directory, the
filesystem root, or Satchel's own state.

1. Prerequisites verified; the directory resolved and validated; the engine's ability to bind-mount
   probed for real.
2. Engine selected and cached for the whole session — deliberately, so cleanup does not re-probe after
   a force-quit briefly breaks detection.
3. Image built if missing (minutes, with a message).
4. Interrupt handling installed *before* any network work, so an interrupt during credential setup
   cannot strand a temporary agent.
5. Credential preflight: probe; optionally load a standard key or start a temporary agent; if none is
   available, explain the concrete consequence and pause for acknowledgement.
6. Pull shared state (time-bounded, best-effort). Validation failures degrade synchronization rather
   than aborting.
7. Prune handoffs past the retention bound; check for updates at most once a day.
8. Discover repositories under the mounted roots and resolve the session's project.
9. Possibly offer baseline onboarding — which, if accepted, *replaces* this session.
10. Seed the agent's Git identity without overwriting existing values; declare mounted directories
    trusted for Git.
11. Materialize the tool-server registry into the agent's native format.
12. Generate the instruction file.
13. Compose mounts and environment; repair ownership of Satchel-managed writable paths only.
14. Launch the agent; the terminal is handed over.
15. On exit: interrupts fully ignored so cleanup cannot be killed; ownership normalized.
16. If a conversation actually occurred, run the restricted handoff writer, validate, scope, and file
    the result.
17. Validate and report skill changes; publish this machine's runtime versions; commit and push.
18. Exit with the **agent's** status code.

**Failure and recovery:** unreachable remote → warn, continue, push next time. Conflict → back out to a
clean tree, keep the local commit, report, continue. Handoff failure of any kind → keep the previous
handoff, never fail the session. Repeated interrupts during exit → ignored through cleanup; a different
interrupt key deliberately skips only the handoff. A user interrupt during startup must stay an
interrupt and not be relabelled as an offline condition.

**Steps 6 and 11 are in the wrong order relative to the product's central guarantee.** Step 6 degrades
gracefully; step 11 then re-validates the same shared state strictly and can abort the session anyway
(§7.2).

## 5.3 Attributing work to projects

1. During the session the agent may work in several repositories, or clone new ones.
2. After the session, repositories under the mounted roots are re-discovered.
3. If more than one scope is in play, the handoff writer is asked to produce delimited per-scope
   sections, including one for each unknown repository.
4. Each well-formed section is filed under its scope. Unknown scopes are dropped with a warning.
   Duplicate scopes are merged rather than overwritten.
5. For an unknown repository with a portable origin, and only with a terminal attached, the user is
   asked once whether to track it. Yes enrolls it caravan-wide; **no ignores it caravan-wide and
   permanently**.
6. Without a terminal, the work is folded into the machine's own handoff and **no decision is
   recorded**, so the question can still be asked later.

The session's own project must always be eligible to receive the session's handoff. It currently is
not, in a common case — see §7.3, the most serious data-loss defect in the product.

## 5.4 Recovering from a conflicted shared repository

1. A conflicting change is detected at session start or end.
2. Satchel abandons the in-progress operation and returns the clone to a clean tree. The local commit
   remains on the branch — only its integration is postponed.
3. The user is told, in plain language, that another machine changed the same file, that Satchel backed
   out rather than guess, and that nothing local was lost.
4. Synchronization is disabled for the rest of the run; the session proceeds normally.
5. The health check continues to report the unreconciled state until the user resolves it with ordinary
   Git.

The critical property: **the clone is never left mid-operation waiting for the user**, because that
state previously made the next session refuse to start.

The cost the user pays is real and should be designed away rather than documented: because every
machine rewrites whole registry files, two machines changing *logically unrelated* entries conflict,
and the recovery is hand-editing the tool's private state with Git. See §9.3.

## 5.5 Registering a tool server

1. The user names the server, gives an endpoint, and chooses whether it needs a bearer token.
2. If it does, the token is entered without echo and the user chooses shared or machine-only storage.
3. The definition is committed and pushed; the endpoint is probed and the result reported.
4. Every later session materializes the definition into each agent's native configuration, preserving
   unrelated content the agent itself wrote there.
5. Removing the server deletes the definition and every local copy of its token, and states plainly
   that a previously shared token remains in history and must be rotated at the service if that matters.

Four requirements this flow establishes, none of which currently hold — see §7.4: distinct server names
must never share a credential channel; a server declared as needing no authentication must never
receive a stored token; a missing token must never prompt or abort during session startup; and removing
a server that does not exist must not report success.

---

# 6. Requirement confidence

## Confirmed — implement these

| Requirement | Basis |
|---|---|
| Directory-scoped disposable container session, exiting with the agent's status | Executed; tests; docs |
| Transparent command redirection with pass-through arguments | Executed; tests |
| Refusal to run sandboxed in a home directory, the root, or Satchel's own state | Tests; executed the guard directly |
| Explicit unsandboxed mode with a visible warning | Tests; decision record |
| Generated native-format instructions describing the real environment | Tests assert content per state |
| Truthful credential status in those instructions (three distinct states) | Tests assert each |
| Five-section handoff, written by a restricted process, filed by the tool | Tests |
| Handoff-writer isolation: conversation home only, empty working directory | Tests; two decision records |
| Every handoff-writer failure preserves the previous handoff | Tests, per failure mode |
| Origin-based global project identity, normalized and credential-free | Tests including credential stripping |
| Nearest-enclosing-repository attribution | Tests |
| Retention bound of 100 handoffs per scope, ordered by filename | Tests; decision record |
| Never merge shared-state conflicts; back out cleanly, keep local work | Tests; decision record |
| No shared-state condition blocks a session | Decision record; tests (with two exceptions, §7.2) |
| Validate only fields actually read; tolerate unknown ones | Tests explicitly assert forward compatibility |
| Skill library packaging validation with local quarantine and restore | Tests, per rejection reason |
| One shared skill library visible to both agents, with no per-agent filtering | Decision record; tests |
| Tool-server secrets never in configuration files or process arguments (where supported) | Tests |
| Three-tier machine knowledge with distinct loading behavior | Tests |
| Personal profile and preferences injected into every session | Executed; tests |
| Baseline onboarding: propose-then-approve, audited afterward, defaults to "not now" | Tests |
| Ownership repair restricted to an exact allowlist | Tests including refusal cases |
| Container ownership label as the sole proof before deleting anything | Tests |
| Uninstall preserves unrecognized and ambiguous commands | Tests |
| Boot-script rewriting: stage-and-rename, keep a known-good backup, refuse unparseable content | Tests |
| Real bind-mount probe before launching, refusing unsupported nested environments | Executed; tests |
| Exit-code convention; stderr/stdout split | Executed |

## Strongly inferred

- **Single-user product.** No multi-user concept anywhere; the credential-sharing rationale depends on
  it.
- **The agent's honest self-description is a core feature**, not a nicety — it recurs in vocabulary,
  instructions, tests, and a decision record.
- **Both agents are meant to be equal citizens**, though coverage is asymmetric in practice.
- **The synchronized repository is meant to be hand-editable** with ordinary Git. The durable
  requirement is inspectability and recoverability, not any particular file layout.
- **Meaningful work should create continuity and trivial invocations should not** — tests distinguish
  transcript-producing sessions from help and version invocations. The specific heuristic is not the
  requirement; the distinction is.
- **Simplicity is an explicit constraint**, with a stated complexity ceiling: if a feature cannot be
  written sanely within the chosen constraints, that is a signal the feature is too complex, not that
  the constraints should change. The existing documentation puts this as "deliberately not
  production-grade: simple, readable, boring." Read as a constraint on *scope and mechanism* — few
  moving parts, boring solutions, no speculative abstraction — it is sound and worth carrying forward.
  It is **not** a lower bar for correctness or data safety: §7 is largely the bill for reading it that
  way, and the acceptance criteria in §10.6 assume the opposite. A rebuild should inherit the modesty
  of scope and none of the tolerance for silent data loss.

## Weakly inferred

- **Unrestricted outbound network in sandboxed sessions** appears intentional (tool servers are reached
  by local-network URL) but is stated nowhere and is disclosed to neither the user nor the agent.
- **The daily update check** as a nagging mechanism rather than a security control.
- **Cross-machine version-drift reporting** — the decision record candidly notes it was built to
  diagnose a problem that turned out to be something else, and is retained "on its own merits."
- **Exactly 100 handoffs** — the bound is well argued, the number is not.

## Questionable

- **Caravan-wide settings.** Documented in three places and surfaced in live help text, but no setting
  is declared with that scope, so the code path cannot execute.
- **The escape offered when a session is refused.** Being refused a sandboxed session in a home
  directory offers a *host session* instead — root, privileged, whole filesystem writable. The offered
  remedy is strictly more dangerous than what was refused.
- **A model deciding whether work was "substantive"** — this gates the one durable, caravan-wide
  decision the product ever asks the user to make.
- **A guidance message recommends a configuration the design forbids** — running the session as root,
  directly contradicting an in-code design constraint.
- **Read-only reporting commands start containers** to read version strings, and a cache built
  specifically to avoid that cost exists but is not used by them.

## Apparently accidental

- Sync status, divergence counts, and baseline state print under a "Commands:" heading, because no
  separate heading was ever introduced.
- Under a piped-input install, a path probe can resolve to the filesystem root, so a file at a specific
  root path would be installed in preference to downloading.
- A scope-relevant field is written into every handoff's header and never read by anything.
- One agent's handoff writer runs with tool access disabled; the other's runs with sandboxing
  explicitly turned off — the container's empty mount set is the only thing enforcing parity. **[C]**
- Two independent implementations of platform detection, one of which ignores the override that exists
  specifically to make it testable.
- The redirect commands accept any name, so a typo installs a permanently broken executable on the
  search path — and a mistyped flag installs a file named after the flag. **[C]**

---

# 7. Problems in current product behavior

Ordered by user-visible severity. Each was verified by execution where feasible; where a claim rests on
reading alone, that is stated.

### 7.1 "Sandbox" promises more than the product delivers **[C]**

A sandboxed session cannot see arbitrary host files, and that is genuinely valuable. But it also has
unrestricted outbound network access, a read-write project, persistent agent credentials and
transcripts, a read-write shared skill library that propagates to every machine, writable machine
knowledge, and — by default — a live signing socket and a live desktop clipboard socket. There are no
CPU, memory, process, or egress limits.

The clipboard forwards whatever the user copies *during* the session, including passwords. The signing
socket authorizes the session to any host reachable by the identities loaded in the user's agent.
Neither is disclosed to the agent in its instructions or to the user at launch.

The individual trade-offs are each defended in a decision record. The problem is the single word
"sandboxed", which is the product's own framing and implies containment the product does not attempt.

### 7.2 A stated core guarantee does not hold — two paths still block a session **[C]**

The product's most emphatic promise is that no state of the shared repository may prevent an agent from
starting; the session path was rewritten specifically to degrade instead of aborting. Two paths defeat
it:

- **Tool-server materialization runs after the degradation and re-validates strictly.** A malformed
  registry file — for example one carrying conflict markers after exactly the cross-machine conflict
  the guarantee was written about — aborts the session anyway. This reproduces the original failure
  cascade through a different door.
- **Shared configuration is executed as shell before any validation at all** (§7.5), so a syntax error
  or a hostile edit in the shared tree stops every command, including ones that do not touch
  synchronization.

The guarantee is therefore path-dependent rather than global. Any rebuild must make it a property of
the whole session path, checked against every reachable shared-state failure, including malformed
tool-server data.

### 7.3 Work is silently lost through inconsistent project attribution **[C]** — verified by execution

Two directional searches disagree. The session's project is found by walking *upward* to the nearest
enclosing tracked repository. The list of scopes the handoff writer is permitted to file under is built
by matching *downward* from the launch directory. Launch inside a subdirectory of a tracked repository
while any other repository is also visible below, and the session's own project is never added to the
permitted list.

Executed against a fixture: the upward search resolved the project correctly; the downward search
returned nothing; the writer received an empty allowlist; the handoff for the session's own project was
dropped as an "unknown scope". Because nothing was filed, the run then reported that attribution was
incomplete and kept the *previous* handoff — so the entire session's continuity is lost, not merely
misfiled. The session could read its project's handoff at startup and could not write one back.

Related losses in the same area: a section missing one required heading is dropped with **no message at
all**; filing 1 of 3 scopes is reported as complete success.

### 7.4 Tool-server credentials are misrouted, and a missing one corrupts state or kills the session **[C]** — verified by execution

Four distinct defects compound here. All were reproduced.

- **Two different servers can share one credential channel.** The environment variable carrying a token
  is derived from the server name by uppercasing it and mapping hyphens to underscores. Both hyphens
  and underscores are legal in names, and case is preserved in the registry, so `my-server` and
  `my_server` — or `Foo` and `foo` — are distinct, valid, simultaneously registered servers that map to
  one variable. The later value wins, and **one server is sent another server's bearer token**. No
  collision check exists anywhere.
- **A server declared as needing no authentication still receives a stored token.** The token lookup is
  unconditional; the declared authentication mode gates only whether the user is *prompted*, never
  whether a credential is *attached*. Re-registering a server as unauthenticated does not delete its
  token, so the stale secret keeps being transmitted.
- **A missing token during session startup does not prompt the user — it reads from the registry
  stream.** The prompt's input is the same stream the registry loop is being fed from, so it consumes
  the next registry line. Reproduced: the literal text of the following server's record was written
  into the *shared* token file as the first server's secret, and the remaining servers vanished from
  the agent's configuration entirely — exit status 0, session proceeds, nothing reported. When the
  token-requiring server is the last entry, the read hits end-of-input instead and **the whole command
  exits 1 before the container starts, with no message at all**. Whether a terminal is attached makes
  no difference, because the process's own input is never consulted. The health check meanwhile
  advertises the intended behavior: "sessions will prompt for it."
- **Removing a server that does not exist reports success.**

### 7.5 Shared configuration is executed as code on every machine **[C]**

The shared settings file is sourced as shell on *every* invocation of *every* command, before any
validation — including trivial ones like printing the version. Anyone who can write the shared
repository executes arbitrary code as the invoking user (often root on the server platform) on every
other machine. It is also the one registry file not covered by validation.

Currently mitigated only by the fact that nothing writes the file: caravan-wide settings are promised
in help text, in the settings command's own footer, and in the README, but no setting declares that
scope, so the write path is unreachable and the "this machine only" flag silently does nothing
different. Verified two ways: the catalog contains five entries, all machine-scoped; and the live
command prints every row tagged as machine-scoped directly above the text promising caravan-wide
behavior. **A documented capability that cannot be exercised is the only thing standing between the
user and remote code execution across the caravan.**

### 7.6 Re-enrolling a machine silently destroys its settings **[C]** — verified by execution

Enrollment rewrites the machine's configuration file from a template, writing back only the machine
name and remote URL and re-emitting every setting as a *comment*. There is no read-back and no merge.

Reproduced end to end: all five settings were set through the public command, enrollment was re-run
with the same name and the same URL, and all five were gone — no warning, no backup. This is not a
corner case. The product itself repeatedly tells users to re-run enrollment — when synchronization is
not set up, when tool-server commands are unavailable, from the health check, and from status. The
canonical path (skip synchronization at first, disable credential forwarding or pin a session user,
then enroll later to attach the remote) destroys every one of those choices. Silently widening
delegated authority or changing the session's identity is the worst possible failure mode for this
particular file. Only the mismatched-URL refusal is tested; the successful re-enrollment path is not.

### 7.7 The tracking prompt is not neutral, and defaults to the more permanent answer **[C]**

The post-session question defaults to **yes**, so a reflexive keypress enrolls a repository across every
machine. Declining is not "not now" — it writes a permanent, caravan-wide *ignored* decision, and
ignored repositories are never offered again. There is no "ask me later" option interactively, though
that is exactly what the non-interactive path does.

### 7.8 The sandbox-escape flag bypasses the protection meant to survive it **[C]** — verified by execution

Running with the "allow a session here" override from the filesystem root is **permitted** (exit 0),
mounting the entire filesystem — including Satchel's own private state, which holds SSH material,
tool-server tokens, and agent logins — into what still calls itself a sandbox, with no warning printed.

The cause: the root case is handled in a branch that never evaluates the state-directory check, and the
override is then gated on a *string label* comparison rather than on the condition that detected the
problem. Confirmed by executing the guard against fixtures: root + override returned 0; state directory
+ override was correctly refused; a subdirectory of the state directory + override was correctly
refused; home + override returned 0, which is its documented purpose. Existing tests exercise the
override only in a home directory.

### 7.9 Destructive-path validation accepts unintended targets **[C]** — verified by execution

The guard protecting the "delete everything local" path refuses the filesystem root, the home
directory, and the install directory, then accepts *any* directory containing any one of four common
names. Executed against a decoy containing only an empty `home` subdirectory: **accepted**. Executed
against a decoy containing `home`, `photos`, and `taxes`: **accepted**, and the whole tree is what the
recursive delete receives. Only a completely empty directory is refused. There is no positive proof of
ownership — no marker the tool wrote itself, no cross-check against the recorded install path.

The same class of gap exists at the other end of the lifecycle: the installer carefully refuses to
overwrite a `claude` or `codex` command it does not own, but **overwrites its own destination path
unconditionally**, with no existence check and no ownership proof — which matters most for the
relocatable install, where that directory is user-supplied.

Related: self-update records whatever path it ran from as the authoritative installed path, with no
ownership validation — and that record is the primary proof uninstall uses to decide it may delete
something.

### 7.10 Unattended use fails silently **[C]**

Under strict error handling, a prompt reading from closed input terminates the command with status 1 and
**no message**. This affects setup, retirement, tool-server management, and skill removal. Only one
prompt in the product guards against it.

### 7.11 Secret scanning is applied inconsistently, and a rejected baseline is published anyway **[C]**

The baseline path refuses to publish machine knowledge that looks like it contains credentials. Two
gaps make that protection much weaker than it appears:

- **The same directory is mounted read-write in every ordinary session**, and the ordinary session-end
  publish applies no scan at all. The protection exists exactly where an approval step already exists,
  and is absent where writes are unsupervised.
- **Rejection is in-process only.** When the audit fails — missing inventory marker or suspected secret
  — the agent's already-written content stays in the working tree; nothing quarantines or reverts it,
  and the "do not synchronize" decision lives in a variable that dies with the process. The next
  ordinary session stages the whole tree and pushes it. The failure message itself tells the user to
  run the health check "and then sync" — which publishes exactly the content the scan just rejected.

### 7.12 Full-tree staging plus writable mounts can propagate destruction **[C]**

Session-end publishing stages the entire tree. The agent has read-write access to the skill library and
this machine's knowledge. An agent that deletes or corrupts content there has that deletion committed
and pushed to every machine, with a report printed *after* the fact and no confirmation or threshold.
Recovery is manual history archaeology.

### 7.13 Unraid persistence has a silent-failure path with a green light **[C]** — verified by execution

Key backup selects the *first* standard private key it finds among three types. The generated boot block
restores only the one specific type. The health check globs all three when reporting the backup as
healthy.

Executed against a host with the other two key types and no key of the restored type: the backup was
made, the boot block's restore pattern matched nothing, the failure was swallowed at boot, and the
health check reported the backup as fine. The user's symptom is "the sync remote is unreachable" on
every boot, with a health check that reports green for the actual cause.

Two related Unraid defects in the same area:

- **The boot block writes a hardcoded command directory** while the surrounding code uses an
  overridable one. The test suite sets the override and asserts the live link, but never inspects the
  link target *inside the generated block* — so the tests pass while generating a block that points at
  the real system path. This is the clearest example in the product of a test that cannot fail for the
  thing it appears to check.
- **An install onto the RAM disk can be silently accepted.** The "is the array started?" guard sits
  inside the interactive branch only, so the documented non-interactive invocation — the one the README
  recommends — skips it and creates the whole directory chain on temporary storage if the array is not
  mounted. The install then disappears at the next reboot.

### 7.14 Reporting commands are miscalibrated, and can abort on the state they exist to explain **[C]**

- **Status and explicit synchronization validate shared state strictly, mid-render.** A malformed
  record truncates the report at the point of failure — so the command a user runs to diagnose a
  malformed record stops before telling them what else is healthy.
- **A sleeping home server makes the health check report a *problem* and exit non-zero**, while "no
  credential key", "image not built", and "behind the remote" are mere warnings.
- **The health check prints "no problems found" after a screenful of warnings.** Verified by execution:
  it exits 1 on failures and 0 otherwise, regardless of warning count.
- **Endpoint health is not health.** Reachability is a bare HTTP request with no protocol exchange, and
  anything other than a connection failure or a 404 counts as reachable — so a server answering 401
  with an expired token reports healthy, while a correctly functioning server whose base URL legitimately
  returns 404 reports as a hard failure.

### 7.15 Additional confirmed problems

- **One agent's managed configuration block is rebuilt lossily.** Configuration the agent wrote inside
  the block is rescued only from the first section header onward; bare key-value lines written before
  any header are discarded with no warning, and rescued sections are relocated to the end of the file,
  silently reordering user configuration. The other agent's native configuration is replaced wholesale
  with no preservation at all.
- **Common legitimate workflows are quarantined.** The most natural way to install a skill — cloning
  it — leaves repository metadata behind, which is a rejection reason. The bundle is moved out of the
  library and reverted to the previously committed version. The user sees two lines in a stream of exit
  output. There is no override, no allowlist, and no restore command.
- **Global deletions have inconsistent authorization.** Retirement and purge confirm. Skill removal,
  tool-server removal, and untracking act immediately on a named argument — and untracking, which
  deletes a project's stored handoffs on every machine, has no confirmation and no picker at all. The
  friction is inverted relative to blast radius.
- **Update can leave a mixed installation.** The executable is replaced before the image rebuild and
  the revision stamp is written after it, so a failed rebuild leaves a new program recorded as the old
  revision — deliberately, and asserted by a test. If the revision lookup fails entirely, the program is
  still replaced and no stamp is written at all, after which the changelog re-lists commits already
  installed and the machine publishes a wrong version into the caravan.
- **Explicitly requested project identifiers are silently ignored** when the origin is already tracked;
  the user is told a different name than the one requested.
- **Boolean settings recognize only the literal `0`** — `false`, `no`, and `off` all mean *enabled*.
  The documented way to clear a setting writes an explicit empty value instead, which the settings
  report then attributes to the wrong layer.
- **Engine misconfiguration is unvalidated** — a typo becomes "command not found" on every operation,
  and is reported back as a configured value.
- **The synchronize command hangs indefinitely** on an unreachable remote while every other network path
  is time-bounded, and fails loudly on push where every other path degrades to a warning.
- **Extra directories are silently ignored in host mode** — validated, capable of aborting the command,
  then never mounted, with no message.
- **This machine's knowledge is mounted twice with opposite permissions**, and the instructions never
  mention it. An agent that follows the all-machines mount to its own machine's entry — a natural move,
  since that mount lists every machine including this one — gets an unexplained read-only failure on a
  file it was told to curate.
- **Quarantine and recovery directories grow without bound** and are never reported as needing attention
  beyond a count.
- **Accepting baseline onboarding consumes the requested session even when it fails.**
- **Persistent trust declarations accumulate forever** for directories that no longer exist.

---

# 8. Features that should not be automatically recreated

Each requires explicit approval before inclusion. Approving a *user goal* is not the same as approving
the current *mechanism*; several entries below exist to separate the two.

| # | Feature | Why it should be re-justified |
|---|---|---|
| 1 | **Caravan-wide settings** | Documented in three places; cannot currently execute. Nobody has ever used it. Decide whether it is wanted at all before rebuilding it |
| 2 | **Executable configuration** | Shared and local settings are evaluated as shell. The convenience is small; the exposure is arbitrary code execution across every machine (§7.5). A parsed key-value format costs nothing |
| 3 | **Default-on credential forwarding** | Grants the session signing authority for every identity loaded in the user's agent, for any reachable host. The capability is right; default-on is a separate decision |
| 4 | **Default-on clipboard forwarding** | Forwards whatever the user copies during the session, including passwords, over a socket whose capabilities depend on the compositor. Screenshot paste is genuinely useful; the default is not obviously right |
| 5 | **Synchronized plaintext tokens** | The user goal is "configure once everywhere", not "retain secrets permanently". History cannot be un-published (§9.5) |
| 6 | **The host-session offer as an escape from a refused sandbox** | Answering a safety refusal by offering strictly more privilege. If a home-directory session is needed, the narrow override already exists |
| 7 | **The broad home-directory override** | Mounting an entire home directory exposes SSH keys, tokens, and unrelated credentials — it defeats the primary scoping promise rather than narrowing it. Establish the real need first |
| 8 | **Model-generated handoffs** | The user need is continuity. Resuming a provider-side conversation to obtain prose in a fixed shape is one costly, nondeterministic way to get it, and it can only fail into "keep the stale one". Approve the outcome, then choose the mechanism |
| 9 | **Model-gated project enrollment** | A language model's judgment of "substantive work" currently gates the one durable, caravan-wide decision the product asks the user to make. Equivalent work prompts inconsistently across model versions |
| 10 | **Three-tier machine knowledge** | Genuinely well-reasoned, but it is three concepts, two loading strategies, a word limit, a version marker, and a migration path. Consider starting with one tier and splitting when the pain is real |
| 11 | **Baseline onboarding** | A large feature — privileged inspection, secret scanning, version markers, a three-way prompt, suppression markers, refresh flow — whose output is a file the user could write themselves. It has the most convoluted control flow in the product (it replaces the session you asked for) and its safety check does not durably hold (§7.11) |
| 12 | **Sibling-machine knowledge visibility** | Convenient, but it widens what every session can read and couples machines together. Needs a concrete scenario |
| 13 | **The rescue-and-relocate configuration rewriter** | Complex, silently lossy (§7.15), and exists to coexist with one agent's habit of appending to its own configuration. A separately namespaced file, or an include, may remove the need entirely |
| 14 | **Version-drift reporting instead of reproducibility** | The decision record admits it was built on an assumption that proved wrong and is useful only at three or more machines. It also treats a symptom: nothing in the runtime is pinned (§9.10) |
| 15 | **Daily update checking and direct-from-branch self-update** | A network call on session start, a stamp file, and interrupt propagation, to print a message — plus an update path with no release boundary, no verification, and no rollback. Distribution policy, not user capability |
| 16 | **Redundant read-time container starts** | Reporting commands start containers to read version strings while an existing cache goes unused. Recreate the cache, not the container start |
| 17 | **Repeated ownership repair** | Runs three times per session over the same trees. One well-placed repair is likely sufficient |
| 18 | **Recovery directories that are never cleaned or surfaced** | Preservation is right; silent unbounded accumulation is not |
| 19 | **Two handoff-writer command shapes** | The two agents are invoked with materially different isolation — one with tools disabled, one with sandboxing explicitly disabled. Specify the *guarantee* and derive both invocations from it |
| 20 | **The undocumented environment switches** | Two variables materially change behavior and appear in no help, documentation, or settings catalog. Either make them real settings or drop them |
| 21 | **Ordering by filename with a one-second timestamp** | Works, but relies on an implicit encoding and cannot distinguish two handoffs in the same second — a real collision case |
| 22 | **Retention of exactly 100** | The bound is justified; the number is not. Make it a setting or justify it |
| 23 | **The reserved lock-metadata carve-out** | An exception to the "everything is a skill directory" rule for a file the product refuses to interpret. Confirm a real installer needs it |
| 24 | **Identical skill exposure to both agents** | Install-once is clearly right; *mandatory* identical visibility is a bet that all skills are cross-agent compatible. The decision record already names the explicit exclusion mechanism that would replace it |
| 25 | **The four-root, dedup-keyed command sweep on uninstall** | The most intricate logic in the product, existing to handle one distribution's symlinked home directory |
| 26 | **Sharing one agent home across concurrent sessions** | Not a feature — an unexamined consequence. Decide deliberately whether concurrent sessions are supported |
| 27 | **Unraid boot-script and flash-key management** | Editing a boot-critical file and storing a private key on unencrypted flash is high-consequence scope for a personal session wrapper. Keep only if Unraid remains a named supported platform with someone owning its validation |

Two further non-requirements worth stating explicitly, because a forensic reading of the existing
product can easily mistake them for intent: **the implementation language and single-artifact packaging
are not product requirements**, and **Git is the current synchronization mechanism, not the
requirement**. What is required is user ownership, inspectability, offline operation, conflict safety,
and a recovery path.

---

# 9. Open decisions

**9.1 Is concurrent use supported at all?**
*Why it matters:* determines whether locking, unique handoff identifiers, and per-session agent homes
are required. *Evidence:* no locking exists; several silent-loss paths follow directly; single-user
framing suggests it was never considered, and a decision record puts concurrent reconciliation out of
scope. *Simplest default:* explicitly support one mutating session per machine at a time, detect and
refuse a second, and revisit only if that is painful.

**9.2 Is there a coherent local-only mode?**
*Why it matters:* setup tells users that without a remote, handoffs, tool servers, and skills "stay on
this machine." In fact none of them exist at all — they are all rooted in the synchronized tree, so a
no-remote machine gets a bare agent with a persistent home. *Evidence:* verified against every one of
the three subsystems. *Simplest default:* either make local-only a real mode with a published feature
matrix, or say plainly at setup that these features require a remote. Do not ship the current middle
ground.

**9.3 Should conflicts be prevented structurally instead of reported?**
*Why:* the current design guarantees conflicts on shared registries, since every machine rewrites whole
files, and the recovery is hand-editing the tool's private state with Git during ordinary multi-machine
use. *Evidence:* the decision record identifies entry-per-file as the right shape and *simpler* than
merging, deferred only because it needs a coordinated migration — a constraint a rebuild does not have.
*Default:* adopt entry-per-file from day one, so logically unrelated changes cannot collide.

**9.4 What is the actual security promise?**
*Why:* "sandbox" currently means filesystem scoping plus an unprivileged user. It does not mean network
containment, resource limits, or protection from a hostile agent, and the product mounts whatever
directory the user happens to be in — including system directories — read-write. *Evidence:* no network
restriction and no disclosure of that fact, in either the user documentation or the agent's own
instructions. *Default:* promise protection against accidental access to unmounted host paths, not
defense against hostile code; name every forwarded authority plainly in both the documentation and the
agent's instructions; decide network policy explicitly rather than by omission.

**9.5 Should the tool own credential distribution?**
*Why:* synchronizing plaintext tokens is a deliberate, well-argued decision resting entirely on the
repository being private, and history retains rotated secrets forever. *Evidence:* a decision record
argues it convincingly for this threat model; the stated opt-out requires the user to hand-write an
ignore rule that no code creates. *Default:* keep secrets machine-local by default; make synchronized
storage an explicit, revocable choice; warn at registration rather than only at removal.

**9.6 Is the second agent a first-class target?**
*Why:* it changes how much abstraction is warranted. *Evidence:* both are supported and share the skill
library, but test coverage, handoff-writer isolation, and native-configuration handling are noticeably
asymmetric. *Default:* commit to both as equal, and specify shared guarantees rather than per-agent
behavior.

**9.7 What actually counts as "substantive work"?**
*Why:* it gates the single most user-visible automatic decision — whether to prompt about a repository.
*Evidence:* the judgment is delegated entirely to a language model, and **nothing tests it**. *Default:*
define an explicit, inspectable rule (for example, commits or file modifications within the repository
during the session).

**9.8 Should the tracking prompt be able to say "not now"?**
*Why:* declining is currently permanent and caravan-wide, and yes is the default (§7.7). *Evidence:* the
non-interactive path already implements exactly the "no decision recorded" behavior. *Default:* three
options, defaulting to "not now".

**9.9 Should there be integrity verification for distribution?**
*Why:* installation and self-update execute downloaded code with no verification beyond a syntax check.
*Evidence:* no signature or checksum anywhere; trust rests entirely on transport plus a repository name.
*Default:* publish and verify a checksum at minimum.

**9.10 What is the release and runtime-reproducibility policy?**
*Why:* nothing in the container image is pinned — base image, system packages, and both agent CLIs all
float — so two machines on the same Satchel revision can behave differently, and an update can change
the agent runtime with no release boundary. There is also no rollback. *Evidence:* the drift is real,
documented, and deliberately accepted, with drift *reporting* as the chosen mitigation; the update path
tracks a branch rather than a release. *Default:* decide explicitly between "always latest, drift is
fine" and "pinned per release with an upgrade command". Either is defensible; the current mix of
floating runtimes plus after-the-fact drift reporting is the expensive option.

**9.11 Which platforms and engines are actually supported?**
*Why:* Docker, rootless Podman, root-run appliances, SELinux, nested containers, Wayland versus X11, and
custom session identities all behave differently, and several have produced regressions. One decision
record knowingly leaves custom-identity support incomplete under one engine because no machine needed
it. *Default:* publish a narrow tested matrix and reject unsupported combinations before launch rather
than failing inside them.

**9.12 What should retention and erasure mean?**
*Why:* pruning bounds the active set while history retains everything forever — rotated tokens, retired
machines, deleted projects. The recovery story and the exposure are the same mechanism. *Evidence:* the
bound is well argued; the value of 100 is not; erasure is nowhere. *Default:* specify active retention
and archival separately, make the bound configurable, and decide whether the user can ever permanently
erase a secret or a retired machine.

**9.13 How does existing user state move to the rebuild?**
*Why:* real caravans hold handoffs, project decisions, skills, and machine knowledge that users will not
want to re-create, and the history so far contains one-off migrations with no general framework.
*Default:* define exactly one documented import from the currently supported state, validate before
converting, and leave the original untouched so the user can roll back.

**9.14 Who owns the agents' native configuration?**
*Why:* the product rewrites files the agents themselves also write, and today that is lossy for one
agent and wholesale for the other. *Evidence:* the rescue logic exists specifically because one agent
appends inside the managed region. *Default:* own a clearly delimited region only, preserve everything
outside it byte-for-byte, and abort rather than truncate when the boundary is ambiguous.

**9.15 What confirmation policy applies to caravan-wide deletion?**
*Why:* today retirement and purge confirm while skill removal, tool-server removal, and untracking act
immediately — and untracking has the largest blast radius of the three. *Default:* preview the scope and
confirm for anything that deletes cross-machine state or active continuity, with an explicit
non-interactive force flag.

**9.16 Should reporting commands ever fail?**
*Why:* a command whose purpose is explaining a broken machine currently aborts partway through on some
kinds of broken machine. *Evidence:* the design intent is explicit and tested for the engine case, but
not applied to shared-state validation. *Default:* reporting commands never abort; they report what they
cannot read and keep going.

**9.17 Is Unraid a supported target, or the primary one?**
*Why it matters:* Unraid accounts for a disproportionate share of total complexity — relocatable
installs, boot-script rewriting with backup and parse-gating, flash key persistence, root-versus-session
identity handling, and a dedicated set of health checks (§3.7). If it is the *primary* deployment
target, that complexity is core and should be designed for first. If it is one supported platform among
several, it should be isolated behind a narrow seam and its cost weighed against the number of users.
*Evidence:* explicit first-class support in documentation and installer; a stated rule not to build a
platform abstraction until a second platform exists; a full test file devoted to it; and an
acknowledgement that a reported cross-machine problem turned out to be Unraid-specific. Nothing states
how many Unraid machines actually exist. *Simplest default:* keep support, keep every Unraid-specific
behavior in exactly one place, and ask the user directly how many Unraid machines they run before
investing further.

---

# 10. Clean-room specification

*Self-contained. No reference to any existing implementation. Terms used here are defined here.*

## 10.1 Product definition

A command-line tool that runs AI coding agents inside disposable containers on the user's own Linux
machines, and synchronizes session-continuity notes, tool-server configuration, reusable agent skills,
and machine-specific knowledge between those machines through a private Git repository the user
supplies and controls.

It is a single-user personal and home-lab tool. It is not a multi-user service, a production platform,
or a defense against a malicious agent. Its ordinary safety promise is that unselected host paths are
absent from a session and that the session runs unprivileged — not that the agent has no network and no
delegated authority.

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
- **Caravan** — all machines sharing one Shared Repository.
- **Shared Repository** — the user-owned private Git repository carrying all synchronized state.
- **Project** — a Git repository the user explicitly chose to track, identified across the caravan by
  its normalized origin.
- **Handoff** — a short structured summary written at the end of a session and injected at the start of
  the next one for the same scope.
- **Skill** — a self-contained folder of agent instructions and supporting files.
- **Tool Server** — an external service the agent can call, registered once and configured everywhere.

## 10.3 Required functionality

### R1 — Run a session

Launch the requested agent in a container scoped to the current directory. Pass all unrecognized
arguments through unchanged. Exit with the agent's own exit status. Delete the container on exit.

*Acceptance:*
- Running the agent through the tool and running it natively produce the same interactive experience.
- The agent's exit status is the tool's exit status, after cleanup has run.
- After exit, no container from that session remains.
- The primary directory is writable from inside at its real absolute path; nothing outside declared
  mounts is present.
- A normal launch prints nothing before the agent's interface appears.
- If the engine cannot bind-mount the paths this session needs, the session refuses to start and says
  why, rather than launching into empty mounts.

### R2 — Refuse unsafe scopes

Refuse a sandboxed session whose scope would be a home directory, the filesystem root, or the tool's own
state directory. Resolve all paths fully before checking, so symbolic links cannot bypass the check.
Provide one explicit override — which must **never** grant access to the tool's own state, under any
combination of arguments or directories.

*Acceptance:*
- Refused for a home directory, the root, a symlink to a home directory, and the state directory.
- With the override: a home directory is permitted; **the root is refused; the state directory is
  refused**; any scope containing the state directory is refused.
- Without an attached terminal, refusal is fatal and explains why.

### R3 — Unsandboxed mode

Provide an explicitly requested mode with the sandbox off and the host filesystem available at a
documented path. Warn visibly before launch. Mark the mode in the environment and in the agent's
instructions.

*Acceptance:* the mode marker is distinct; the warning appears before launch; the host filesystem is
reachable at the documented path and nowhere else; the agent's instructions state that changes there
affect the real machine; any additional directories the user requested are either mounted or explicitly
refused, never silently discarded.

### R4 — Describe the environment to the agent

Before each session, generate instructions in the agent's own native format stating: the mode; what is
reachable and what is not; the exact credential capability; every delegated authority in effect; the
location and rules of the skill library; this machine's notes in full; pointers (not contents) to larger
references; and the most recent handoff for the current scope.

*Acceptance:*
- Regenerated every session; declares itself managed.
- All paths absolute.
- Credential status is one of exactly three states and never claims pushing works when no identity is
  loaded.
- Every forwarded socket or authority the session actually has is named, including network reach.
- Any path that appears in the session more than once is described once, with its real permissions at
  each location.
- With no shared repository configured, it does not claim a skill library exists.
- Instructs the agent to say a path is *outside its view* rather than that it does not exist.

### R5 — Session continuity handoffs

At the end of a session that produced a conversation, generate a handoff with exactly five sections —
goal, done, in flight, next steps, gotchas — and file it under the correct scope. Inject the most recent
handoff for that scope at the next session start.

The generating process must receive **only** what it needs to read the conversation: no project
contents, no host access, no credentials, no clipboard, no tool servers, no skills, no machine
knowledge. The tool, not the agent, validates and files the result.

*Acceptance:*
- A session with no conversation produces no handoff and does not overwrite the previous one.
- Generator failure, malformed output, timeout, or explicit skip each leave the previous handoff intact
  and never fail the session.
- A dedicated interrupt skips only handoff generation.
- The generating container has exactly one durable mount, and both agents are invoked with equivalent
  isolation — the guarantee is specified once and each invocation derived from it.
- Two handoffs for the same scope can never collide on a name, however close together they are written.
- The next session's instructions contain the handoff, its origin machine, and its date.

### R6 — Project identity and attribution

Identify repositories by a normalized, credential-free origin. Common equivalent spellings of the same
repository must produce one identity. Maintain one global decision per identity: tracked or ignored.
Attribute work to the nearest enclosing tracked repository. Multiple checkouts of one origin are one
project.

*Acceptance:*
- Equivalent URL spellings yield one identity; embedded credentials and query strings never appear in
  stored identity.
- Different repositories with the same folder name receive distinct identifiers; folder name alone never
  establishes identity.
- An identifier already in use by a different origin is rejected, not merged.
- An explicitly requested identifier is either honored or refused with the reason — never silently
  replaced by a different one.
- Changing a checkout's origin invalidates the cached association and forces a new decision.
- Work in a subdirectory is attributed to the enclosing project.
- **A session's own project is always eligible to receive that session's handoff**, regardless of where
  the session was launched within it and regardless of what else is visible. *(Explicit fix for §7.3.)*
- A section that cannot be filed is reported, with its scope named; partial filing is never reported as
  success.

### R7 — Ask before tracking, and make the answer reversible

Ask at most once per repository, only after a session, only for a repository with a portable origin and
no existing decision, only when the work was substantive by a **documented, inspectable rule**, and only
with a terminal attached.

*Acceptance:*
- Reading or opening a repository never prompts.
- Three options are offered — track, ignore, decide later — and **the default is "decide later"**.
- "Decide later" records nothing; "ignore" is caravan-wide and is stated as such before it takes effect.
- Without a terminal, nothing is recorded and the work is attributed to the machine.

### R8 — Synchronization that cannot block work

Pull at session start, publish at session end, both time-bounded. Never merge a conflict: return the
local clone to a clean state, keep local work, report plainly, and continue. Never leave the clone
mid-operation. Validate only the fields actually read; accept unknown ones.

*Acceptance:*
- Every reachable failure state — unreachable, conflicted, malformed, interrupted, absent, or carrying
  unknown fields — still allows a session to start. **This is verified against every consumer of shared
  state, including tool-server configuration, not only the first validation step.** *(Explicit fix for
  §7.2.)*
- No shared input is executed, parsed, or consumed after the tool has declared shared state unusable for
  that run.
- Shared configuration is data, never code: it is parsed, and a malformed or hostile file can at worst
  be rejected, never executed. *(Explicit fix for §7.5.)*
- After a conflict, local work is intact and the clone is clean and usable.
- A user interrupt during startup remains an interrupt, and is not reported as a network failure.
- Changes to logically unrelated entries do not conflict with each other.
- Commands that ask *about* the repository fail loudly; session paths degrade quietly.
- Unpublished work is reported until it is published.

### R9 — Shared skill library

Maintain one library shared by all agents and machines, mounted read-write into every session at each
agent's native location. Expose its path in the environment. Validate packaging only — never interpret
content. Quarantine invalid bundles locally, restore the last valid version where one exists, and never
synchronize or delete a quarantined item.

*Acceptance:*
- A skill installed in one session on one machine is available to both agents on every machine after the
  next synchronization.
- Each rejection reason quarantines rather than deletes, and reports the reason and the location, with a
  documented way to correct and reinstate the bundle.
- Runtime-owned agent content is never synchronized.
- Removal by name deletes and publishes immediately; history is the recovery path.

### R10 — Tool-server registry

Register a server once by name, endpoint, and whether it requires a token. Materialize it into each
agent's native configuration at session start. Never place secret values into command lines or process
listings. Provide a supported choice between shared and machine-only secret storage.

*Acceptance:*
- A server registered on one machine is configured on every machine after synchronization.
- Secrets never appear in process arguments, diagnostic output, or logs.
- **Two distinct registered servers can never share one credential channel**, under any naming that the
  tool accepts as valid. *(Explicit fix for §7.4.)*
- **A server declared as needing no authentication never receives a stored credential**, even if one was
  stored previously. *(Explicit fix for §7.4.)*
- **A missing secret never blocks, prompts, or consumes input during session startup** — it warns and
  configures without authentication, identically with and without a terminal. *(Explicit fix for §7.4
  and §7.10.)*
- Removing a server removes its stored secrets from every local location, states what remains in
  history, and reports honestly whether anything was removed.
- Rebuilding managed configuration never discards or reorders content the tool does not own; ambiguity
  aborts rather than truncates. *(Explicit fix for §7.15.)*
- Reachability reporting distinguishes "the endpoint answered" from "the integration works", and never
  reports a working server as failed for answering an unrelated request.

### R11 — Machine knowledge and personal context

Maintain per-machine notes loaded into every session, larger references loaded on demand, and a
user-authored personal profile and preference set injected everywhere. Sessions may read other machines'
knowledge but write only their own.

*Acceptance:* notes appear in full in the instructions; larger references appear as a path and date;
another machine's knowledge is readable and not writable; this machine's own knowledge is presented
once, consistently, with accurate permissions; personal context is discoverable and editable through a
supported path, not only by hand-editing synchronized files.

### R12 — Handle credentials explicitly

Separate local provider logins, delegated signing authority, integration tokens, and non-secret
synchronized state, and describe each to the user.

*Acceptance:*
- Private key files are never mounted into an ordinary session; only a signing socket is forwarded.
- Delegated authority is accurately reported to both the user and the agent, and can be disabled.
- Missing signing authority never blocks a session; the user gets a concrete next action.
- Provider logins and conversation transcripts never enter synchronized state.
- Integration secrets are machine-local by default; synchronized storage is an explicit choice that
  states its permanence.
- Host-key trust decisions are persisted where the user can inspect and revoke them, and first-contact
  acceptance is disclosed rather than silent.

### R13 — Health check

One command that reports, per check, whether the machine's setup is sound: tooling, container engine,
image, real mount capability, credentials, shared-repository reachability and divergence, and
tool-server reachability.

*Acceptance:*
- Exits non-zero only for conditions the user must fix locally.
- **A transient remote outage is a warning, not a failure.** *(Fix for §7.14.)*
- Never claims success when warnings were emitted; summarizes both counts.
- Runs to completion on a badly broken machine and never aborts partway.
- Never reports a capability as healthy when the mechanism that would exercise it does not cover the
  case actually present. *(Fix for §7.13.)*

### R14 — Status

One command reporting: machines in the caravan; tracked projects with origins and handoff counts; a
count of ignored repositories, expandable on request; registered servers; installed skills; quarantined
items; and unpublished work.

*Acceptance:* completes on a machine with no engine and no shared repository; never aborts on malformed
shared state — names the malformed record precisely and continues reporting everything still readable.

### R15 — Install, enroll, redirect, uninstall

Single-command installation. Optional redirection of the agent commands through the tool. Enrollment
names the machine and connects the shared repository. Uninstall must distinguish removing the program
from removing local data, must never touch the remote repository, and must never delete anything it
cannot prove it created.

*Acceptance:*
- An existing command not created by this tool is never overwritten or deleted — **including the tool's
  own destination path.** *(Explicit fix for §7.9.)*
- Command redirection accepts only the supported agent names and rejects everything else, including
  flag-shaped arguments.
- **Re-running enrollment preserves every setting the user has chosen**, or states exactly what it is
  about to change and requires confirmation. *(Explicit fix for §7.6.)*
- Interactive uninstall defaults to cancel and states before any choice that the remote is not deleted
  and that unpublished work would be lost.
- Full removal requires a separate explicit confirmation.
- **The path validated for deletion must be proven to be this tool's own state — by a positive marker it
  wrote itself, not by resemblance to a directory layout.** *(Explicit fix for §7.9.)*
- Running containers are never stopped; unrecognized containers are never removed.
- If the tool cannot operate without a shared repository, setup says so plainly; if it can, the feature
  matrix for that mode is published. *(Fix for §9.2.)*

### R16 — Safe writes and recoverable failures

When modifying any file owned by the user or the operating system, stage the replacement on the same
filesystem, verify it is well-formed, keep the previous known-good version, and install by rename —
never by truncate-and-write. Refuse to install content that does not verify. When an operation spans
several durable systems, make its partial outcomes legible.

*Acceptance:*
- An interrupted write never leaves a partial file; malformed content is refused and the original is
  byte-identical; a recoverable previous version exists afterward.
- Incomplete setup data is preserved rather than overwritten.
- A refusal to publish content — for any reason, including a failed safety check — durably prevents that
  content from being published later by an unrelated command. *(Explicit fix for §7.11.)*
- A failed multi-step operation names which effects committed, which were rolled back, and exactly what
  retry is safe. *(Fix for §7.15.)*
- Session cleanup survives repeated interrupts after the interactive agent exits.
- Destructive operations that reach beyond this machine preview their scope and confirm, with an
  explicit non-interactive override. *(Fix for §9.15.)*

## 10.4 Optional functionality

Valuable, but not required for a coherent product. Each should be separately approved, and none may
weaken the safety, failure, or credential criteria above. The absence of any of them must leave the
basic local session fully usable.

| Feature | Note |
|---|---|
| Multi-directory sessions | Clear value for cross-repository work; adds validation surface |
| Unsandboxed host mode | Powerful and dangerous; confirm it belongs in this product rather than beside it |
| Clipboard forwarding | High user value, narrow mechanism; decide the default deliberately |
| Signing-socket forwarding | Effectively required for the core workflow, but the default is still a decision |
| Guided machine inventory | Large; the same file can be written by hand (§8.11) |
| Sibling-machine knowledge | Convenient; widens exposure |
| Cross-machine version drift reporting | Only useful at three or more machines, by its own analysis |
| Unraid support (§3.7) | Substantial complexity; required only if an Unraid machine is in the caravan; keep isolated |
| Credential import from the host | Convenience only |
| Self-update | Requires integrity verification (§9.9) and a release policy (§9.10) if retained |
| Update notification | Consider folding into the health check |
| Caravan-wide settings | Do not build until a setting actually needs it (§7.5) |

## 10.5 Explicitly out of scope

Multi-user support, access control, a hosted service, a daemon, a database, automatic conflict
resolution, agent-version pinning as a user-facing feature, and any mechanism that interprets skill
*content* rather than skill *packaging*.

The rebuild is also not required to preserve: the implementation language, source layout, or packaging;
Git as the synchronization mechanism; current file formats; current container-image composition; exact
prompt wording; the exact retention number; or the undocumented environment switches.

## 10.6 Cross-cutting acceptance criteria

1. **No shared-repository state prevents a session from starting.** Verify against: unreachable,
   conflicted, malformed, interrupted mid-operation, absent, and containing unknown fields — *including
   malformed tool-server configuration and malformed shared settings.*
2. **Shared state is data, never code.** Nothing read from the shared repository is executed.
3. **No unattended path prompts, hangs, or exits silently.** Every command run without a terminal
   either completes or fails with an explanatory message and a non-zero status. No prompt ever reads
   from a stream that is carrying data.
4. **Nothing is deleted or overwritten without proven ownership.** Every destructive operation names a
   specific target the tool can prove it created, or a target the user named exactly.
5. **Isolation properties are verified against a running container**, not against command arguments —
   user identity, capabilities, namespaces, read-only mounts, and absent mounts must be asserted from
   inside a live session in the automated test run.
6. **Documented behavior exists.** Every capability described in user-facing documentation or help text
   is reachable and covered by a test. Every claim a message makes about what will happen next is true.
7. **Secrets never reach process listings, command lines, logs, or the wrong server.**
8. **User-authored content is never silently discarded or reordered** when the tool rewrites a file it
   shares with another program, or when the user re-runs setup.
9. **Every warning names a concrete next action, and no suggested action defeats a safety decision the
   tool just made.**
10. **The session's own work always has somewhere to go.** No combination of launch directory and
    visible repositories may leave a completed session unable to record its continuity.

---

## Appendix — What the existing product gets genuinely right

Worth preserving as intent, independent of implementation:

- **"The session is the product; synchronization is bookkeeping."** A clear, correct priority that most
  tools of this kind get wrong, arrived at after a real failure. The two places it does not hold (§7.2)
  are gaps in application, not in the idea.
- **Never merging conflicts.** Backing out and reporting is the right call for a single-user tool, and
  the decision record honestly documents removing a working merge implementation because it solved a
  problem the user did not have.
- **Telling the agent the truth about its environment**, including the precise credential state. This is
  a real insight: an agent that knows it is sandboxed gives better answers than one that concludes the
  user's files are missing.
- **Validating what you read and ignoring what you do not** — the property that keeps one machine's
  upgrade from breaking the caravan.
- **Preserve rather than delete** for anything uncertain, applied consistently to malformed skills and
  interrupted setup.
- **Proving ownership before deleting**, via a label the tool itself applies — a pattern the product
  understands well and simply fails to apply in three places (§7.9).
- **Refusing to install a boot script that does not parse**, with a known-good backup — appropriate care
  for a file that can render a machine unbootable.
- **Isolating the handoff writer to a single mount**, so the process that summarizes a session cannot
  read the project it summarized.
- **An honest vocabulary document**, including which words to avoid. Rare, and clearly load-bearing.
- **Decision records that state what was rejected and why**, including one that documents a feature
  built on an assumption that turned out to be wrong and was kept for different reasons. That kind of
  honesty is exactly what makes a rewrite possible.
