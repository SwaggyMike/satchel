# Rewrite Specification

This document specifies a program to be built from scratch. It describes the
problem, not the existing solution. Nothing here should be read as a
recommendation about structure, language, or decomposition.

Every statement is intended to be a fact about the world — about operating
systems, container engines, version control, the third-party command-line tools
involved, or the people using them. Where a statement is instead an open
question, it appears in section 1 and is deliberately left unresolved.

---

## 1. Decisions not yet made

### 1.1 The scope question, first

The evidence in section 8 points at breadth rather than carelessness. The prior
implementation exposed roughly seventy distinct user-visible capabilities. Its
defects did not cluster in one badly-written area; they clustered at the seams
*between* capabilities — where a feature added for one purpose was reached
through a path built for another. That is the signature of a surface area larger
than any single implementation strategy can keep coherent, not of undisciplined
work.

**So the first question is: how many of the capabilities in 1.3 should exist at
all?**

The tradeoff is real in both directions. Each capability was added because
something concretely failed without it — none is decorative, and the volume of
external-system behavior in section 7 exists precisely because each one turned
out to be harder than it looked. But every capability multiplies the number of
reachable states, and the defects concentrate exactly where those states meet. A
smaller program with fewer promises would have fewer seams to get wrong, at the
cost of pushing work back onto the person using it.

This question is not answered here. It should be answered before any other
question in this section, because most of the others dissolve if the answer is
"fewer".

### 1.2 Questions answered inconsistently

Each of these was resolved one way in one place and another way elsewhere, or
was documented as one thing and behaved as another, or had a mechanism built for
it that nothing ever used. None is resolved here.

**Should a setting be able to apply to every machine at once, or only to the
machine it is set on?**
A layered configuration model was built — a shared layer overridden by a
per-machine layer, a flag to force the per-machine layer, and user-facing text
promising that settings apply everywhere unless that flag is given. Every
setting that actually exists is per-machine, so the shared layer is never
written and the flag never changes anything. The read path works; only the write
path is unreachable. *Tradeoff:* fleet-wide settings are the whole point of
shared state, but every setting identified so far genuinely describes one
machine's hardware or local policy, and a setting that must differ per machine
is actively harmful if it propagates.

**May the machine's root directory be mounted into a session that still calls
itself sandboxed?**
The primary working directory and the additional working directories answer this
differently. An override flag exists that permits the root directory as the
primary mount, while the additional-directory path refuses it unconditionally
with no flag that relaxes it. Both paths describe themselves as enforcing the
same promise. *Tradeoff:* an escape hatch that cannot be opened is not an escape
hatch; but an escape hatch that voids the program's central safety claim while
the interface still says "sandboxed" is a lie the user cannot see.

**What is the attribution scope of a session that deliberately has no sandbox?**
Discovery of repositories is disabled for such sessions, on the grounds that
scanning an entire machine is inappropriate. Visibility of already-known
repositories is simultaneously unrestricted for them, on the grounds that such a
session can reach everything anyway. So a no-sandbox session can file work
against any repository the machine has ever recorded, but can never cause a new
one to be recorded. *Tradeoff:* consistency argues for picking one; but a
full-machine scan is genuinely expensive and genuinely invasive, while refusing
to attribute work the session really did do is genuinely lossy.

**When something is missing, may the program ask?**
Some prompts are guarded by a check for an interactive terminal and some are
not. At least one unguarded prompt is reachable from an unattended path, and at
least one comparable decision elsewhere is explicitly declined when
unattended — the same question answered opposite ways in two places.
*Tradeoff:* asking is the only way to obtain a secret the program does not have,
and failing silently produces a session configured with a broken integration;
but a program that can block forever waiting for input nobody will type is worse
than one that starts degraded and says so.

**Is validation of shared state a gate or a diagnostic?**
Two answers coexist deliberately: commands *about* the shared state fail hard on
malformed input, while commands that merely *use* it degrade and continue. This
is a defensible split, but the boundary is drawn per-command rather than
per-operation, so whether a given piece of malformed data stops you depends on
which command you happened to run. *Tradeoff:* failing loudly is how people find
out something is broken; failing loudly on the command they run fifty times a
day is how they learn to ignore it.

**Who wins when two machines both write?**
The shared store is written wholesale by every participant, so two machines
changing unrelated entries collide. Automatic reconciliation was built, worked,
and was then deliberately removed as disproportionate — leaving "back out and
tell the human" as the answer. *Tradeoff:* never guessing is safe and cheap and
means a machine can silently fall behind indefinitely; merging is more code and
can pick the wrong side, but a personal tool used by one person across several
machines has an unusually strong claim that both sides are wanted.

**Should a capability's cost be paid where it is defined or where it is used?**
Version information about the containerized tools was deliberately cached at
build time so that publishing it costs nothing at session end. The reporting
commands that display the same information start a container to ask for it
directly. *Tradeoff:* fresh is more correct; a status command that takes seconds
is a status command people stop running.

**What counts as "this program's own file" when the file lives in a directory
another tool owns?**
Managed regions are written into configuration files belonging to the agent
tools, delimited by markers. The other tool appends to the same files at
unpredictable positions. Rescue logic exists for one specific collision observed
in practice. *Tradeoff:* owning a whole file is unambiguous but destroys
anything the other tool put there; owning a region is cooperative, but the
boundary is only as good as the marker discipline and the other tool has never
agreed to it.

**How much should be undoable versus prevented?**
Malformed additions to shared content are preserved locally rather than deleted,
and never cleaned up automatically. Deliberate removals are deleted outright
with version-control history as the only recovery path. *Tradeoff:* these are
opposite philosophies applied to adjacent operations; unbounded preservation
accumulates junk nobody revisits, while relying on history assumes the user is
comfortable with it.

**Are the escape hatches for suppressing automated work supported interfaces?**
Environment variables exist that disable end-of-session summarization and force
the no-sandbox mode. Neither appears in any user-facing documentation or help
output. A rebuild flag for the environment image is likewise real, used
internally, and undocumented. *Tradeoff:* undocumented switches are how
automation quietly gets built on things that were never promised; documenting
them makes them permanent.

**How much should the program promise about a platform it cannot test?**
One platform with a RAM-backed root filesystem receives substantial special
handling: boot-time restoration, alternative install locations, credential
persistence to removable storage. The handling is real and load-bearing.
*Tradeoff:* the platform genuinely breaks a normal install, and supporting it
well is a large fraction of the total accidental complexity; a second such
platform would need a generalization that does not exist and cannot honestly be
designed from one example.

**Should discovery be recursive, and how deep?**
Repositories are found by walking the mounted directories, with a fixed
exclusion list of directory names that commonly contain vendored checkouts.
*Tradeoff:* the list is a guess that will be wrong for some ecosystem; excluding
nothing makes launching from a large parent directory slow enough to notice;
requiring explicit enumeration removes the convenience that motivated recursive
discovery at all.

**What does "the latest" mean when several machines write timestamped records
concurrently?**
Ordering is by name, which encodes a timestamp generated on the writing machine.
Machine clocks are not synchronized, and two machines can produce records for
the same instant. *Tradeoff:* a total order requires coordination the design
deliberately lacks; an approximate order is usually right and occasionally shows
the wrong record as newest.

**Should the program act on a repository it has not been told about?**
Unknown repositories with a portable origin trigger a question at the end of a
session, but only when the summarizing model judges the work in them
"substantive". That judgement is made by a language model against a prose
definition. *Tradeoff:* asking about every repository ever seen is unusable;
delegating the threshold to a model means the threshold is neither stable nor
inspectable.

**Is an agent run that is not a normal session still a session?**
Two additional kinds of agent run exist — one that inspects the machine, one
that summarizes a conversation — and the promises made about "every session"
hold for neither. Neither publishes the environment contract that third-party
installers detect. Both mount an instruction file written for a *different*
run, so each is told about resources it does not have. *Tradeoff:* giving every
agent run the full contract contradicts the deliberate minimalism that makes the
summarizer safe; but a documented guarantee that silently excludes two of the
three cases is not a guarantee, and an agent told it has a resource it lacks
behaves worse than one told nothing.

**Does a safety hold survive the process that set it?**
A refusal to publish machine knowledge — because it might contain a secret, or
because it failed a structural check — is recorded only for the lifetime of the
running process. The content it refused to publish is left where the next run
will collect and publish it without re-checking. *Tradeoff:* durable holds need
somewhere to live and a way to be cleared, which is more state and another thing
to get stuck; process-scoped holds are free and correct exactly once.

