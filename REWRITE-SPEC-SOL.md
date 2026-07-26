# Satchel Ground-Up Rewrite Specification

This document is intentionally architecture-free. It describes the problem
Satchel exists to solve, the external facts a replacement must respect, and
the decisions that remain open. It does not preserve the current
implementation's structure, lifecycle, storage model, or internal protocols.

## 1. Decisions not yet made

### Open questions

**Is the product trying to support too many capabilities at once?** The current
behavior spans isolation, privileged host work, credentials, clipboard access,
repository identity, distributed synchronization, model-generated handoffs,
machine knowledge, tool configuration, skill distribution, installation,
updates, diagnostics, and appliance boot persistence. Keeping all of them
preserves convenience; cutting or deferring some of them reduces the number of
trust boundaries and cross-product interactions that must remain coherent.
Section 8 provides the defect-density evidence behind this question.

**What remains useful without cross-machine synchronization?** Current setup
messages say handoffs, integrations, and skills remain local, while actual
behavior makes those capabilities unavailable. Local operation gives a useful
single-machine product and a graceful offline path; requiring synchronization
gives one simpler capability boundary and less duplicate state.

**What is the precise promise of a normal session?** The product calls it a
sandbox, yet accepts a configured root identity and gives the agent a
persistent credential-bearing home plus network access. A stronger boundary
limits damage and disclosure; a convenience boundary allows authenticated tools
to work naturally but must not be described as containing identity or secrets.

**Should host-wide access and sandbox bypasses exist at all?** Host access is
valuable for machine repair, and mounting a home directory can be useful for
deliberate broad work. Both make a mistaken invocation materially dangerous.
The decision must cover discoverability, confirmation, automation, and whether
environment-only switches may activate either behavior.

**Which host capabilities should be forwarded by default?** SSH signing and a
live graphical clipboard remove common friction. They also let an agent
authenticate as the user, read newly copied secrets, and on some compositors
exercise capabilities wider than clipboard access. Per-session consent is safer
but repetitive; machine-level defaults are convenient but easy to forget.

**Must passphrase-protected host keys work in an automatically created
agent?** Feeding key bytes through standard input avoids a sandbox-readable
copy, but may not preserve the normal terminal prompt behavior of loading a key
by filename. Supporting that interaction improves convenience; excluding it
makes the credential boundary simpler and more predictable.

**What is the trust boundary of persistent agent state?** Reusing the agent's
login and conversation state avoids repeated authentication and enables
continuity. It also gives every session access to durable credentials and
transcripts that may be disclosed over the network. The product must decide
whether that agent is trusted with the whole persistent identity or receives a
narrower delegated identity.

**How should repositories acquire stable identity?** Network origins are
portable but have many equivalent spellings and can change. Local or
network-filesystem repositories lack a portable origin and currently depend on
user assertion. Stronger identity avoids accidental cross-project attribution;
weaker identity is easier to understand and works with more repositories.

**Where should repository tracking decisions apply?** A global decision makes
the same repository behave consistently on every machine. A machine-local
decision handles different purposes, permissions, and checkout topologies.
Either choice needs explicit behavior for origin changes, multiple checkouts,
nested repositories, missing origins, and stale paths.

**Should repository classification depend on model judgment?** Asking only
after substantive work avoids prompts caused by casual inspection. Letting a
model decide what was substantive makes a durable tracking decision depend on
probabilistic output. Deterministic activity signals are more predictable but
cannot reliably distinguish reading from meaningful investigation.

**What is a handoff, and when is one warranted?** Conversation continuity can
be based on transcript changes, explicit user intent, observed repository
changes, model judgment, or some combination. Each choice trades missed useful
context against needless model calls and noisy notes.

**How authoritative may a generated handoff be?** A model can summarize intent
and unresolved reasoning that no filesystem diff contains, but it can omit,
misattribute, or invent work. A handoff may be advisory prose, validated
structured state, or a blend; the replacement must state which facts later
sessions may trust.

**What establishes handoff chronology and uniqueness?** Current instructions
name one source of freshness while retention uses another, and two writes in
the same second can collide. Human-readable timestamps are convenient;
monotonic or content-derived identities are safer across clock skew,
concurrency, locale, and malformed content.

**How much history belongs in active context?** A larger retained set helps a
user reconstruct how work evolved, while a smaller set limits synchronized
tree size and stale context. Git history may be sufficient recovery, but only
for users willing to inspect it.

**What knowledge should be maintained about each machine?** Concise current
warnings, broad dated inventory, repeatable procedures, and unfinished work
have different lifetimes. A richer system is useful across machines but relies
heavily on agents following editorial rules; a narrower system is easier to
keep current.

**How much authority should machine inspection receive?** Useful inventory
requires broad read access. Persisting approved conclusions requires some write
access, but the present boundary is wider than the stated approval target and
its secret checks are not durable. The replacement must decide whether
approval is enforced mechanically, socially, or by eliminating automatic
writes.

**What does synchronization guarantee?** Possible promises include best-effort
eventual propagation, confirmed remote durability, conflict-free logical
merging, or merely a recoverable local commit. Stronger guarantees require more
coordination; weaker guarantees must make pending and divergent work obvious.

**Who resolves concurrent changes?** Automatic field-level merging is
convenient but can choose a semantically wrong result. Human reconciliation
avoids guessing but makes ordinary independent edits block propagation.
Conflict-resistant representation can reduce the issue but introduces a
migration decision for existing installations.

**What may an automatic synchronization publish?** Publishing every change in
the private state clone is simple and preserves manual edits, but can commit
unrelated or unreviewed content. Publishing only changes attributable to the
current operation is safer but requires provenance and leaves manual changes
for an explicit path.

**How are synchronized formats versioned and migrated?** Lenient readers let
newer machines add fields without disabling older ones. Explicit versions and
migrations make incompatible changes legible but create upgrade coordination.
The current mixture of permissive fields, hostile rejection of one older
format, and selective legacy fallbacks is not a coherent policy.

**How does a caravan move to a different remote?** Requiring an exact match
prevents accidental split-brain state. It also rejects equivalent remote
spellings and leaves deliberate migration undefined. A migration workflow must
choose which remote is authoritative and how unpushed work is preserved.

**Are preferences global or machine-local?** The interface advertises both
scopes, but all currently exposed settings are machine-local. Global
preferences reduce repetition; local settings better represent engines,
identities, and hardware-specific permissions.

**What is the settings data model?** Executable shell assignments are easy for
humans and dangerous before validation. A data-only format is safer but needs
clear typing, clearing semantics, forward compatibility, and migration from
existing installations.

**Who owns agent-native integration configuration?** Rebuilding the whole
native section makes the registry authoritative but can delete entries created
by users or other managers. Merging preserves coexistence but must understand
third-party formats that can evolve independently.

