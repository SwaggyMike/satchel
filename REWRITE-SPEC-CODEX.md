## 1. What the program does, as observable behavior

### Purpose and installation

- Satchel installs one host command that launches Claude Code or Codex in disposable Linux containers. It can also install host commands named `claude` and `codex` that redirect to the corresponding Satchel session.
- Installation can be conventional, with the command on the host `PATH` and state in the user's home, or self-contained, with the command, redirects, and state beside one another in a user-selected persistent directory.
- Initial setup gives the machine a caravan-wide name, optionally connects it to a user-owned private Git repository, creates or imports the initial synchronized state, registers the machine, and ensures that the shared agent image exists.
- Setup can work without a Sync Repo. Normal sessions still launch, but synchronized capabilities are unavailable. The current messages about what remains local in this mode are contradictory; see section 6.
- A local path can be used as the Sync Repo remote. If it is absent or empty, interactive setup can create a bare Git repository there.
- The program can generate an unencrypted Ed25519 SSH key, print every public key found in the host user's SSH directory, and explain that the user must authorize a key at the Git host manually. It never registers a key through a forge API.

### Sessions

- A normal session launches the selected agent in the current directory. The current directory is mounted read-write at the same absolute path and is also the container working directory.
- Extra directories can be mounted read-write at their real absolute paths with repeatable `--with` options.
- Normal session containers are removed when the agent exits. The agent's login state, settings, SSH trust records, and transcripts persist in a separate per-agent local home and are reused by later sessions on that machine.
- The session receives generated instructions describing which files are real host-mounted files, which paths belong only to the disposable container, whether SSH is usable, which synchronized resources are available, the machine-knowledge rules, visible Projects, and the latest relevant handoff.
- Claude and Codex receive all unrecognized session arguments. Satchel consumes its own `--host`, `--unsafe-home`, and `--with` options even when those options occur after the agent name.
- Agent self-updaters are disabled. Agent upgrades happen when the shared container image is rebuilt.
- Codex runs with its own inner sandbox disabled because the container is the normal Session safety boundary. A user-supplied later Codex configuration option can override the default passed by Satchel.
- The session returns the interactive agent's exit status after best-effort cleanup, handoff generation, state validation, and synchronization.

### Normal Session safety boundary

- A normal Session runs without Linux capabilities, with `no-new-privileges`, as a configurable non-root UID and GID. A root-run host defaults the container user to `1000:1000`; a non-root host defaults to the invoking user's UID and GID.
- By default, the normal Session does not mount the host root filesystem. Files outside the declared project and extra mounts are not visible unless they are part of Satchel's explicitly mounted persistent state. Explicit `--unsafe-home` use can deliberately broaden the primary mount to the user's home or `/`.
- The program refuses a normal Session whose primary mount is `/`, contains the user's home, is inside Satchel's private state, or contains Satchel's private state. In an interactive terminal it can offer a Host Session instead. `--unsafe-home` bypasses a refusal classified as `/` or home exposure. It does not bypass a path classified directly as private-state exposure, but mounting the home or `/` can indirectly expose private state beneath that broader root.
- Extra mounts always reject `/`, a nonexistent path, a path that contains the user's home, and a path that overlaps Satchel's private state. Symlinks are resolved before these decisions.
- On root-run hosts, the program warns before launch when a mounted work directory is not writable by the configured Session UID and prints host-side ownership and alternative launch options.
- The program adds each normal Session mount root to the persistent agent Git configuration as a trusted Git directory. It also copies the host Git configuration into a new agent home, or fills only a missing `user.name` or `user.email` in an existing agent Git configuration.

### Host Sessions

- `--host` launches a deliberately unsandboxed Host Session. It runs as root, is privileged, shares the host PID and network namespaces, and exposes the host root filesystem read-write at `/host`.
- The original project remains mounted at its bare absolute path as the working directory. Bare container paths such as `/etc` and `/var` are still disposable container paths; the corresponding real host paths are under `/host`.
- A Host Session prints an explicit pre-launch warning. Normal Sessions do not print a routine mode banner. Because the working directory is also mounted at its bare absolute path, a Host Session launched from a system directory can make that particular bare path refer to the real host even though the general instructions call bare system paths disposable; this conflict is an open question in section 6.
- Extra `--with` directories are ignored in Host Sessions because the complete host filesystem is already visible at `/host`.

### SSH and Git behavior

- SSH-agent forwarding is enabled by default. The Session receives a Unix socket, never private-key files.
- Before any Sync Repo network operation, Satchel determines whether the agent socket is usable by the Session UID and whether it has identities.
- If a reachable agent is empty, Satchel attempts to add standard host keys. If no usable agent exists but a standard host private key exists, Satchel starts a temporary per-Session agent, loads the key, forwards that socket, and destroys it after the session and final sync.
- Supported automatic key names are `id_ed25519`, `id_ecdsa`, and `id_rsa`, in that preference order.
- Passphrase entry occurs in the host terminal. If it is interrupted, launch stops and temporary SSH state is cleaned up.
- If no usable identity can be provided, an interactive launch explains that Git-over-SSH pushes will fail and waits for acknowledgment; a noninteractive launch warns and continues.
- First contact with an SSH Git host accepts and records a new host key in the persistent agent home. Later sessions verify against that stored record.
- Host `~/.ssh/config` is not mounted. Host-specific aliases, usernames, ports, and `IdentityFile` selections therefore do not apply in a normal Session.

### Clipboard behavior

- Clipboard forwarding is enabled by default when a graphical socket is available.
- Wayland is preferred. Otherwise, X11 is used when `DISPLAY` is set and the X11 socket directory exists.
- A running Session can read and write the live host clipboard, including clipboard changes that occur after launch. This applies to normal, Host, and Machine Baseline sessions.
- Headless hosts and hosts with no usable compositor socket receive no clipboard mount and no error.

### Projects and repository decisions

- A Project is an explicitly tracked Git repository. Ordinary directories cannot become Projects.
- A portable, credential-free Git origin is the global identity used across machines. Multiple checkouts of the same normalized origin share one Project. Different origins must not share one Project ID.
- Network-origin repositories can be discovered recursively within only the primary and extra mount roots. Discovery occurs before and after the interactive Session so repositories cloned or initialized during the Session can be recognized.
- Discovery does not follow symlinks and skips common high-volume dependency/build directories.
- Git repositories with no origin or only a local origin can be tracked only through an explicit command. On another machine, the user must explicitly name an existing Project ID to associate such a checkout.
- An unknown network-origin repository is offered for tracking only if end-of-session analysis says substantive continuation-worthy work occurred there. Merely discovering, listing, or casually reading it does not prompt.
- Declining the tracking prompt records a caravan-wide ignored decision. Work done there is still eligible for the current machine's handoff.
- Explicit tracking reverses a prior ignored decision.
- Untracking a network Project records its origin as ignored, removes every machine's active path mapping, and removes the active Project handoffs. Git history remains the recovery mechanism.
- Nested repositories attribute work to the nearest enclosing tracked repository.
- Project IDs and machine names must begin with an ASCII letter or digit and otherwise contain only ASCII letters, digits, dots, underscores, and hyphens. Suggested IDs replace other characters with hyphens and add `-2`, `-3`, and so on to resolve collisions.

### Handoffs

- After a Session that creates a new agent transcript, Satchel asks the same agent to resume the conversation and generate a short continuation note.
- No handoff is generated for trivial launches that create no transcript or when handoffs are explicitly disabled.
- One tracked Project visible at the launch scope receives a single Project handoff. Multi-repository Sessions can receive separate handoffs for every tracked Project actually worked in plus one machine handoff for work outside all tracked Projects.
- Work in an unknown repository can be converted to a newly tracked Project handoff after an interactive tracking decision. In noninteractive operation, or when enrollment fails, that work is preserved in the machine handoff without creating a global decision.
- The unattended handoff writer can access the selected agent's persistent conversation home and an empty temporary filesystem at the original working-directory path. It does not receive project contents, `/host`, the SSH socket, clipboard sockets, synchronized machine state, Project state, shared skills, or registered MCP tools.
- Handoff generation uses the agent's normal default model at low reasoning effort and has a four-minute limit.
- Ctrl-C used to leave the interactive agent is ignored during durable cleanup and handoff generation. Ctrl-\ deliberately cancels the handoff writer and preserves the previous handoff.
- `NO_HANDOFF` from a successful writer is a valid "nothing meaningful happened" result. A nonzero writer exit, timeout, malformed output, incomplete scope, or unknown scope preserves the previous valid handoff and produces a warning.
- Each Project or machine scope retains the latest 100 handoff Markdown files by filename. Older active files are removed but remain recoverable from Sync Repo history.

### Machine knowledge and onboarding

