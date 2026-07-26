# Satchel Forensic Product Specification

## Purpose and method

This document extracts the apparent product contract from the existing Satchel repository without endorsing its architecture. It is intended to let another team understand what users are meant to accomplish without seeing the original implementation.

Evidence was weighted in this order:

1. automated behavioral contract tests and directly observable command behavior;
2. public user documentation and command help;
3. accepted product and security decisions;
4. installation, deployment, and operational behavior;
5. implementation details only when needed to resolve an externally meaningful ambiguity;
6. change history as evidence of drift, repeated failure modes, or unstable intent.

The complete automated contract suite passed during this review: 16 test groups passed and none failed. That means the defects identified below are not simply failing tests. Many are contradictions, unsafe product choices, missing contracts, or behavior that works as currently asserted but should not be inherited automatically.

Confidence labels used throughout:

- **Confirmed** — directly supported by public documentation and/or automated behavioral contracts.
- **Strongly inferred** — not stated as a formal requirement, but multiple high-quality evidence sources converge.
- **Weakly inferred** — plausible intent with limited evidence.
- **Questionable** — implemented or documented, but its status as a product requirement is doubtful.
- **Apparently accidental** — evidence points to drift, contradiction, or an implementation side effect rather than deliberate product intent.

---

# 1. Product summary

## 1.1 What the product is

Satchel is a personal Linux command-line tool for running supported AI coding-agent CLIs inside short-lived containers while preserving the parts of an agent experience that users want between sessions: authentication, conversation records, personal context, project handoffs, selected integrations, and reusable skills.

It also synchronizes continuity data across a user's machines through a private, user-controlled Git repository. The product calls the group of participating machines a “caravan.”

It is explicitly positioned as a home-lab and personal-tool product, not as a production platform, hosted service, multi-user collaboration system, or security boundary suitable for hostile workloads.

**Confidence: Confirmed.** This positioning appears in the public product description, user vocabulary, command help, and accepted product decisions.

## 1.2 Who it is for

The apparent target user is a technically capable individual who:

- uses Claude Code and/or Codex on one or more Linux machines;
- wants coding agents to edit only explicitly selected working directories during ordinary sessions;
- wants agent logins and transcripts to survive disposable containers;
- wants project continuation notes, tool-server settings, and skills to follow them between machines;
- is comfortable operating Git, SSH keys, Docker or Podman, and plain configuration files;
- may run home-lab systems, including Unraid.

The product is not evidenced as suitable for teams, untrusted tenants, centrally managed fleets, regulated environments, or users who cannot manually resolve Git conflicts.

**Confidence: Confirmed** for the personal/home-lab audience; **Strongly inferred** for the excluded audiences because the documentation explicitly says “not production-grade” and the state model assumes one user.

## 1.3 Problem it solves

The product tries to solve four user problems:

1. **Contain routine agent access.** A coding agent should normally see and modify the current project, not the entire host.
2. **Preserve useful continuity.** Container disposal should not force the user to reauthenticate or lose agent transcripts and project context.
3. **Carry personal agent setup between machines.** Project handoffs, machine knowledge, MCP server registrations, and user-installed skills should be available wherever the user runs a session.
4. **Provide an explicit escape hatch for machine administration.** When the user intentionally wants the agent to inspect or change the host, they can start a visibly dangerous host-access session.

**Confidence: Confirmed.**

## 1.4 Primary workflows

The primary workflows are:

1. install the command and optionally route the native agent command names through it;
2. initialize a named machine and optionally connect it to a private synchronization repository;
3. launch Claude Code or Codex in the current directory;
4. optionally add extra working directories or explicitly enable host access;
5. authenticate once or import an existing host login;
6. work normally, including Git-over-SSH when forwarding is available;
7. on meaningful sessions, generate and synchronize continuation handoffs;
8. explicitly track or ignore Git repositories as portable Projects;
9. register MCP servers and install shared skills once for reuse on other machines;
10. inspect health/status, retry synchronization, update, retire a machine, or uninstall.

**Confidence: Confirmed.**

## 1.5 Minimum useful functionality

The smallest useful product is:

- launch either supported agent in a disposable environment;
- mount only one explicitly selected working directory by default;
- preserve the selected agent's local login and conversation state;
- state the actual filesystem and credential boundary clearly to both the user and the agent;
- refuse obviously dangerous mount roots unless the user explicitly overrides the refusal;
- return the agent's exit status and leave project files on the host;
- continue to launch local sessions when synchronization is absent, offline, or malformed.

Cross-machine synchronization and handoffs are central to the current product identity, but the repository itself says the session is the product and synchronization is bookkeeping. Therefore, synchronization is required for the full Satchel product but must not be required for the basic local session workflow.

**Confidence: Strongly inferred.** The individual behaviors are confirmed; their classification as the minimum coherent product is an inference from repeated product priorities.

---

# 2. User-visible capabilities

## 2.1 Installation and bootstrap

- **User goal:** Install Satchel and get to a launch-ready state with minimal manual assembly.
- **Trigger or input:** Run the published installer, optionally choosing a custom install directory and whether agent-command shims should be installed.
- **Expected behavior:** Verify required host commands, install an executable, optionally install launch shims, record the installation location, begin interactive initialization when a terminal is available, and ensure the shared agent image exists for an already initialized installation.
- **Output or result:** An executable `satchel` command, optional `claude` and `codex` redirects, local state storage, and a ready or explicitly retryable container image.
- **Failure behavior:** Missing dependencies stop installation with a named requirement. Existing unrelated `claude` or `codex` redirects are not overwritten. However, the primary `satchel` destination is replaced without proving ownership; that is a current defect, not an intended requirement. A downloaded executable that fails syntax validation is not installed. Image-build failure leaves the installed command in place and prints an exact retry command.
- **Required persisted state:** Installed command path, selected local state path, installed revision identifier when known, optional command redirects, and built container image.
- **External systems involved:** GitHub download/API endpoints, Docker or Podman, local filesystem, and optionally a terminal.
- **Evidence of intent:** Public one-line installation instructions, installer contract tests, command help, and appliance-specific installation documentation.
- **Confidence:** **Confirmed.**

## 2.2 Machine initialization and joining the caravan

- **User goal:** Name a machine and connect it to the user's private shared state.
- **Trigger or input:** `satchel init`; machine name; private Git repository URL or local bare-repository path; optional SSH-key setup.
- **Expected behavior:** Validate the machine name, store machine-local settings, connect or create the synchronization repository, initialize the machine's shared records, push a machine registration, build the agent image, and optionally offer machine-baseline onboarding.
- **Output or result:** A locally configured machine, a usable synchronization clone when configured, and a registered machine entry visible to other machines.
- **Failure behavior:** A different remote URL is refused if an existing clone already points elsewhere. Incomplete non-repository content at the clone destination is moved to recovery storage rather than deleted. Symlink destinations are refused. Clone failure shows SSH guidance and may be retried; the user may continue without synchronization.
- **Required persisted state:** Machine name, synchronization URL, local configuration, synchronization clone, machine record, default global context, and repository/project registries.
- **External systems involved:** Git, private Git remote or shared filesystem, SSH agent/keys, container engine.
- **Evidence of intent:** Public setup flow, initialization tests, recovery tests, and command help.
- **Confidence:** **Confirmed.**

Current initialization also rewrites the machine configuration template and thereby drops previously stored `SATCHEL_*` setting overrides. That data-loss behavior is not treated as an intended requirement; it is recorded as a defect below.

## 2.3 Ordinary sandboxed agent session

- **User goal:** Run Claude Code or Codex against the current project without exposing the rest of the host filesystem.
- **Trigger or input:** `satchel claude [agent arguments]`, `satchel codex [agent arguments]`, or an installed agent-name shim.
- **Expected behavior:** Resolve the current directory, reject dangerous roots, prepare the selected agent's persistent home, pull shared state best-effort, materialize context and integrations, launch the agent in a short-lived container, mount the project read-write at the same absolute path, and remove the container at exit.
- **Output or result:** An interactive or noninteractive agent process operating on host project files; agent login, transcript, known-host, and native configuration state remain available for later sessions.
- **Failure behavior:** Missing required tools or engine, unsupported nested-container mounts, nonexistent paths, or unsafe mount roots stop launch with an explanation. Synchronization failures normally degrade only synchronization and do not block the agent. User interruption is propagated. The agent's exit status is returned after cleanup.
- **Required persisted state:** Per-agent home, local configuration, optional synchronization clone, and project files outside Satchel's state.
- **External systems involved:** Docker or Podman, Claude or OpenAI services, project Git remotes, optional MCP services.
- **Evidence of intent:** Central public product promise, CLI help, lifecycle tests, mount-boundary tests, and accepted decisions.
- **Confidence:** **Confirmed.**

## 2.4 Additional working directories

- **User goal:** Let one session work across multiple related repositories or directories.
- **Trigger or input:** Repeatable `--with <directory>` flags before or after the agent name.
- **Expected behavior:** Resolve every additional directory to a real absolute path, mount it read-write at the same path, tell the agent which extra roots are visible, and include repositories discovered within those roots in project attribution.
- **Output or result:** One agent session with access to the primary directory and all approved extras.
- **Failure behavior:** Missing directories, the filesystem root, a home-directory scope, Satchel private state, and symlink-based boundary bypasses are refused.
- **Required persisted state:** None solely for the mount list; discovered checkout-to-Project mappings and resulting handoffs may persist.
- **External systems involved:** Host filesystem and Git.
- **Evidence of intent:** Public examples, CLI help, mount-guard tests, project-attribution tests.
- **Confidence:** **Confirmed.**

## 2.5 Host-access session and unsafe-home override

- **User goal:** Deliberately let an agent inspect or modify the real machine, or deliberately work from a normally forbidden home-level directory.
- **Trigger or input:** `--host` or `--unsafe-home`, accepted before or after the agent name.
- **Expected behavior:** Host mode runs the agent as root in the container, exposes the host filesystem under `/host` with real mount permissions, exposes the host PID namespace, and displays a danger warning. Unsafe-home mode bypasses the normal refusal to mount a home scope.
- **Output or result:** A session capable of machine-level work or broad home-directory access.
- **Failure behavior:** The product warns that Host Session packaging is not protection. Ambiguous path resolution still fails. No finer-grained authorization is provided.
- **Required persisted state:** Same per-agent state as a normal session; host changes persist because they are real host changes.
- **External systems involved:** Entire host filesystem and processes, container engine, any services reachable from the host.
- **Evidence of intent:** CLI help, public safety documentation, environment-contract tests, and explicit accepted terminology.
- **Confidence:** **Confirmed.**

## 2.6 Persistent agent authentication, transcript state, and Git identity

- **User goal:** Authenticate once and have later disposable sessions start ready to work and commit.
- **Trigger or input:** Authenticate inside an agent session, or run `satchel import claude|codex` to copy an existing host login.
- **Expected behavior:** Preserve each agent's native home between sessions, including login and transcripts. Import only from recognized host login locations. Seed missing Git author name/email from the host without overwriting an identity already chosen in the agent home.
- **Output or result:** Authenticated future sessions, persistent conversation records, and a usable Git commit identity when the host has one.
- **Failure behavior:** Import fails when no recognized login exists. Credentials are not synchronized to other machines. Partial Git identity is completed where possible; absence of a host identity is not silently invented.
- **Required persisted state:** Separate persistent home per agent with native credentials, transcripts, configuration, SSH known-host state, and optional Git identity.
- **External systems involved:** Claude and OpenAI authentication systems; host Git configuration.
- **Evidence of intent:** Public “log in once” promise, import command help, authentication tests, and session lifecycle tests.
- **Confidence:** **Confirmed.**

## 2.7 SSH-agent forwarding