**What happens when two sessions run on one machine at once?**
Nothing prevents it, and nothing accounts for it: the two share one agent home
whose instruction and configuration files each rewrites at startup, and each
publishes by sweeping in every change present in the shared working copy —
including the other's in-flight edits. Exactly one mechanism, the passing of
credentials through the process environment, was deliberately made
concurrency-safe. *Tradeoff:* serializing sessions is a real restriction on a
machine with several projects; making them independent requires per-session
isolation of state that is currently shared precisely so it can persist.

**Which spellings of a remote are the same repository?**
Host names are compared case-insensitively everywhere, but *paths* are
case-folded only for three named public forges. On any self-hosted service, two
spellings differing only in case become two separate identities with separate
histories. *Tradeoff:* case sensitivity of a repository path is genuinely a
property of the hosting service, and guessing wrong in the other direction
merges two repositories that are actually distinct; but a hard-coded list of
three services silently behaves differently for everyone else.

**Are the program's global options global?**
Options that modify session behavior are accepted before *any* subcommand.
Most are inert elsewhere, but the one that disables isolation is not: it
silently changes what the diagnostic command reports about authentication and
what the reporting commands consider visible. *Tradeoff:* a uniform option
parser is simpler and lets the transparently-named commands feel native;
per-command parsing means options are rejected where they do not apply, at the
cost of the wrapper no longer behaving like the tool it wraps.

**Is a malformed name normalized or rejected?**
Enrolling a repository or naming a machine silently rewrites unacceptable
characters; the corresponding removal and load paths reject the same input
fatally. A machine whose hostname contains a character the validator refuses is
therefore accepted at setup and then fails every subsequent command.
*Tradeoff:* normalizing is friendlier and means the user never sees a
constraint; rejecting is honest and means the name the user typed is the name
they get. Doing both, in different places, is the one option that is certainly
wrong.

**How much of a superseded format must a new version understand?**
Three different answers coexist: one obsolete layout is read as a fallback and
migrated, another causes every command to fail until a human fixes it by hand,
and a third is accepted indefinitely with no plan to stop. At least one
documented reorganization has no migration path at all, so a participant that
has not caught up simply finds its content unmounted. *Tradeoff:* compatibility
code is permanent weight and was explicitly rejected once in favor of a
coordinated one-time migration — which is only available to someone who controls
every participant simultaneously.

### 1.3 Capability inventory

Every user-visible capability the prior implementation exposed. The final column
is for the reader to fill in.

| # | Capability | Keep / Cut / Defer |
|---|---|---|
| 1 | Run an agent session in an isolated, disposable environment scoped to the working directory | |
| 2 | Support more than one agent tool through the same interface | |
| 3 | Run a session with isolation deliberately off, machine reachable, full privilege | |
| 4 | Mount additional working directories alongside the primary one, repeatably | |
| 5 | Override the refusal to start where the mount would expose the user's whole home | |
| 6 | Provide transparently-named commands so the wrapped tools are invoked by their own names | |
| 7 | Accept the program's own options both before and after the agent name | |
| 8 | Let a session authenticate outbound version-control operations without exposing key material | |
| 9 | Obtain such an authentication channel automatically when the host has keys but no usable agent | |
| 10 | Give a session access to the desktop clipboard so images can be pasted in | |
| 11 | Give in-session commits an authorship identity derived from the host's | |
| 12 | Mark mounted repositories trusted so version control will operate despite ownership mismatch | |
| 13 | Warn before launch when the session's identity will not be able to write the mounted directories | |
| 14 | Generate per-session instructions describing what the agent can and cannot see and do | |
| 15 | Prevent the containerized agent tools from attempting to update themselves | |
| 16 | Disable the agent tool's own inner sandbox where the outer one already provides isolation | |
| 17 | Produce a continuation summary automatically after a session that did real work | |
| 18 | Attribute that summary to each tracked repository the session actually worked in | |
| 19 | Ask, at most once, whether an unknown repository with substantive work should be tracked | |
| 20 | Let the user deliberately skip summarization while it is running | |
| 21 | Let automation suppress summarization entirely | |
| 22 | Bound how many summaries are retained per scope | |
| 23 | Inject the most recent relevant summary into the next session's starting context | |
| 24 | List, on demand, the other repositories a session can see, rather than inlining all their context | |
| 25 | Explicitly enroll the enclosing repository, optionally joining an existing identity | |
| 26 | Globally stop tracking a repository and discard its active summaries | |
| 27 | Treat different spellings of the same remote as one identity | |
| 28 | Discover repositories recursively within the mounted roots, before and after a session | |
| 29 | Cache the mapping from local checkout paths to global identities, per machine | |
| 30 | Interactively set up a machine: name it, connect shared storage, recover a partial prior attempt | |
| 31 | Create the shared store at a local or network filesystem path when none exists | |
| 32 | Refuse to silently repoint an existing installation at a different shared store | |
| 33 | Reconcile shared state on demand | |
| 34 | Continue running sessions when shared state is unusable, instead of blocking | |
| 35 | Return an interrupted or conflicted shared store to a clean state without discarding local work | |
| 36 | Remove a machine's contribution from shared state | |
| 37 | Preserve, rather than delete, files left by an interrupted prior setup | |
| 38 | Register external tool-servers once and have every machine and agent configured for them | |
| 39 | Store per-server credentials either shared or machine-local, at the user's choice | |
| 40 | Translate the server registry into each agent tool's own configuration format | |
| 41 | Diagnose why a registered server endpoint is unreachable, distinguishing likely causes | |
| 42 | Share one library of agent extensions across every machine and every agent | |
| 43 | Publish a machine-readable contract so third-party installers can find that library | |
| 44 | Validate the library's packaging and isolate malformed contributions without deleting them | |
| 45 | List the installed extensions | |
| 46 | Remove an extension everywhere, by name or from a picker | |
| 47 | Carry installer-owned metadata without interpreting it | |
| 48 | Produce a first structured description of the machine by letting an agent inspect it read-only | |
| 49 | Refresh that description later | |
| 50 | Defer or permanently decline the offer to produce it | |
| 51 | Scan newly-written machine knowledge for apparent secrets before it leaves the machine | |
| 52 | Warn when always-loaded machine knowledge exceeds a size that degrades every session | |
| 53 | Let a session read other machines' knowledge, read-only | |
| 54 | Install via a single piped command from a published URL | |
| 55 | Support a fully self-contained, relocatable installation | |
| 56 | Add and remove the transparently-named commands after installation | |
| 57 | Restore installation artifacts at boot on platforms that rebuild their root filesystem | |
| 58 | Generate and display the machine's public key for granting access to shared storage | |
| 59 | Persist that key and known-host records to storage that survives a reboot on such platforms | |
| 60 | Update itself from the published source, reporting what changed | |
| 61 | Check periodically whether an update exists, without blocking anything | |
| 62 | Build the containerized environment, and rebuild it on demand | |
| 63 | Reclaim the superseded environment image after a rebuild | |
| 64 | Copy the host's existing agent login into the sandbox so sessions start authenticated | |
| 65 | Uninstall, choosing between removing the program and removing all local data | |
| 66 | Clean up containers it can prove it created, and refuse to touch any it cannot | |
| 67 | Report overall state: machines, repositories, summary counts, servers, extensions, unsynced work | |
| 68 | Diagnose the machine end to end and say specifically what is wrong | |
| 69 | Show and change settings | |
| 70 | Report its own version and usage | |
| 71 | Publish what each machine is actually running so version drift across machines is visible | |
| 72 | Detect an environment where its own isolation mechanism cannot work, and refuse clearly | |

---

## 2. What the program is for

A person who works across several machines wants to hand a coding agent a
directory and have it be useful immediately — without that agent being able to
damage anything outside the directory, and without re-establishing context,
credentials, tool access, or accumulated know-how on each machine separately.

The value, in priority order:

**Containment that is honest.** The agent runs where it cannot reach the rest of
the machine, and it is *told* that — so when asked about a file it cannot see it
says the file is out of reach, rather than inventing an answer or reporting the
file absent. Containment the agent does not know about produces confidently
wrong behavior, which is worse than no containment. The boundary must be real,
and the program must never claim a boundary it did not establish. Where the user
deliberately removes the boundary, the agent must be told that too, because the
correct behavior on the other side is different.

**Continuity across time and across machines.** Work stops mid-thought. Resuming
should not mean reconstructing what was being attempted, what was already tried,
and what was about to happen next — and it should not require being at the
machine where the work happened. This is the single property that makes the tool
worth installing on a second machine.

**A working environment on arrival.** The agent tool's credentials, access to
the external tool-servers the person uses, the extensions they have written or
vendored, and the durable facts about the machine they are on — all present
without setup. Configured once, available everywhere. The alternative is a
per-machine ritual that people skip, after which the machines diverge and "it
works on the other box" becomes unanswerable.