- Every machine can have concise current notes, a dated inventory, and topic-oriented reusable guides.
- Current notes are injected into every Session on that machine and have a 750-word soft limit. Exceeding the limit warns but does not delete content.
- The current inventory and guides are listed by path and title or generation time but are not loaded automatically. All machines' knowledge is readable to Sessions; only the current machine's knowledge is writable.
- After an agent has authenticated, the next normal interactive launch offers a Machine Baseline if none has been completed and the reminder has not been disabled.
- Accepting the offer consumes that launch: the baseline runs and the command returns to the shell rather than continuing into the originally requested normal Session.
- Deferring or permanently suppressing the reminder continues into the originally requested Session.
- The baseline agent sees the real host at `/host` through a read-only mount and can write its persistent agent home plus the current machine's entire synchronized directory. Its prompt restricts writes to approved knowledge files, but that narrower boundary is not enforced by the mount. It must show proposed content and obtain user approval before saving it.
- A successful current baseline must replace the inventory with a version-2 marker, preserve or improve valid current notes and guides, avoid histories and one-off incidents, and pass a heuristic scan for newly introduced secrets.
- A clean agent exit that does not create or change the inventory is a baseline failure. An invalid marker or suspected secret prevents automatic synchronization and leaves the content local for review.
- Re-running initialization on an already initialized machine offers a baseline creation or refresh when at least one agent is authenticated.

### MCP Registry

- MCP servers are registered once and synchronized across the caravan.
- A server has a safe name, a URL, and either bearer authentication or no authentication.
- Adding or removing a server commits and best-effort pushes the change immediately.
- A bearer token can be stored in the private Sync Repo or only on the current machine. A local token overrides a synchronized token with the same server name.
- Missing bearer tokens are requested interactively when a server is added or when an agent configuration is materialized. Skipping the prompt configures the endpoint without an authorization header.
- Removing a server removes both current local and synchronized token entries. A formerly synchronized token remains in Git history, and the user is told to rotate it at the source when that matters.
- At every Session start, the registry replaces the managed MCP portion of the selected agent's persistent native configuration.
- Claude receives HTTP MCP entries and inline bearer headers in its local persistent configuration.
- Codex receives MCP server tables whose bearer tokens are named through environment variables. Token values are inherited by the container process but are not placed in the container engine's command-line arguments.
- Server addition and diagnostics perform a five-second reachability probe. A 404 is reported as a likely wrong path; a server reachable only with TLS verification disabled is reported as likely self-signed; an HTTPS URL whose HTTP counterpart responds is reported as a likely wrong scheme; any other HTTP status is treated as reachable.

### Skill Library

- One synchronized Skill Library is mounted read-write at each agent's native skills path. Both agents and every machine share the same user-installed skill set.
- Installing or updating a skill means placing a complete top-level skill directory into the mounted library during a Session. No host-side install command or source/update protocol is provided.
- A new skill can be assumed discoverable only after starting a fresh Session.
- At Session end and explicit sync, every top-level entry is validated. A skill must have a safe directory name, be a real directory, contain `SKILL.md`, contain no nested `.git`, and contain no broken or escaping symlinks.
- Invalid additions are moved to a machine-local quarantine and never synchronized. If an existing committed skill was damaged, its committed valid version is restored after the invalid attempt is quarantined.
- A single installer-owned `skills-lock.json` file is allowed when it is a real nonsymlink file containing valid JSON. Satchel synchronizes but does not interpret or rewrite it.
- Codex's `.system` skills are runtime-owned, local, ignored by the Sync Repo, and not reported as user-installed skills.
- Active skills can be listed or removed by exact name or interactive numbered choice. The chosen removal is immediate, has no second confirmation, and is committed and best-effort pushed caravan-wide. If the lock file still appears to refer to the removed name, the program warns and leaves the lock file unchanged.

### Synchronization and caravan behavior

- The Sync Repo carries shared user context, repository decisions, Project and machine handoffs, machine knowledge, MCP configuration and optionally tokens, settings, runtime reports, and the Skill Library.
- Agent OAuth/API login data and transcripts remain machine-local and never enter the Sync Repo.
- Session startup best-effort pulls with rebase and autostash. Session completion validates state, records changed skill state and runtime versions, creates an ordinary Git commit if needed, integrates upstream changes, and best-effort pushes.
- Explicit synchronization validates state, repairs or quarantines skills, prunes handoffs, commits all local changes, pulls with rebase, and pushes.
- The program supplies a repository-local Git author identity when no identity is configured.
- A Sync Repo failure must not prevent an agent Session from starting. Malformed synchronized state degrades synchronization for that run; the Session continues without synchronized mounts or final push.
- A rebase/merge/cherry-pick/revert conflict is not resolved automatically. The in-progress operation is aborted, the local commit and preexisting uncommitted edits are preserved, and the user is told to reconcile with ordinary Git.
- Failed/offline pushes leave a local commit for a later explicit sync.
- Status and explicit synchronization are strict operations: invalid synchronized state is an error because the user explicitly asked about that state.

### Status, diagnostics, image management, updates, and removal

- Status reports the program version, machine, detected engine, image and agent versions, command redirects, Sync Repo and ahead/behind state, baseline state, caravan machines, Projects and handoff counts, ignored-repository count or details, MCP names, skills, quarantine count, and host-only Claude plugins.
- Status and settings reporting still work when no container engine is installed or running.
- Diagnostics check host commands, engine health, image presence, a real bind-mount probe, SSH keys and agent usability, GitHub update reachability, internal ownership, Sync Repo reachability/cleanliness/ahead/behind state, cross-machine version drift, Unraid persistence, and MCP endpoint reachability. Warnings do not make diagnostics fail; one or more `FAIL` results produce a nonzero exit.
- The shared image is built on demand, can be explicitly rebuilt, and contains both agent CLIs plus development, Git, SSH, JSON, search, compiler, Python, and clipboard tools.
- Every machine builds its own image from floating upstream package versions. The machine reports its actual Satchel and agent versions after Session completion; diagnostics compare reporting peers and distinguish "no peers," "peers have not reported," "peers agree," and "peers differ."
- Once per 24 hours, Session startup best-effort checks whether the published script differs from the installed script and prints an update notice. The timestamp is recorded before the probe, so an offline host does not retry on every Session.
- Explicit update resolves GitHub `main` to a commit when possible, downloads and syntax-checks the script, replaces the installed command, invokes the newly installed command to rebuild the image, records the installed commit only after the image succeeds, and reports included commits when GitHub supplies them.
- Linking and unlinking redirects never overwrite or remove an unrelated executable. Removal recognizes only an exact redirect owned by the current installation; ambiguous legacy or other-installation redirects are preserved with a warning.
- Uninstall can remove only the program, owned redirects, and image while preserving local state, or can permanently purge the validated local state directory as well. It never deletes the remote Sync Repo.
- Interactive uninstall defaults to cancellation, can optionally retire the current machine first, and stops without local removal if that retirement cannot be committed and pushed safely. Noninteractive `--yes` never retires a machine.
- Uninstall removes stopped containers carrying Satchel's ownership label before removing the image. It does not stop active or unrecognized containers and reports engine errors that block image removal.

## 2. External contracts that must be preserved for compatibility

### CLI grammar

The public command grammar is:

```text
satchel [--host] [--unsafe-home] [--with <dir>]... <command> [args]

satchel claude [--host] [--unsafe-home] [--with <dir>]... [claude-args...]
satchel codex  [--host] [--unsafe-home] [--with <dir>]... [codex-args...]

satchel init
satchel sync
satchel status [--ignored]
satchel skills [list]
satchel skills remove [name]
satchel key [--persist]
satchel retire [machine]
satchel track [project-id]
satchel untrack [project-id]
satchel settings
satchel settings <SETTING> <value> [--local]
satchel doctor
satchel mcp [list]
satchel mcp add [name] [url] [--no-auth]
satchel mcp remove [name]
satchel link [claude|codex]...
satchel unlink [claude|codex]...
satchel uninstall [--purge] [--yes|-y]
satchel import <claude|codex>
satchel image [--rebuild]
satchel update
satchel version
satchel --version
satchel help
satchel --help
satchel -h
```

The three Session options can occur before the agent command or anywhere among the agent arguments. They are consumed by Satchel and are not forwarded to the native agent. All other agent arguments retain their order and are forwarded.

With no command, the program behaves as `satchel help`. Unknown commands and unsupported command-specific options exit nonzero. The version line is:

```text
satchel 2.0.0
```

Informational and error messages use the prefixes:

```text
satchel: ...
satchel: warning: ...
satchel: error: ...
```

Color is enabled separately for stdout and stderr when that descriptor is a terminal. `CLICOLOR_FORCE=1` forces color unless `NO_COLOR` is nonempty or `TERM=dumb`. Piped output is uncolored by default.

### Installation and host environment variables

Supported installation inputs are:

```text
SATCHEL_BIN=<install-directory>
SATCHEL_DIR=<state-directory>
SATCHEL_SHIMS=y|<anything-else>
```

`SATCHEL_BIN` is a directory, not a path to the executable. Exact `y` enables redirect installation; any other value disables it.

Supported runtime inputs include:

```text
SATCHEL_DIR=<state-directory>
SATCHEL_BIN=<redirect-directory>
SATCHEL_ENGINE=<container-engine-command>
SATCHEL_SSH=0|<enabled-value>
SATCHEL_CLIPBOARD=0|<enabled-value>
SATCHEL_HOST=<nonempty-enables-host-mode>
SATCHEL_NO_HANDOFF=<nonempty-disables-handoffs>
SSH_AUTH_SOCK=<host-agent-socket>
GIT_SSH_COMMAND=<host-git-ssh-command>
WAYLAND_DISPLAY=<absolute-socket-or-name>
XDG_RUNTIME_DIR=<wayland-runtime-directory>
DISPLAY=<x11-display>
XAUTHORITY=<x11-authority-file>
NO_COLOR=<nonempty-disables-color>
CLICOLOR_FORCE=1
TERM=<terminal-name>
TMPDIR=<temporary-directory>
```

The following platform-path overrides are accepted and are used by tests and specialized deployments; whether they are supported public API is an open compatibility question:

```text
SATCHEL_UNRAID_MARKER=<path>
SATCHEL_UNRAID_BOOT_DIR=<path>
SATCHEL_UNRAID_LIVE_BIN_DIR=<path>
SATCHEL_SELF=<installed-command-path>
```

Inside normal Sessions, installers and skills can depend on:

```text
SATCHEL_SESSION=1
SATCHEL_SESSION_MODE=sandbox|host
SATCHEL_SKILLS_DIR=/home/satchel/.claude/skills
SATCHEL_SKILLS_DIR=/home/satchel/.codex/skills
HOME=/home/satchel
DISABLE_AUTOUPDATER=1
```

When Codex needs a bearer token, the generated name is:

```text
SATCHEL_MCP_TOKEN_<SERVER_NAME>
```

Lowercase ASCII letters become uppercase and `-` becomes `_`. Other permitted characters are retained.

### State-root selection and durable local files

The state root is selected in this order:

1. A nonempty `SATCHEL_DIR`.
2. A real `.satchel` directory beside the resolved installed command.
3. `$HOME/.satchel`.

The machine-local configuration is a Bash source file named `config`. Initialization writes this shape, with shell-escaped values:

```bash
# Satchel config — plain bash, sourced by satchel.
# See and change settings with 'satchel settings'; this file is the
# machine-local layer (it wins over the synced settings.env).
MACHINE=<shell-escaped-machine-name>
SYNC_URL=<shell-escaped-git-url-or-empty>
# SATCHEL_ENGINE=  # force docker or podman (default: auto-detect)
# SATCHEL_SSH=1  # forward the host's ssh-agent into sessions so git push works (0 = off)
# SATCHEL_CLIPBOARD=1  # forward the desktop clipboard socket so pasting images works (0 = off)
# SATCHEL_UID=  # user id inside session containers (default: your uid; 1000 if root)
# SATCHEL_GID=  # group id inside session containers (default: SATCHEL_UID)
```

Active local settings are Bash assignments:

```bash
SATCHEL_ENGINE=docker
SATCHEL_SSH=1
SATCHEL_CLIPBOARD=1
SATCHEL_UID=1000
SATCHEL_GID=1000
```

The supported machine-setting keys are exactly:

```text
SATCHEL_ENGINE
SATCHEL_SSH
SATCHEL_CLIPBOARD
SATCHEL_UID
SATCHEL_GID
```

The synchronized settings file, when present, is `settings.env` and uses the same shell-assignment format. Synchronized settings are loaded before the local `config`, so local assignments win.

Other durable local state contracts are:

```text
home/claude/                 persistent Claude login, configuration, SSH trust, and transcripts
home/codex/                  persistent Codex login, configuration, SSH trust, and transcripts
mcp-tokens.local.env         machine-only MCP tokens
quarantine/skills/           invalid skill attempts retained locally
script-sha                   full installed Git commit SHA plus newline
install-path                 resolved absolute installed command path plus newline
image-agents                 "claude <version>, codex <version>" plus newline
update-check                 decimal Unix timestamp, no required trailing newline
recovery/sync-<UTC stamp>/   preserved non-Git content formerly occupying the clone destination
```

Agent-login import and authentication detection depend on these native paths:

```text
Claude:
  ~/.claude/.credentials.json
  ~/.claude.json

Codex:
  ~/.codex/auth.json
```

Imported credentials are copied into the corresponding persistent agent home and are not synchronized.

### Redirect executable format

A current redirect is an executable file named `claude` or `codex` with this exact shape:

```bash
#!/usr/bin/env bash
# satchel shim
exec <shell-escaped-absolute-satchel-path> <claude-or-codex> "$@"
```

The legacy ownership marker also recognized is a line matching:

```text
exec satchel claude ...
exec satchel codex ...
```

Legacy redirects are recognized for status and replacement, but deletion requires proof that the redirect resolves to the current installation.

### Sync Repo root contracts

The default root context files are:

```markdown
# Profile
```

```markdown
# Preferences
```

Their first line is not injected into Session context; content from line 2 onward is concatenated as global context, Profile first and Preferences second.

The global repository registry is `repositories.json`. It is a JSON object keyed by canonical, credential-free remote identity:

```json
{
  "github.com/example/project": {
    "status": "tracked",
    "project": "project-id"
  },
  "github.com/example/ignored": {
    "status": "ignored"
  }
}
```

Required rules are:

- The root is an object.
- Every key is a nonempty canonical identity string.
- Every value is an object.
- `status` is exactly `tracked` or `ignored`.
- A tracked entry has a nonempty string `project`.
- No two tracked origins use the same Project ID.
- Unknown fields are accepted.

The current validator does not reject a `project` field on an ignored entry even though the documented schema says ignored entries do not carry one. Compatibility intent is an open question.

The per-machine checkout cache is `machines/<machine>/projects.json`:

```json
{
  "paths": {
    "/absolute/checkout": {
      "project": "project-id"
    }
  }
}
```

Path keys must be absolute. `project` is required and must name an existing Project. Unknown fields are accepted.

A Project exists as `projects/<project-id>/handoffs/`. The Project directory name is its identity. An old `project.json` inside a Project is explicitly invalid.

The MCP registry is `mcp.json`:

```json
{
  "servers": {
    "homeassistant": {
      "url": "http://host:8123/api/mcp",
      "auth": "bearer"
    },
    "public": {
      "url": "https://example.test/mcp",
      "auth": "none"
    }
  }
}
```

Server names match:

```text
^[A-Za-z0-9_-]+$
```

The root and each server object may contain unknown fields. `servers`, `url`, and `auth` are required. `url` must be a nonempty string containing no control character, double quote, backslash, or DEL. `auth` is exactly `bearer` or `none`.

Both `mcp-tokens.env` and machine-local `mcp-tokens.local.env` use unquoted line records:

```text
homeassistant=<token bytes through the end of the line>
another_server=<token bytes through the end of the line>
```

The first exact `<server>=` line wins within a file. The local file is checked before the synchronized file. Writers set mode `0600`, but Git does not preserve that non-executable mode across machines.

Each machine runtime report is `machines/<machine>/environment.json`:

```json
{
  "satchel": "2.0.0",
  "commit": "7179842",
  "engine": "docker",
  "agents": "claude 2.1.217, codex 0.145.0"
}
```

All four values are strings; `satchel` is nonempty. Unknown fields are accepted. `commit`, `engine`, and `agents` may be empty when the information is unavailable.

Machine names are directory names under `machines/` and use:

```text
^[A-Za-z0-9][A-Za-z0-9._-]*$
```

Every immediate machine entry must be a real directory, not a symlink.

Machine knowledge contracts are:

```text
machines/<machine>/notes.md
machines/<machine>/inventory.md
machines/<machine>/guides/<topic>.md
machines/<machine>/.baseline-skip
```

The current baseline marker must be the first inventory line:

```html
<!-- satchel-machine-baseline version=2 generated=2026-07-25T12:34:56Z -->
```

For migration compatibility, a version-1 marker is recognized in the inventory, or in notes only when the inventory file is absent:

```html
<!-- satchel-machine-baseline version=1 generated=2026-07-25T12:34:56Z -->
```

Permanent reminder suppression is:

```text
suppressed at 2026-07-25T12:34:56Z
```

### Handoff contract

Project handoff filenames are:

```text
projects/<project-id>/handoffs/YYYY-MM-DDTHH-MM-SSZ--<machine>.md
```

Machine handoff filenames are:

```text
machines/<machine>/handoffs/YYYY-MM-DDTHH-MM-SSZ.md
```

The file header and required body headings are:

```markdown
<!-- satchel-handoff project=<project-id-or-> machine=<machine> date=YYYY-MM-DDTHH:MM:SSZ -->
## Goal
...
## Done
...
## In flight
...
## Next steps
...
## Gotchas
...
```

All five headings must appear as complete lines. Project and machine handoffs are ordered and retained by their lexically sortable filenames, not by filesystem modification time.

The multi-scope writer protocol uses:

```text
=== project: <project-id> ===
=== candidate: candidate-<integer> ===
=== machine ===
```

The exact no-op response is:

```text
NO_HANDOFF
```

### Skill Library contract

The synchronized library is:

```text
skills/shared/
```

User skill names match:

```text
^[A-Za-z0-9][A-Za-z0-9._-]*$
```

Every user skill is a real top-level directory containing `SKILL.md`. Nested `.git` entries, top-level symlinks, broken symlinks, and symlinks resolving outside that skill directory are invalid.

The only allowed top-level metadata file is:

```text
skills/shared/skills-lock.json
```

Its schema is installer-owned; Satchel requires only valid JSON and a real nonsymlink file.

The Sync Repo ignore contract includes this exact line:

```gitignore
/skills/shared/.system/
```

Quarantined names are:

```text
<UTC YYYYMMDDTHHMMSSZ>--<original-name>
<UTC YYYYMMDDTHHMMSSZ>--<original-name>-<collision-number>
```

### Agent-native MCP materialization

Claude's persistent `.claude.json` retains unrelated root fields but has its entire `mcpServers` property replaced. A no-auth server is:

```json
{
  "mcpServers": {
    "server": {
      "type": "http",
      "url": "https://example.test/mcp"
    }
  }
}
```

A bearer-auth server adds:

```json
{
  "headers": {
    "Authorization": "Bearer <token>"
  }
}
```

Codex's persistent `.codex/config.toml` uses exactly one managed marker pair:

```toml
# >>> satchel mcp >>>
# managed by satchel — rebuilt every session start
[mcp_servers.server]
url = "https://example.test/mcp"
bearer_token_env_var = "SATCHEL_MCP_TOKEN_SERVER"
# <<< satchel mcp <<<
```

The managed block is inserted before the first TOML table. Content outside the markers must survive. A missing, duplicate, nested, or unclosed marker pair is an error and leaves the original configuration unchanged.

### Generated Session instruction contract and mount paths

The generated file is rewritten every Session at:

```text
Claude: /home/satchel/.claude/CLAUDE.md
Codex:  /home/satchel/.codex/AGENTS.md
```

Its exact first line is:

```markdown
# Managed by Satchel — rewritten at every session start; do not edit.
```

Stable in-container paths are:

```text
/home/satchel                         persistent selected-agent home
/home/satchel/machine                 current machine state, read-write
/home/satchel/projects                all Project state, read-only
/home/satchel/machines                all machine state, read-only
/home/satchel/.claude/skills          shared skills for Claude, read-write
/home/satchel/.codex/skills           shared skills for Codex, read-write
/run/ssh-agent.sock                   forwarded SSH agent
/run/satchel/wayland-0                forwarded Wayland socket
/run/satchel/Xauthority               forwarded Xauthority, read-only
/host                                 host root in Host or baseline sessions
```

Normal project and `--with` mounts retain their real absolute host paths inside the Session.

### Container-engine identities

The shared image name is:

```text
localhost/satchel:latest
```

Managed Session and helper containers carry:

```text
io.github.swaggymike.satchel.managed=true
```

The handoff helper name is:

```text
satchel-handoff-<host-process-id>
```

### Git-origin canonicalization

Portable origins are URLs beginning with `ssh://`, `git://`, `http://`, or `https://`, plus SCP-like forms matching `user@host:path`.

Canonicalization applies these exact transformations in order:

1. Remove everything from the first `#` or `?` onward.
2. Remove one trailing `/`.
3. For scheme URLs, remove the scheme, remove user information through the last `@` in the authority, lowercase the hostname, retain any `:<port>`, and join authority and path with `/`.
4. For SCP-like URLs, remove the user portion, lowercase the host, and change the first host/path separator from `:` to `/`.
5. Remove one trailing lowercase `.git`.
6. Remove one trailing `/`.
7. For identities beginning `github.com/`, `gitlab.com/`, or `bitbucket.org/`, lowercase the entire identity.

Examples:

```text
git@github.com:Example/Repo.git
https://github.com/example/repo
=> github.com/example/repo

https://token@example.com/Owner/Repo.git?x=secret
=> example.com/Owner/Repo
```

### Git commit-subject contract

Automatic Sync Repo commits use these subjects:

```text
add machine <machine>
sync from <machine>
mcp: add <server>
mcp: remove <server>
skills: remove <skill>
machine baseline v2 on <machine>
skip machine baseline on <machine>
session: <project-id-or-untracked> on <machine>
settings: <setting> on <machine>
track project <project-id>
ignore project <project-id>
retire <machine>
```

### Unraid persistence contract

Unraid detection defaults to:

```text
/etc/unraid-version
```

The persistent boot configuration defaults to:

```text
/boot/config/go
/boot/config/go.satchel-bak
/boot/config/ssh/root/
```

The managed block delimiters are exact:

```bash
# >>> satchel boot persistence >>>
...
# <<< satchel boot persistence <<<
```

The generated body has this command shape, with every path shell-escaped:

```bash
ln -sf <installed-satchel> [<owned-claude-shim> <owned-codex-shim>] /usr/local/bin/
mkdir -p /root/.ssh && chmod 700 /root/.ssh
cp <boot-key-directory>/id_ed25519* /root/.ssh/ 2>/dev/null && chmod 600 /root/.ssh/id_ed25519
cp <boot-key-directory>/known_hosts /root/.ssh/ 2>/dev/null
```

### External network endpoints

Satchel exposes no HTTP or other service API.

Self-installation and update consume these outbound endpoints:

```text
https://api.github.com/repos/SwaggyMike/satchel/commits/main
https://api.github.com/repos/SwaggyMike/satchel/contents/satchel?ref=main
https://api.github.com/repos/SwaggyMike/satchel/compare/<old>...<new>
https://raw.githubusercontent.com/SwaggyMike/satchel/<commit-or-main>/satchel
https://raw.githubusercontent.com/SwaggyMike/satchel/main/install.sh
```

The Sync Repo uses its configured Git `origin`. MCP probes and agents use the exact registered server URLs.

## 3. Real-world constraints revealed by the current behavior

### Supported environment and dependencies

- The host target is Linux. The supported container engines are Docker and Podman; Docker is preferred when both is auto-detected and its daemon answers.
- The host requires Bash, Git, jq, curl, OpenSSH client utilities, and common GNU/Linux utilities including `timeout`, `readlink`, `find`, `stat`, `sed`, `awk`, `grep`, `mktemp`, and `chmod`. Root-host SSH fallback additionally requires `setpriv` from util-linux when the Session UID differs.
- Installation requires only that a Docker or Podman command exists. Session launch requires an engine that can actually build/run the image and bind-mount Satchel's real local files.
- Running Satchel inside another application container is supported only when the selected engine daemon sees the same host paths. A Docker/Podman socket connected to a daemon with a different filesystem namespace is explicitly unsupported.
- The runtime image targets Node 22 on Debian Bookworm slim and installs the latest available Claude Code and Codex npm packages at image-build time. No agent or base-image digest is pinned.
- Codex native skills compatibility was verified against Codex 0.145.0. Current agent command-line options are assumed to remain accepted by whatever floating versions are installed.

### Permission and isolation constraints

- A normal Session is a containment boundary for filesystem visibility and privilege, not for network or user identity. It has ordinary container networking, may use the user's forwarded SSH identity, and may access the live clipboard.
- A Host Session is not a security boundary. It has root, host PID and network namespaces, privileged container capabilities, and write access to the host under `/host`.
- The Machine Baseline's host bind is read-only, but it still exposes the full namespace of host special files. It also retains ordinary network access, live clipboard access when available, and native agent authentication/configuration. The behavioral contract relies on the agent instruction not to use control sockets or make changes.
- SSH forwarding authorizes signing with every identity in the forwarded agent for the life of the Session. Key bytes are not mounted, but the Session can authenticate wherever those identities are authorized.
- Clipboard forwarding can expose passwords and other clipboard content copied while a Session runs. On some Wayland compositors, access to the compositor socket can be broader than clipboard alone.
- Host project files must already be writable by the configured Session UID. Satchel may repair ownership only for the two agent homes, the shared Skill Library, and the current machine's synchronized directory. It must never recursively change ownership of project files or arbitrary host paths.
- Rootless Podman needs keep-ID user namespace behavior and an invented passwd entry whose home is `/home/satchel` for custom UIDs. Docker with a custom UID that is absent from the image has no equivalent passwd entry and is an accepted limitation.
- SELinux label separation must be disabled for these Sessions rather than relabeling arbitrary project, home, or socket paths.