**What does integration health mean?** TCP or HTTP reachability, successful
authentication, and a valid protocol exchange are different claims. A strict
health command catches more failures but turns temporarily powered-off home-lab
services into red status; a reachability report is less disruptive but must not
claim the service is healthy.

**What should happen when a required token is absent?** Prompting preserves a
guided interactive experience. Omitting the integration lets noninteractive
sessions continue; failing makes incomplete configuration impossible to miss.
The choice must not depend accidentally on whether standard input happens to be
a terminal.

**What does validating a skill mean?** Package-boundary validation can prove
that a complete, self-contained bundle is safe to synchronize. It cannot prove
that instructions are correct or scripts are trustworthy. Semantic validation
offers stronger assurance but makes Satchel a skill interpreter and trust
manager.

**Should user skills be shared across agents by default?** One library makes
installation predictable across machines and agents. Per-agent selection
avoids exposing one agent to untested instructions or another agent's
runtime-owned content. Either choice must define ownership of reserved runtime
entries.

**What are the release and reproducibility promises?** Floating operating-system
and agent versions make updates immediately useful but let two machines behave
differently without a source change. Pinned artifacts and a stable channel are
reproducible but require release management and an explicit upgrade policy.

**What must update success mean?** Replacing the launcher before rebuilding its
runtime can leave a mixed version after failure. Transactional update and
rollback are safer; independent, retryable phases are simpler but must not
report a partially updated system as complete.

**Should diagnostics be read-only?** Updating caches and probing networks can
make a report more current, but surprises callers who expect observation only.
A pure report is safer for automation; an active diagnostic can discover more
but needs declared side effects and severity rules.

**What counts as success, warning, cancellation, or failure?** Current commands
sometimes return success for absence, cancellation, offline propagation, and
partial cleanup, while one onboarding failure shares the command status a
normal session would use. Stable automation needs a deliberate exit-status
contract.

**How much appliance-specific behavior belongs in the product?** Supporting a
RAM-backed root filesystem requires persistent placement, boot restoration,
key handling, and protection of a boot-critical script. Keeping this support
serves a real target; separating or cutting it reduces high-consequence
platform-specific code.

**Are appliance detection and path overrides public API or test seams?**
Supporting overrides makes unusual installations and safe off-platform testing
possible. Treating them as public creates more frozen host-path behavior;
treating them as private permits change but requires another way to test
boot-critical behavior without touching the real machine.

**Should private keys ever be persisted on unencrypted removable media?**
Automatic reboot recovery is convenient. The medium is readable by anyone with
physical access, and the program cannot prove that the key is restricted to
the private synchronization repository.

**How should command-line ownership coexist with third-party CLIs?** Recognizing
Satchel flags on either side of the agent name makes wrappers feel natural but
can silently consume a present or future agent flag. A delimiter or stricter
position is less magical and more forward-compatible.

### Capability disposition table

The final column is intentionally blank for product review.

| Exposed capability | Keep / cut / defer |
| --- | --- |
| Install from a published shell entry point | |
| Initialize a named machine | |
| Connect to a user-owned private Git remote | |
| Operate on one machine without a remote | |
| Launch Claude Code | |
| Launch Codex | |
| Run a restricted project session | |
| Run a host-wide root session | |
| Override the home-directory safety refusal | |
| Add multiple working directories to one session | |
| Redirect native `claude` and `codex` commands through Satchel | |
| Build or rebuild the shared agent runtime | |
| Preserve agent authentication and conversations between sessions | |
| Import existing host agent authentication | |
| Forward SSH-agent signing access | |
| Start a temporary SSH agent from standard host keys | |
| Generate and display a machine SSH public key | |
| Persist SSH material across RAM-backed-root reboots | |
| Forward a live Wayland or X11 clipboard | |
| Track a repository as a named project | |
| Ignore or untrack a repository across machines | |
| Discover nested and newly created repositories in visible roots | |
| Normalize network origins into portable repository identity | |
| Attribute work to the nearest tracked repository | |
| Generate continuation handoffs from agent conversations | |
| Generate separate handoffs for several projects and machine work | |
| Retain and prune bounded handoff history | |
| Share global profile and preference context | |
| Maintain concise machine notes | |
| Maintain dated machine inventory | |
| Maintain reusable machine guides | |
| Offer first-use machine inspection and later refresh | |
| Synchronize user state across machines | |
| Continue sessions when synchronization is unavailable or malformed | |
| Register, list, probe, and remove MCP servers | |
| Store MCP tokens globally or per machine | |
| Materialize MCP configuration for both agents | |
| Share a user skill library across agents and machines | |
| Validate and quarantine malformed skill bundles | |
| Restore a previous valid skill bundle | |
| List and remove shared skills | |
| Configure machine and caravan settings | |
| Report local and caravan status | |
| Diagnose tools, engine, image, mounts, SSH, sync, drift, and MCP endpoints | |
| Publish runtime-version information for cross-machine comparison | |
| Show command help and the installed version | |
| Produce terminal-aware, disableable color output | |
| Check for updates in the background | |
| Self-update the installed command and agent runtime | |
| Retire a machine from shared state | |
| Uninstall the program while preserving local state | |
| Purge local state | |
| Remove owned stopped containers and the shared image | |
| Maintain appliance boot restoration links and keys | |

## 2. What the program is for

Satchel's highest-priority value is letting a user give capable coding agents a
bounded place to work without first assembling a container command, copying
credentials, rebuilding tool configuration, or explaining the environment on
every launch. A normal invocation should feel like launching the native agent,
while the user can still understand what the agent can see, change, and
authenticate as.

Its second value is continuity. Work should remain resumable after a disposable
session ends and when the user moves to another machine. That continuity
includes the intent and unresolved reasoning that a filesystem diff cannot
capture, but it must not confuse one repository's work with another's or turn
bookkeeping failure into loss of access to the agent.

Its third value is one-time configuration for a small personal fleet. The user
should not repeatedly register the same integrations, reinstall the same
skills, or rediscover the same durable machine constraints. Private state
remains under the user's ownership and recoverable with ordinary tools.

Finally, it should make dangerous work explicit. When the user deliberately
needs the real host, the boundary changes visibly and honestly. Convenience
must not come from silently widening access, publishing credentials, deleting
uncertain data, or claiming safety that the environment does not provide.

## 3. Invariants

- A restricted session must never receive host paths outside the roots and
  capabilities the user explicitly placed in scope. It must never be described
  as restricted if a home directory, private Satchel state, or the whole host is
  exposed.

- Host-wide access must never be mistaken for sandboxed access. The user and
  the agent must both know that changes beneath the host view affect the real
  machine.

- A synchronization failure, malformed synchronized record, conflict,
  unavailable remote, or version skew must never prevent the user from
  launching an otherwise usable agent session.