- **User goal:** Push and pull project repositories over SSH from inside a session without copying private key files into it.
- **Trigger or input:** Enabled by default; controlled by `SATCHEL_SSH`; uses the host's current agent or standard host key locations.
- **Expected behavior:** Determine whether the agent socket is reachable by the session user and contains identities. If needed, load standard keys or start a temporary agent owned by the session user. Forward only the socket. Persist trust-on-first-use host records in the agent home.
- **Output or result:** Git-over-SSH can request signatures from loaded host identities during the session.
- **Failure behavior:** If no usable key is available, explain that SSH authentication will fail and allow the user to continue. A dead socket is not mounted. Passphrase-entry interruption stops launch and cleans up the temporary agent. Host SSH configuration is not copied, so remotes depending on host-specific settings may still fail.
- **Required persisted state:** Agent-home host-key records; optional local SSH key; temporary agent exists only for the session.
- **External systems involved:** Host `ssh-agent`, SSH keys, Git remotes.
- **Evidence of intent:** Accepted security decision, public documentation, and extensive socket-state and UID tests.
- **Confidence:** **Confirmed.**

## 2.8 Desktop clipboard forwarding

- **User goal:** Paste screenshots or other clipboard content into an agent session.
- **Trigger or input:** Enabled by default on a graphical Wayland or X11 host; controlled by `SATCHEL_CLIPBOARD`.
- **Expected behavior:** Detect a usable display socket, expose it to ordinary, baseline, and Host Sessions, and provide clipboard client tools in the agent environment.
- **Output or result:** The agent can read and write the live desktop clipboard during the session.
- **Failure behavior:** Headless or missing-socket hosts proceed without clipboard integration. Explicit opt-out exposes nothing.
- **Required persisted state:** None.
- **External systems involved:** Host Wayland compositor or X server.
- **Evidence of intent:** Public screenshot-paste promise, accepted security decision, and clipboard mount tests.
- **Confidence:** **Confirmed.**

## 2.9 Personal context injection

- **User goal:** Give every session a small amount of stable personal profile and preference context.
- **Trigger or input:** Edit the global profile and preference documents in the private shared state.
- **Expected behavior:** Inject their user-authored content into the generated starting instructions for each supported agent.
- **Output or result:** Both agent types receive the same personal context on every machine where synchronization is usable.
- **Failure behavior:** Missing or empty documents contribute no context. Invalid shared state may suppress synchronization for the run.
- **Required persisted state:** Global profile and preference content.
- **External systems involved:** Private synchronization store.
- **Evidence of intent:** Public “what syncs” documentation and generated-context behavior.
- **Confidence:** **Confirmed**, though the absence of a dedicated editing command makes discoverability weaker.

## 2.10 Project tracking and portable repository identity

- **User goal:** Associate continuation state with the same Git repository across paths and machines.
- **Trigger or input:** `satchel track [id]`, automatic discovery under mounted roots, or a post-session prompt for a previously unknown network-origin repository.
- **Expected behavior:** Treat explicitly tracked Git repositories as Projects. Normalize credential-free network origins so equivalent SSH/HTTPS forms map to one identity. Use an explicit stable Project ID. Keep checkout paths machine-local. Allow local/no-origin repositories only through explicit tracking and explicit ID linkage.
- **Output or result:** Project-specific handoffs follow the repository across machines and multiple checkouts.
- **Failure behavior:** Ordinary directories cannot become Projects. Unsafe IDs, duplicate identities, conflicting IDs, missing Projects, and malformed mappings are rejected rather than guessed. An origin change invalidates the cached mapping and requires a new decision.
- **Required persisted state:** Global origin decision (tracked or ignored), stable Project ID, Project handoff scope, and machine-local checkout mapping.
- **External systems involved:** Git repositories and private synchronization store.
- **Evidence of intent:** Public project workflow, vocabulary, accepted identity decisions, and broad project contract tests.
- **Confidence:** **Confirmed.**

## 2.11 Project ignore/untrack behavior

- **User goal:** Stop being prompted about a repository and stop maintaining active Project continuity for it.
- **Trigger or input:** Decline an automatic tracking prompt or run `satchel untrack [id]`.
- **Expected behavior:** Record a global ignored decision for a portable repository identity, clear machine checkout mappings, and remove the active Project handoff scope when explicitly untracked.
- **Output or result:** The repository no longer receives Project handoffs or tracking prompts; future non-Project work remains eligible for a machine-scoped handoff.
- **Failure behavior:** Unknown or unsafe IDs fail. Removed active handoffs are recoverable only through synchronization-history tooling.
- **Required persisted state:** Ignored origin decision; deletion of active Project state and mappings.
- **External systems involved:** Private synchronization store and Git history.
- **Evidence of intent:** Public command description, accepted project decisions, and untracking tests.
- **Confidence:** **Confirmed.**

## 2.12 Automatic session handoffs

- **User goal:** Continue meaningful work in a later session without replaying a full transcript.
- **Trigger or input:** End a session in which the agent created new transcript data; automatic handoff may be disabled by environment override or deliberately skipped during generation.
- **Expected behavior:** Resume the agent conversation in a tightly restricted helper environment, request a short Markdown handoff with Goal, Done, In flight, Next steps, and Gotchas, validate the shape, attribute chunks to touched tracked Projects or to the current machine, retain the latest 100 per scope, and sync them.
- **Output or result:** The next relevant session receives the latest handoff inline or can load it on demand in multi-project sessions.
- **Failure behavior:** Empty/trivial sessions do not replace a good handoff. Writer exit failure or malformed output preserves the previous handoff and reports the distinction. Unknown Project IDs are dropped. Work from undecided repositories is retained at machine scope. Repeated Ctrl-C after the interactive agent exits should not kill cleanup; Ctrl-\ deliberately skips handoff generation.
- **Required persisted state:** Timestamped human-readable handoff records per Project or machine.
- **External systems involved:** The selected agent CLI and provider, private synchronization store.
- **Evidence of intent:** Central public continuity promise, accepted handoff decisions, and extensive formatting, signal, attribution, and retention tests.
- **Confidence:** **Confirmed.**

## 2.13 Cross-machine synchronization and recovery

- **User goal:** Carry supported Satchel state between machines without letting bookkeeping stop agent work.
- **Trigger or input:** Automatic pull before sessions, automatic commit/push after relevant changes, or explicit `satchel sync`.
- **Expected behavior:** Pull remote changes, commit local changes as ordinary recoverable revisions, push them, and expose unpushed/behind status. Session startup treats offline or broken synchronization as degradable. Explicit synchronization validates shared state strictly.
- **Output or result:** Shared state converges when the remote is reachable and nonconflicting; Git history provides recovery for removed or pruned active data.
- **Failure behavior:** Network failure leaves local state usable and local commits retryable. A conflict is aborted rather than automatically merged; the clone should return to a usable state with local work preserved. The user must reconcile conflicting histories manually with Git. User interruption remains an interruption rather than being reported as offline. Although soft validation is intended to make malformed shared state nonblocking, a malformed MCP registry can be validated again later and still abort session launch; this is a confirmed gap rather than intended behavior.
- **Required persisted state:** Local synchronization clone, upstream relationship, commits, registries, handoffs, knowledge, skills, and integrations.
- **External systems involved:** User-owned Git remote or local/shared bare repository.
- **Evidence of intent:** Public recovery documentation, accepted “session is the product” decision, and end-to-end local-remote conflict tests.
- **Confidence:** **Confirmed.**

## 2.14 MCP server registry

- **User goal:** Register an MCP HTTP server once and make it available in both supported agents on every participating machine.
- **Trigger or input:** `satchel mcp list|add|remove`; server name, URL, authentication mode, optional bearer token, and token storage scope.
- **Expected behavior:** Validate names, URLs, and supported auth modes; store server definitions globally; optionally store tokens in the private sync state or only on one machine; probe the endpoint; and update each agent's native configuration at session start. Preserving unrelated native settings is strongly intended and tested for one managed configuration path, but not achieved consistently for both agents.
- **Output or result:** Registered servers appear in agent-native MCP configuration; bearer credentials are supplied without placing token values in container-engine arguments.
- **Failure behavior:** Invalid shared registry data is rejected before native configuration is changed, although the same validation can still abort a Session after shared state was supposedly degraded. Missing bearer tokens prompt at an interactive launch and may be skipped; noninteractive materialization with a missing token exits unsuccessfully. A damaged managed-config boundary leaves the existing native config untouched. Removal deletes current token entries but warns that formerly synced secrets remain in history; removing an absent but syntactically valid name still reports success. Stored token lookup is not constrained by the declared auth mode, so an `auth:none` server can receive a stale stored token. Distinct valid server names can also collapse onto one Codex credential variable.
- **Required persisted state:** Global server name/URL/auth records; bearer token either globally synced or machine-local; generated native configuration in each agent home.
- **External systems involved:** MCP HTTP endpoints, private synchronization store, Claude Code and Codex configuration contracts.
- **Evidence of intent:** Public command documentation, accepted token decision, and configuration preservation/security tests.
- **Confidence:** **Confirmed.**

## 2.15 Shared Skill Library

- **User goal:** Install a complete agent skill once and use it with either agent on any participating machine.
- **Trigger or input:** Ask an agent or installer to write a skill bundle into the exposed shared library; use `satchel skills` or `satchel skills remove [name]` for host-side management.
- **Expected behavior:** Mount one read-write user-skill library at each agent's native discovery path, identify it through runtime variables and generated instructions, validate top-level bundles after sessions, synchronize valid changes, list active skills, and remove a selected skill caravan-wide.
- **Output or result:** Complete user-installed skill bundles become discoverable in fresh sessions for both agents.
- **Failure behavior:** Missing manifests, unsafe names, nested Git metadata, broken/escaping symlinks, and unexpected top-level entries are moved to machine-local quarantine; a previously valid version is restored. Malformed installer lock metadata is also quarantined. Removal does not rewrite installer-owned lock metadata and warns if it appears stale.
- **Required persisted state:** Shared skill bundles, optional installer-owned lock metadata, machine-local quarantine, and Git history.
- **External systems involved:** Both agent-native skill systems, installers or source repositories used to obtain skills, private synchronization store.
- **Evidence of intent:** Public Skill Library documentation, accepted cross-agent decision, and extensive validation/removal tests.
- **Confidence:** **Confirmed.**

## 2.16 Machine knowledge and baseline onboarding

- **User goal:** Give future sessions concise machine-specific operating context plus an on-demand system inventory.
- **Trigger or input:** Optional prompt after an agent has authenticated, or refresh offer during initialization.
- **Expected behavior:** Run the chosen agent with read-only host access, ask it to inspect the system, show proposed changes for human approval, and separate knowledge into concise current notes, a replace-in-place dated inventory, and reusable topic guides. Scan newly added content for likely secrets before allowing automatic synchronization.
- **Output or result:** Current machine notes are loaded into every local session; inventory and guides are discoverable on demand; sibling-machine notes are readable.
- **Failure behavior:** Declining continues the originally requested normal session; “don't ask again” persists suppression. Accepting consumes that launch and returns to the shell afterward. Missing required inventory marker, no written inventory, agent failure, interruption, or suspected secret prevents success and automatic sync.
- **Required persisted state:** Machine notes, inventory marker and generation time, optional guides, suppression marker, and synchronization history.
- **External systems involved:** Selected agent/provider, read-only host filesystem, private synchronization store.
- **Evidence of intent:** Public onboarding description, accepted knowledge-lifetime decision, and baseline authorization/secret-scan tests.
- **Confidence:** **Confirmed.**

## 2.17 Settings, status, and diagnostics