**Never being blocked by the plumbing.** The machinery that carries context
between machines is bookkeeping; the session is the product. No state that
bookkeeping can get into may prevent an agent from starting — not a conflict,
not a corrupted record, not an unreachable network, not a version written by a
newer copy of the program elsewhere. A person locked out of their agent by their
notes-syncing system will stop using the notes-syncing system, and rightly.

**Recoverability over cleverness.** When something is ambiguous, the program
should preserve what it has, say plainly what it did not do, and leave the
person a normal way to fix it with ordinary tools. It must never resolve an
ambiguity on the user's behalf in a way that silently discards one of the
possibilities.

Explicitly *not* the point: being a platform, a service, or a daemon; managing
multi-user access; providing production-grade guarantees; or being something the
user thinks about. Success is that it is invisible.

---

## 3. Invariants

Violating any of these is a real failure, not an inelegance.

**Key material never enters the isolated environment.** The environment may be
granted the *ability to use* a credential — an authentication channel, a
short-lived token — but the credential itself must never be readable, copyable,
or persistable from inside. A session that can exfiltrate a private key has
defeated the reason the isolation exists.

**A session's declared boundary is the boundary.** Nothing outside the mounts
the user asked for is reachable from an isolated session. If the program cannot
establish that, it must refuse rather than proceed with a weaker boundary under
the same name.

**Isolation is never silently weakened.** Any reduction in the boundary is
either requested explicitly by the user or refused. A path that widens access as
a side effect of handling an error is a defect, however convenient.

**The agent is never told the environment is safer or more capable than it is.**
Claiming that outbound authentication works when it does not, or that a path is
writable when it is not, sends the agent — and then the user — to debug the
wrong system entirely. Silence is acceptable; a false promise is not.

**Bookkeeping state can never prevent a session from starting.** No corruption,
conflict, version skew, or network failure in the shared store may block the
core operation.

**Conflicting concurrent edits are never resolved by guessing.** If two machines
changed the same thing, the program either merges by a rule the user can
predict, or backs out entirely and says so. It must never pick a side silently,
and must never leave the shared store in a state that requires specialist
recovery.

**Local work is never lost to a failed remote operation.** A failed network
operation must leave a retryable state with the local contribution intact.

**Nothing is deleted that the program cannot prove it owns, or that the user did
not name exactly.** This binds every destructive path: installed commands,
containers, images, configuration, shared entries, stored state. An ownership
marker that a second installation would also have written is not proof.

**Malformed or uncertain user data is preserved, not discarded.** Where the
program rejects something, the rejected thing must remain recoverable.

**Agent-tool credentials and conversation transcripts never enter shared
storage.** This line does not move regardless of how convenient it would be.

**A destructive operation on shared state never runs unattended.** Anything that
removes a machine, a repository's accumulated context, or another participant's
data requires a human present.

**Newer versions elsewhere cannot disable older ones.** Shared records must
remain usable by participants that do not understand every field in them. One
machine upgrading must never stop the others working.

**A diagnostic never reports success from an absence of data.** "Nothing
disagreed" and "nothing was compared" are different results and must be reported
differently.

**Automated context capture never overwrites good context with worse.** A
failed, empty, or malformed attempt to record continuation state must leave the
previous state in place.

**Unattended helper work receives only what its task requires.** A process
invoked to summarize a conversation gets the conversation and nothing else — not
the project, not the machine, not credentials, not tool access.

**A decision not to publish something outlives the process that made it.**
Content withheld because it might contain a secret, or because it failed a
structural check, must stay withheld until the condition is actually resolved.
A hold that expires when the program exits, while the content it withheld
remains staged for the next run to collect, is equivalent to no hold at all.

**A guarantee stated once is enforced on every path that can reach it.** Where
the program promises a property — that a boundary holds, that a class of failure
cannot block the core operation, that a contract is published to every agent
run — that promise must be a property of the operation, not a check repeated at
each call site where someone remembered it.

**What a consumer is told about the data is how the data is actually
ordered, named, and selected.** Describing one selection rule to an agent or a
user while implementing a different one produces confident, unfalsifiable wrong
answers.

---

## 4. Frozen external contracts

Only things that break a third party or an existing installation if changed.
Quoted exactly.

### 4.1 Published install entry point

```
curl -fsSL https://raw.githubusercontent.com/SwaggyMike/satchel/main/install.sh | bash
```

The path `main/install.sh` on that host, reachable unauthenticated, is
referenced by existing documentation and by users' own notes. The installer must
remain executable by piping into a shell with no arguments and no guaranteed
terminal.

Environment variables honored by that entry point, which existing installs and
scripted deployments already pass:

- `SATCHEL_BIN` — names a **directory** for a self-contained install, not an
  executable path.
- `SATCHEL_DIR` — overrides the state location.
- `SATCHEL_SHIMS` — set to `n` to skip creating the transparently-named
  commands.

### 4.2 User-facing command names

The primary command is `satchel`. The transparently-named commands it installs
onto the user's path are exactly `claude` and `codex`. These names collide by
design with the tools they wrap; changing which name is installed changes what a
user's existing shell invocations do.

Existing subcommand names, all reachable today:

```
claude  codex  init  sync  status  skills  key  retire  track  untrack
settings  doctor  mcp  link  unlink  uninstall  import  image  update
version  help
```

Global option spellings: `--host`, `--unsafe-home`, `--with <dir>`. These are
accepted both before and after the agent name, because the wrapped tools do not
use those names and users rely on `claude --host` being equivalent to
`satchel --host claude`.

### 4.3 On-disk forms of prior installs that must be detected for removal

An existing installation must be recognizable so an uninstall or upgrade does
not orphan it, and so files belonging to *another* installation or to the real
wrapped tool are never removed.

Current generated wrapper files contain this exact marker line:

```
# satchel shim
```

and a body line of exactly this form, where the first field is a shell-quoted
absolute path to the installed command and the second is the agent name:

```
exec /path/to/satchel claude "$@"
```

An older generation of wrapper, still present on long-standing installs, has no
marker comment and must also be recognized. It matches:

```
^exec[[:space:]]+satchel[[:space:]]+(claude|codex)([[:space:]]|$)
```

Matching the marker alone is sufficient to decide "some installation owns this".
It is **not** sufficient to decide "this installation owns this", because a
second installation on the same machine writes the identical marker. Ownership
requires matching the exact generated body line.

On platforms whose root filesystem is rebuilt at boot, a managed region is
appended to the platform's boot script, delimited by exactly:

```
# >>> satchel boot persistence >>>
# <<< satchel boot persistence <<<
```

That region must be detectable and removable by any future version, and a region
with a start marker but no end marker must be left alone rather than guessed at.

Further paths load-bearing for existing installs on that platform: the boot
script at `/boot/config/go`; the key backup directory `/boot/config/ssh/root/`;
and a previous version's backup of the boot script kept beside it with the
suffix `.satchel-bak`. Platform detection reads the file
`/etc/unraid-version`.

### 4.4 Third-party CLI grammar this program drives

These belong to other projects. They are recorded because the exact spellings
are load-bearing and were arrived at by failure.

Unattended continuation-summary invocation for one agent:

```
claude --continue --strict-mcp-config --tools "" --effort low -p <prompt>
```

Unattended continuation-summary invocation for the other:

```
codex exec resume --last --skip-git-repo-check --ignore-user-config --ignore-rules -c 'sandbox_mode="danger-full-access"' -c 'model_reasoning_effort="low"' <prompt>
```

Interactive launch options for that same tool, where the inner sandbox must be
disabled because it cannot create namespaces inside an already-isolated
environment and self-update checks must not run:

```
codex -c 'sandbox_mode="danger-full-access"' -c check_for_update_on_startup=false
```

Both tools honor `DISABLE_AUTOUPDATER=1`.

### 4.5 Third-party file formats this program reads or writes

One agent's configuration is JSON with a server map under the key `mcpServers`,
whose entries take this shape, credentials inline:

```json
{"type": "http", "url": "https://example/endpoint", "headers": {"Authorization": "Bearer <token>"}}
```

The other agent's configuration is TOML and does **not** accept a credential
inline — only the *name of an environment variable* to read one from:

```toml
[mcp_servers.<name>]
url = "https://example/endpoint"
bearer_token_env_var = "<ENV_VAR_NAME>"
```

Authentication state belonging to those tools, detected to decide whether a
login exists and copied when importing one:

```
~/.claude/.credentials.json
~/.claude.json          (keys: oauthAccount, primaryApiKey)
~/.codex/auth.json
```

Instruction files those tools read automatically from their own home
directories:

```
~/.claude/CLAUDE.md
~/.codex/AGENTS.md
```

Extension directories those tools scan at startup. The second resolves relative
to that tool's own home-directory override:

```
~/.claude/skills
${CODEX_HOME:-$HOME/.codex}/skills
```

Conversation-history locations, whose modification times are the only available
evidence that a session did anything:

```
~/.claude/projects
~/.codex/sessions
```

One of those tools materializes a version-specific bundled-extension tree named
`.system` beneath its extension directory. It belongs to the installed version
of that tool and must never be treated as user content.

Both tools locate a conversation to resume partly by the working directory the
conversation originally ran in.

### 4.6 Remote APIs consumed

```
https://api.github.com/repos/<owner>/<repo>/commits/main
https://api.github.com/repos/<owner>/<repo>/contents/satchel?ref=main
https://api.github.com/repos/<owner>/<repo>/compare/<old>...<new>
https://raw.githubusercontent.com/<owner>/<repo>/<ref>/satchel
```

### 4.7 Contract published to third-party extension installers

Extension installers running inside a session detect this environment
mechanically. Changing these names breaks installers this program does not
control:

```
SATCHEL_SESSION=1
SATCHEL_SESSION_MODE=host|sandbox
SATCHEL_SKILLS_DIR=<absolute path to the shared extension library>
```

### 4.8 Exit codes

- `0` — success.
- `1` — every fatal error, without further discrimination. The diagnostic
  command also exits `1` when it found problems.
- `2` — reserved by the build tooling for usage errors.
- `130` — the operation was interrupted by the user at the terminal. This must
  not be reported as a failure of the thing being attempted.
- `131` — the user deliberately skipped an optional unattended step, as distinct
  from the step failing.

---

## 5. Capabilities

Each paragraph states what must be accomplished and what must never happen.

**Isolated session.** Give an agent tool a working environment containing the
user's chosen directory or directories and nothing else of the machine, running
under an identity that cannot escalate, and discard that environment when the
session ends. It must never expose paths the user did not name, never run with
more privilege than the isolation requires, and never present itself as isolated
when it is not.

**Unisolated session.** Provide an explicitly-requested mode where the machine
itself is the subject of the work: real filesystem reachable, full privilege
available, the container serving only as packaging. It must be impossible to
enter this mode by accident, and the agent must be told unambiguously which
paths are the machine's and which belong to the disposable environment, because
the same absolute path means different things in each mode.

**Boundary refusal.** Recognize when the requested working directory would place
the user's credentials, keys, or the program's own state inside the session, and
refuse. It must not silently proceed, and it must not refuse without offering
the honest alternative. Whatever override exists must behave identically across
every path that can establish a mount.

**Outbound authentication.** Let work done inside a session reach remote
version-control hosts without the session ever being able to read, copy, or
retain a credential. Where no such channel can be established, say so before the
session starts, in terms of what will concretely fail. It must never report a
channel as working without having confirmed it works for the identity the
session will actually run as.

**Desktop clipboard access.** Let images pasted from the host desktop reach the
agent. Prefer the narrower of the available display protocols when both exist.
It must be silently absent on machines with no desktop, and disableable by users
who consider a live channel to their clipboard unacceptable.

**Session briefing.** Generate, fresh for each session, a description of what
the agent can see, what it cannot, what will and will not work, where shared
resources are, and what the user's durable context is. It must never assert a
capability that was not verified, and must stay small enough that adding to it
does not degrade everything else in it.

**Continuation capture.** After a session that did real work, produce a compact
structured summary of intent, progress, in-flight state, next steps, and
hazards, and make it available to the next session anywhere. It must never run
with access to anything beyond the conversation it is summarizing, never
overwrite a good summary with a failed or malformed attempt, and never be
mandatory — the user must be able to abandon it while it is running.

**Work attribution.** Determine which tracked repositories a session actually
worked in and record continuation state separately for each, independent of
where the session was launched. Work belonging to no tracked repository must
still be retained, scoped to the machine. It must never infer identity from a
directory name, and nested repositories must resolve unambiguously.

**Repository identity.** Treat different spellings of the same remote as one
thing across all machines, and keep local checkout locations as disposable
per-machine detail. It must never let two identities claim the same record, and
never require a network round-trip to decide identity.

**Shared state transport.** Carry context, registries, and extensions between
machines over storage the user owns and can inspect with ordinary tools. It must
degrade to local-only operation on any failure, never block the primary
operation, and never leave the user's copy needing specialist recovery.

**Tool-server registry.** Let the user register external tool endpoints once and
have every agent on every machine configured for them, including credentials
where the user chooses to share them. It must never place a credential where the
host's process list or another local user could read it, and never destroy
configuration those tools wrote for themselves.

**Extension library.** Maintain one library of agent extensions shared by every
agent and machine, writable from inside a session, and publish a contract so
third-party installers can target it. It must validate packaging without
interpreting content, isolate rather than delete anything malformed, and never
propagate content the agent tools own themselves.

**Machine knowledge.** Maintain durable, tiered facts about each machine —
always-loaded operational context, an on-demand detailed reference, and
on-demand procedures — writable by agents during sessions and readable by
sessions on other machines. It must keep the always-loaded tier small, never let
it become an incident log, and never let apparent secrets leave the machine
inside it.

**Machine onboarding.** Offer, once an agent can authenticate, to have that
agent inspect the machine read-only and propose an initial description for human
approval. It must never permit modification of the machine during inspection,
never write anything unapproved, and never expand into a normal session the user
did not ask for.

**Installation lifecycle.** Install by a single published command, place itself
and its state so both survive whatever the platform does at boot, update itself
atomically from published source, and uninstall cleanly with an explicit choice
about local data. It must never leave a partially-written executable or boot
script, and never remove anything it cannot prove it created.

**Environment provisioning.** Build and maintain the containerized environment
the agent tools run in, and make what each machine is actually running visible so
divergence between machines is discoverable rather than mysterious. It must not
require build tooling on the target machine beyond what it already needs, and
must never reclaim an image something else still references.

**Diagnosis.** Check the machine end to end — tooling, isolation mechanism,
authentication, shared-storage reachability and divergence, platform-specific
persistence, endpoint reachability — and report specifically what is wrong and
what to do. It must distinguish "checked and found nothing wrong" from "had
nothing to check", and must never skip reporting on one subsystem because a
different one is broken.

**Unsupported-environment detection.** Detect when the available isolation
mechanism cannot actually reach this program's own files — the case where it is
itself inside another container whose engine has a different filesystem view —
and stop with an explanation rather than degrading into a cascade of mount
errors.

---

## 6. Environmental reality

### 6.1 Platform targets

Linux on x86-64 and ARM, on machines the user administers themselves: laptops,
home servers, and NAS appliances. Multi-user hardening is out of scope; the
threat model is the agent's own mistakes, not a hostile local user.

At least one target platform rebuilds its root filesystem from removable storage
at every boot. Anything at `/`, at the system-wide command directory, or in the
superuser's home is gone after a reboot unless restored from persistent storage.
On that platform the program frequently runs as the superuser while sessions
deliberately do not.

At least one target platform runs its container engine rootless, where the
container's superuser maps to an unprivileged host account. Paths owned by other
host accounts are unwritable from inside regardless of in-container privilege.

Not targets: macOS, Windows, and any environment where the user cannot install a
container engine.

### 6.2 Required of the host

A container engine — either of the two dominant ones, which differ in ways
section 7 details. Version control. A JSON processor. A URL fetcher. An SSH
client, key generator, and agent. A privilege-dropping utility that accepts a
*numeric* identity and does not consult the account database, because the
identity a session runs as need not correspond to any named account.

### 6.3 Constraints imposed from outside

**The agent tools are not pinned and are not this program's to version.** They
are installed from a floating upstream tag into the environment image, which
each machine builds independently whenever it happens to update. Two machines in
the same setup will legitimately run different versions of the same tool.
Preventing this means taking on release engineering for tools this program does
not own; the only available response is to make the divergence visible.

**The wrapped tools' configuration files are shared with the tools
themselves.** They write to the same files at times this program does not
control, including immediately before trailing content. Any managed region
inside them must survive the other writer.

**Ordering constraint — authentication before network.** Outbound authentication
must be established before the first network operation against shared storage.
*Reason:* an authentication channel that exists but holds no identity produces a
failure indistinguishable from the remote being unreachable. Attempting the
network first therefore reports a misleading startup failure moments before the
identity that would have fixed it is loaded.

**Ordering constraint — identity normalization around the session.** Ownership
of the program's own writable state must be normalized for the identity the
session will run as, after anything that writes to that state and before the
session begins — and again after a session that ran with elevated privilege.
*Reason:* on hosts where the program runs as the superuser and sessions do not,
the program creates files the session then cannot modify; and where a privileged
session ran previously, it left files a subsequent unprivileged one cannot
touch.

**Ordering constraint — trust declaration before any repository operation.**
Mounted repositories must be declared trusted before the agent can use version
control on them. *Reason:* version control refuses outright to operate on a
repository owned by a different account, which is the normal case wherever the
host account and the session identity differ. Without the declaration every
version-control command fails with an ownership error that reads like a
corrupted repository.