- Failed synchronization must never lose the only local copy of work or leave
  the user's clone in an unfinished merge, rebase, cherry-pick, or revert.

- Durable files whose partial content would be destructive must never be
  replaced by truncating the live copy. Failure must leave either the previous
  valid content or a clearly recoverable candidate.

- No unrelated executable, redirect, state tree, container, image, project,
  machine record, skill, integration, or remote repository may be overwritten
  or deleted without proof of ownership or an exact user-authorized target.

- Uninstalling or retiring one machine must never delete shared projects,
  shared skills, other machines, or the upstream private repository.

- Agent login credentials and conversation transcripts must never enter
  cross-machine synchronization. Private key files must never be mounted into
  an agent session.

- Secret values must never be printed, embedded in process arguments, included
  in generated instructions, or echoed by a validation warning.

- A configuration value that means "no authentication" must never cause an
  old credential to be attached. Two logical integration identities must never
  collapse onto one credential channel.

- A model or a folder name must never be able to invent portable repository
  identity. Work must never be filed under a project the session could not
  actually reach.

- Failure, timeout, cancellation, malformed model output, or incomplete
  attribution must never replace a previously valid handoff with a less
  trustworthy one.

- An unattended continuation writer must never gain access to project content,
  host files, SSH signing, clipboard contents, integrations, shared skills, or
  machine state merely because the interactive session had that access.

- A machine inspection must never change the host. Content suspected of
  containing secrets must never be synchronized merely because a later process
  forgot the earlier suspicion.

- Materializing managed configuration must never discard third-party
  configuration the product does not own.

- Invalid or incomplete shared skill attempts must never poison other machines.
  They must remain recoverable for diagnosis.

- A diagnostic must never claim agreement, health, successful deletion,
  successful propagation, or successful update without evidence for that exact
  claim.

- User interruption must never corrupt durable cleanup. A deliberately
  cancellable background model call must not continue consuming resources
  after cancellation.

- A boot-critical appliance script must never be installed empty, malformed,
  partially written, or with an unresolved command target.

## 4. Frozen external contracts

This section contains only names and formats that a replacement would break for
users, existing installations, or third-party tools if changed. Internal
formats appear only in Appendix A.

### Published installation entry points

The documented network installation command is:

```sh
curl -fsSL https://raw.githubusercontent.com/SwaggyMike/satchel/main/install.sh | bash
```

The documented persistent-install form is:

```sh
curl -fsSL https://raw.githubusercontent.com/SwaggyMike/satchel/main/install.sh | SATCHEL_BIN=/mnt/user/appdata/satchel bash
```

`SATCHEL_BIN` means an installation directory, not an executable path.
`SATCHEL_DIR` overrides the local state location. `SATCHEL_SHIMS=y` enables
redirect creation; other values disable it.

### User-facing command grammar

The executable name and these command names are published:

```text
satchel [--host] [--unsafe-home] [--with <dir>] <command> [args]

satchel claude [args]
satchel codex [args]
satchel track [id]
satchel untrack [id]
satchel init
satchel sync
satchel status [--ignored]
satchel skills [list]
satchel skills remove [name]
satchel key [--persist]
satchel retire [machine]
satchel import claude|codex
satchel mcp add [name] [url] [--no-auth]
satchel mcp list
satchel mcp remove [name]
satchel settings
satchel settings <KEY> <value> [--local]
satchel doctor
satchel link [claude|codex]
satchel unlink [claude|codex]
satchel image [--rebuild]
satchel update
satchel uninstall [--purge] [--yes|-y]
satchel version
satchel help
```

The redirect command names `claude` and `codex` are published. Arguments not
owned by Satchel are passed to the corresponding third-party CLI.

### Terminal output conventions

`NO_COLOR` disables ANSI color. `CLICOLOR_FORCE=1` enables color when
`NO_COLOR` is absent and `TERM` is not `dumb`. Without the force setting,
color is emitted only to a terminal. These are user- and ecosystem-facing
conventions rather than an internal rendering decision.

### Exit status behavior

`0` means the requested operation completed or reached a documented benign
outcome such as cancellation, no change, a skipped handoff, or a best-effort
network warning. `1` is the general refusal, validation, health-check, setup,
or command failure. A normal agent session returns the third-party agent
process's exit status. `130` is propagated when startup or machine inspection
is interrupted with Ctrl-C.

These distinctions are relied on by shell callers even though the current
documentation does not fully describe them. Section 1 leaves open whether the
semantics should be refined; compatibility requires deliberate migration
rather than accidental change.

### Existing redirect formats that removal must recognize

A current redirect is an executable named `claude` or `codex` containing:

```sh
#!/usr/bin/env bash
# satchel shim
exec <shell-escaped-absolute-satchel-path> claude "$@"
```

or:

```sh
#!/usr/bin/env bash
# satchel shim
exec <shell-escaped-absolute-satchel-path> codex "$@"
```

Older redirects may contain either of these narrow legacy forms and must still
be detected without treating an unrelated executable that merely mentions
Satchel as owned:

```sh
exec satchel claude "$@"
exec satchel codex "$@"
```

An existing installation can also prove its command path with a one-line
record containing the installed command's path. Removal must continue to
recognize installations at `/usr/local/bin/satchel`,
`$HOME/.local/bin/satchel`, and self-contained installations whose adjacent
state carries either that path record, an installed-script hash, or a machine
configuration marker.

### Third-party agent CLI grammar

Interactive invocation depends on these public third-party forms:

```text
claude [args]
codex -c 'sandbox_mode="danger-full-access"' -c check_for_update_on_startup=false [args]
```

Conversation continuation currently depends on:

```text
claude --continue --strict-mcp-config --tools "" --effort low -p <prompt>
codex exec resume --last --skip-git-repo-check --ignore-user-config --ignore-rules -c 'sandbox_mode="danger-full-access"' -c 'model_reasoning_effort="low"' <prompt>
```

Machine inspection currently depends on:

```text
claude <prompt>
codex -c 'sandbox_mode="danger-full-access"' -c check_for_update_on_startup=false <prompt>
```

These are third-party contracts to revalidate against supported agent
versions, not recommendations for the rewrite's architecture.

### Third-party agent authentication and configuration formats

Existing Claude authentication may be present at:

```text
~/.claude/.credentials.json
~/.claude.json
```

The latter may indicate authentication through a non-empty `oauthAccount` or
`primaryApiKey`. Existing Codex authentication is:

```text
~/.codex/auth.json
```

Claude's native MCP configuration is the JSON object `mcpServers` in
`~/.claude.json`. An HTTP server has the third-party shape:

```json
{
  "mcpServers": {
    "<name>": {
      "type": "http",
      "url": "<url>",
      "headers": {
        "Authorization": "Bearer <token>"
      }
    }
  }
}
```