- **User goal:** See machine configuration and caravan state, change supported preferences, and diagnose setup problems.
- **Trigger or input:** `satchel settings`, `satchel settings <KEY> <value> [--local]`, `satchel status [--ignored]`, and `satchel doctor`.
- **Expected behavior:** Show all supported settings with value and source; report machine name, sync remote, engine, command-link status, machines, Projects, ignored count/details, handoffs, MCP servers, skills, quarantine, and synchronization divergence; run deeper checks for engine mount capability, SSH, sync health, MCP endpoints, appliance persistence, and runtime-version drift.
- **Output or result:** Human-readable status tables and health results with actionable warnings or failures.
- **Failure behavior:** Reporting commands should still explain a machine with no container engine. Status and explicit sync validate shared state strictly and may stop on malformed records. Doctor exits unsuccessfully when hard failures are found.
- **Required persisted state:** Existing configuration and shared state; runtime environment reports for cross-machine comparison.
- **External systems involved:** Container engine, Git remote, MCP endpoints, host filesystem, SSH setup.
- **Evidence of intent:** Public command help, accepted runtime-reporting decision, and reporting/doctor tests.
- **Confidence:** **Confirmed.**

## 2.18 Image build and self-update

- **User goal:** Create the shared agent runtime and update Satchel plus bundled agent versions.
- **Trigger or input:** Automatic first-use build, `satchel image [--rebuild]`, daily update availability check, or `satchel update`.
- **Expected behavior:** Build an image containing both supported agent CLIs and common coding tools; update the installed command from the upstream main branch; show intervening commit subjects when possible; validate the downloaded command; replace it atomically; rebuild the image; and report agent versions.
- **Output or result:** Updated executable and locally built agent image.
- **Failure behavior:** Offline daily checks are silent and nonfatal. An update download or syntax failure does not install invalid content. If staging beside the installed command is impossible, update refuses to risk a cross-filesystem overwrite. Image-build failure is reported.
- **Required persisted state:** Container image, installed revision stamp, image agent-version cache, and daily check timestamp.
- **External systems involved:** GitHub API/raw content, container image registry, package repositories, language package registry, Docker or Podman.
- **Evidence of intent:** Public command help, update documentation, and atomicity/failure tests.
- **Confidence:** **Confirmed.**

## 2.19 Command linking and unlinking

- **User goal:** Type the native agent command name to start a Satchel session, or restore direct access to the native CLI.
- **Trigger or input:** Installer choice; `satchel link [claude|codex]`; `satchel unlink [claude|codex]`.
- **Expected behavior:** Create or remove only redirects demonstrably owned by the current Satchel installation; support one or both agents; remain idempotent; update appliance boot persistence when applicable.
- **Output or result:** Agent command names either route through Satchel or do not.
- **Failure behavior:** Existing unrelated executables, dangling unrelated links, ambiguous legacy redirects, and redirects owned by another installation are left untouched with an explanation. The current command does not validate the requested agent name and can create/remove a redirect for an arbitrary name; this is accidental behavior, not part of the supported interface.
- **Required persisted state:** Optional executable redirects and install-location record.
- **External systems involved:** Host PATH and filesystem.
- **Evidence of intent:** Installer prompts, command help, and ownership-safety tests.
- **Confidence:** **Confirmed.**

## 2.20 SSH key assistance and appliance persistence

- **User goal:** Prepare Git authentication and keep a self-contained installation usable after reboot on Unraid.
- **Trigger or input:** `satchel key [--persist]`, initialization prompts, and automatic appliance detection.
- **Expected behavior:** Show existing public keys or generate an unencrypted Ed25519 key when needed. On Unraid, install to persistent storage, optionally maintain a marked boot-script block that restores command links, key material, and host trust records, and preserve the last syntactically valid boot script.
- **Output or result:** A public key the user can register, and reboot-persistent Satchel command/authentication wiring on the appliance.
- **Failure behavior:** Non-appliance `--persist` is a no-op with explanation. Ambiguous or syntactically damaged boot-script blocks are left untouched. Replacement is refused if the result is empty, malformed, or cannot resolve the installed command. State on volatile storage is a diagnostic failure.
- **Required persisted state:** Local SSH key, appliance flash copy, host trust records, boot script block, and known-good backup.
- **External systems involved:** Git host, SSH tooling, Unraid flash storage and boot script.
- **Evidence of intent:** Public appliance documentation, command help, accepted deployment decisions, and boot lifecycle tests.
- **Confidence:** **Confirmed.**

## 2.21 Machine retirement and uninstall

- **User goal:** Remove one machine from shared state and/or remove the local program safely.
- **Trigger or input:** `satchel retire [machine]`; interactive `satchel uninstall`; noninteractive `satchel uninstall --yes`; destructive `satchel uninstall --purge --yes`.
- **Expected behavior:** Retirement deletes only the named machine's shared folder after confirmation and leaves Projects/shared state untouched. Uninstall removes the installed command, owned redirects, stopped owned helper containers, and image; it either preserves or explicitly purges local state. Interactive uninstall may offer to retire the current machine first.
- **Output or result:** Machine removal from the caravan, local program removal, or full local-state deletion according to the selected scope.
- **Failure behavior:** Unsafe or arbitrary deletion targets are refused. Active or unverified containers are not stopped. Image-removal errors are shown but do not justify deleting unknown containers. Failed interactive retirement stops uninstall before local removal and restores the shared clone. Purge warns about uncommitted/unpushed data and never deletes the remote repository.
- **Required persisted state:** None after full local purge; private remote and its history remain unless separately managed by the user.
- **External systems involved:** Container engine, private Git remote, host filesystem, appliance boot configuration.
- **Evidence of intent:** Public uninstall description, command help, and extensive destructive-action tests.
- **Confidence:** **Confirmed.**

---

# 3. Interfaces

## 3.1 Command-line interface

The following is the externally supported command surface evidenced by help, documentation, and tests.

| Interface | Purpose | Inputs and notable behavior |
|---|---|---|
| `satchel claude [args]` | Run Claude Code in the current directory | Passes remaining arguments to Claude after consuming Satchel flags. |
| `satchel codex [args]` | Run Codex in the current directory | Passes remaining arguments to Codex after consuming Satchel flags. |
| `claude [args]`, `codex [args]` | Optional shorthand via installed redirects | Equivalent to the corresponding Satchel session command. |
| `--host` | Disable ordinary host-filesystem isolation | Accepted before or after agent name; exposes host at `/host` and runs root in the container. |
| `--unsafe-home` | Override home/root mount refusal | Accepted before or after agent name; explicitly broad and dangerous. |
| `--with <dir>` | Add a read-write working root | Repeatable; accepted before or after agent name. |
| `satchel track [id]` | Enroll enclosing Git repository as a Project | Optional explicit ID; required mechanism for local/no-origin repositories. |
| `satchel untrack [id]` | Globally ignore a Project and remove active handoffs | Without ID, resolves enclosing tracked repository. |
| `satchel init` | Configure machine and synchronization | Interactive machine name and remote URL; can operate without remote. |
| `satchel sync` | Strictly validate, commit, pull, and push shared state | Conflicts require manual Git reconciliation. |
| `satchel status [--ignored]` | Show local and caravan state | `--ignored` expands ignored repository identities. |
| `satchel skills [list]` | List active user-installed skills | Bare command and `list` are equivalent. |
| `satchel skills remove [name]` | Remove a skill globally | Bare form provides a numbered picker; named form removes immediately. |
| `satchel key [--persist]` | Show or create public SSH key | `--persist` copies an existing standard key to appliance flash where supported. |
| `satchel retire [machine]` | Remove a machine from shared state | Bare form provides picker; confirmation required. |
| `satchel mcp list` | List registered MCP servers | Shows URL, auth mode, and whether this machine has a token. |
| `satchel mcp add [name] [url] [--no-auth]` | Add or replace an MCP server | Bare form is guided; default auth is bearer unless interactively declined or `--no-auth` is given. |
| `satchel mcp remove [name]` | Remove server and current token entries | Bare form provides picker. |
| `satchel settings` | Show settings and their sources | Does not require a working container engine. |
| `satchel settings <KEY> <value> [--local]` | Change a supported setting | Help says an empty value clears an override, but current behavior writes an explicit empty override and continues reporting that source; all supported keys are machine-scoped. |
| `satchel doctor` | Run end-to-end diagnostics | Probes mounts, synchronization, SSH, MCP, appliance state, and cross-machine version drift. |
| `satchel link [claude|codex]` | Install agent-name redirects | Bare form handles both agents. |
| `satchel unlink [claude|codex]` | Remove owned redirects | Bare form handles both agents. |
| `satchel import claude|codex` | Copy recognized host login into Satchel state | Does not sync credentials. |
| `satchel image` | Build image if missing | No-op when already present. |
| `satchel image --rebuild` | Force rebuild | Used by update; behavior is tested though not prominent in top-level help. |
| `satchel update` | Replace command from upstream main and rebuild image | Requires network and a writable install directory or privilege escalation. |
| `satchel uninstall` | Interactive uninstall scope selection | Defaults to cancel if no choice is made. |
| `satchel uninstall --yes` | Noninteractive program-only removal | Preserves local state and does not retire machine. |
| `satchel uninstall --purge --yes` | Noninteractive full local deletion | Deletes local credentials/transcripts/clone, never the remote repository. |
| `satchel version`, `satchel --version` | Print product version | Human-readable output. |
| `satchel help`, `satchel --help`, `satchel -h` | Print command help | Unknown commands fail and direct user to help. |

There are no API endpoints, web screens, webhooks, background workers, or daemon control interfaces.

**Confidence: Confirmed.**

## 3.2 Supported settings

| Setting | Scope | Default | Product effect |
|---|---|---|---|
| `SATCHEL_ENGINE` | Machine-local | Auto-detect | Force Docker or Podman. |
| `SATCHEL_SSH` | Machine-local | Enabled | Forward or prepare an SSH agent for sessions. |
| `SATCHEL_CLIPBOARD` | Machine-local | Enabled | Forward a graphical clipboard/display socket. |
| `SATCHEL_UID` | Machine-local | Host user ID, or 1000 when host is root | User ID for ordinary session containers. |
| `SATCHEL_GID` | Machine-local | Session UID | Group ID for ordinary session containers. |

The settings command describes a generic caravan-wide preference layer, but no currently supported setting is caravan-wide. This is a visible interface drift discussed later.

The local configuration is described as “plain bash” and is loaded as shell syntax. A synchronized settings file is also treated as shell syntax if populated. That is externally significant because a malicious or accidentally edited setting can execute commands on launch, not merely fail validation.

## 3.3 Environment variables

### Documented or user-relevant inputs

| Variable | Purpose |
|---|---|
| `SATCHEL_BIN` | Installation directory for a self-contained/relocatable install; it names a directory, not the executable. |
| `SATCHEL_DIR` | Override local state directory. |
| `SATCHEL_SHIMS` | Installer choice for agent-command redirects; `n` skips them noninteractively. |
| `SATCHEL_ENGINE` | Force container engine. |
| `SATCHEL_SSH` | Disable default SSH forwarding with `0`. |
| `SATCHEL_CLIPBOARD` | Disable default clipboard forwarding with `0`. |
| `SATCHEL_UID`, `SATCHEL_GID` | Override ordinary session user/group. |
| `NO_COLOR` | Disable ANSI color. |
| `CLICOLOR_FORCE=1` | Force ANSI color when output is not a terminal. |
| `SATCHEL_HOST` | Undocumented alternate way to enable Host Session when nonempty. |
| `SATCHEL_NO_HANDOFF` | Undocumented alternate way to suppress automatic handoff generation when nonempty. |

`SATCHEL_HOST` and `SATCHEL_NO_HANDOFF` are behaviorally real but not part of the public command documentation. They should not be treated as required compatibility contracts without approval.

### Variables exposed inside normal sessions

| Variable | Purpose |
|---|---|
| `SATCHEL_SESSION=1` | Let tools detect that they run inside Satchel. |
| `SATCHEL_SESSION_MODE=sandbox|host` | Identify the active safety boundary. |
| `SATCHEL_SKILLS_DIR` | Give installers the shared user-skill destination when synchronization is available. |
| `HOME` | Point tools at the persistent agent home. |
| `SSH_AUTH_SOCK` | Refer to the forwarded agent socket when available. |
| `GIT_SSH_COMMAND` | Enable first-contact host-key acceptance while later contacts are verified. |
| generated MCP bearer-token variables | Supply Codex with tokens by environment-variable name rather than command-line value. |