**Ordering constraint — repository discovery must also happen after the
session.** *Reason:* a session can clone or initialize repositories that did not
exist when it started, and work in them is exactly the work worth attributing.

**Ordering constraint — self-replacement must be a rename within one
filesystem.** *Reason:* section 7.6 explains the interpreter behavior that makes
any other approach corrupt the running program.

### 6.4 Timeouts and bounds, with justification

| Bound | Value | Justification |
|---|---|---|
| Unattended summarization | 240 s | It resumes and re-reads a full conversation transcript, the slowest model operation in the system. Shorter values truncated legitimate work; this is the point past which a hung container is more likely than a slow one. |
| Shared-store fetch at session start | 20 s | On the critical path of every launch and best-effort by definition. Long enough for a normal fetch over a home network, short enough that an unreachable remote is not a perceptible delay before the agent appears. |
| Shared-store publish at session end | 30 s | Off the critical path, so a longer allowance is affordable; a push does more work than a fetch. |
| Remote reachability probe in diagnostics | 10 s | The user is watching a diagnostic run and expects it to terminate; distinguishing "slow" from "unreachable" is not the check's purpose. |
| Update availability probe | 5 s | Entirely optional information. Any delay it adds to a launch is unjustifiable. |
| Endpoint reachability probe | 5 s | Several are probed in sequence during diagnostics; the total must stay bounded. |
| Update check interval | 86 400 s | Frequency at which an update is worth mentioning, against a network round-trip per launch. Recorded *before* the probe runs, so a day spent offline costs one failed request rather than one per session. |
| Retained continuation summaries | 100 per scope | Enough to read back as a record of how work arrived where it is; ten was measured to be too few and evicted real history. Nothing in a session scales with this number, so the bound exists only to keep the active set a working set rather than an archive. |
| Always-loaded machine knowledge | 750 words, soft | Injected into every session's context, so its size is paid on every launch and dilutes everything else present. Soft because a guardrail that discards essential information to satisfy a count is worse than the overrun. |
| Published-source cache staleness | ~5 min | Not chosen — imposed by the CDN in front of the published raw source. See 7.6. |

---

## 7. Hard-won knowledge

Non-obvious behavior of external systems that the prior implementation had to
work around. This is the material that cannot be re-derived by reasoning.

### 7.1 OpenSSH and its agent

**The agent authenticates its clients by peer credentials, not by file
permissions.** It serves a connection only when the connecting process's
effective user id is either 0 or exactly equal to the agent process's own user
id; otherwise it closes the socket. Changing the socket's ownership or mode has
no effect whatsoever on this check. An agent started by the superuser cannot be
used by a session running as an unprivileged identity, no matter how the socket
is chowned. The agent process itself must run as the identity it will serve.

**This makes reachability tests misleading unless performed as the right
identity.** A privileged process probing such an agent gets a successful answer —
because the agent does serve the superuser — and concludes the channel works.
Every client inside the unprivileged session then fails. The observable symptom
is an authentication failure at push time, which sends debugging toward the
remote host's access controls and away from the agent that was never reachable.
Any readiness claim must be established from the identity that will actually use
the channel.

**A socket existing proves nothing.** It can point at a dead process, or at a
live agent holding no identities at all — the latter being the common case when
an agent is forwarded over SSH but was never loaded on the originating machine.
These three states (identities present; agent answering but empty; nothing
answering) need different responses and are distinguishable by exit status: `0`,
`1`, and anything else respectively.

**An empty agent can become useful mid-session.** Identities added on the host
while a session is running are immediately visible to it, because the socket is
live. So an empty agent is worth forwarding; a dead one is not, since mounting
it can only produce confusing in-container errors.

**Resolving `~` does not consult the environment.** OpenSSH resolves the home
directory through the account database, not through `HOME`. Setting `HOME` to a
mounted persistent directory therefore does not stop SSH writing its state —
known-hosts records above all — to whatever the account database says, which in
a container is an ephemeral path that vanishes. The consequence is that
trust-on-first-use never accumulates: every session re-encounters every host as
new. On a platform where the superuser's home contains a symbolic link to
storage not present in the container, it also produces a dangling path.

**Dropping privilege to a numeric identity requires a tool that does not consult
the account database.** The conventional privilege-dropping utilities require an
account *name*, which an arbitrary numeric identity need not have. A utility
taking a numeric id, performing no login and no pluggable authentication, is
required. Its absence is a distinct condition and must be reported as such —
reporting "no key found" when a key is present and merely unusable sends
debugging in the wrong direction.

**A file descriptor survives a privilege drop.** This is the mechanism by which
a key readable only by the superuser can be handed to an agent running as an
unprivileged identity without ever copying it to a path the sandbox could read.

**Per-host client configuration is not part of the agent.** Forwarding the agent
socket conveys identities, not the host's client configuration. Per-host
identity selection, user names, and ports from that configuration do not apply.
The result is that some remotes work and others fail in the same session, which
looks like an intermittent credential problem and is not.

**First contact with an unknown host is an interactive prompt.** Under
automation with suppressed output and a timeout, that prompt manifests as a
stall followed by an apparent unreachable-remote error. Accepting new host keys
automatically converts it into a recorded fact — but only if the record is
persistent, which returns to the account-database problem above.

### 7.2 Container engines

**The two dominant engines do not accept the same options.** At least one
process-namespace option spelling is accepted by one and rejected by the other.
Any option set must be validated against both, or selected per-engine.

**An init process requires a private process namespace.** Requesting both a
supervising init process and a shared host process namespace is contradictory
and rejected. Where the host namespace is shared, the host's own init reaps
orphaned processes, so the supervisor is unnecessary.

**Rootless operation needs explicit identity mapping.** One engine maps
container identities to host identities one-to-one; the other, run rootless,
does not, and requires an explicit request to keep the invoking identity. When
that request is made for an identity absent from the image's account database,
the engine *invents* an account entry — and the invented entry's home directory
is not the one the session actually uses, which recreates the SSH problem in
7.1. The invented entry can be templated explicitly.

**Automatic container removal is handled by the daemon, not the client.**
Killing the client process does not remove the container, and does not stop it.
An unattended task that is cancelled or times out therefore leaves a container
running and, if it is a model invocation, continuing to consume budget. A
container that must be reliably reclaimed needs a predictable name so it can be
addressed after the client is gone. A predictable name is also a hazard: it can
already be held by something unrelated, so ownership must be confirmed before
any forced removal.

**Mandatory access control blocks bind mounts by default.** On distributions
with it enabled, a confined container cannot read host paths carrying the
default home-directory label, so a session fails reading its own state. The
documented relabeling options are the wrong instrument here: they rewrite labels
on arbitrary host directories — including the user's project — and cannot cover
a socket at all. Disabling label separation for the session is the supported way
to mount arbitrary host paths, and does not weaken the namespace, identity,
capability, or privilege-escalation controls.

**Rebuilding an image from floating upstream tags strands the previous layers.**
Where the image includes large package installations, each rebuild leaves the
superseded image untagged but present. On appliances with a fixed-size image
store this exhausts the store within a few updates. The superseded image can
only be reclaimed safely if nothing else still names it.

**A container engine reachable from inside another container may have a
completely different filesystem view.** In appliance environments that expose an
engine socket to applications, the engine cannot see the calling application's
own files, so every bind mount silently refers to something else or fails. This
is not detectable from the engine's version or capabilities; it requires
actually attempting a mount and verifying the content arrives.

**The legacy image builder runs the build shell as the superuser and as process
1.** Account-modification utilities refuse to alter an account currently in use,
so changing the account database during a build requires editing the database
file directly rather than using the conventional tool.

**Working directories must exist.** At least one engine refuses to start a
container whose requested working directory does not exist inside it. Where the
working directory must match a path for reasons unrelated to its contents — see
7.4 — an empty in-memory filesystem mounted at that path satisfies the
requirement without exposing anything.

**A read-only mount option and an actually-rejected write can disagree.**
Verifying that a mount is read-only requires attempting a write, not inspecting
the mount's recorded options.

### 7.3 Version control

**Repositories owned by a different account are refused outright.** Since a
version 2.35 security change, operating on a repository whose owner differs from
the current account fails every command with an ownership error rather than a
permission error. Wherever the host account and the session identity differ —
the normal case on appliance platforms — this affects every repository the
session can see, and reads as repository corruption rather than a permissions
issue. Directories must be declared trusted explicitly.

**A rebase detaches the head, so upstream-relative references stop resolving.**
Any guard that tests for an upstream before testing for an interrupted operation
will be skipped in exactly the state it exists to catch. This produced a
reproducible cascade in which a conflict left the working copy mid-rebase, the
recovery check was bypassed on the next run, a strict validator then parsed
conflict markers as data, and the program refused to start at all until a human
resolved a rebase by hand.