### Ordering and atomicity requirements

- SSH preflight must complete before the first Sync Repo pull so an available standard key is not loaded only after a misleading pull failure.
- A Session must pull and validate synchronized state before mounting or materializing it.
- Session rules and native MCP configuration must be regenerated before the agent starts.
- Ownership normalization must occur after all host-side writes and immediately before the normal Session, and again after a Host Session before an unprivileged handoff writer reads the transcript.
- Repository discovery must happen both before and after the interactive agent, and post-Session discovery must precede attribution and candidate tracking decisions.
- Durable cleanup, handoff filing, validation, and synchronization must survive repeated Ctrl-C after the interactive agent exits.
- A Sync Repo change must be committed locally before a best-effort integration/push so an offline or rejected push leaves a recoverable commit.
- Replacement of the installed command and Unraid boot script must be staged in the destination directory and installed by same-filesystem rename. A partially overwritten running script or boot script is unacceptable.
- Uninstall retirement must complete upstream before any local program or state removal begins.

### Time limits and bounds

- Session-start Sync Repo pull: 20 seconds.
- Session-end best-effort pull and push: 30 seconds each.
- Diagnostics Sync Repo reachability: 10 seconds.
- Daily update probe: 5 seconds.
- Each MCP endpoint probe attempt: 5 seconds; TLS and HTTP fallback probes can make multiple attempts.
- Handoff generation: 240 seconds.
- Update checks occur at most once per 86,400 seconds according to the local stamp.
- Active handoff retention is 100 Markdown files per Project or machine scope.
- Machine notes have a 750-word soft limit.

### Data-integrity and safety prohibitions

- Agent login credentials and transcripts must never synchronize.
- Host SSH private-key files must never enter normal Session mounts.
- Unknown or malformed state must not be silently deleted. Incomplete initial clone content and invalid skill attempts must be moved to recoverable local storage.
- A Session must not be blocked by an unusable Sync Repo. It must degrade synchronized behavior and continue.
- A Git conflict must not be resolved by choosing or merging content on the user's behalf and must not leave the clone mid-operation after recoverable Session paths.
- Forward-compatible JSON must validate required fields while ignoring unknown fields.
- The program must not overwrite or delete unrelated redirects, active containers, unrecognized containers, arbitrary scripts, arbitrary state trees, or user-owned Unraid boot content.
- Purge must never delete the upstream private Git repository.
- A malformed or partially marked Unraid boot block must be left untouched, and a syntactically invalid replacement must never be installed.
- Token values must not appear in container-engine process arguments or diagnostic output.
- Baseline secret scanning must never echo the suspected secret.

### External-system constraints

- Unraid rebuilds `/`, `/usr/local/bin`, and `/root` from flash at boot. The install directory and state must live under persistent `/mnt` storage, while command links, SSH keys, and known hosts must be restored through `/boot/config/go`.
- Unraid flash storage is unencrypted FAT and is a single point of failure. Persisting a private key there is an explicit tradeoff suitable only for a narrowly scoped private Sync Repo key.
- Git 2.35 and later reject repositories owned by a different user unless explicitly marked safe. This is routine on root-run Unraid hosts whose Sessions use UID 1000.
- The same private Sync Repo is written from multiple machines. Whole-file registries make ordinary concurrent edits conflict even when the machines changed different logical entries.
- Each machine's floating image build can contain different agent versions. Runtime drift is expected and is reported rather than automatically corrected.

## 4. Edge cases and failure modes currently handled

### Installation and initialization

- When required host commands are missing, the installer must stop and name the missing dependency.
- When Unraid is detected and no persistent install directory is supplied, an interactive installer must ask for one; a noninteractive installer must refuse the volatile default and print the required `SATCHEL_BIN` form.
- When the parent of an Unraid install directory does not exist, the installer must stop rather than create a misleading directory chain on the RAM filesystem.
- When `SATCHEL_BIN` would create a directory named `satchel` in a `PATH` directory, installation must stop before creating it.
- When an existing `claude` or `codex` path is unrelated, including a dangling symlink, installation or linking must skip it and continue without overwriting it.
- When installation is already initialized, the installer must ensure the image exists; when that image build fails, the installed command must remain and the output must give one exact retry command.
- When an incomplete non-Git clone destination is empty, initialization must remove the empty directory and retry cleanly.
- When an incomplete non-Git clone destination contains data, initialization must move it under timestamped recovery storage, report the new location, and retry cloning into a clean path.
- When the clone destination is a symlink or a non-directory file, initialization must refuse to move, follow, or replace it.
- When initialization is rerun with a Sync Repo URL that differs textually from the existing clone's origin, it must stop before changing either the clone or local configuration.
- When an SSH clone fails, initialization must preserve Git's error, explain the observed agent/key state, optionally generate and print a key, and allow an in-place retry or a choice to continue without sync.
- When a local Sync Repo target is absent, empty, or an existing non-Git directory, interactive initialization must offer to initialize it as a bare repository.
- When machine registration cannot push, initialization must retain the local clone and machine state and tell the user to fix access and run explicit sync.

### Session launch and runtime

- When no working container engine exists, a Session must fail clearly; status and settings must still report without one.
- When Satchel is itself containerized and the selected daemon cannot bind-mount Satchel's actual local state, launch must stop with an unsupported nested-container explanation.
- When the primary Session path is unsafe, an interactive launch must default to refusal and offer Host Mode; a noninteractive launch must fail. A path classified directly as Satchel private state must remain forbidden with `--unsafe-home`, while explicit home or `/` exposure currently includes any private state nested under that broader mount.
- When an extra mount is unsafe, nonexistent, `/`, home-containing, state-containing, or state-contained, launch must fail before starting a container.
- When a root host's mounted work paths are not writable by the Session UID, launch must warn with the affected paths and possible host-side remedies while still allowing the read-only Session.
- When a host Git identity appears after an agent configuration already exists, the missing identity fields must still be copied; existing agent-selected values must not be overwritten.
- When Session startup is interrupted during SSH prompting, pulling, or the daily update check, status 130 must propagate and later launch work must stop.
- When the interactive agent exits nonzero, cleanup and best-effort handoff/sync must still run, then the original agent status must be returned.
- When the engine becomes temporarily unhealthy after an interrupted interactive run, cleanup must continue using the already selected engine rather than re-detecting another one.
- When a Host Session or root-run operation leaves persistent agent or synchronized files owned by root, the next normal lifecycle must normalize only the allowlisted internal paths.

### SSH and clipboard

- When `SATCHEL_SSH=0`, launch must remain quiet about missing SSH and must not forward a socket.
- When a socket path is absent, not a socket, or has no responding agent, it must not be mounted.
- When the agent answers but has no identities, its socket must still be mounted so keys added on the host during the Session become immediately usable.
- When a root-owned agent cannot serve the unprivileged Session UID, Satchel must not claim it works; it must prefer a temporary agent owned by the Session UID.
- When `setpriv` is unavailable on a root host with an unprivileged Session UID, Satchel must explain that it cannot create a usable temporary agent and must not announce SSH readiness.
- When a standard private key loads but the temporary agent still fails a probe as the Session UID, launch must reject and clean up that temporary agent.
- When no standard key is usable, launch must say that SSH pushes will fail and continue only after interactive acknowledgment or a noninteractive warning.
- When the Wayland socket is valid, it must be preferred over X11 and exposed through the fixed absolute display path.
- When the compositor variables name no real socket, clipboard forwarding must quietly do nothing.

### Synchronization

- When the Sync Repo is unconfigured, normal Sessions must still run and must say that nothing will sync.
- When synchronized state is malformed during Session startup, the intended contract is that the Session must continue with synchronization disabled for that run and explain the reason. Current MCP startup behavior violates this contract, as recorded in section 6.
- When the same malformed state is encountered by explicit sync or status, the command must fail and name the invalid contract.
- When a best-effort pull is offline or times out without leaving a Git operation in progress, startup must warn and continue from local state.
- When a best-effort pull is interrupted, startup must stop rather than misclassify the interrupt as offline operation.
- When a pull conflicts, Satchel must abort the operation, remove unmerged state, preserve the local commit and preexisting tracked edits, warn that it did not guess, and continue the Session.
- When an unfinished Git operation is discovered before checking for an upstream, Satchel must recover it even though rebase may have detached `HEAD`.
- When automatic recovery cannot return the clone to a usable state, synchronization must degrade for that Session.
- When a Session-end push or pull fails, the Session's commit must remain on the local branch and the user must be directed to explicit sync.
- When the remote rejects initial machine registration, the failure must not be described as success or discard the local registration.
- When status sees local commits ahead of or behind the upstream, it must report the counts and direct the user to explicit sync.
- When synchronized JSON contains unknown fields but all currently required fields are valid, older versions must continue.
- When one tracked origin points to a missing Project, two origins claim one Project ID, a path cache points to a missing Project, a Project name is unsafe, an old Project metadata file exists, or a machine entry is unsafe, strict validation must fail rather than repair identity.