The `headers` object is absent when no credential is used.

Codex's native MCP configuration is TOML under
`~/.codex/config.toml`:

```toml
[mcp_servers.<name>]
url = "<url>"
bearer_token_env_var = "<environment-variable-name>"
```

The bearer-token line is absent when no credential is used. Codex may also
write nested per-tool approval tables and project trust tables to this file;
they are third-party-owned content and must survive managed changes.

### External SSH and Git contracts

SSH-agent forwarding uses the standard `SSH_AUTH_SOCK` protocol. The effective
client identity is determined by operating-system peer credentials, not socket
file ownership. `ssh-add -l` returns `0` when identities are loaded, `1` when
an agent answers with no identities, and a different non-zero status when no
usable agent answers.

Git repository trust uses the public `safe.directory` configuration key.
Commit identity uses `user.name` and `user.email`. Git-over-SSH first-contact
behavior currently relies on:

```text
GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=accept-new
```

Git remote syntax must continue to accept local paths and common
`ssh://`, `git://`, `http://`, `https://`, and SCP-like
`user@host:path` forms.

### Existing appliance boot markers

Removal and migration must recognize the exact markers:

```sh
# >>> satchel boot persistence >>>
# <<< satchel boot persistence <<<
```

An opening marker without a closing marker is ambiguous and must not be
rewritten or removed automatically.

## 5. Capabilities

### Installation and initialization

The product must establish a runnable command, optionally preserve the familiar
agent command names, identify the machine, and make incomplete setup
recoverable. It must never overwrite an unrelated command, delete uncertain
pre-existing state, or claim readiness before the selected agent runtime can
launch.

### Restricted agent sessions

The product must run either supported coding agent with a clearly stated,
bounded view of user-selected work and enough persistence to remain logged in.
It must never expose the user's home, private orchestration state, or arbitrary
host paths while calling the session restricted.

### Host-wide sessions

The product must allow deliberate machine-repair work when that capability is
kept. It must never obscure that the session is root-equivalent, that the
container is packaging rather than protection, or which path denotes the real
host.

### Multi-directory work

The product must let one session work across explicitly selected directories
when tasks span repositories. It must never let symlinks, broad ancestors, the
filesystem root, a home directory, or private state widen the declared scope
accidentally.

### Agent identity and continuity

The product must preserve the authentication and conversation state needed for
the native agent experience across disposable sessions. It must never
synchronize those credentials or transcripts between machines, and it must
state the disclosure boundary created by giving them to a network-capable
agent.

### SSH-backed Git work

The product must let a session use authorized SSH signing without exposing
private key files, and must report whether the forwarded agent is usable from
the session's actual UID. It must never infer that every remote will work from
socket reachability alone or send the user debugging a credential problem that
can only be fixed on the host.

### Graphical clipboard access

The product must support image pasting from graphical Linux hosts when the
capability is enabled. It must never imply that forwarding a compositor socket
is limited to one static clipboard value or is equivalent to no desktop
access.

### Repository identity and tracking

The product must maintain stable user decisions about which repositories
receive project-specific continuity and which do not. It must never derive
identity from a folder name, embed credentials in portable identity, merge
different origins under one project, or treat an ordinary directory as a
repository.

### Work attribution

The product must associate continuation context with the repository where work
actually occurred, including nested repositories and sessions that can see
several projects. It must never let launch location override a nearer
repository or accept a model-invented project that was not visible.

### Handoff generation

The product must preserve goals, completed work, in-flight state, next steps,
and important hazards after meaningful work. It must never replace a valid
handoff after timeout, cancellation, malformed output, an empty session, or
failed attribution.

### Isolated handoff writing

The product must be able to resume the relevant conversation without giving
the unattended writer the interactive session's project or host authority. It
must never leave a cancelled writer running, spending tokens, or holding
resources.

### Machine knowledge

The product must make durable machine-specific facts and reusable procedures
available where they prevent repeated mistakes. It must never turn resolved
incidents into permanent startup context, present dated inventory as live
truth, or silently publish suspected secrets.

### Machine inspection

The product must support conservative discovery of hardware, operating-system,
storage, networking, services, containers, and operational constraints when
kept. It must never alter the host, bypass user approval for durable
conclusions, or let failure-state edits escape later validation.

### Cross-machine synchronization

The product must propagate approved portable state through a private remote
while preserving useful local operation during outage, conflict, corruption,
or skew. It must never destroy local work, guess through a semantic conflict,
or leave recovery state that prevents the next session from launching.

### Integration registration

The product must let a user register, inspect, diagnose, and remove remote MCP
servers once for the intended scope. It must never attach a credential to an
unauthenticated registration, conflate distinct server identities, or report a
removal that did not occur.

### Integration credentials

The product must make required bearer credentials available to the native
agent without printing them or placing values in engine arguments. It must
never imply that a private Git remote erases the consequences of credential
history or that inherited environments are a complete secret boundary.

### Native configuration coexistence

The product must express managed integrations in each supported agent's native
format. It must never discard user-owned servers, learned trust decisions,
approval choices, or future third-party fields merely because they share the
same configuration document.

### Shared skills

The product must preserve complete user-installed skill bundles across the
selected agents and machines. It must never synchronize nested repository
metadata, escaping links, incomplete packages, or runtime-owned entries as
ordinary user skills.

### Skill recovery and removal

The product must preserve malformed attempts for diagnosis, keep the last
known-valid package recoverable, and remove an exact user-authorized skill when
requested. It must never guess at installer-owned metadata or treat a generic
name as permission to delete a different target.

### Settings

The product must expose supported preferences, their effective values, their
scope, and a genuine way to clear an override. It must never execute
unvalidated synchronized content, accept values that cannot satisfy the
declared type, or advertise a scope no setting uses.

### Status and diagnostics

The product must distinguish configured, available, healthy, synchronized,
pending, divergent, missing, and unknown states where those differences affect
the user's next action. It must never report agreement from no data, call an
HTTP error a healthy protocol service, hide unpushed durable work, or make an
observational command unexpectedly destructive.

### Runtime drift reporting

The product must make meaningful differences among machines visible when
runtime inputs are not reproducible. It must never compare fields selectively
while implying complete agreement or present a stale report as current.

### Updates

The product must discover and install an intended release without being fooled
by a stale branch cache, and it must leave a coherent, retryable installation.
It must never execute a partial artifact, mix new code with an old runtime
silently, or trust syntax validation as artifact authentication.

### Machine retirement

The product must remove exactly one machine's portable state when requested
and make local-state removal a separate decision. It must never broaden that
decision to projects, shared state, other machines, or the remote itself.

### Uninstallation