**Aborting a rebase started with automatic stashing restores pre-existing
uncommitted edits.** Those edits can be the only surviving copy of work. A "make
the tree look clean" step after aborting therefore destroys data; verifying that
the abort actually cleared the operation is the correct check.

**Wholesale rewriting of a shared file makes unrelated edits conflict.** Where
every participant rewrites a registry file entirely, two participants changing
*different* entries produce adjacent edits that conflict textually. This is the
ordinary case, not an exception, for any format regenerated rather than patched.

**Exact-schema validation of shared state is a fleet-wide outage mechanism.** A
validator requiring an exact set of keys rejects anything a newer version
elsewhere writes, turning one machine's upgrade into every other machine failing
every command. Validating only the fields actually read, and ignoring unknown
ones, is the difference between a rolling upgrade and a flag day.

**A freshly-cloned empty repository has no upstream** until the first push
establishes one, so upstream-relative operations must tolerate its absence
rather than treating it as an error.

**Commits must work on a machine where version control was never configured.**
Absent an identity, commits fail. A repository-local identity supplies one
without overriding a user's global configuration where they have it.

**Creating a configuration file as a side effect breaks later "does the file
exist" tests.** Where one operation writes a configuration file for its own
purposes, a later feature guarded by the file's absence never runs again.
Observed consequence: a machine whose first session predated having a
version-control identity failed every in-session commit permanently and
silently. Guards must key on the specific fact they need, not on a file's
existence.

**Blob hashing identifies a file's content independently of history.** This
allows comparing a locally-installed script against a published one without
knowing which commit the local copy came from — which matters because
hand-installed copies have no recorded provenance.

**Version control does not carry file permissions.** Only the execute bit
survives; ownership and access mode do not. A file created with restrictive
permissions on one machine arrives on every other machine at whatever that
machine's default mask produces. Any confidentiality that depends on a file's
mode must therefore be re-established wherever the file lands, not once where it
was written.

**A bare repository on a network filesystem is a legitimate remote.** Users
without a hosted service will point shared storage at an NFS path, where there
is no interface to click "create repository" in.

### 7.4 The agent tools driven

**Conversation resumption is keyed partly on the original working directory.**
To resume a specific conversation unattended, the working directory must match
the one the conversation ran in — but the *contents* of that directory are
irrelevant to the lookup. This is what makes it possible to summarize a
conversation about a project without granting access to the project.

**Non-interactive execution enforces constraints interactive execution does
not.** One tool's non-interactive mode fails outright outside a version-
controlled directory, while its interactive mode remembers a trust decision and
proceeds. An unattended invocation therefore needs an explicit opt-out the
interactive one never required. This failure was silent for an extended period
because the unattended invocation's error output was discarded — the diagnostic
lesson being that an unattended subprocess's error stream must be captured and
surfaced, or its failures become indistinguishable from each other.

**The tools' own inner sandboxes cannot nest.** One tool sandboxes itself using
kernel namespace creation, which is unavailable inside an already-isolated
environment. Where the outer environment *is* the sandbox, the inner one must be
disabled or the tool cannot run at all.

**Self-update inside a disposable environment is pure waste.** The tools check
for and apply their own updates by default. In a container discarded at exit the
update either fails or evaporates, while costing startup latency every session.

**Clipboard access is implemented differently by each tool.** One shells out to
external clipboard utilities, which must therefore be present in the image; the
other speaks the display protocols directly. Both need a path to the host
compositor, because that is the only place the clipboard exists — a snapshot
taken at launch is useless, since pasting happens mid-session.

**Instruction files are read from the tools' own home directories** and consumed
in full at every session start. This makes them a genuine interface, and makes
their size a cost paid on every launch: adding to them makes everything already
in them work less well. Corrections are preferable to additions.

**Those instruction files must use absolute paths.** A session running as the
superuser resolves `~` to the superuser's home, not to the agent home the
program actually mounted, and an agent told to read a tilde path will look in
the wrong place.

**Extension discovery happens at startup only.** An extension installed during a
session is durable immediately but not discoverable until the next session.
Users must be told this or they will conclude the installation failed.

**One tool materializes a version-specific bundled-extension tree inside the
same directory it discovers user extensions in.** That tree belongs to the
installed version of the tool. Treating it as user content causes different
versions on different machines to repeatedly overwrite each other's bundled
extensions.

**Extension metadata files written by third-party installers are not this
program's to interpret.** Their schemas are owned elsewhere and change without
notice. They can be carried and validated as well-formed, but rewriting them on
the basis of a guessed schema corrupts installer state.

**One tool cannot accept a bearer credential inline** in its configuration; it
accepts only the name of an environment variable to read one from. This forces
the credential through the process environment, which in turn constrains how the
container is launched — see 7.7.

**A model given a formatting contract will sometimes drift out of it,**
especially when resuming a long transcript. A smaller or faster model increases
that probability, and every drift costs a full retry on the default model —
which measured *more* wall-clock than the smaller model saved. The useful lever
is reasoning effort on the default model, not model substitution.

**A model correctly reporting "there is nothing to record" is a valid result,
not a failure,** and must be distinguished from a failed invocation. Partial
output from a failed invocation, by contrast, is not authoritative and must not
be accepted as a result.

**Asking a model to emit exact literal delimiters is fragile.** Where structured
output is separated by literal marker lines, anything the model gets slightly
wrong is silently unattributable, and two sections that resolve to the same
destination will overwrite each other unless explicitly merged.

### 7.5 Operating system and desktop

**The Wayland display protocol accepts an absolute socket path** in its display
variable, which removes any need to reproduce the host's runtime directory
structure inside the container. The X11 fallback requires the socket directory
plus the display variable and, where present, the authority file. X11 access is
strictly broader than Wayland — any client can observe input — so where both
exist the narrower one is the correct choice.

**Forwarding a compositor socket grants more than clipboard access on some
compositors.** Screen capture and virtual input are gated behind portals on the
major desktop environments but are directly available on others. This is a real
widening of what a session can do, not a formality.

**A platform whose root filesystem is rebuilt at boot loses everything not on
persistent storage** — installed commands, path entries, and the superuser's SSH
state including host-key records. The boot-time restoration script on such
platforms is also what starts the appliance's own management interface, so a
partially-written or non-parsing copy of it costs the user a physical trip to
the machine with removable media. Any modification to it must be a rename of a
fully-written file within the same filesystem, must be syntax-checked before
installation, and must keep the last known-good copy. The removable storage
holding it is typically unencrypted and is a single point of failure for the
entire appliance configuration, independently of this program.

**On such platforms the program commonly runs as the superuser while sessions
run as an unprivileged identity.** Project files then belong to the superuser
and are readable but not writable from the session, and version control refuses
them entirely (7.3). An agent encountering a permission error there will reach
for privilege escalation or permission changes, neither of which can work from
inside; it must be told the cause is host ownership and that only the user can
fix it.

**Shells cache the location of commands they have already resolved.** A newly
created command on the path is not found by an already-running shell until its
cache is cleared or a new shell is started, which reads as the installation
having failed.

**Terminal capability must be determined per output stream.** Whether output is
a terminal is independent for standard output and standard error, and they are
routinely redirected separately. A single global decision produces escape codes
in a captured log or strips them from an interactive display.

### 7.6 Network, distribution, and self-replacement

**Raw file access on the published-source host sits behind a cache of roughly
five minutes** and will serve a stale copy. Resolving a branch to a commit
through the API and fetching by commit identifier bypasses this; fetching by
branch name does not.

**A cross-device move is a copy into the existing destination inode, not a
rename.** This matters catastrophically for a program that replaces itself: the
interpreter reads a script incrementally and seeks back into the file between
top-level commands. Copying a longer replacement into the running file's inode
causes execution to resume at a stale byte offset inside the new content, so an
arbitrary fragment of the new program executes. The staging location must be on
the same filesystem as the target — and the conventional temporary directory is
*not* on the same filesystem on the appliance platform, where it is memory-backed
while the program lives on storage.

**The same interpreter behavior means the program must have nothing after its
final top-level command** — there must be no later offset for it to resume into.

**A downloaded replacement must be syntax-checked before installation.** A
truncated download otherwise replaces a working program with an unparseable one.

### 7.7 Credentials and process visibility

**Passing a value as an environment assignment on a container engine's command
line discloses it in the host process list**, readable by any local user.
Passing only the *name* of an already-exported variable does not. Where a
wrapped tool requires a credential to arrive through the environment (7.4), this
is the only way to satisfy it without disclosure.