### Projects and handoffs

- When a path is not inside a Git repository, explicit tracking must fail.
- When a repository has no portable origin, automatic candidate prompting must not occur; explicit tracking must still work.
- When the same portable origin appears at multiple paths or machines, all paths must resolve to the same Project.
- When two unrelated origins have the same basename, generated IDs must remain distinct.
- When a requested Project ID already belongs to another origin, tracking must fail instead of merging identities.
- When an origin changes, any old path cache must be invalidated until the new origin receives its own global decision.
- When a discovered repository lies only behind a symlink outside the declared roots, it must not be discovered or offered.
- When a candidate is mentioned by the handoff writer in an interactive terminal, Satchel must ask whether to track it; when it is not mentioned, Satchel must not prompt.
- When candidate enrollment fails, its work must be reassigned to the machine handoff rather than discarded.
- When operation is noninteractive, candidate work must become machine handoff content while the origin remains undecided.
- When a multi-scope handoff names an unknown Project or malformed chunk, that chunk must be dropped without creating state for the invented scope.
- When multiple chunks resolve to the machine at one timestamp, they must be combined into one file rather than overwrite one another.
- When the handoff writer returns `NO_HANDOFF` successfully, the prior handoff must remain.
- When the writer exits nonzero, times out, or returns incomplete formatting, the prior handoff must remain and the warning must distinguish process failure from format failure.
- When Ctrl-\ cancels the writer, its helper container must be stopped and removed only after its Satchel ownership label is verified.
- When an unrelated container already owns the predicted helper name, cleanup must not delete it.
- When a handoff header is truncated but its filename is valid, it must still participate in latest selection and retention.
- When retention exceeds 100, the lexically oldest handoff filenames must be removed first.

### Machine Baseline

- When neither agent is authenticated, no baseline offer must appear.
- When the requested agent invocation begins with its native version or help flag, the baseline offer must not replace that informational request.
- When only one agent is authenticated during an explicit refresh, that agent must be selected and the reason stated.
- When both are authenticated during an explicit refresh, the user must be allowed to choose, with Claude as the default.
- When the user chooses "not now," the requested normal Session must continue.
- When the user chooses "don't ask again," a synchronized suppression marker must be written and the requested normal Session must continue.
- When the user accepts the automatic first-launch baseline, success, failure, or interruption must return directly to the shell without a second agent launch.
- When the baseline exits successfully but does not create or change the inventory, it must remain incomplete.
- When the inventory lacks the exact version marker, automatic synchronization must stop and the user must be told to review the machine knowledge.
- When newly added inventory, notes, or guide content resembles a secret, the suspected value must not be printed and automatic synchronization must stop.
- When notes exceed 750 words, the content must be retained and a consolidation warning must be shown.
- When a peer machine exists but has not published a runtime report, diagnostics must say that comparison data is missing rather than report agreement.

### MCP

- When an MCP name contains characters outside the allowed set, add/remove must fail.
- When an MCP URL is empty or contains a quote, backslash, control character, or DEL, state validation must fail before either agent configuration is changed.
- When a required MCP field is missing or authentication is not `bearer` or `none`, validation must fail; unknown fields must be ignored.
- When a bearer token is missing, interactive materialization must offer synchronized or local storage and allow the user to skip.
- When local and synchronized tokens both exist, the local token must win.
- When Codex's managed marker pair is malformed, materialization must leave the original file byte-for-byte unchanged and remove scratch files.
- When Codex has written learned tool approval or Project trust tables inside the managed marker area, rematerialization must preserve those non-base tables outside the rebuilt block.
- When an MCP probe receives 404, TLS-only success, HTTP-only success for an HTTPS URL, or no response, the command must report the distinct condition.
- When diagnostics finds an unreachable MCP endpoint, it must count as `FAIL`; when only a bearer token is absent, it must be a warning.

### Skills

- When the Skill Library contains a safely named complete skill, it must remain active and eligible for synchronization.
- When a top-level entry is hidden other than the reserved `.system` directory or `.gitkeep`, unsafe, a file other than valid `skills-lock.json`, a symlink, missing `SKILL.md`, contains nested Git metadata, or contains a broken/escaping symlink, it must be moved to local quarantine.
- When the invalid entry replaced a committed valid skill or lock file, the committed copy must be restored after quarantine.
- When the committed copy is also invalid, it too must be quarantined and not synchronized.
- When Codex creates `.system` content, it must remain local and absent from Sync Repo changes and active user-skill reports.
- When a named skill does not exist or the name is unsafe, removal must fail without deleting anything else.
- When interactive skill removal is canceled or the number is invalid, the active library must remain unchanged.
- When pre-removal pull is interrupted, removal must not proceed.
- When lock metadata appears to mention a removed skill, removal must complete but warn without modifying the lock.

### Unraid, updates, diagnostics, retirement, and uninstall

- When an Unraid boot block has no closing marker, update and removal must report it and leave the complete boot file unchanged.
- When a proposed Unraid boot file is empty, has duplicate markers, contains an unresolved link target, or fails Bash syntax validation, it must not replace the current boot file.
- When a valid boot file is replaced, the last syntactically valid previous version must be retained as `go.satchel-bak`.
- When an existing standard SSH key is explicitly persisted on Unraid, the key pair and `known_hosts` should be copied to flash. The current restore mismatch for non-Ed25519 keys is a known weakness.
- When diagnostics sees Unraid state outside `/mnt`, it must emit a `FAIL`, not a warning.
- When GitHub's commit API is unavailable during update, update must warn and fall back to raw `main`.
- When the update cannot create a staging file beside the installed command, it must leave the running script untouched and fail with a directory-writability explanation.
- When the downloaded script does not parse, update must leave the installed command unchanged.
- When the script is unchanged, update must still rebuild the image and can backfill the installed commit record.
- When the new image build fails after script replacement, the commit record must not advance.
- When uninstall cannot prove the running script is an installed Satchel command or the state path is a safe Satchel state tree, it must refuse deletion.
- When purge would discard uncommitted, unpushed, or no-upstream Sync Repo work, uninstall must warn before deletion.
- When a stopped labeled container exists, uninstall must attempt to remove it; when a labeled container is active or its state is unknown, uninstall must leave it.
- When image deletion fails, uninstall must preserve completion of the requested program/state removal, show the engine's error, and print an engine-appropriate inspection command.
- When interactive current-machine retirement starts from a dirty Sync Repo, it must stop before mutation. When its retirement commit or push fails after mutation, it must restore the prior local Sync Repo state and stop before removing local files. A pull conflict currently stops local removal but may leave Git mid-operation; that is a weakness in section 6.
- When the current machine is retired directly, the command must explain that local state remains and separately ask before deleting it.

## 5. Non-obvious domain knowledge encoded in the behavior