The environment inherits normal terminal and display context as needed. Test-only path overrides are not product interfaces.

## 3.4 Files and persisted interfaces

### Machine-local Satchel state

By default, local state is under `~/.satchel`; a self-contained install may use a sibling `.satchel` directory. The product reads or writes:

- machine-local configuration;
- synchronization clone;
- persistent Claude and Codex homes;
- machine-local MCP tokens;
- installed revision and install-path metadata;
- skill quarantine;
- cached agent-image versions;
- daily update-check timestamp;
- incomplete initialization recovery directories.

### Shared state in the private synchronization repository

Externally meaningful shared files and directories include:

- global profile and preference Markdown;
- portable repository tracking/ignore registry;
- global MCP server registry;
- optional synced MCP token file;
- generic synchronized settings file;
- one shared user Skill Library and optional installer lock metadata;
- per-machine path cache;
- per-machine notes, inventory, guides, handoffs, and runtime environment report;
- per-Project bounded handoffs.

These formats are part of the current external operational contract because users are told they may edit some of them by hand and may need normal Git to recover conflicts. Their existing JSON/env/directory schemas are not clean-room requirements.

### Host files and sockets read or modified

The product may interact with:

- standard host public/private SSH key locations and `known_hosts`;
- host `ssh-agent` socket;
- host Git configuration for author identity;
- native host Claude/Codex login files during explicit import;
- Wayland or X11 sockets and X authority;
- project directories and explicitly named extra directories;
- the entire host filesystem in Host Session;
- command locations under `/usr/local/bin` or `~/.local/bin`;
- on Unraid, the boot script and flash-backed SSH backup area.

## 3.5 Network and external-service contracts

The product communicates with:

- a user-supplied Git remote for synchronization;
- arbitrary project Git remotes from inside sessions;
- GitHub API and raw-content endpoints for install/update checks;
- public container/package registries during image build;
- Claude and OpenAI agent services through their native CLIs;
- user-configured MCP HTTP endpoints;
- any other network destination reachable by an agent session.

There is no evidence of network isolation, destination allowlisting, or a Satchel-hosted backend.

## 3.6 Authentication and authorization

- **Product users:** No account system, roles, or multi-user authorization exists.
- **Agent providers:** Native agent OAuth/API login is persisted per machine and never intentionally synchronized.
- **Git:** Host SSH-agent signing is forwarded by default; no private key is mounted into the session. HTTPS credentials are not managed explicitly.
- **Synchronization remote:** Uses ordinary Git/SSH or Git/HTTPS access configured by the user.
- **MCP:** Supports no authentication or bearer-token authentication. Tokens may be local-only or plaintext in the private Git repository.
- **Host access:** Authorized solely by the user choosing `--host` or `--unsafe-home`; there is no secondary approval or policy engine.
- **Destructive commands:** Authorization is inconsistent: retirement and interactive purge confirm, while named skill removal, MCP removal, and Project untracking treat the command itself as sufficient authorization.

---

# 4. Data requirements

## 4.1 Conceptual entities

### User

One implicit owner of the installation and private shared state. The product requires no user database, but assumes all machines, credentials, Projects, skills, and integrations belong to the same person.

**Lifecycle:** Exists outside the product. No invitation, role, revocation, or ownership-transfer workflow.

### Machine

A named participating Linux host.

**Required information:** Stable machine name; local settings; optional shared runtime report; machine knowledge; machine-scoped handoffs; checkout-to-Project cache.

**Lifecycle:** Created/joined at initialization; updated by sessions; optionally retired from shared state; local state may remain after retirement until separately purged.

### Agent type

One of the supported native coding-agent CLIs.

**Required information:** Agent identifier, persistent native home, authentication state, transcript state, native integration configuration, skill discovery path.

**Lifecycle:** Home is created on first use/import and retained until local purge.

### Session

One execution of one agent against a primary working directory, optional extra directories, and an explicit safety mode.

**Required information:** Agent, start/end boundary, primary path, extra paths, safety mode, environment capabilities, exit status, whether new transcript data appeared.

**Lifecycle:** Container is ephemeral; project changes and selected agent/shared state persist. Session records are not a separate database entity.

### Repository identity

A credential-free canonical identity derived from a portable Git origin.

**Relationships:** May be globally tracked as one Project or globally ignored. Multiple checkout paths and machines can refer to the same identity.

**Lifecycle:** Discovered, undecided, tracked, ignored, or changed when origin changes.

### Project

A user-approved Git repository continuity scope with a stable user-facing ID.

**Relationships:** One portable origin should map to at most one Project. One Project may have many machine-local checkout paths and many handoffs.

**Lifecycle:** Explicitly enrolled or accepted after substantive work; untracking removes active Project state and records ignore for portable origins; history retains recovery.

### Checkout mapping

A machine-local association between an absolute Git checkout path and a Project.

**Lifecycle:** Rebuilt from portable origin discovery, invalidated by origin change, removed when a Project is untracked, and considered disposable cache rather than identity.

### Handoff

A human-readable continuation record scoped to one Project or one machine.

**Required information:** Generation time, source machine, scope, goal, completed work, in-flight work, next steps, and gotchas.

**Lifecycle:** Created only after meaningful session activity; latest 100 active files retained per scope; older records recoverable through shared-state history.

### Personal context

Global user profile and preferences given to sessions.

**Lifecycle:** User-maintained, synchronized, loaded on every usable session.

### Machine knowledge

Three conceptual tiers:

- concise, current facts loaded every session;
- dated broad inventory loaded only when relevant;
- reusable topic procedures loaded only when relevant.

**Lifecycle:** Initial baseline or refresh, update-in-place, delete stale/incident-only facts, never treat as an append-only incident log.

### MCP server

A globally named HTTP integration.

**Required information:** Safe name, URL, auth mode.

**Relationships:** May have a bearer token stored globally or overridden locally per machine.

**Lifecycle:** Add/replace, materialize per session, remove current record and tokens, rotate externally if a formerly synced token matters.

### Skill bundle

A named, complete user-installed agent capability bundle.

**Required information:** Safe top-level name, required manifest, referenced files/assets as supplied by installer, no nested repository metadata or escaping links.

**Relationships:** Shared by both agent types and all machines. Optional installer metadata may describe sources/versions but remains installer-owned.

**Lifecycle:** Added/updated in-session, validated at session end, synchronized if valid, quarantined if invalid, removed explicitly, recovered through history if needed.

### Local quarantine

Recoverable storage for invalid skill attempts and malformed skill lock metadata.

**Lifecycle:** Created on validation failure; not synchronized or automatically deleted; surfaced through status.

### Runtime environment report

A machine's last reported Satchel revision, container engine, and agent versions.

**Lifecycle:** Updated after a session only when content changes; may be stale until the next session; used only for diagnostics.

### Credentials and trust records

Distinct categories with different retention:

- provider login and transcripts: machine-local until purge;
- SSH private keys: host-local, optionally copied to appliance flash;
- SSH-agent authority: ephemeral forwarding during a session;
- SSH known-host records: persisted per agent/machine;
- MCP bearer tokens: machine-local or synchronized plaintext;
- Git author identity: copied into persistent agent home where missing.

## 4.2 Relationships

- One User owns many Machines.
- One Machine has separate persistent homes for each Agent type.
- One Session uses one Agent type and one Machine.
- One Session has one primary working root and zero or more extra roots.
- One portable Repository identity is either undecided, ignored, or associated with one Project.
- One Project can appear at many checkout paths across Machines.
- One Handoff belongs to one Project or one Machine, never both.
- One MCP server definition is global; its token may be global or machine-local.
- One shared Skill Library is consumed by both Agent types on all Machines.
- Machine knowledge is authored locally but readable across the caravan.

## 4.3 Persistence and retention

- Project files persist because they live on the host.
- Agent login, transcripts, native config, and trust records persist locally until purge.
- Credentials and transcripts must not enter the shared synchronization state, except MCP bearer tokens when the user explicitly accepts synced storage.
- Active handoffs are bounded to 100 per scope; older handoffs depend on Git history for recovery.
- Machine inventory is replace-in-place, not historical.
- Machine notes/guides are current truth, not an incident archive.
- Skill quarantine is retained locally until the user handles it; no automatic retention bound is evidenced.
- Removed Projects, machine folders, skills, and old handoffs may remain in Git history indefinitely.
- Update-check metadata and runtime-version cache have no user-facing retention policy.

## 4.4 Import and export

- Agent login import copies recognized native host credentials into Satchel's machine-local agent home.
- Synchronization is the primary export/import mechanism for shared state.
- Public SSH key display is a manual export for registration with a Git host.
- Handoffs, notes, inventory, guides, profile, preferences, and skills are plain files and can be edited or extracted manually.
- No supported full backup/restore, archive export, data migration command, or credential export is evidenced.
- Uninstall can preserve local state for reinstall; purge permanently deletes the local copy but not the remote shared state.

## 4.5 Consistency and concurrency

Confirmed consistency requirements:

- durable structured files must not be left partially written;
- malformed required fields must be rejected;
- unknown fields should be ignored for forward compatibility;
- ambiguous identity conflicts must be reported, not guessed;
- synchronization conflicts must preserve local commits and leave the clone outside an in-progress merge/rebase;
- sessions must continue from local state when synchronization is unavailable;
- shared state deletion must target exactly proven-owned records.

Missing or unsupported consistency requirements:

- no same-machine multi-session locking contract exists;
- concurrent sessions share the same agent home and synchronization clone;
- concurrent changes to whole shared registries can conflict even when logically unrelated;
- no transactional boundary spans agent-home mutation, handoff generation, shared-state commit, and remote push;
- no formal schema-version or migration compatibility policy exists beyond ignoring unknown fields and one-time manual migrations.

These omissions are important open decisions, not requirements to reproduce.

---

# 5. Behavioral workflows

## 5.1 Install and initialize

### Preconditions

- Linux host.
- Bash, curl, Git, jq, and Docker or Podman available.
- Write permission to a standard command directory or a selected custom install directory.
- Optional private Git remote or shared bare-repository location.

### User actions

1. Run the installer.
2. Choose whether native agent commands should route through Satchel.
3. Provide a machine name.
4. Provide a private synchronization URL/path or skip synchronization.
5. Resolve any Git authentication prompt and optionally register the displayed public key.
6. On a volatile-root appliance, choose persistent storage and optionally approve boot persistence.

### System responses

1. Validate dependencies and target paths.
2. Install only validated content.
3. Preserve unrelated existing commands.
4. Configure local state.
5. Clone/create synchronization state or continue without it.
6. Preserve incomplete old state in recovery storage.
7. Register the machine and build the agent image.
8. Report a concrete next launch command.

### External interactions

- GitHub download/API.
- Container and package registries.
- Private Git remote.
- SSH tooling.
- Appliance flash, where applicable.

### Persisted changes

- Installed executable and optional redirects.
- Local machine configuration.
- Agent image.
- Synchronization clone and initial machine/global records.
- Optional SSH key and appliance persistence.

### Expected result

The user can change into a project and launch either supported agent.

### Failure and recovery

- Missing dependencies: install them and rerun.
- Image build failure: run the printed image command.
- Clone/auth failure: add/load the correct key and retry in place, or skip and rerun initialization later.
- Conflicting remote URL: manually move/reconcile the old clone before switching.
- Incomplete old clone directory: use preserved recovery copy if needed.

## 5.2 Ordinary local session

### Preconditions

- Installed Satchel and working container engine.
- Existing current directory that is not a forbidden broad root.
- Agent image available or buildable.

### User actions

1. Run the chosen agent command from the desired working directory.
2. Authenticate natively on first use if necessary.
3. Work in the agent.
4. Exit the agent normally or by interruption.

### System responses