The product must remove only artifacts provably owned by the selected
installation and must distinguish preserving from purging local state. It must
never stop an active session, remove an unrecognized container, delete a
checkout mistaken for an installation, or erase unpushed work without an
explicit destructive choice.

### RAM-backed-root persistence

The product must remain usable after reboot on supported systems whose root,
root home, and command directories are rebuilt from persistent boot media. It
must never damage the boot-critical script, claim a key will return when the
restoration pattern excludes it, or hide the security consequences of
plaintext flash storage.

## 6. Environmental reality

### Platform targets

The observed target is personal or home-lab Linux, including Debian-family
containers, Fedora-family SELinux hosts, Docker, rootful and rootless Podman,
and Unraid. A replacement cannot assume a desktop, a non-root invoking user, a
mutable root filesystem, a configured global Git identity, or a repository
working directory.

Some supported invocations occur inside another application container. A
container-engine daemon can bind only paths visible in the daemon's filesystem,
not necessarily paths visible to its client. A nested launch is unsupported
when a real bind-mount probe shows that the engine cannot see the local state.

### External dependencies

The present product depends on Bash, Git, `jq`, cURL, OpenSSH client tools,
Docker or Podman, and common core utilities. Building the current agent
environment additionally depends on network access to a Linux base image,
Debian package repositories, npm, Claude Code, and Codex. Graphical clipboard
support depends on Wayland or X11 access and suitable clipboard clients.

The agents themselves, Git hosts, MCP servers, container registries, package
registries, and the user's private Git remote are independently versioned and
may be offline, slow, misconfigured, or mutually incompatible. Reporting and
session launch must not treat every external outage as a local corruption.

### Identity and permissions

Linux bind mounts preserve host ownership. A root-run host combined with an
unprivileged session therefore produces readable but potentially unwritable
worktrees. Git 2.35 and later can reject such repositories even when ordinary
reads succeed because repository ownership is also a trust decision.

Supplementary groups, ACLs, immutable flags, and unwritable descendants mean
that checking only the mount root's owner and mode bits cannot prove
writability. Any preflight can at most provide evidence and actionable
warning, not a guarantee.

SELinux label separation can prevent a container from reading bind-mounted
user files and sockets. Relabeling arbitrary project directories mutates host
security metadata and still does not solve every socket case, so support must
state the chosen isolation tradeoff.

### Timeouts and bounds

The current values below are user-observable limits, not architectural
recommendations. Where the evidence does not establish that the number itself
is correct, retaining or changing it is an open product decision.

| Current bound | Why a bound exists |
| --- | --- |
| 5 seconds for an individual MCP HTTP probe | A powered-off home-lab endpoint must not hold a command indefinitely. Total diagnostic time still grows with the number of endpoints. |
| 5 seconds for the background release check | Update discovery is incidental to session launch and must remain cheaper than the work the user requested. |
| One background release check per 86,400 seconds | Repeated launches must not repeatedly contact the update host; the stamp is written even when offline to cap failure noise. |
| 10 seconds for the diagnostic remote-reachability check | A health report needs evidence about the remote but must return promptly when DNS, network, or SSH is unavailable. |
| 20 seconds for launch-time synchronization pull | Synchronization is bookkeeping and cannot indefinitely delay the interactive product. |
| 30 seconds for best-effort synchronization integration and push | Durable propagation deserves more time than an update hint, while session cleanup must still finish predictably. |
| 30 seconds each for strict retirement pull and push | A destructive cross-machine action needs confirmed remote state but must not hang forever. |
| 240 seconds for unattended handoff generation | Resuming a long transcript can be slow; a bound prevents runaway cost and a permanently blocked shell. The current duration can still be a substantial exit delay. |
| 100 retained handoffs per project or machine scope | Active continuity needs more than a few recent notes, but synchronized state is not intended as an unbounded incident archive. Older content remains recoverable from Git history. |
| 750 words for always-loaded machine notes | Startup context must remain small enough that warnings stay visible. This is a soft editorial bound because deleting essential safety information to meet it would be worse. |
| 30 lines requested per generated handoff | Concision improves startup context. The current behavior does not enforce the limit, so whether it is a real contract is unresolved. |

Explicit synchronization, some initialization and registration paths, image
builds, downloads, and some retirement work presently have no complete timeout
bound. DNS, SSH authentication, credential prompts, engine operations, and
package downloads can therefore wait indefinitely. The rewrite must decide
which of those are interactive long-running operations and which need a
deadline.

### Ordering constraints imposed by causes

SSH readiness must be established before the first private-remote operation,
because an initially empty desktop agent may become usable after loading a key;
probing earlier avoids falsely reporting the remote offline.

Any native configuration derived from synchronized state must be based on
validated input, because parsing it again after declaring synchronization
degraded can reintroduce the fatal condition the degradation boundary was
meant to contain.

The last host-side write to persistent agent or shared state must be complete
before the unprivileged agent consumes it, because root-run hosts and
host-wide sessions can otherwise leave unreadable content behind.

Repository visibility must be reconsidered after a session when attribution
depends on repositories created during that session. This does not imply a
particular scan or lifecycle; it follows from the fact that the set may have
changed.

Durable handoff or synchronization work must be protected from interrupt
spillover after the foreground TUI exits, because repeated terminal signals
can outlive the process the user intended to stop.

Release identity must be resolved before immutable download when the branch
content endpoint is cached. A running process must not be asked to finish an
update with logic that existed only in the newly downloaded artifact.

## 7. Hard-won knowledge

The entries below are facts about external systems and observed behavior that
are expensive to rediscover. They do not prescribe the rewrite's architecture.

### Operating systems, identity, and permissions

**OpenSSH agents authenticate local clients by peer credentials.** Changing a
socket's owner or mode does not change the UID of the agent process, so an
agent started as root can reject a non-root session even when that session can
open the socket. A probe made as root can therefore report readiness while the
session's UID is rejected.

**A reachable SSH agent may contain no identities.** A socket path and a
successful connection do not imply that signing will work. OpenSSH
distinguishes an agent with identities, a reachable empty agent, and no usable
agent through different `ssh-add -l` statuses.

**A usable agent does not reproduce the host's SSH configuration.** Forwarding
signing identities does not forward host aliases, custom usernames, ports,
`IdentityFile` selection, proxy commands, or other per-host rules. A remote
that depends on those rules can fail while ordinary forge remotes succeed.

**OpenSSH resolves `~` through the passwd database rather than `$HOME`.** When
the two disagree, trust records and other SSH state go to an unexpected,
possibly disposable directory. A root session can also encounter a host-style
root-home symlink that is meaningless inside a container.

**A numeric UID need not have a passwd name.** Utilities that require a login
name cannot reliably drop privileges to an arbitrary configured numeric UID.