- **An SSH-agent socket's ownership and mode do not determine which users it serves.** OpenSSH checks peer credentials and accepts only root or the agent process's own effective UID. A temporary agent for a UID-1000 Session must itself run as UID 1000; changing socket ownership is insufficient. This exists because root-run hosts previously announced an agent that reset every in-Session connection.
- **A host agent being reachable does not mean every Git SSH remote will work.** The Session has the agent's identities but not host `~/.ssh/config`. Aliases, nondefault ports, usernames, and per-host key selection may disappear. This distinction exists to stop agents from debugging credentials that only the host user can change.
- **OpenSSH resolves home through the passwd database, not only `$HOME`.** Both root and the normal image user must have `/home/satchel` as their passwd home or SSH trust state lands in disposable `/root` or `/home/node`. This exists so `known_hosts` survives and Host Sessions do not follow dangling host-specific home symlinks.
- **A numeric Session UID may have no passwd account name.** Privilege-dropping tools that require a login name cannot reliably start or probe an SSH agent for an arbitrary configured UID. The numeric-ID-aware utility requirement exists for this case.
- **Unattended Git cannot answer a first-contact host-key prompt.** Trust-on-first-use must accept a previously unseen key and retain it for later verification. This exists so background synchronization does not hang before authentication.
- **Debian's account-management tool refuses to change the active root account when the image build shell is root/PID 1.** The passwd home fields therefore need direct field-level replacement. This exists because the more obvious account-modification command fails during legacy Docker builds.
- **Rootless Podman can invent a passwd record for keep-ID users.** Its home must be explicitly templated to `/home/satchel`, especially for custom UIDs absent from the image. This exists so SSH and other passwd-aware tools agree with the mounted home.
- **Git 2.35+ treats a repository owned by another UID as unsafe.** Merely making files readable is not enough; the Session must declare its exact mounts as trusted. This exists for root-owned Unraid worktrees opened by UID 1000.
- **SELinux relabeling is unsafe for this workload.** Relabeling project trees or sockets mutates arbitrary host labels and still does not solve every socket mount. Disabling label separation for the Session is the supported Podman-compatible tradeoff while retaining the remaining container restrictions.
- **Wayland accepts an absolute `WAYLAND_DISPLAY`.** Mounting the socket at a fixed absolute path avoids reproducing the host runtime directory inside the container and works with both libwayland and Codex. This exists because clipboard access belongs to the compositor, not to a file copied at launch.
- **X11 access is broader than Wayland access.** It is deliberately only a fallback when a real X display is present. This exists because image pasting requires a live display protocol, but X11 can expose more input and desktop state.
- **Codex's inner bubblewrap sandbox cannot create its expected namespaces inside the Session container.** Its sandbox is disabled because the outer normal Session provides the intended boundary. This exists to prevent Codex startup failure inside an already constrained container.
- **Codex accepts MCP bearer tokens by environment-variable name, not inline token value.** Passing only `-e NAME` to Docker/Podman prevents the value from appearing in the host process list. This exists because `-e NAME=value` would expose secrets through process inspection.
- **Codex can persist learned TOML tables immediately before a trailing comment.** If the managed close marker is the trailing comment, Codex may insert Project trust and per-tool approval tables inside the managed area. Such tables must be rescued before rebuilding. This exists to avoid silently deleting user trust and approval choices.
- **Claude's and Codex's conversation resume selection depends partly on the original working directory.** The unattended handoff writer therefore needs an empty filesystem at that exact path even though it must not see the project. This exists because one engine rejects a nonexistent working directory and both use cwd in transcript selection.
- **Killing a container-engine client does not guarantee that a daemon-side `--rm` container stops.** A timed-out or canceled handoff helper may keep running and spending tokens. It needs a predictable name and verified ownership label for force cleanup.
- **Repeated Ctrl-C can outlive the foreground agent.** Terminal interrupts can strike cleanup commands in the gaps after the agent UI has exited. Cleanup uses a separate process group that ignores SIGINT, while Ctrl-\ remains the deliberate cancellation signal, so ownership repair and synchronization are not randomly interrupted.
- **Codex noninteractive resume rejects non-Git working directories unless its Git-repository check is explicitly skipped.** The handoff writer must skip that check because Sessions may start in ordinary directories.
- **A smaller model alias that works for standalone prompts may fail when resuming a long transcript under a strict output format.** The default model at low effort is retained because fallback retries cost more time than the smaller model saves.
- **A Git rebase detaches `HEAD`, making the usual upstream expression unavailable.** Recovery detection must happen before asking whether an upstream exists. This exists because the old ordering skipped recovery in exactly the broken state.
- **An empty Git remote has no upstream branch.** Pulling before the first upstream-establishing push would fail despite there being nothing to integrate. Initial registration therefore has to distinguish a new remote from an offline or damaged one.
- **Aborting a rebase started with autostash can restore preexisting tracked edits.** Cleanup must not reset merely to obtain a visually clean tree, or it can destroy the only copy of those edits.
- **Whole-file synchronized registries conflict under ordinary independent edits.** Two machines can add different entries and still collide. The behavior intentionally backs out rather than applying an unproven merge policy.
- **Raw GitHub branch URLs may be cached for roughly five minutes.** Resolve `main` to a commit and download by immutable SHA when possible. This exists so an update does not report success while installing stale branch content.
- **Replacing a running Bash script across filesystems can overwrite its inode while Bash is still reading and seeking through it.** Staging beside the installed command and renaming avoids executing an offset from the old script inside new content.
- **A running shell process does not acquire logic from the script that replaces it.** The newly installed command must perform the image rebuild or the old in-memory behavior can build an environment inconsistent with the downloaded program. This exists to keep a successful update internally coherent.
- **Unraid's root filesystem and root home are RAM-backed.** Persistent install state must live on array storage, while links and SSH material need flash-backed boot restoration. This exists because an apparently successful conventional install otherwise vanishes at reboot.
- **Unraid's `go` script starts the web UI and is boot-critical.** Replacements must be syntax-checked, staged on the flash filesystem, installed atomically, and backed up. This exists because a partial or malformed write can require repairing the flash drive from another computer.
- **Unraid commonly stores container layers in a fixed-size virtual disk.** Rebuilding floating agent packages can strand roughly gigabytes of old layers. A superseded untagged image is reclaimed when it can be proven safe.
- **Filename order is the durable handoff chronology.** A truncated metadata header must not make a newer file immortal or invisible. The timestamp spelling intentionally sorts lexically after replacing filename-invalid colons.
- **Skill discovery is an agent-startup behavior.** A skill written during a Session is durable immediately but may not enter that already-running agent's discovery index. A fresh Session is the compatibility boundary.
- **A diagnostic that has no peer runtime reports has not demonstrated agreement.** The program distinguishes missing evidence from matching evidence because prior behavior falsely reported "no drift" from an empty comparison set.

## 6. Known weaknesses, ambiguities, and open questions