1. Validate working roots and engine mount capability.
2. Prepare SSH before any synchronization network access.
3. Pull shared state best-effort.
4. Degrade synchronization instead of blocking on most shared-state failures.
5. Restore/preserve agent home and personal/project context.
6. Materialize MCP and skills if shared state is available.
7. Explain the real sandbox boundary to the agent.
8. Launch the agent in a disposable container.
9. After exit, repair owned persistent state, optionally generate handoffs, publish runtime facts, validate skill changes, and push shared changes.
10. Return the agent's exit status.

### External interactions

- Container engine.
- Agent provider.
- Sync Git remote.
- Project Git remotes.
- MCP endpoints.
- SSH/display sockets.

### Persisted changes

- Host project edits.
- Agent credentials/transcripts/native configuration.
- Trust records and Git identity.
- Skills, machine knowledge, handoffs, Project mappings, and runtime report when applicable.

### Expected result

The project is changed as requested, the container is gone, and the next session retains useful local and cross-machine continuity.

### Failure and recovery

- Synchronization offline: continue from local state, commit shared changes locally at exit, retry with `satchel sync`.
- Shared state malformed: continue without sync-derived mounts/context for the run.
- Agent failure: return its status; cleanup still runs.
- Handoff failure: preserve previous handoff.
- Cleanup/sync failure: warn and direct user to explicit sync.
- User interrupt during startup: stop instead of relabeling it as an offline condition.

## 5.3 Cross-repository session

### Preconditions

- All desired directories exist.
- None is filesystem root, a home scope, or Satchel private state.

### User actions

1. Start an agent with one or more `--with` flags, or launch from a parent directory containing multiple repositories.
2. Work across repositories.

### System responses

1. Resolve/validate each explicit root.
2. Mount only those roots.
3. Discover Git repositories only under allowed roots.
4. Tell the agent which tracked Projects are visible.
5. Attribute work to the nearest enclosing repository.
6. Combine work from multiple checkouts of the same origin into one Project handoff.
7. Store unrelated/non-Project work at machine scope.

### Persisted changes

- Project edits.
- Updated path mappings.
- Zero or more Project handoffs and possibly one machine handoff.

### Expected result

Each tracked Project touched receives its own continuation state without exposing unrelated host paths.

### Failure and recovery

- Unsafe/missing extra path: fail before launch.
- Unknown repository in noninteractive cleanup: preserve its work in a machine handoff without making a global decision.
- Failed enrollment prompt: preserve work at machine scope.

## 5.4 Explicit Host Session

### Preconditions

- User understands that the host is not protected from the agent.
- Container engine can mount host root.

### User actions

1. Start the selected agent with `--host`.
2. Refer to host paths through `/host`.
3. Make machine-level changes.

### System responses

1. Display a prominent warning.
2. Run the container process as root.
3. Mount host root read-write and expose host process namespace.
4. Tell the agent that container system paths are disposable and host paths live under `/host`.
5. Store non-Project continuation state at machine scope unless work is attributable to visible tracked Projects.

### Persisted changes

- Any writes under `/host`.
- Persistent agent-home changes.
- Machine or Project handoffs.

### Expected result

The user can use a packaged agent CLI to troubleshoot or modify the host deliberately.

### Failure and recovery

There is no product-level rollback for host changes. Recovery depends on host backups, ordinary system administration, and the agent/user's care.

## 5.5 Track a repository and continue across machines

### Preconditions

- Synchronization configured.
- Current directory is inside a Git repository.

### User actions

1. Run `satchel track [id]`, or accept a post-session prompt after substantive work.
2. On another machine, clone the same network origin and run a session.

### System responses

1. Canonicalize the credential-free remote identity.
2. Create or reuse a stable Project.
3. Record the local checkout mapping.
4. Discover the same identity on the second machine and map it to the same Project.
5. Inject or expose the latest Project handoff.

### Persisted changes

- Global tracked decision and Project ID.
- Machine-local checkout mappings.
- Project handoffs.

### Expected result

Continuation follows repository identity rather than folder name or machine path.

### Failure and recovery

- No portable origin: user must explicitly name an existing Project ID on each machine.
- Origin change: mapping is removed until a new decision is made.
- ID collision or malformed registry: fail explicitly.
- Decline: store ignored decision; work may still appear in machine handoff.

## 5.6 End-of-session handoff

### Preconditions

- Synchronization usable.
- New native transcript content appeared.
- Handoff not disabled.

### User actions

1. Exit the interactive agent.
2. Optionally press Ctrl-\ during the announced handoff phase to skip it.

### System responses

1. Isolate the helper from projects, host, credentials, clipboard, MCP, skills, and machine state.
2. Resume the relevant agent conversation using only the agent's local conversation home.
3. Request the fixed continuation fields.
4. Validate complete output.
5. Resolve Project/candidate/machine scopes.
6. Preserve unknown candidate work at machine scope.
7. Write new handoffs atomically and prune by filename to 100 per scope.
8. Commit and push best-effort.

### Persisted changes

- New handoff records and shared-state revision.

### Expected result

The next relevant session receives concise, current continuation context.

### Failure and recovery

- Helper exits nonzero: discard partial output and keep prior handoff.
- Helper output malformed: report format failure distinctly and keep prior handoff.
- Name collision with a container not proven to be Satchel-owned: do not remove it.
- Remote unavailable: retain local commit for later sync.

## 5.7 Synchronization conflict

### Preconditions

- Two machines have divergent edits in shared state.

### User actions

1. Start a session or run explicit sync.

### System responses

1. Attempt rebase/pull.
2. Detect conflict or unfinished Git operation.
3. Abort the in-progress operation.
4. Preserve local commit and preexisting uncommitted edits.
5. Leave the clone usable rather than mid-rebase.
6. During session startup, continue locally and warn.
7. During explicit sync, fail and instruct the user to reconcile with ordinary Git.

### Persisted changes

- Local branch retains local work; remote retains remote work; histories remain divergent until manual reconciliation.

### Expected result

No session lockout and no silent conflict resolution.

### Failure and recovery

If automatic abort cannot restore a usable clone, synchronization is disabled for that run. The user must repair the clone manually, then rerun explicit sync.

## 5.8 Add an MCP server

### Preconditions

- Synchronization configured and valid.
- Server reachable or at least has a syntactically valid URL.

### User actions

1. Run guided or argument-based `mcp add`.
2. Choose bearer or no auth.
3. If bearer, enter hidden token and choose synced or local storage.

### System responses

1. Validate and store definition.
2. Store token at selected scope.
3. Commit/push definition.
4. Probe endpoint and report response category.
5. On each later session, materialize the definition into the selected agent's native configuration while preserving unrelated settings.

### Persisted changes

- Global definition.
- Local or global token.
- Native per-agent configuration.

### Expected result

Both supported agents can discover the MCP server on each relevant machine.

### Failure and recovery

- Invalid URL/name/auth: refuse without changing native config.
- Missing token: prompt; skipping produces a registration without an auth header.
- Damaged native managed boundary: preserve the file unchanged and fail materialization.
- Formerly synced token removal: rotate it at the external service if repository history exposure matters.

## 5.9 Install, validate, and remove a skill

### Preconditions

- Synchronization configured.
- Session exposes the shared Skill Library.

### User actions

1. Ask an agent/installer to place a complete skill bundle in the shared library.
2. Exit the session.
3. Start a fresh session before relying on automatic discovery.
4. Optionally run skill removal by name or picker.

### System responses

1. Tell the agent the authoritative installation path and bundle rules.
2. Validate packaging at exit.
3. Move invalid attempts to local quarantine and restore prior valid content.
4. Report valid additions/updates/removals and synchronize them.
5. For removal, pull first, delete selected bundle, warn about stale installer metadata, and push immediately.

### Persisted changes

- Shared bundle or local quarantine entry.
- Optional installer metadata.
- Git revision/history.

### Expected result

A valid skill is available to both agents on all synchronized machines in a fresh session.

### Failure and recovery

- Invalid bundle: not synchronized; status shows quarantine.
- Push failure: local commit remains retryable.
- Misbehaving cross-agent skill: no per-agent placement fallback exists; the skill itself must handle compatibility.

## 5.10 Machine baseline

### Preconditions

- Synchronization configured.
- At least one agent authenticated.
- No completed current baseline, or user requested refresh.
- Interactive terminal.

### User actions

1. Accept, defer, or suppress the baseline prompt.
2. If accepted, review the agent's proposed knowledge files.
3. Approve or reject the proposal inside the agent interaction.

### System responses

1. Mount host root read-only.
2. Permit writes only to the machine knowledge area and agent home.
3. Instruct the agent on knowledge tiers and prohibited secrets.
4. Require a dated baseline marker.
5. Scan newly added content for likely secrets.
6. Synchronize only after successful validation.
7. End the command rather than launching a second normal session.

### Persisted changes

- Inventory, notes, guides, and optional suppression marker.

### Expected result

Future sessions have concise machine context and a discoverable dated inventory.

### Failure and recovery

- Agent exits or writes no valid inventory: onboarding remains incomplete.
- Suspected secret or invalid marker: disable automatic sync and require review.
- Defer/suppress: normal originally requested session continues.

## 5.11 Update

### Preconditions

- Installed command, network access, writable install directory, and working container engine.

### User actions

1. Run `satchel update`.

### System responses

1. Resolve current upstream main revision.
2. Download by immutable revision when possible.
3. Validate syntax.
4. Show commit subjects since installed revision when available.
5. Stage beside installed command and atomically replace.
6. Invoke the newly installed command to rebuild the image.
7. Record revision only after image build succeeds.

### Persisted changes

- Installed executable, image, revision record, and cached agent versions.

### Expected result

The local machine runs current upstream Satchel and newly fetched agent versions.

### Failure and recovery

- API unavailable: may fall back to a possibly stale main URL.
- Download/syntax failure: old executable remains.
- Install directory not writable: refuse update and explain.
- Image rebuild failure after executable replacement: executable may already be new while the revision stamp remains old; rerun update/image build.

## 5.12 Retire and uninstall

### Preconditions

- Installed command whose ownership can be proven.

### User actions

1. Optionally retire a named machine.
2. Choose program-only removal or full local purge.
3. Confirm destructive scope.

### System responses

1. Retirement pulls and validates shared state, deletes only target machine state, commits and pushes.
2. Program-only removal preserves local credentials/transcripts/clone.
3. Purge warns about unsynced data and deletes the exact local state tree.
4. Remove only owned redirects/containers; leave active or ambiguous resources untouched.
5. Never delete the remote repository.

### Persisted changes

- Remote machine folder removed if retired.
- Local state retained or deleted according to scope.
- Git history retains retired/deleted shared content.

### Expected result

The selected removal scope is completed without collateral deletion.

### Failure and recovery

- Failed interactive retirement push: restore local clone and stop before uninstall.
- Image blocked by active container: leave blocker, show engine error and inspection command.
- Unsafe path: refuse.
- Program-only removal: reinstall can reuse retained state.

---

# 6. Requirement confidence

## 6.1 Confirmed requirements

The following have convergent public documentation and automated contracts:

- support Claude Code and Codex;
- ordinary project-scoped disposable sessions;
- persistent per-agent local homes;
- explicit Host Session;
- repeatable extra directory mounts;
- home/root/Satchel-state mount guard;
- private Git synchronization;
- session launch survives synchronization failure;
- portable tracked-Project identity based on canonical network origin;
- global ignored repository decisions;
- machine- and Project-scoped handoffs;
- bounded active handoff retention;
- personal profile/preferences injection;
- MCP HTTP server registration with none/bearer auth;
- local or synchronized bearer-token storage;
- one shared cross-agent user Skill Library;
- skill quarantine and recovery;
- machine knowledge tiers and optional baseline onboarding;
- SSH-agent and clipboard forwarding with opt-outs;
- status, doctor, update, retirement, and safe uninstall;
- Unraid persistent-install behavior;
- no hosted service, database, or daemon;
- personal/home-lab rather than production positioning.

## 6.2 Strongly inferred requirements

### Local session is the non-negotiable core