**Secrets that reach shared storage persist in its history** even after removal.
Rotation at the source is the only real remediation, and users must be told
that rather than being left to believe deletion suffices.

**A warning about a suspected secret must never quote the suspected value**, or
the warning becomes another place the secret is recorded.

### 7.8 Interaction and signals

**A held interrupt keystroke continues to deliver signals after the foreground
process is gone.** Repeated interrupts used to exit an interactive tool spill
over into whatever runs next — which is exactly the cleanup and context-capture
work that must not be lost. Protecting that work requires running it in its own
process group, because programs like container clients and version control
install their own signal handlers regardless of what the parent does.

**Clearing a signal handler before restoring the previous one leaves a window at
the default disposition.** A signal arriving in that window terminates the
process. Handlers must be restored directly rather than cleared first.

**A caught signal handler still lets child processes receive the signal, while
an ignored one does not.** This distinction is what allows an interactive child
to respond to interrupts normally while the parent is protected.

**A distinct second key is needed for "deliberately skip this optional step",**
because the obvious one is already overloaded with "stop what is happening" and
is being delivered in bursts by the user's own muscle memory.

**Prompt defaults are part of the safety design.** A destructive question must
default to refusal so that a reflexive keystroke declines it; a routine question
should default to acceptance so it is not a toll. A question about granting
elevated inspection deserves a third option — permanently stop asking — because
otherwise the user's only way to silence it is to accept it.

### 7.9 Language-specific artifacts

*These exist only because of the implementation language and would not recur in
a different one. They are recorded so they are not mistaken for facts about the
world.*

- **The shell counts tab as whitespace for field splitting.** Reading
  tab-delimited records with tab as the separator therefore mis-parses any record
  with an empty leading field, silently shifting every column. This produced a
  retention bound that stopped working entirely for records missing an optional
  field.
- **Negating a command's status exempts it from error-on-failure mode.** Every
  negative test assertion written that way runs, discards its result, and passes
  unconditionally. This affected a third of one test suite's negative assertions
  and concealed two tests asserting directly contradictory requirements, both
  "passing".
- **A function's return status is whatever its last command returned.** A loop
  whose final iteration's test fails returns failure, which under strict mode
  terminates a caller that was merely asking a question with a legitimately empty
  answer.
- **A fatal error inside command substitution exits the subshell, not the
  program**, so the assignment merely returns non-zero — which strict mode then
  turns into a program exit at a completely different place than intended. This
  made read-only reporting commands die on machines that simply lacked an
  optional dependency.
- **Reading input inside a loop whose input is redirected reads from the
  redirection, not the terminal.** A prompt placed inside an iteration over a data
  stream silently consumes the next record of that stream as the user's answer.
- **Reading input at end-of-input returns failure**, which under strict mode
  terminates the program rather than yielding an empty answer.
- **Expanding an empty array under strict mode is an error on older interpreter
  versions**, requiring a guarded expansion idiom that is easy to apply
  inconsistently — and was.
- **There is no structured data type**, so records are strings parsed with text
  tools, and every delimiter choice is a latent injection or mis-parse.
- **Configuration implemented as sourced code executes**, so a configuration file
  is an arbitrary-code channel rather than data.
- **Tracing execution is unusable as a debugging technique** where tests capture
  a function's combined output and assert it is empty, because the trace lands in
  the captured output.
- **Concatenating sources into a single deliverable means the deliverable and the
  sources can drift**, requiring mechanical enforcement that they match and
  requiring test tooling to be explicit about which of the two it exercises.

---

## 8. Why it went wrong

Defects were assessed by one question: would this have happened in a different
language with a different architecture? Those that would not are artifacts of
choices being discarded and are not reported. What remains clusters into a small
number of patterns.

### Pattern A — A human is assumed present on paths reachable unattended

Acquisition of missing information — credentials, confirmations, choices — was
implemented inline in code paths that also run without a terminal. Some such
points test for an interactive terminal first; others do not, and the
inconsistency is invisible from the call site.

*Evidence.* Verified by execution: starting a session on a machine that has a
registered tool-server requiring a credential it does not hold aborts the entire
launch when no terminal is attached — directly violating the invariant that
nothing about shared state may prevent a session from starting. Verified
separately, and worse: when two such servers are registered, the prompt for the
first consumes the second server's record as its answer, so a fabricated
credential is stored, written into the agent's live configuration as a bearer
header, *and propagated to every other machine*, while the second server is
silently dropped from the configuration entirely. Elsewhere in the same program
the opposite discipline is applied deliberately — an unattended session
explicitly declines to make a durable global decision about an unknown
repository and preserves the work instead — which is what makes this a
consistency failure rather than an oversight.

*Why it recurs.* The specific mechanism is language-dependent; the shape is not.
Any design that treats "obtain something missing" as a step inside a
data-processing pass, rather than as a distinct concern with an explicit answer
for the unattended case, reproduces this. The question — "what does this program
do when it needs an answer nobody is there to give?" — has to be answered once,
globally, not per call site.

### Pattern B — A global guarantee enforced per path

The program states properties that are supposed to hold everywhere, then
implements them as a check repeated at each site where someone remembered it.
Every site that was missed is a silent hole in a documented guarantee.

*Evidence.* The strongest case is the central invariant itself. "No condition of
the shared store may prevent an agent from starting" is implemented as a soft
validation on the session path — and then a *strict* validator, with no guard,
runs again moments later while translating the tool-server registry into the
agent's configuration. Verified by execution: with a malformed registry, the
soft check correctly degrades and the strict one immediately terminates the
program. This is precisely the lockout the invariant exists to prevent,
surviving on one unguarded path.

The same shape recurs across unrelated features. Verified by execution: the
machine's root directory can be mounted into a session that still describes
itself as sandboxed, via the primary-mount path's override, while the
additional-mount path refuses the identical request unconditionally and has no
override at all — the documentation asserts the two are symmetric. Whether the
program refuses to mount its own private state depends on whether a terminal is
attached: interactively the same condition is offered an upgrade to the
unisolated mode, which mounts it. The environment contract published for
third-party installers is documented as present in "every session" and is set by
one of the three kinds of agent run. "Has this machine an SSH key" has three
different definitions in three subsystems, and the boot-time restoration written
for one of them restores only one key type — so a machine whose only key is a
different standard type is reported healthy by the diagnostic while its shared
storage breaks at every reboot. Historically the platform-specific boot content
existed in three copies — installer, program, documentation — and had already
drifted by one line.

*Why it recurs.* Not about language. It follows from a capability count high
enough that many features plausibly need "the same thing", built at different
times by different reasoning. Nothing detects the divergence because the
guarantee has no single representation to diverge *from*.

### Pattern C — Checks that report success from an absence of evidence

Verification steps concluded "fine" when they had in fact examined nothing.

*Evidence.* A cross-machine consistency check reported agreement while zero
machines had published anything to compare — its comparison loop never executed,
so its difference counter stayed at zero and was read as concurrence. A readiness
probe for outbound authentication was performed as the wrong identity, which the
underlying service *does* serve, so a channel no session process could reach was
reported as working. A retention bound counted only records it could parse, so
unparseable records were never counted and never removed; the bound was measured
holding more than its limit while reporting nothing to remove.

*Why it recurs.* Wholly independent of language. It follows from encoding
"nothing was found wrong" and "nothing was examined" in the same value —
typically a zero counter or a boolean — which any implementation will do unless
the distinction is made explicit in the result.

### Pattern D — Guards keyed on a proxy rather than on the fact required

Conditions tested something correlated with what mattered, and the correlation
was later broken by an unrelated change.

*Evidence.* A feature that copied a version-control identity was guarded by the
absence of a configuration file; a different feature then began creating that
file for its own reasons, so the identity was never copied again and every
in-session commit on affected machines failed permanently and silently. A
recovery guard was placed behind an upstream-existence test, but the very
condition it recovered from detaches the head and makes upstream references stop
resolving — so it was skipped in precisely the state it existed to catch, which
is what turned a routine conflict into a machine unable to start an agent at all.
A compatibility probe intended to recognize machines onboarded under an older
scheme tests for the *presence of a file* and then stops, rather than for the
presence of the marker it is looking for — so a machine carrying a valid old
marker in the old location, plus an unmarked file in the new one, is reported as
never onboarded, which is the exact case the probe was written to handle.

*Why it recurs.* Language-independent. It arises whenever a condition is
expressed in terms of an observable side effect rather than the underlying fact,
and the coupling is invisible because the two features are unrelated in every way
except that one happens to touch the other's proxy.

### Pattern E — Identity and ownership assumed rather than established

Operations assumed the identity performing them was the identity that would later
need the result.

*Evidence.* Files created by the program while running privileged were unusable
by the unprivileged session moments later; a privileged session left state a
subsequent unprivileged one could not modify; an authentication channel was
established under one identity and consumed under another; version control
refused every mounted repository because its owner differed from the session's
identity. Each was found separately and fixed separately.