**An open file descriptor survives a credential drop.** A privileged process
can open a key that the target UID cannot read and let a child consume the
already-open descriptor after changing identity. This avoids creating another
readable pathname, but changes how interactive passphrase prompting behaves and
does not itself prove that a prompt will reach the terminal.

**Docker's legacy build shell may run as root and PID 1.** Debian account tools
can refuse to modify the account currently in use, including root, even during
an image build.

**Rootless Podman can synthesize a passwd entry for a keep-ID user.** The
synthesized home can disagree with the persistent agent home, especially for
custom UIDs absent from the image.

**Git rejects some repositories owned by another UID.** Since Git 2.35,
readability does not imply trust; commands can fail with “detected dubious
ownership” until the exact worktree is declared safe.

**Creating Git trust configuration can mask missing commit identity.** A new
configuration file may exist only because safe-directory entries were written.
File existence therefore does not prove that `user.name` and `user.email` are
available.

**SELinux relabeling is not a neutral mount option.** Relabeling changes host
metadata on the user's project, and socket coverage remains incomplete.
Disabling label separation is a documented container-engine tradeoff, not a
way to preserve the original SELinux boundary.

**A read-only filesystem mount does not make devices and sockets harmless.**
Reading or connecting to a special file can cause side effects even when
ordinary file writes are prohibited.

### Container engines and graphical systems

**A container client and its daemon may see different filesystems.** This is
common when the client runs inside an appliance add-on but talks to an engine
outside it. Command presence and daemon reachability do not prove that required
bind sources exist from the daemon's perspective.

**Codex's inner Linux sandbox can fail inside an already restricted
container.** Namespace creation may be forbidden even when the outer container
is otherwise healthy, causing all tool execution to fail until one boundary is
chosen as authoritative.

**Docker does not accept every intuitive PID namespace spelling.** Private PID
namespaces are the default; an invented explicit value can be rejected even
though the intended isolation is supported.

**A container init helper assumes a private PID namespace.** Combining an
engine-provided init process with the host PID namespace is rejected or
meaningless because the host already has its own init and reaping behavior.

**Rootless engines may hide ancestor PIDs.** Seeing PID 1 alone does not prove
which namespace is in use; the identity of PID 1 matters when validating
isolation.

**Killing the container-engine client does not guarantee daemon-side
termination.** A helper started with automatic removal can remain alive after
timeout or cancellation and continue spending model tokens. A predictable name
can also collide with an unrelated container, so force removal based only on
the name can delete somebody else's container.

**Wayland accepts an absolute display socket path.** A client can use a socket
mounted at a fixed absolute path without recreating the host's runtime
directory.

**X11 access is broader than Wayland clipboard access.** X11 clients can
observe more desktop input, while some Wayland compositors expose additional
protocols such as screen capture or virtual input through the same compositor
connection. A “clipboard” label understates the possible authority.

### Git and distributed state

**An empty Git remote has no upstream branch.** “No upstream yet” and a broken
or offline upstream can otherwise appear as the same failed lookup.

**A rebase detaches `HEAD`.** The usual upstream expression can stop resolving
during precisely the conflict state where recovery matters. A recovery check
placed behind that lookup is skipped.

**Aborting a rebase with autostash restores pre-existing tracked edits.**
Resetting afterward merely to obtain a clean-looking tree can destroy the only
copy of those edits.

**Independent whole-file edits conflict even when their logical keys differ.**
Two machines adding unrelated entries to one JSON or environment document can
produce an ordinary Git conflict. This is expected workload, not exceptional
corruption.

**Exact-key validation breaks rolling upgrades.** A newer writer adding an
unknown field can make older readers reject the entire shared state even when
all fields they understand remain valid.

**Unattended Git cannot answer first-contact host-key prompts.** Without a
trust-on-first-use policy or pre-established host record, a background
operation can hang before authentication and be misreported as remote
unreachability.

**A fresh machine may have no Git author identity.** Automated commits cannot
assume global `user.name` and `user.email` exist.

**Common Git remote spellings are not a trivial identity function.** SSH URLs,
SCP-like syntax, HTTPS credentials, query strings, fragments, default ports,
case rules, `.git` suffixes, IPv6 authorities, and forge-specific
case-sensitivity create equivalence and ambiguity. Including credentials in
portable identity both leaks them and changes identity when a credential
rotates.

### Agent CLIs, configuration, and models

**Codex's noninteractive resume rejects an ordinary non-Git directory unless
its repository check is skipped.** Interactive trust memory does not imply the
same behavior for noninteractive execution.

**Both supported agents use the conversation's original working directory when
selecting what to resume.** The path can be required to exist even when the
continuation writer has no reason to see the real project. Podman can reject a
nonexistent working directory before the agent starts.

**Codex accepts an MCP bearer token by environment-variable name.** Putting the
literal `NAME=value` pair in engine arguments exposes the value through process
inspection. Passing only the name closes that channel but does not make the
inherited environment secret from same-user processes.

**Codex may append learned TOML tables immediately before a trailing comment.**
When a managed closing marker is the last comment, project trust and per-tool
approval tables can land inside the managed region and be deleted by the next
rewrite.

**Textual normalization of integration names can collide.** Case folding and
mapping hyphens to underscores can turn two valid external names into the same
environment-variable identifier.

**A smaller model that follows a format in isolation may fail when resuming a
long transcript.** The failed attempt plus fallback can cost more time and
tokens than using the default model once. Low reasoning effort proved a more
reliable speed lever than a smaller model alias.

**A model's clean exit does not prove its output is structurally usable.** A
non-zero exit with partial-looking stdout is also not authoritative. Exit
status, exact sentinel handling, format validation, and attribution evidence
are separate facts.

**Agent-native skill discovery occurs at startup.** A skill written during a
session can be durable immediately without appearing in that running agent's
discovered skill set.

**Agent CLIs update their own configuration formats independently.** A marker
or parser that matches today's write pattern can destroy future fields or
tables without the third-party CLI being wrong.

### Installation, updates, and appliance behavior

**Raw branch-content URLs can be stale for roughly five minutes.** Resolving a
branch to a commit and downloading the immutable commit content avoids a CDN
serving an older script after an update was published.

**Replacing a running Bash script can make the shell resume at an old byte
offset in new content.** Bash reads and seeks through a script incrementally.
A cross-filesystem move may copy over the existing inode rather than replace
it atomically, which makes this failure realistic when temporary storage is a
RAM disk and the installed command is on persistent array storage.

**A running process does not acquire newly downloaded logic.** Replacing its
script on disk does not replace functions already loaded in memory. A later
operation in the same process still uses the old logic.

**Dangling symlinks fail ordinary existence tests.** A redirect path can exist
as a symlink while its target does not; treating it as absent can follow the
missing target during overwrite and abort installation.

**Unraid rebuilds its root filesystem, command directory, and root home from
flash on every boot.** A conventional installation and SSH trust state can
vanish even though setup initially succeeded.