The implementation repeatedly degrades bookkeeping to preserve launch, and an accepted decision explicitly states that the session is the product. The uncertainty is only whether a future product could omit cross-machine features entirely; current branding says it should not.

### Human-readable, inspectable state is a product value

Public language repeatedly emphasizes plain files, plain Git, readable context, and user recovery. This is strongly supported but partly entangled with the current implementation choice. The clean requirement is inspectability and recoverability, not a specific file layout.

### The user is trusted; agent activity is only partially trusted

The product assumes one owner controls all machines and shared state, while ordinary sessions limit filesystem scope. Default SSH/clipboard/network exposure shows that preventing data exfiltration by a malicious agent is not a fully enforced goal. This threat model is inferred rather than formally specified.

### Meaningful work should create continuity; trivial invocations should not

Tests distinguish transcript-producing sessions from `--help`, `--version`, or instant exits. The exact transcript-file heuristic is not a product requirement, but the intent is strongly supported.

## 6.3 Weakly inferred requirements

### One hundred active handoffs is the correct retention

The number is explicitly documented and tested, but it changed recently from ten and is described as a guardrail rather than a user need. Retaining “enough recent continuation history” is supported; exactly 100 is weakly justified.

### Runtime-version drift reporting belongs in the product

It is documented, tested, and accepted, but the decision record admits it was created while diagnosing the wrong cause and is useful mainly with several machines. The behavior is real; its necessity is weakly inferred.

### Both agents must always receive exactly the same skills

The shared library is intentional and fixed a real absence problem, but no evidence establishes that all future skills are cross-agent compatible. “Install once” is supported; mandatory identical exposure is less certain.

### Automatic daily update checks are necessary

Behavior is tested and nonfatal, but the product need is simply discoverable updates. A daily GitHub probe is one current expression, not a strongly supported requirement.

## 6.4 Questionable requirements

### AI-generated machine baseline

It is extensively documented and tested, so the behavior is intentional, but its relevance to the core session-and-continuity product is questionable. It introduces broad host inspection, model-dependent output, secret leakage risk, and a first-launch detour.

### AI-determined “substantive work” as the trigger for Project enrollment

Avoiding prompts for casual repository reads is a valid user goal. Making the handoff model decide whether a repository deserves tracking is a questionable requirement because model output controls durable global classification prompts.

### Cross-machine plaintext secret synchronization

“Configure once everywhere” is supported. Storing bearer tokens in Git history by default is a product choice, not a necessary requirement, and should be reconsidered independently.

### Appliance boot-script management

Unraid support is real and unusually well-tested. It is still a specialized deployment feature and should not define the core rebuild unless that platform remains explicitly in scope.

### Current synchronized settings mechanism

The UI describes caravan-wide preference settings, but the catalog contains only machine-local settings. The generic mechanism appears unfinished or vestigial.

### Supporting a broad `--unsafe-home` override

Users need an explicit escape hatch, but exposing an entire home directory—including SSH keys, tokens, and unrelated credentials—may be too coarse to be a product requirement.

## 6.5 Apparently accidental behavior

### “Without sync, handoffs/MCP/skills stay on this machine”

Initialization output claims those features remain local when no sync repository is configured. Actual command contracts disable Satchel MCP management, do not expose the shared Skill Library, and do not generate Satchel handoffs without a usable synchronization clone. Only the agent's native local home persists. This is a direct documentation/behavior contradiction.

### Settings UI claims a global preference path that no setting uses

The text is observable, but there is no current preference-scoped key. This appears left over from an earlier feature shape.

### Undocumented environment control surface

`SATCHEL_HOST` and `SATCHEL_NO_HANDOFF` change material behavior but are not documented as supported interfaces. They should be treated as implementation leakage until approved.

### Update can become half-applied

The executable is replaced before the image rebuild completes, while the installed revision record is written afterward. A failed rebuild leaves a mixed state. This is consistent with current code/tests but conflicts with the product's general atomic-update language.

### Docker custom-UID support is incomplete

An accepted decision explicitly tolerates missing passwd identity behavior for custom Docker UIDs because no current machine used it. That is environment-specific debt, not a clean requirement.

### Re-initialization discards established machine settings

A direct public-command probe showed that running initialization again replaces previously selected engine, SSH, clipboard, UID, and GID overrides with a fresh commented template. Nothing in the interface warns that initialization is also a settings reset. This appears accidental.

### Link and unlink accept unsupported agent names

Although help limits redirects to Claude and Codex, a public-command probe successfully created a redirect for an arbitrary name. That redirect later invokes an unsupported command. This is missing input validation, not an intentional extensibility contract.

### Distinct MCP identities can share one credential channel

Valid server names that differ only by case or by hyphen versus underscore can map to the same Codex token variable. The later value wins, so one logical server can receive another server's token. No product evidence supports this lossy identity mapping.

### “No authentication” can still use an old credential

Changing a registered server to unauthenticated mode does not remove an earlier token, and session materialization checks for a stored token without consistently honoring the current authentication mode. Retaining and attaching that stale secret contradicts the selected mode.

### A missing token or malformed shared registry can still block launch

A noninteractive missing-token probe exited unsuccessfully, and malformed MCP state is validated again after the Session path has announced that synchronization was degraded. Both contradict the explicit product rule that shared bookkeeping must not prevent a usable local Session.

---

# 7. Problems in the current product behavior

## 7.1 The “sandbox” name overstates the security boundary

An ordinary session cannot see arbitrary host files, which is valuable. However, it has unrestricted network access, a read-write project, persistent agent credentials/transcripts, a read-write shared skill library, writable current-machine knowledge, and by default live SSH-signing and desktop-clipboard sockets. The clipboard can expose passwords copied mid-session; the SSH agent can authorize any remote reachable by loaded keys. The product itself acknowledges these tradeoffs, but the single word “sandboxed” can imply stronger containment than exists.

There are also no evidenced CPU, memory, process-count, or network limits.

**Impact:** Users may overestimate protection against a malicious dependency, prompt injection, compromised agent, or accidental destructive command.

## 7.2 No-sync mode is described inaccurately

Public/setup messaging says handoffs, MCP, and skills remain on one machine without synchronization. The actual product provides only the local agent home/session; Satchel-managed MCP commands require sync, the shared library is not mounted, and handoff generation is skipped.

**Impact:** A user who intentionally chooses local-only operation receives less continuity than promised and cannot predict which features exist.

## 7.3 Same-machine concurrent sessions have no supported consistency model

Multiple sessions share one agent home, one shared-state clone, one skill library, and machine knowledge. There is no lock or transaction contract. The accepted project decision explicitly leaves concurrent-session reconciliation out of scope.

**Impact:** Concurrent sessions can race when rewriting native config, repairing skills, updating path mappings, creating commits, rebasing, pruning handoffs, or modifying the same skill/knowledge file. Failures may appear as Git conflicts, lost last-writer changes, or malformed state.

## 7.4 Cross-machine synchronization creates ordinary whole-file conflicts

Multiple machines rewrite centralized registries. Even changes to different logical entries can conflict. The recovery behavior is intentionally conservative and preserves work, but the user must enter the product's private state and perform manual Git reconciliation.

**Impact:** A feature sold as effortless cross-machine continuity can require expert Git surgery during normal multi-machine use.

## 7.5 Handoffs are nondeterministic and provider-dependent

Continuation depends on resuming a native agent transcript, the provider remaining available, a default model following an exact output structure, and conversation storage formats remaining compatible. The change history shows repeated work on model choice, empty sessions, Codex behavior, failure preservation, signals, and format handling.

The product fails safely by keeping the previous handoff, but that means stale context may silently remain the “latest” usable context after a meaningful session.

Validation checks only for required heading lines rather than order, uniqueness, size, or factual accuracy. Two handoffs for the same scope, machine, and UTC second can also select the same durable name.

**Impact:** The core cross-machine continuity feature is less reliable and less testable end-to-end than plain deterministic state capture; rare same-second writes can overwrite rather than append.

## 7.6 Durable Project decisions are coupled to model interpretation

The system tries to avoid nuisance prompts by asking only after a handoff model identifies substantive work. This lets model output influence whether the user is offered a durable global tracking/ignore choice.

**Impact:** Equivalent user activity may prompt inconsistently across models/versions, and missed candidate attribution moves work into machine scope.

## 7.7 Runtime builds are not reproducible

The base image and both agent CLIs are fetched from floating upstream tags/packages. Each machine builds at a different time. The product reports drift after the fact rather than preventing it.

**Impact:** The same Satchel revision can behave differently across machines and dates. Update can change the agent runtime without a product release boundary.

## 7.8 Plaintext bearer tokens persist in Git history

Synced storage is the default token choice. Removal deletes current files but cannot remove historical revisions. The product tells users to rotate tokens if that matters.

**Impact:** A copied backup, mistakenly shared remote, compromised Git account, or future collaborator can recover old tokens. This is a risky default even for a private personal repository.

## 7.9 Configuration is executable rather than purely declarative

Local and potentially synchronized settings are evaluated as shell syntax. Generated values are escaped, but manual edits or a compromised private remote can execute commands on the host whenever configuration is loaded.

**Impact:** The shared-state trust boundary is much broader than “plain configuration.” A synchronization compromise can become host code execution.

## 7.10 Machine baseline relies on an AI and heuristic secret detection

The baseline exposes the entire host read-only to an authenticated agent and allows writes to synchronized machine knowledge after in-agent approval. The secret scanner is pattern-based and only examines additions. It cannot prove that generated inventory is accurate, non-sensitive, current, or free from secrets that evade its patterns.

The inspection can write beyond the stated knowledge files within the current machine's synchronized area. If the baseline fails or a secret/marker check rejects it, partial changes remain in the working tree while the decision not to sync exists only in that process; a later command can publish them without repeating the same safety check.

**Impact:** Sensitive host details may be sent to the provider or committed to shared history. Users may mistake generated inventory for authoritative live state, and a rejected baseline is not durably quarantined.

## 7.11 Cross-agent skill sharing assumes compatibility

One bundle is exposed to both native skill systems. Validation checks packaging boundaries, not semantics, referenced-file completeness, trustworthiness, or compatibility.

**Impact:** A skill installed for one agent can misfire on the other; executable assets or prompt instructions propagate to every machine.

## 7.12 Global destructive commands have inconsistent confirmation rules

Named skill removal, MCP removal, and Project untracking can immediately create caravan-wide deletions; untracking also removes active handoffs. Retirement and purge require explicit confirmation.

**Impact:** Users cannot infer a uniform safety model from command shape. Recovery depends on knowing how to use shared-state Git history.

## 7.13 Update is tied to an unversioned main branch

There is no release channel, signature verification beyond HTTPS/GitHub trust, pinned dependency set, or rollback command. The executable can update before its image rebuild succeeds.

**Impact:** Reproducibility and rollback are weak, and a failed update can leave mismatched executable/image/revision metadata.

## 7.14 Diagnostic commands do not fully honor degradation

Sessions soft-fail malformed shared state, while explicit status and sync validate strictly. That is defensible for mutation, but it means the primary status command may stop at the first malformed record instead of providing a complete inventory of what remains healthy and what is broken.

**Impact:** The tool intended to explain state can itself be unavailable when explanation is most needed.

## 7.15 Specialized appliance behavior greatly expands the safety surface

The product edits a boot-critical script and persists an SSH private key on unencrypted flash. Current behavior is carefully tested and backed up, but this is high-consequence scope for a personal session wrapper. Persistence can choose several standard key types while the generated restoration path restores only one of them.

**Impact:** A defect can affect boot behavior or credential storage, a reported backup may not actually restore at boot, and the product must permanently carry platform-specific safety obligations.

## 7.16 The behavior set has changed extremely rapidly

The repository history shows the current product was assembled over only a few days with many successive feature additions, reversions, corrections, and reliability patches. Examples include changing skill topology, removing a drift helper and later adding different drift reporting, changing handoff model strategy repeatedly, revising Project identity storage, adding then simplifying automatic conflict recovery, and numerous fixes for signal, ownership, config, boot, and sync edge cases.