- **No-sync behavior is contradictory.** Setup says that handoffs, MCP, and skills stay on the machine when no Sync Repo is configured, but current Sessions do not mount a local Skill Library, MCP management refuses to run, and handoff generation is skipped. Open question: should these capabilities operate locally, or should the message say they are unavailable?
- **The settings feature is half-built.** The UI and storage support caravan-wide preference settings, but every currently defined setting is machine-local. The published claim that the generic setter is caravan-wide is therefore false for every supported key.
- **"Clear a setting" does not clear it.** Passing an empty value writes an explicit empty assignment and continues to report the source as local or synchronized instead of removing the override. Open question: whether compatibility means preserving empty overrides or honoring the documented clearing behavior.
- **Synchronized settings are executable shell code.** `settings.env` and local `config` are sourced before strict synchronized-state validation. A syntax error, conflict marker, or malicious Sync Repo edit can stop launch or execute host commands, contradicting the broader promise that no Sync Repo condition can block a Session.
- **MCP startup also violates fail-open synchronization.** A normal Session can detect malformed synchronized state, announce that synchronization is disabled, and then validate the MCP registry again as part of agent configuration. A malformed MCP registry can therefore abort the Session after the fail-open decision. Conversely, a valid MCP registry may still be consumed after some other registry caused synchronization to be disabled. The authority of the degraded-state boundary is ambiguous.
- **Two behavior-changing environment variables are undocumented.** Any nonempty `SATCHEL_HOST`, including the string `0`, enables a fully privileged Host Session; any nonempty `SATCHEL_NO_HANDOFF` suppresses handoffs. Their support and safer truth-value semantics are open questions.
- **A nominally normal Session can be configured to run as root.** A zero Session UID is accepted and is even presented as a workaround for root-owned worktrees, contradicting the claim that normal agents run unprivileged. Open question: whether UID zero is a supported safety exception.
- **Satchel-owned flag names cannot be passed through to the selected agent.** There is no end-of-options escape that makes `--host`, `--unsafe-home`, or `--with` native agent arguments, so a future or existing agent option with one of those names is inaccessible.
- **Several CLI parsers accept unintended inputs.** Linking can create an arbitrary command name that later invokes an unknown Satchel command; some MCP, settings, init, and retirement forms ignore extra arguments or unrecognized optional-position values instead of rejecting them.
- **Setting values lack semantic validation.** UID/GID need not be numeric, Boolean settings disable only on exact `0`, and the engine value can name any executable. Failures appear later and can be confusing.
- **A custom Session UID is not consistently honored on a non-root host.** UID switching and SSH-agent probing occur only when the invoking host process is root. If a non-root user configures a different Session UID, an agent can be reported usable for the host UID even though it may reject the container UID.
- **The persistent agent home is not a secret-isolation boundary.** A normal Session receives the selected agent's entire durable home plus network access, including transcripts, OAuth state, native MCP configuration, and other credentials the agent stores there. It can therefore transmit those materials even though the project and host mounts are restricted. Whether this is an accepted trust assumption is not stated.
- **Host Git configuration is imported wholesale into a newly created agent home.** It may contain absolute host paths, conditional includes, credential helpers, signing programs, or other settings that do not exist or are inappropriate inside the Session. The resulting compatibility behavior is undefined.
- **The pre-launch writability test is only an approximation.** It considers ownership and basic mode bits at the mount root; it does not account for ACLs, immutable attributes, filesystem restrictions, supplementary groups, or unwritable descendants. A warning can therefore be missing or misleading.
- **Host Sessions process extra-mount arguments that they later ignore.** An invalid or unsafe `--with` path can block Host Session launch even though the complete host is already exposed and the path would create no additional mount.
- **The documented ignored-repository invariant is not enforced.** An ignored entry carrying a stale `project` field passes current validation even though the published schema says ignored entries have no Project.
- **Origin validation is incomplete.** A registry key need only be nonempty and stable under the canonicalizer; it is not required to look like a network origin. IPv6 authorities, uppercase `.GIT`, percent-encoding, path normalization, and forge URLs with ports have ambiguous or inconsistent identities.
- **Remote migration is unsupported.** Initialization requires the requested URL to textually equal the existing `origin`, so equivalent URL spellings can be refused and moving a caravan between remotes is a manual operation with no defined workflow.
- **Local/no-origin Project linking is based only on explicit user choice.** There is no portable identity proof that two local repositories linked to the same Project ID are actually the same repository.
- **Host Session Project visibility uses the path cache without scanning the host.** Stale cached paths can appear visible or affect attribution until a normal scoped discovery refreshes them.
- **Handoff freshness is described two different ways.** Generated instructions tell the agent to find the latest handoff by the date in its first line, while actual selection and retention use filenames so truncated headers remain valid. The compatibility authority must be clarified.
- **Handoff format enforcement is weaker than the prompt.** It checks only that the five headings occur as complete lines. It does not enforce heading order, uniqueness, the 30-line limit, or well-formed content within every scope before accepting the writer's overall output.
- **Handoff filenames can collide.** Two handoffs for the same machine, scope, and UTC second overwrite the same path.
- **A changed transcript is only a proxy for meaningful work.** Handoff generation can be skipped after useful work that does not update the expected transcript, or attempted after a transcript change that contains no handoff-worthy work.
- **Handoff chronology and retention depend on host locale.** Filename sorting is intended to be lexical UTC ordering, but the ordering command inherits the process locale. Whether all supported locales preserve the expected order is not established.
- **The candidate-classification decision is delegated to model output.** A repository prompts only if the resumed agent emits the exact candidate delimiter. Substantive work can therefore be missed, and casual work can prompt, depending on model behavior.
- **MCP token files are a fragile line format.** Tokens containing a newline cannot be represented safely. Git does not preserve mode `0600`, and a synchronized token fetched on another host is not always explicitly re-chmodded before reading.
- **`auth: "none"` does not reliably suppress a stale token.** Re-adding a server without authentication does not remove a previously stored token, and materialization can still attach any token it finds without consulting the current authentication mode.
- **A missing bearer token can abort a noninteractive Session.** The interactive path can ask whether to store or skip a token, but an unanswered prompt or failed input read can propagate as a launch failure instead of simply omitting that server.
- **Removing a nonexistent MCP server reports success.** A syntactically valid name is accepted even when no registry entry or token was removed, so scripts cannot distinguish deletion from absence.
- **Codex MCP environment names can collide.** Server names that differ only by case or by `-` versus `_` can map to the same token variable, potentially giving one server another server's token.
- **MCP probing is reachability-only.** It sends no bearer token, treats every non-404 HTTP response—including authorization errors and server errors—as healthy, and performs no MCP protocol handshake.
- **Codex token values remain visible to same-user process inspection.** Keeping values out of container-engine arguments avoids one exposure channel, but an inherited environment is not a general secret store.
- **Claude MCP materialization replaces the entire native `mcpServers` object.** Native entries added outside Satchel are silently removed on the next Session. Malformed Claude JSON has no tailored preservation/recovery path comparable to the Codex marker handling.
- **Codex configuration preservation is heuristic, not a full TOML merge.** It recognizes table headers and base MCP server tables textually, can reorder rescued tables, and may not preserve future Codex write patterns.
- **The baseline secret scan is heuristic.** It can miss secrets that do not resemble its patterns and can block harmless long hashes, encoded data, or prose. It scans only newly added lines, so a preexisting secret is not caught.
- **Baseline safety decisions are process-local and non-transactional.** A detected secret or invalid marker blocks synchronization only in the current process. The changed files remain in the Sync Repo worktree and a later Session or explicit sync can commit them without repeating the secret scan. A failed, interrupted, declined, or incomplete baseline also leaves partial edits in place rather than restoring its starting snapshot.
- **The baseline's enforced access exceeds its stated prompt boundary.** It can write the current machine's entire synchronized area, not only the approved knowledge files, and retains network access, live clipboard access when available, persistent agent credentials, and native MCP configuration. The prompt is the only control preventing unrelated synchronized edits or data disclosure.
- **Machine-knowledge content rules are advisory.** The notes length is only warned about, while the distinctions between current facts, history, one-off work, inventory, and guides are prompt instructions rather than structurally validated contracts.
- **A read-only host bind does not make special files inert.** The Machine Baseline is instructed not to use control sockets, but a readable socket or device exposed under `/host` may still permit side effects despite the filesystem being mounted read-only.
- **Runtime drift data is incomplete and can be stale.** Published reports contain source-commit and engine fields that diagnostics never compare, and reports are refreshed only after a normal Session. A machine can therefore appear current after an update or engine change until another Session publishes. With no local agent-version cache, agent drift can also appear healthy despite missing evidence.
- **Skill validation proves package boundaries, not skill semantics.** It does not validate frontmatter, instructions, declared references, executable safety, or the existence of every file named by the skill. A bundle can pass synchronization checks yet fail or behave dangerously when an agent uses it.
- **The reserved Codex skill area has an unclear trust boundary.** It is physically colocated with the shared Skill Library and hidden from Git and user-skill reports, but it may still be visible to another agent that receives the library mount. Whether cross-agent visibility is intended is an open question.
- **The image is unreproducible.** The base tag and both agent packages float, so rebuilds at different times can change behavior without a Satchel source change. Drift is only reported after another Session publishes it.
- **Install and update trust remote content without a signature or pinned digest.** Syntax validation catches corruption that breaks Bash parsing but does not authenticate the artifact beyond HTTPS/GitHub.
- **Installation can overwrite an unrelated existing `satchel` command.** Redirects have ownership checks, but the main command destination is replaced unconditionally.
- **Update has no script rollback transaction.** The installed script is replaced before the new image is built. If the image build fails, the new script remains active while the recorded commit deliberately stays old.
- **Automatic synchronization commits every change in the private clone.** A Session-end sync can stage and publish unrelated manual edits that happened to be present, not only state generated by the just-finished Session.
- **Not every network operation is timeout-bounded.** Startup's best-effort synchronization is bounded, but explicit sync, some initialization and registration work, and non-strict retirement can wait indefinitely on Git, SSH, DNS, or credential prompts.
- **Continuing after a failed clone leaves ambiguous configuration.** The current run behaves as unsynchronized, but the stored Sync Repo URL remains configured. A later launch sees a configured URL with no usable clone and may follow a different failure path.
- **Generated identifiers have no stated length limit.** Very long origin-derived or user-supplied identifiers can approach filesystem component limits and break path creation after otherwise passing validation.
- **Uninstall can leave an inaccessible image behind.** Program and state removal can complete even when image deletion fails, so the command needed to inspect or retry cleanup may already have been removed.
- **Explicit retirement conflict handling is inconsistent with Session sync recovery.** Some retirement pull failures can leave an in-progress rebase rather than aborting it and restoring a clean clone. This contradicts the general no-mid-rebase safety invariant.
- **Unraid key persistence and restoration disagree.** Persistence chooses the first of Ed25519, ECDSA, or RSA, but the boot block restores only `id_ed25519*`. An ECDSA- or RSA-only machine can report a flash backup that will not be restored at boot. Persistence also assumes the matching `.pub` file already exists.
- **Unraid flash stores the private key in plaintext.** This is documented and intentional, but the program does not enforce that the key is limited to the private Sync Repo.
- **Engine detection is asymmetric.** Docker must answer `docker info` to be selected, while mere Podman command presence is enough. Installation checks only command presence for either engine.
- **Diagnostics have side effects and incomplete strictness.** They may refresh the local cached image-version file, contact GitHub and all MCP endpoints, and do not comprehensively run every synchronized-state validator before reporting success.
- **Whole-file registry conflicts remain a routine weakness.** The current policy preserves data and avoids guessing, but requires manual Git reconciliation even when machines changed unrelated logical entries.
- **Current-format compatibility is intentionally hostile to one older Project format.** The presence of the obsolete per-Project metadata file is a hard error; no automatic migration remains. Version-1 baseline markers receive a read fallback, but other historical formats do not.
- **The host-only plugin report is informational and incomplete.** Plugins are neither mounted nor synchronized, and the report depends on one host directory shape. There is no compatibility contract for other plugin managers or newer layouts.
- **The program has no release channel besides `main`.** Updates can change all machines independently, and there is no stable-version selection, downgrade command, release manifest, or declared synchronized-state schema version.