**The Unraid boot script starts the web interface.** A partial or malformed
write can require repairing the flash drive from another computer. The flash
medium is also unencrypted FAT, so persisted private keys are plaintext.

**Unraid commonly stores container layers in a fixed-size virtual disk.**
Repeatedly pulling floating layers and global agent packages can strand about
gigabytes of untagged data. An untagged image is not necessarily unreferenced
if another tag still names it.

**Agent version discovery costs a container start.** If every session needs the
information for drift reporting, gathering it on every exit adds visible
latency.

**No peer data is not agreement.** A diagnostic whose comparison set is empty
has learned nothing; an empty comparison and matching reports are different
observations.

### Shell-specific implementation traps

These entries explain failures caused by the discarded implementation
language. They are not requirements for a rewrite in another language.

**Negating a command disables `errexit` for that command.** A negative test
assertion written as `! command` can become decorative and pass regardless of
the behavior. This invalidated 71 negative assertions at once.

**A function returns the status of its last command unless it returns
explicitly.** A loop that legitimately finds nothing can end on a false test,
propagate through `pipefail`, and terminate a caller that expected an empty
successful result.

**A fatal exit inside command substitution happens before an outer fallback.**
Putting `|| true` outside the wrong boundary does not catch it. This caused
read-only reporting to stop on a host without a container engine.

**Tab is shell field-separator whitespace.** A tab-delimited record with an
empty first field can shift the second field into the first position and leave
the second empty. Undated handoffs became invisible to retention and allowed
unbounded growth.

**Shell glob order and explicit sort are separate operations influenced by
locale.** Relying on them as two implementations of one chronology is not a
portable proof that they agree.

**Process signal disposition and process groups are easy to misread.** A
caught signal can reset to default in a child; briefly clearing a trap creates
a fatal window; repeated terminal interrupts can strike cleanup after the
foreground process exits; and killing an already-finished group can itself
trip `errexit`.

**Some `find` formatting extensions are not portable to appliance userlands.**
An ownership repair that silently depends on one implementation can be skipped
on the platform that needs it most.

**Tracing changes test output.** Shell tracing written to standard error breaks
tests that intentionally capture both output streams and assert silence.

**Testing generated output without rebuilding exercises stale code.** A source
edit and a test run can appear to prove a regression while the test is still
loading the previous generated artifact.

## 8. Why it went wrong

The following are root-cause clusters, not a bug list. Only defects that could
recur in another language and a different architecture are represented here.

### Product promises were not settled before mechanisms accumulated

The evidence repeatedly shows two incompatible answers coexisting: local
capabilities are said to work without synchronization but do not; a session is
called unprivileged while UID zero is accepted and recommended; settings are
described as caravan-wide though no exposed setting uses that scope; handoff
freshness is explained by header content while retention trusts the filename;
diagnostics disagree on whether endpoint unavailability is failure; and
undocumented switches change safety and continuity. These are not Bash
failures. They recur when implementation advances faster than the product
contract and every new path chooses its own interpretation.

### Authority exceeded ownership

Several features were given more authority than their stated purpose required:
machine inspection could write beyond approved knowledge, automatic
synchronization could publish unrelated clone edits, a restricted session
received a durable credential-bearing home, installation could replace an
unowned primary command, and native integration materialization could erase
third-party entries. Safety checks were process-local, so content rejected in
one run could be published by a later run. A different architecture will
repeat these failures unless authority is derived from exact ownership and
survives across process boundaries.

### The same identity crossed incompatible namespaces

Machine identity, repository origin, project ID, host path, session UID, key
type, integration name, authentication mode, environment-variable name, and
third-party flag name all cross system boundaries. Evidence includes distinct
integration names collapsing onto one credential variable, “no auth” retaining
an old token, one persisted key type being excluded by reboot restoration,
ignored repository records retaining stale ownership, custom UIDs being probed
as the wrong user, and Satchel flags consuming potential agent flags. These
failures are language-independent: every lossy or duplicated translation needs
an explicit equivalence rule and collision behavior.

### Durable multi-system work was not one transaction

Registration, synchronization, machine inspection, update, retirement,
uninstall, and skill repair each span local files, Git history, a remote,
container state, or model output. Evidence includes retirement leaving a
rebase in progress, a failed clone leaving configured-but-unusable state,
inspection failures leaving later-publishable edits, update replacing the
launcher before the runtime was ready, uninstall removing the retry command
while an image remained, and startup versus shutdown choosing different skill
recovery. A new architecture can move the seams, but it cannot remove the need
to define commit, rollback, retry, and evidence of remote durability.

### Probabilistic or partial evidence was promoted to fact

Transcript modification was used as a proxy for meaningful work, model
delimiters controlled repository tracking and attribution, five heading names
stood in for a valid handoff, HTTP reachability stood in for protocol health,
and missing peer reports once stood in for version agreement. These are all
category errors between evidence and conclusion. They recur anywhere a rewrite
uses heuristic or model output to make a durable claim without representing
uncertainty.

The audit found **62 distinct current defects, contradictions, ambiguous
contracts, and unsafe gaps**. Applying the required counterfactual—would the
same failure remain plausible in a different language with a different
architecture—left **34**; the other 28 depended on discarded choices such as
shell control flow, glob and delimiter behavior, marker-based configuration
editing, particular mount layouts, or particular file encodings. The surviving
defects concentrate at capability boundaries rather than in one subsystem:
authority, cross-system identity, distributed transactions, and claims derived
from incomplete evidence. That distribution, together with repeated
contradictory implementations of the same promise, is strong evidence that the
feature count exceeded what this implementation could support coherently, not
merely that individual functions needed more discipline.

## Appendix A: Reference-only migration inventory

Nothing in this appendix constrains the rewrite's architecture. These formats
exist only so a replacement can detect, migrate, preserve, or remove prior
installations. “Looked right” evaluates the fit of the current representation,
not whether its contents should remain a product capability.