**Impact:** Passing tests establish current consistency, not settled product-market intent. Many behaviors are too new to treat as durable requirements without user validation.

## 7.17 Operational logging is minimal

The product relies on console messages, agent transcripts, shared-state history, and handoffs. There is no dedicated structured operational log, correlation ID, or session event record for diagnosing a failed lifecycle across engine, handoff helper, and sync.

**Impact:** Intermittent failures can be hard to reconstruct, especially after a warning-only cleanup failure.

## 7.18 Re-running initialization silently loses local settings

Initialization rewrites the machine configuration rather than preserving existing supported overrides. This was reproduced through the public initialization path: previously disabled SSH and clipboard forwarding and a custom Session UID disappeared without a warning.

**Impact:** A refresh or retry can silently widen delegated authority, change the Session identity, or select a different engine on the next launch.

## 7.19 The synchronization fail-open promise has blocking escape paths

Shared-state validation initially degrades a Session as intended, but later MCP materialization validates the same shared registry strictly. Synchronized settings are evaluated even earlier as executable shell input. A malformed MCP registry, shell syntax error, conflict marker, or hostile synchronized setting can therefore stop a normal Session despite the stated rule that bookkeeping must never block it.

**Impact:** The product's strongest recovery guarantee is path-dependent rather than global; damaged shared state can lock out the local workflow it is supposed to preserve.

## 7.20 MCP credential identity and unattended behavior are unsafe

Several current behaviors interact badly:

- two valid names can resolve to one Codex credential variable;
- an unauthenticated registration can still receive a stale stored token;
- a missing bearer token can abort a noninteractive launch;
- with multiple missing tokens, an inline prompt can consume registry input rather than human input;
- removing an absent server reports success;
- health probing treats most non-404 HTTP responses, including authentication and server errors, as reachable without performing an MCP exchange.

**Impact:** A server can receive the wrong secret, automation can hang or fail unexpectedly, removal cannot be verified reliably, and “healthy” does not mean authenticated protocol availability.

## 7.21 Native agent configuration ownership is inconsistent

One agent's managed MCP area has preservation logic for unrelated settings, while the other agent's entire native MCP collection is replaced. The preservation logic itself is textual and depends on third-party formatting conventions that may change.

**Impact:** User-created or third-party-managed integrations, trust decisions, and approval settings can be removed, moved, or misclassified during an otherwise routine Session start.

## 7.22 CLI and settings validation is incomplete

The link/unlink commands accept arbitrary names despite advertising only two agents. Some commands tolerate extra or misplaced arguments. UID/GID values need not be numeric; Boolean controls disable only on exact `0`; an engine override can name an arbitrary executable; and an empty setting value does not perform the documented clear operation.

**Impact:** Invalid input is accepted early and fails later in confusing or unsafe ways. Scripts cannot rely on strict grammar, and configuration output can misstate which layer controls a value.

## 7.23 Multi-system lifecycle operations are not atomic

Several user workflows can stop between durable steps:

- a failed clone can leave a configured remote URL without a usable clone;
- update can replace the command before runtime preparation succeeds;
- explicit retirement can leave an in-progress Git operation on some conflict paths;
- uninstall can remove the retry command after image deletion fails;
- baseline rejection is remembered only for the current process while changed files remain eligible for a later sync.

**Impact:** A reported failure does not identify one stable rollback point. The next command can observe a mixture of old and new state or publish content a previous safety check rejected.

## 7.24 Installation ownership and appliance key restoration are inconsistent

Redirect installation protects unrelated agent commands, but the main command destination is overwritten without proving ownership. On Unraid, key persistence may select Ed25519, ECDSA, or RSA material, while boot restoration restores only the Ed25519 spelling.

**Impact:** Installation can replace an unrelated program, and an appliance can report a key as backed up even though that key type will not be restored after reboot.

---

# 8. Features that should not automatically be recreated

Each item below requires explicit product approval even when current behavior is intentional.

## 8.1 Plaintext MCP tokens in synchronized Git history

The user goal is portable integration setup, not permanent secret retention. Require a deliberate threat-model decision and credential-lifecycle design.

## 8.2 Default SSH-agent forwarding

It gives the session signing authority for all identities loaded in the agent. Reconsider default-on versus explicit opt-in, per-session approval, or narrower authority.

## 8.3 Default live clipboard forwarding

It can expose sensitive content copied after launch and, depending on compositor, capabilities beyond clipboard. Screenshot paste is useful, but default-on broad socket access needs explicit approval.

## 8.4 Broad Host Session

Root plus host filesystem and process visibility is powerful and dangerous. Confirm that full-machine mutation belongs in the product rather than a separate explicit mode/tool.

## 8.5 `--unsafe-home`

Mounting a whole home directory defeats the primary filesystem-scoping promise and exposes many credentials. The need should be validated before recreating this exact escape hatch.

## 8.6 AI-generated automatic handoffs

The user need is continuity. A model-resumed transcript and strict prose format are one costly, nondeterministic way to obtain it. Approve the behavior, not the current mechanism.

## 8.7 AI-mediated Project enrollment

The “substantive work” heuristic reduces prompts but adds nondeterminism to durable classification. Recreate only if user research confirms the prompt problem and the desired trigger.

## 8.8 Identical shared skills for both agents

Cross-machine portability is supported; cross-agent identity is less certain. Require an explicit compatibility policy before making every installed skill visible everywhere.

## 8.9 Installer-owned skill lock-file exception

This exists to accommodate external installers and current library layout. It may be unnecessary in a clean product contract.

## 8.10 Machine baseline and knowledge taxonomy

Notes/inventory/guides are thoughtful but peripheral, model-dependent, and security-sensitive. Approve them as an optional product area only after the core session/continuity workflow is stable.

## 8.11 Sibling-machine knowledge visibility

Reading every other machine's notes from a session is convenient but broadens information exposure and coupling. It needs a clear user scenario.

## 8.12 Runtime drift reporting instead of reproducibility

Reporting mismatched versions treats a symptom. Decide whether reproducible runtimes, controlled releases, or simply local latest versions best match the product.

## 8.13 Daily GitHub update probing and direct-main self-update

These are release/distribution choices, not user capabilities. Do not inherit them without an update trust and rollback decision.

## 8.14 Unraid boot-script and key persistence

This is specialized and high consequence. Keep only if Unraid remains a named supported platform with dedicated validation ownership.

## 8.15 Automatic generated agent instruction files

The user goal is accurate boundary/context communication. Rewriting native instruction files is one integration strategy and may conflict with future native agent behavior.

## 8.16 Generic caravan-wide settings layer

There are no current global preference keys. Do not recreate an unused abstraction.

## 8.17 Undocumented environment switches

`SATCHEL_HOST`, `SATCHEL_NO_HANDOFF`, and test-oriented platform overrides should not become compatibility requirements by accident.

## 8.18 Exact handoff retention of 100

Retain a bounded, useful history, but choose the number based on user need, storage behavior, and recovery expectations.

## 8.19 Git repository as the required synchronization implementation

User ownership, inspectability, offline work, conflict safety, and recovery are strongly supported. A Git remote is the current external interface but may not be the simplest future way to provide those outcomes.

## 8.20 One self-contained Bash artifact

This is an implementation/deployment decision, not a product requirement. The rewrite team must not inherit it from this analysis.

---

# 9. Open decisions

## 9.1 What is the product's actual security promise?

- **Why it matters:** “Sandbox” can mean filesystem scoping, containment against accidents, or defense against a malicious agent. Current defaults satisfy only parts of those meanings.
- **Evidence:** Project/root mount guards are strong; network, SSH agent, clipboard, and several writable persistent mounts remain broad.
- **Simplest reasonable default:** Promise protection against accidental access to unmounted host files, not defense against hostile code; name every forwarded authority plainly and default sensitive sockets off until opted in.

## 9.2 Is cross-machine synchronization mandatory for setup?

- **Why it matters:** Current no-sync messaging contradicts actual feature availability.
- **Evidence:** Sessions work without sync, but Satchel handoffs/MCP/skills do not.
- **Simplest reasonable default:** Support a fully coherent local-only mode; make synchronization an optional enhancement with an explicit feature matrix.

## 9.3 What continuity data is truly required?

- **Why it matters:** Handoffs, transcripts, Project identity, profile, preferences, and machine knowledge overlap.
- **Evidence:** Handoffs are central, but generation has been repeatedly revised and can fail.
- **Simplest reasonable default:** Preserve native transcript state locally and one user-editable latest continuation note per tracked Project; add automatic summarization only if validated.

## 9.4 Should Project tracking be explicit or automatic?

- **Why it matters:** Automatic discovery/classification is one of the most complex workflows.
- **Evidence:** Users need cross-machine identity, but model-gated prompts exist mainly to avoid nuisance.
- **Simplest reasonable default:** Explicit tracking with clear status; no durable automatic decisions.

## 9.5 What identifies the same Project?

- **Why it matters:** Network origin is portable, but local/no-origin repositories are common.
- **Evidence:** Canonical credential-free remote identity works for hosted repositories; explicit ID linking handles local cases.
- **Simplest reasonable default:** Use a user-confirmed portable repository identifier; require explicit linking for repositories without one.

## 9.6 What should happen when shared changes conflict?

- **Why it matters:** Manual Git reconciliation undermines “configure once everywhere.”
- **Evidence:** Whole-file registry conflicts are expected; automatic merging was implemented and removed as unjustified complexity.
- **Simplest reasonable default:** Prevent unrelated logical entries from conflicting; never silently choose between conflicting edits to the same entry.

## 9.7 Are concurrent sessions on one machine supported?

- **Why it matters:** Shared agent homes and sync state can race.
- **Evidence:** No lock/transaction contract or tests; concurrent reconciliation is explicitly out of scope.
- **Simplest reasonable default:** Declare one mutating session per machine at a time until safe concurrency is specified.

## 9.8 How should secrets synchronize?

- **Why it matters:** Plaintext Git history is durable and hard to revoke.
- **Evidence:** Portability is intentional; local-only token mode already exists.
- **Simplest reasonable default:** Keep secrets machine-local by default; make any synchronized secret storage explicit and revocable.

## 9.9 Which integration protocols and authentication types are in scope?

- **Why it matters:** Current MCP support assumes HTTP and none/bearer auth only.
- **Evidence:** Validation and materialization are tightly bound to those cases.
- **Simplest reasonable default:** Support only the smallest protocol/auth set demonstrated by real users; fail clearly on unsupported cases.

## 9.10 Should skills be shared across agents?

- **Why it matters:** Similar manifest formats do not guarantee semantic compatibility.
- **Evidence:** A single library fixed missing-install problems; misbehavior is delegated to skill metadata.
- **Simplest reasonable default:** Share source bundles only when marked compatible; otherwise maintain explicit visibility without silent absence.

## 9.11 Is machine inventory part of the core product?

- **Why it matters:** It expands host exposure, provider data sharing, onboarding, and secret-handling scope.
- **Evidence:** Thorough documentation/tests, but weak relation to the minimum session workflow.
- **Simplest reasonable default:** Omit from the first rebuild; retain only concise manually maintained machine notes if users need them.

## 9.12 Which platforms and engines are supported?

- **Why it matters:** Docker, rootless Podman, root-run appliances, SELinux, nested containers, Wayland/X11, and custom UIDs have distinct behavior.
- **Evidence:** Many regressions and platform-specific tests; custom Docker UID remains knowingly incomplete.
- **Simplest reasonable default:** Publish a narrow tested matrix and reject unsupported combinations before launch.

## 9.13 Is Unraid a first-class supported platform?

- **Why it matters:** First-class support entails safely editing boot configuration and storing SSH keys on flash.
- **Evidence:** Extensive user documentation and tests indicate a real use case.
- **Simplest reasonable default:** Keep it as a separately approved platform adapter, not a core requirement.