*Why it recurs.* The problem domain genuinely spans identity boundaries — host
account, session identity, container account, and remote identity are four
different things, and the target environments map them differently. Any
implementation faces this; what varies is whether the mapping is represented once
explicitly or rediscovered at each site.

### Pattern F — Cancellation and cleanup as an afterthought

Termination paths were less well specified than success paths, and the work that
must survive termination is precisely the work that captures state.

*Evidence.* Repeated interrupts intended to exit the interactive tool killed the
context capture that followed; restoring a signal handler by clearing it first
left a window in which a held keystroke terminated cleanup; cancelling an
unattended model invocation killed the client but left the container running and
consuming budget, because removal is handled by the daemon and not the client; an
interrupted self-replacement could leave a corrupted executable because the
staging location was on a different filesystem than the target.

*Why it recurs.* Independent of language. Cancellation is a cross-cutting concern
that cannot be added per-operation, and its correctness is observable only under
conditions inconvenient to reproduce — which is also why the original test for
one of these could not fail even against completely unprotected code.

### Pattern G — State whose scope does not match the lifetime of what it guards

A fact was recorded somewhere narrower than the hazard it was recorded about, so
the hazard outlived the record of it.

*Evidence.* A refusal to publish machine knowledge — triggered either by a
suspected secret in newly written content or by a failed structural check — is
held in memory for the duration of the run, while the content it refused to
publish stays exactly where it was written. The next run collects and publishes
it with no warning and no re-check. The same shape appears when machine
inspection fails partway: the check that declares failure looks at one artifact,
while anything else the agent already wrote remains staged for the next run to
collect. A credentials file is created with restrictive permissions on the
machine that writes it, but the transport carries no permissions, so every other
machine receives it at whatever its default mask produces — the protection
exists only where it was applied.

*Why it recurs.* Independent of language, and specific to this problem shape: the
program's whole purpose is moving state between processes, machines, and points
in time, so any decision recorded in process memory is recorded in the one place
guaranteed not to travel with the thing it describes. Every such decision needs
an explicit answer to "how long must this outlive the thing that made it", and
the default answer — the current process — is almost always wrong here.

### Census

Across the implementation's own recorded history and three independent readings
performed for this document, on the order of sixty distinct defects,
contradictions, and dead mechanisms were identified. Roughly half are defects
proper; the remainder are documentation that no longer describes behavior, and
mechanisms that were built, wired, and never reached — a layered settings model
whose shared tier nothing can write, a flag that changes nothing, fields written
and validated but never read, a legacy format probe for a format nothing has
produced in a long time. Those are not defects, but they are evidence for the
same conclusion.

Of the defects, most were found and fixed by the implementation itself, and its
own commit record documents several as having been deliberately reproduced
before being repaired. Six were verified by execution as still present during
this analysis, including two that violate stated invariants outright: a
non-interactive launch aborted by a missing credential, and a launch aborted by
malformed shared state. Applying the filter, somewhat more than half of the
defects survive as language- and architecture-independent; the remainder are
quoting, expansion, strict-mode, and text-parsing artifacts that a language with
real data types and explicit error handling would never have produced.

The survivors do not concentrate in a subsystem. They concentrate at
*boundaries*: between privileged and unprivileged identity, between interactive
and unattended execution, between this program and the tools it drives, between
one process and the next, and between the two container engines and the several
platforms targeted. That distribution is the evidence behind section 1.1. A
defect density concentrated in one area indicates a badly-built area; a defect
density concentrated at seams indicates too many seams. With roughly seventy
capabilities, nearly every one crossing at least one of those boundaries, the
feature count did exceed what a single coherent implementation could hold — not
because any individual capability was unreasonable, but because the number of
boundary crossings grows with the product of features and environments, and this
implementation was carrying both. The clearest single symptom is that the
program's most emphatically stated guarantee — that bookkeeping can never block
a session — is documented in its own decision record, enforced on the path that
record examined, and still violated on two other paths that reach the same
point.

---

## Appendix — Internal formats (reference only)

**This appendix is not a specification.** Everything in it was invented by the
prior implementation for talking to itself. None of it is a contract, and a
rewrite is under no obligation to reproduce any of it. It is recorded solely so a
migration path from existing installations can be written if one is wanted, with
an assessment of whether each format was actually a good idea.

**Shared store layout.** A single version-controlled working copy carrying:
per-machine directories (durable notes, a dated inventory, topic guides, a path
cache, machine-scoped continuation records, a published runtime description);
per-repository directories containing only continuation records; a repository
registry at the root; a tool-server registry and a separate credentials file;
global profile and preferences documents; and one shared extension tree.
*Assessment:* tiering machine knowledge by lifetime — always-loaded, on-demand
reference, on-demand procedure — was correct and worth carrying forward as a
concept. The rest was reasonable, but the whole-file-rewrite pattern is what
produced the conflict class in 7.3.

**Repository registry.** A flat object keyed by credential-free canonical origin,
each value carrying a status of `tracked` or `ignored` and, when tracked, a
project identifier. *Assessment:* keying on normalized origin rather than on path
or folder name was correct, and had to be arrived at by getting it wrong twice.
The single-file-for-all-entries shape was not: one file per entry would have made
the conflict class structurally impossible, and was identified as such but
deferred because it required a simultaneous migration everywhere.

**Machine path cache.** Per machine, an object mapping absolute checkout paths to
project identifiers and nothing else. *Assessment:* correct — deliberately
disposable, rebuildable, and carrying no identity of its own.

**Continuation record format.** A markdown document preceded by a single comment
line carrying project, machine, and timestamp, with a fixed set of five required
headings, and a filename derived from the same timestamp so lexical order equals
chronological order. Multi-scope output uses inline delimiter lines to separate
per-scope sections. *Assessment:* deriving order from the filename rather than
from the body was correct and fixed a real bug — but the header retained a date
that the display path still reads and that the generated agent instructions still
describe as the selection key, leaving three notions of ordering (filename,
header date, modification time) of which only one is authoritative. The project
field in that header is written by everything and read by nothing. The
delimiter-based multi-scope format is fragile for the reason given in 7.4.

**Tool-server registry.** An object under a `servers` key, each entry carrying a
URL and an authentication mode of `bearer` or `none`; credentials in a separate
key-value file with restrictive permissions, with a machine-local file taking
precedence over the shared one. *Assessment:* separating credentials from the
registry so the credential file alone can be excluded from sharing was elegant
and produced a per-machine credential mode for no extra code. Storing credentials
in version control at all is a deliberate, documented, defensible trade for this
threat model — and the first thing to revisit.

**Configuration files.** Shell-sourced key-value assignments, in a shared layer
overridden by a machine-local layer. *Assessment:* executable configuration is a
liability, and the shared layer was never reachable through the interface (1.2).

**Managed regions in other tools' files.** Comment-delimited blocks with distinct
begin and end markers, rebuilt at every session start, with surrounding content
preserved and content the other tool appended inside the region rescued out of
it. *Assessment:* necessary given the files are co-owned, but the rescue logic
patches one observed collision and is not general.

**Onboarding marker.** A versioned comment on the first line of the generated
inventory recording completion and generation time, with a fallback read of an
older location so machines onboarded under a previous scheme are recognized
rather than treated as new. *Assessment:* the fallback is the right instinct and
does not work — see Pattern D.

**Published runtime description.** A small per-machine object naming the program
version, its source revision, the container engine, and the agent-tool versions,
rewritten only when its content changes so ordinary sessions produce no churn.
*Assessment:* rewrite-on-change is exactly right and worth copying. The engine
field is written and validated but never read by anything, and the agent-version
string is a human-readable sentence rather than structured data, so comparing
machines is a string equality test that reports any formatting change as drift.

**Local state directory.** Configuration, the shared-store working copy,
per-agent home directories, machine-local credentials, a quarantine area for
rejected extension content, an update-check timestamp, a recorded install path, a
recorded source revision, and a cached description of the built environment.
Discovered either beside the installed executable — which is what makes a
self-contained relocatable install possible — or at a conventional location under
the user's home. *Assessment:* the "state beside the executable wins" rule is
what makes the appliance platform workable and is worth keeping as a concept; the
specific contents are incidental.

**In-container layout.** A fixed home directory shared by every session, with the
shared extension tree mounted at each agent's native extension path, this
machine's knowledge directory mounted writable, all machines' knowledge and all
repositories' continuation records mounted read-only, and forwarded sockets at
fixed absolute paths. *Assessment:* mounting the shared tree directly at the
agent's native path — rather than materializing copies into it — removed an
entire class of second-source-of-truth problems and was the single best
structural decision in this area.