| Prior-install representation | Looked right? | Migration note |
| --- | --- | --- |
| State beside the installed command or under the user's home | Mixed | Relocatable state solves RAM-backed roots, but discovery by several fallbacks makes ownership and uninstall proof complicated. |
| Executable shell machine configuration | No | Human-readable, but unvalidated synchronized code can execute on the host and fail before graceful degradation. |
| One private Git working tree containing all portable state | Mixed | User ownership, history, and ordinary recovery are strong; automatic staging and whole-file conflicts blur provenance. |
| One repository registry keyed by normalized origin | Mixed | A single portable authority is sound, but origin canonicalization and migration are under-specified. |
| Per-machine absolute-path cache | Mostly | Absolute paths are correctly machine-local and disposable, but stale host-wide visibility can affect attribution. |
| Central JSON MCP registry plus separate line-based token files | No | Separation of metadata and secrets is useful; newline handling, mode portability, stale credentials, and name mapping are fragile. |
| Timestamped Markdown handoffs in bounded directories | Mixed | Human readability and Git history work well; chronology, collision, structure, and model authority are ambiguous. |
| Markdown profile, preferences, notes, inventory, and guides | Mixed | Plain text is inspectable; lifetime and secret rules are largely advisory prompt policy. |
| One shared skill tree with complete bundles | Mostly | Preserving native bundles is simple and portable; runtime-owned entries, semantic trust, and repair scope need a clearer boundary. |
| Per-machine JSON runtime report | Mixed | It can expose drift cheaply, but refresh is stale and some published fields are never compared. |
| Generated global agent instruction document | Mixed | Agents need environmental truth, but the document combines safety policy, product vocabulary, storage directions, and current context into a large mutable interface. |
| Managed JSON/TOML MCP materialization | No | Native compatibility is necessary; replacing a whole object and textually rescuing tables do not establish safe coexistence. |
| Fixed container mount destinations and environment flags | No opinion | These are entirely architectural and should be rediscovered from the chosen isolation model. |
| Marker-delimited appliance boot block | Mixed | Ownership markers enable safe removal, but key-type drift and the consequence of editing a boot-critical script make migration high risk. |

### Prior state discovery

The previous state root may be explicitly configured, may live at
`$HOME/.satchel`, or may be a `.satchel` directory adjacent to the resolved
installed command. Important local entries include:

```text
config
sync/
home/claude/
home/codex/
mcp-tokens.local.env
script-sha
install-path
quarantine/skills/
image-agents
update-check
```

The authentication and conversation homes are local-only and must not be
imported into shared state during migration.

### Previous machine configuration

The prior machine-local format is executable Bash assignments:

```sh
MACHINE=<shell-escaped-name>
SYNC_URL=<shell-escaped-remote>
SATCHEL_ENGINE=<value>
SATCHEL_SSH=<value>
SATCHEL_CLIPBOARD=<value>
SATCHEL_UID=<value>
SATCHEL_GID=<value>
```

The synchronized preference layer, when manually present, uses the same
assignment format in `settings.env`. Unknown or malformed values must be
treated as untrusted migration input, not sourced.

### Previous synchronized tree

The observed portable layout is:

```text
profile.md
preferences.md
repositories.json
mcp.json
mcp-tokens.env
settings.env
skills/
  shared/
    .gitkeep
    .system/
    skills-lock.json
    <skill>/
      SKILL.md
      ...
projects/
  <project-id>/
    handoffs/
      .gitkeep
      <timestamp>--<machine>.md
machines/
  <machine>/
    projects.json
    notes.md
    inventory.md
    guides/
      <topic>.md
    handoffs/
      <timestamp>.md
    environment.json
    .baseline-skip
```

The `.system` entry is runtime-owned and ignored rather than portable user
content. `skills-lock.json` is installer-owned metadata; its schema is not
defined by Satchel.

### Previous repository registry

The registry is a JSON object keyed by a credential-free canonical origin:

```json
{
  "github.com/example/project": {
    "status": "tracked",
    "project": "project"
  },
  "github.com/example/ignored": {
    "status": "ignored"
  }
}
```

Readers accepted unknown fields. A tracked entry required a project ID, and
project IDs were intended to be unique. Ignored entries were documented
without `project`, although the validator accepted a stale field.

An older format stored `project.json` beneath each project. The current
implementation rejects that metadata rather than migrating it. A rewrite
intending to preserve older installations must detect it before applying the
current validator.

### Previous machine path cache

Each machine cache has this JSON shape:

```json
{
  "paths": {
    "/absolute/checkout": {
      "project": "project"
    }
  }
}
```

These paths are not portable identity and may be discarded and rebuilt after
migration.

### Previous MCP state

The registry shape is:

```json
{
  "servers": {
    "example": {
      "url": "https://example.test/mcp",
      "auth": "bearer"
    }
  }
}
```

`auth` is either `"bearer"` or `"none"`. Unknown object fields were accepted.
Token files use one unescaped line per server:

```text
example=token-value
```

The machine-local token file takes precedence over the synchronized token file.
Git history may retain removed or rotated synchronized tokens.

### Previous handoff format

A stored handoff begins with:

```html
<!-- satchel-handoff project=<id-or-> machine=<machine> date=<UTC-timestamp> -->
```

Its body is expected to contain these headings:

```markdown
## Goal
## Done
## In flight
## Next steps
## Gotchas
```

Project filenames replace timestamp colons and append
`--<machine>.md`. Machine filenames replace timestamp colons and append `.md`.
The current selector and retention logic trust filename order, even though
generated instructions tell agents to inspect the header date.

The multi-scope model response uses:

```text
=== project: <id> ===
=== candidate: candidate-<number> ===
=== machine ===
```

This response protocol is internal and should not constrain the rewrite.

### Previous machine knowledge markers

The current inventory marker is:

```html
<!-- satchel-machine-baseline version=2 generated=<UTC-timestamp> -->
```

Version 1 placed the corresponding marker in machine notes and remains
readable as a migration fallback. The reminder-suppression marker contains a
human-readable suppression timestamp but has no versioned schema.

### Previous runtime report

Each machine may publish:

```json
{
  "satchel": "2.0.0",
  "commit": "7179842",
  "engine": "docker",
  "agents": "claude 2.1.217, codex 0.145.0"
}
```

The report may be missing, stale until a session exits, or contain an empty
commit for a hand-installed copy.

### Previous generated session environment

Normal sessions expose these invented environment values:

```text
SATCHEL_SESSION=1
SATCHEL_SESSION_MODE=sandbox|host
SATCHEL_SKILLS_DIR=<agent-native-skill-path>
```

The previous fixed in-container paths include:

```text
/home/satchel
/home/satchel/machine
/home/satchel/machines
/home/satchel/projects
/home/satchel/.claude/skills
/home/satchel/.codex/skills
/host
/run/ssh-agent.sock
/run/satchel/wayland-0
/run/satchel/Xauthority
```

These are not external compatibility requirements. They matter only if a
migration must preserve a running session or an installed skill manager that
explicitly detects the prior environment.

### Previous appliance persistence content

Content between the frozen markers restored command links into
`/usr/local/bin`, created `/root/.ssh`, copied `id_ed25519*`, and copied
`known_hosts`. Existing ECDSA- or RSA-only backups may therefore exist on flash
without a restoration command that matches them. The prior backup may be named
`go.satchel-bak`, and staged temporary files may use a
`.satchel-tmp.` infix.

An unterminated marker block, malformed live script, or unresolved installed
command is migration evidence requiring human review, not permission to
rewrite the file.