## 9.14 What is the release and runtime reproducibility policy?

- **Why it matters:** Floating dependencies cause machine drift and make rollback difficult.
- **Evidence:** Drift reporting exists; direct-main updates are intentional.
- **Simplest reasonable default:** Version Satchel releases and record/pin the runtime components for each release, with an explicit upgrade command and rollback path.

## 9.15 What is the migration policy for durable state?

- **Why it matters:** A rewrite must consume or deliberately abandon existing user state.
- **Evidence:** Current history includes incompatible one-time migrations and no general migration framework.
- **Simplest reasonable default:** Define one documented import from the currently supported state, validate before conversion, and preserve the original for rollback.

## 9.16 What confirmation policy applies to global deletion?

- **Why it matters:** Current commands are inconsistent.
- **Evidence:** Some commands confirm; others treat a named argument as authorization.
- **Simplest reasonable default:** Preview scope and confirm any operation that deletes cross-machine state or active continuity; provide a noninteractive explicit force flag.

## 9.17 Who owns native agent configuration?

- **Why it matters:** Generated integration blocks and instruction files can conflict with settings written by the agent itself.
- **Evidence:** Special rescue logic exists because Codex wrote settings inside a managed block.
- **Simplest reasonable default:** Own only a clearly namespaced portion, preserve all unrelated native content, and abort rather than truncate on ambiguity.

## 9.18 What observability is required?

- **Why it matters:** Console-only warnings are insufficient for intermittent lifecycle failures.
- **Evidence:** Doctor/status exist, but no durable structured session event log.
- **Simplest reasonable default:** Keep a small local diagnostic record of session phase outcomes and last synchronization error, excluding prompts, project content, and secrets.

## 9.19 What should “retention” mean?

- **Why it matters:** Active file pruning relies on Git history as an archive and retains secrets/deleted content indefinitely.
- **Evidence:** Handoffs are bounded; Git history is the recovery story.
- **Simplest reasonable default:** Define separate active-continuation and archival policies, including whether users can permanently erase secrets or retired machine data.

## 9.20 Is this permanently a single-user product?

- **Why it matters:** Shared plaintext secrets, globally writable skills, and no authorization only make sense under a single trusted owner.
- **Evidence:** All vocabulary and behavior assume one user.
- **Simplest reasonable default:** State single-user ownership explicitly and reject shared/team use until separately designed.

---

# 10. Clean-room specification

## 10.1 Product definition

Satchel is a single-user Linux command-line product that runs supported AI coding agents in disposable execution environments. An ordinary session is limited to user-selected working directories while retaining the selected agent's local login and conversation state. Optional private synchronization carries approved continuity and integration data between the user's machines.

The product is for personal development and home-lab use. It is not a multi-user service, a production orchestration platform, or a defense against a malicious agent. Its ordinary safety promise is that unselected host filesystem paths are unavailable, not that the agent has no network or delegated credentials.

## 10.2 Required functionality

### R1. Install and initialize

The user can install the product on a supported Linux machine, select a local state location, choose whether native agent command names route through it, and initialize a stable machine identity.

**Acceptance criteria**

1. Installation validates required host capabilities before reporting readiness.
2. Existing unrelated commands or files are never overwritten.
3. Invalid downloaded program content is never installed.
4. A failed runtime preparation leaves the installed command available and gives a deterministic retry.
5. The product can initialize without a synchronization destination and clearly states which features remain available.
6. Repeating or refreshing initialization preserves established settings unless the user explicitly changes or resets them.

### R2. Launch supported agents

The user can launch either supported coding agent from a working directory and pass through that agent's ordinary arguments.

**Acceptance criteria**

1. The primary working directory is available read-write at the same absolute path.
2. The agent runs interactively when attached to a terminal and noninteractively otherwise.
3. The execution environment is removed when the agent exits.
4. Host project changes remain.
5. The product returns the agent process's exit status after cleanup.
6. Missing dependencies or unsupported runtime conditions fail before the agent starts with an actionable explanation.

### R3. Enforce the ordinary filesystem boundary

Ordinary sessions can access only the primary working directory, explicitly approved extra working directories, and narrowly defined product-owned persistent state.

**Acceptance criteria**

1. Host root, the user's home scope, product-private state, and symlink equivalents are refused as working roots by default.
2. Every extra working directory is explicitly named, resolved, and validated.
3. Unselected host paths are absent from the session.
4. The agent receives accurate instructions explaining which paths are host-backed and which are disposable.
5. A broad-access override, if provided, is explicit, visibly dangerous, and never silently inferred.

### R4. Preserve local agent state

Authentication, native conversation records, trust records, and user-selected native agent settings survive disposal of a session on the same machine.

**Acceptance criteria**

1. Each supported agent has separate persistent local state.
2. Provider login credentials and full transcripts are never included in cross-machine synchronization.
3. The user can authenticate normally inside the agent.
4. The user can explicitly import an already existing recognized host login.
5. Import failure does not damage either host or product-managed credentials.
6. Product-managed integration updates preserve unrelated native agent configuration.

### R5. Remain usable when synchronization fails

The local agent session is more important than bookkeeping.

**Acceptance criteria**

1. No synchronization destination is required to launch a local session.
2. Network unavailability, remote rejection, malformed shared state, or a recoverable conflict does not block an ordinary session.
3. The user is told which synchronized features are unavailable for that run.
4. Local shared changes remain recoverable and retryable.
5. A user interruption remains a user interruption and is not converted into a warning-only network failure.
6. No shared input is executed or consumed after the product has declared shared state unusable for that run.

### R6. Synchronize approved continuity data privately

The user can connect multiple machines to a private, user-controlled synchronization destination and carry noncredential continuity data between them.

**Acceptance criteria**

1. Setup identifies the machine and synchronization destination explicitly.
2. Shared data categories are documented, including what never synchronizes.
3. Updates are validated before consumption.
4. Required fields are validated while unknown future fields do not break older clients.
5. Conflicts never silently discard either side or leave shared state in an unusable in-progress operation.
6. The user can see pending local changes and remote divergence.
7. The synchronization mechanism provides a documented recovery path for recent deletion or pruning.

### R7. Associate continuity with portable Projects

The user can explicitly track a Git repository as a Project so that continuation follows the repository across paths and machines.

**Acceptance criteria**

1. Ordinary non-Git directories cannot become Projects.
2. Equivalent credential-free remote identities resolve to one Project.
3. Folder name alone never establishes identity.
4. Different remote identities never merge without explicit user action.
5. Local/no-origin repositories require explicit linking.
6. Changing a checkout's origin invalidates stale identity.
7. The user can list tracked and ignored repositories.
8. Removing a Project previews the cross-machine state that will be removed and preserves a recovery path.

### R8. Provide reliable continuation handoffs

After meaningful work, the product can preserve a concise human-readable continuation record for the relevant Project or machine.

**Acceptance criteria**

1. A handoff records goal, completed work, in-flight work, next steps, and gotchas.
2. Trivial or empty sessions do not replace a valid existing handoff.
3. A failed or malformed handoff attempt leaves the prior valid handoff unchanged.
4. Multi-Project work is attributed to each touched Project; unrelated work is kept at machine scope.
5. The next relevant session can find the latest handoff without loading every Project's history.
6. Active retention is bounded and older data has a documented recovery/erasure policy.
7. The user can disable or skip automatic handoff creation.

### R9. Handle credentials explicitly

The product clearly separates local provider credentials, delegated SSH authority, integration tokens, and synchronized nonsecret state.

**Acceptance criteria**

1. Private SSH key files are never mounted into ordinary sessions.
2. Any delegated SSH-agent authority is accurately reported and can be disabled.
3. Missing SSH authority does not block sessions; the user receives actionable guidance.
4. Secret values do not appear in process arguments or diagnostic output.
5. Integration tokens are local-only by default unless the user explicitly approves a synchronized secret mechanism.
6. Removing a synchronized token states whether historical copies remain and what rotation is required.
7. Distinct integration identities cannot collapse onto one credential channel.
8. A declared unauthenticated integration never receives a stored credential.
9. Missing credentials in unattended operation have a deterministic, non-prompting outcome that does not block unrelated local work.

### R10. Fail safely and preserve user data

Ambiguous, malformed, interrupted, or partially completed operations preserve recoverable user state.

**Acceptance criteria**

1. Incomplete initialization data is preserved rather than overwritten.
2. Structured durable writes are atomic.
3. Ambiguous symlinks, ownership, identity conflicts, and malformed records are refused rather than guessed.
4. Failed cleanup never justifies deleting an unrecognized process, container, command, or directory.
5. Session cleanup survives repeated terminal interrupt signals after the interactive agent exits.
6. Failures distinguish remote/network, validation, provider, and format errors where the recovery actions differ.
7. A failed multi-system operation identifies which effects committed, which rolled back, and what exact retry remains safe.

### R11. Report state and health

The user can inspect local configuration, synchronized state, pending changes, and runtime health even when some dependencies are absent.

**Acceptance criteria**

1. Status reports machine identity, runtime availability, synchronization state, tracked Projects, ignored count, continuity data, and enabled integrations.
2. A missing container engine does not truncate reporting.
3. Diagnostics probe the exact mount capability required by sessions.
4. Invalid shared data is reported precisely enough to repair without suppressing unrelated health information.
5. No diagnostic claims successful comparison when no comparison data exists.
6. Diagnostic output excludes secret values.

### R12. Remove the product safely

The user can remove the program while retaining local data, or explicitly delete all local product state. A machine can be retired from synchronized state independently.

**Acceptance criteria**

1. Program-only removal preserves local logins, transcripts, configuration, and synchronized clone.
2. Full local deletion requires explicit destructive authorization and warns about uncommitted/unpushed work.
3. The remote synchronization destination is never deleted by local uninstall.
4. Only installation-owned commands, redirects, and stopped helper resources are removed.
5. Active or ambiguous resources are left untouched and reported.
6. Failed remote retirement leaves local uninstall unstarted and shared state recoverable.

## 10.3 Optional functionality

The following may be included only after explicit product approval:

- read-write access to additional working directories;
- a full host-access session;
- SSH-agent forwarding;
- live desktop clipboard forwarding;
- MCP server registration;
- cross-machine skill distribution;
- automatic AI-generated handoffs;
- personal profile/preference injection;
- machine notes and AI-generated inventory;
- cross-machine runtime-version comparison;
- self-update;
- native command-name redirects;
- specialized persistence for volatile-root appliances.

Optional capabilities must preserve all required safety, failure, and credential-handling criteria. An optional capability's absence must not make the basic local session unusable.

## 10.4 Explicit non-requirements

The rebuild is not required to preserve:

- any current programming language, source layout, function boundary, or packaging strategy;
- a Git repository as the internal synchronization mechanism;
- current file or JSON schemas;
- current container-image composition;
- a daemon-free design, unless separately chosen for operational reasons;
- exact current prompt wording;
- exact numeric retention limits;
- undocumented environment switches;
- automatic model-based Project classification;
- plaintext secret synchronization;
- direct updates from an unversioned branch;
- identical skill exposure to both agents;
- specialized appliance behavior unless that platform remains supported.

## 10.5 Product-level completion criteria

A new implementation is behaviorally complete when:

1. a user can install it on the declared supported platform matrix;
2. both supported agents launch against an explicitly selected project;
3. unselected host filesystem paths are unavailable in ordinary mode;
4. agent login and conversation state persist locally;
5. sessions still launch with synchronization absent or broken;
6. approved continuity data can move safely between two machines;
7. the same Project is recognized across two differently located checkouts;
8. a failed handoff, sync, update, or uninstall attempt preserves the last known recoverable state;
9. every credential path and delegated authority is documented, observable, and optional where feasible;
10. diagnostics explain partial failure without exposing secrets;
11. concurrent-session support is either verified or explicitly refused;
12. destructive operations show their scope and never delete unproven targets.

This specification deliberately stops at observable behavior. It does not select a replacement architecture.
