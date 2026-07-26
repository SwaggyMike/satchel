# Satchel — Rewrite Requirements Specification

Aggregated from two independent readings of the current implementation. Where the
two disagreed, the source was consulted and the verified statement kept.

This document describes what Satchel does and what a replacement must keep doing.
It records observable behavior and external contracts, not implementation.
Anywhere behavior is unclear, contradictory, or looks accidental, it is flagged as
an **Open question** rather than resolved by guessing.

---

## 1. What the program does

### 1.1 Purpose

Satchel is a single-user command-line tool for Linux. It runs AI coding agent
CLIs — Claude Code and Codex — inside disposable containers scoped to one
directory, and carries a small amount of state between the user's machines
through a private Git repository the user owns and hosts themselves.

There is no daemon, no database, no service, and no HTTP API of its own.
Everything is plain files, Git, and a container engine. The user's collection of
machines is called a *caravan*.

### 1.2 Installation shapes

Two supported layouts:

- **Conventional** — the command on the host `PATH`, state under the user's home.
- **Self-contained** — command, redirect shims, and state all beside one another
  in a user-chosen persistent directory. This exists for systems whose root
  filesystem is rebuilt at boot.

Initial setup names the machine, optionally connects a private Git repository,
creates or adopts the initial synchronized state, registers the machine, and
ensures the shared container image exists.

Setup can complete without a Sync Repo. Sessions still launch, but every
synchronized capability is unavailable — see §6.1, where the current messaging
about this is contradictory.

A plain local path may be used as the Sync Repo remote. If it is absent or empty,
interactive setup offers to create a bare repository there.

Satchel can generate an unencrypted Ed25519 key and print every public key in the
host user's SSH directory. Authorizing a key at the Git host is always manual; it
never talks to a forge API.

### 1.3 Command surface

Global options, accepted before the command **or** anywhere among the agent's own
arguments:

- `--host` — Host Session (sandbox deliberately off)
- `--unsafe-home` — permit a sandboxed session in `$HOME` or above
- `--with <dir>` — mount an additional directory (repeatable)

The environment variable `SATCHEL_HOST`, set to any non-empty value, also enables
Host Session mode.

| Command | Observable behavior |
| --- | --- |
| `satchel claude [args]` | Run Claude Code in a container scoped to `$PWD`; remaining args pass to the agent |
| `satchel codex [args]` | Same for Codex |
| `satchel init` | Interactively name this machine and connect the Sync Repo |
| `satchel sync` | Commit, pull, push the Sync Repo; report conflicts |
| `satchel status [--ignored]` | Report engine, image, shims, sync state, caravan, Projects, MCP, skills |
| `satchel doctor` | Run end-to-end health checks; non-zero exit on any hard failure |
| `satchel track [id]` | Explicitly enroll the enclosing Git repository as a Project |
| `satchel untrack [id]` | Globally ignore a Project and delete its active handoffs |
| `satchel skills [list]` | List user-installed skills |
| `satchel skills remove [name]` | Remove a skill everywhere; numbered picker when unnamed |
| `satchel mcp [list\|add\|remove]` | Manage the MCP registry; bare `add`/`remove` are interactive |
| `satchel settings` | Print all settings, values, and sources |
| `satchel settings <KEY> <value> [--local]` | Change a setting |
| `satchel key [--persist]` | Print public keys, generating one if absent |
| `satchel retire [machine]` | Remove a machine's folder from the Sync Repo |
| `satchel import claude\|codex` | Copy the host user's agent login into Satchel's agent home |
| `satchel image [--rebuild]` | Build the shared image if missing, or force a rebuild |
| `satchel update` | Self-update from upstream and rebuild the image |
| `satchel link [claude\|codex]` | Install redirect shims |
| `satchel unlink [claude\|codex]` | Remove them |
| `satchel uninstall [--purge] [--yes]` | Remove program, shims, image; optionally purge state |
| `satchel version` / `--version` | Print the version |
| `satchel help` / `--help` / `-h` | Print usage |

No command behaves as `help`. Unknown commands and unsupported command-specific
options exit non-zero.

### 1.4 Redirect shims

Two thin wrappers, `claude` and `codex`, may be installed on the user's `PATH`.
Each execs Satchel with the corresponding agent name, so typing `claude` in a
project directory starts a sandboxed session there.

Satchel recognizes a shim as its own only by exact content, and refuses to
overwrite or delete anything it cannot prove it created.

### 1.5 A session, observably

1. Refuses outright if the working directory is `$HOME`, an ancestor of `$HOME`,
   `/`, or Satchel's own private state directory — offering a Host Session
   instead when a terminal is attached.
2. Validates and normalizes any extra mount directories under the same rules.
3. Selects a container engine, builds the shared image if absent, and verifies the
   engine can actually bind-mount Satchel's local files.
4. Determines whether an SSH agent will be reachable **by the container's UID**,
   loading a standard host key or starting a temporary agent as needed, and
   pausing for acknowledgement if `git push` over SSH will not work.
5. Pulls the Sync Repo (best-effort, bounded, never blocking).
6. Validates synchronized state; on any problem, disables syncing for the run and
   continues.
7. Repairs the shared skill library, quarantining malformed entries.
8. Prunes handoff directories to their retention bound.
9. At most once per day, checks whether a newer version exists upstream.
10. Discovers Git repositories inside the mount roots and maps them to Projects.
11. On an agent's first normal launch after it authenticates, offers a one-time
    Machine Baseline. Accepting **consumes the launch** and returns to the shell.
12. Seeds a Git identity into the agent home from the host's, never overwriting an
    existing value.
13. Materializes the MCP registry into the agent's native configuration.
14. Writes the generated instruction file into the agent home.
15. Declares the mounted roots trusted for Git and warns, with an exact `chown`,
    if the session's UID will not be able to write them.
16. Runs the agent interactively.
17. Repairs ownership of Satchel's own writable state.
18. If new transcripts appeared, re-discovers repositories and runs the unattended
    handoff writer, then files the resulting notes.
19. Re-validates skills, publishes this machine's runtime versions, commits and
    best-effort pushes.

The interactive agent's exit status is returned after all of that.

Nothing in steps 5–8 or 17–19 may prevent step 16 — with one currently-broken
exception recorded in §6.2.

### 1.6 Session safety boundary

A normal session runs with no Linux capabilities, `no-new-privileges`, and a
configurable non-root UID/GID. A root-run host defaults to `1000:1000`; a non-root
host defaults to the invoking user's IDs.

It is a boundary for **filesystem visibility and privilege**, not for network or
user identity: it has ordinary networking, may use the forwarded SSH identity, and
may read and write the live desktop clipboard.

A Host Session is deliberately not a security boundary at all: root, privileged,
host PID and network namespaces, host root filesystem read-write at `/host`. It
prints an explicit pre-launch warning. Normal sessions print no routine banner.

### 1.7 Projects

A Project is an explicitly tracked Git repository. Ordinary directories can never
become Projects.

Identity is the portable, credential-free normalized Git origin, global across
machines. Multiple checkouts of one origin share one Project; different origins
must never share a Project ID.

Discovery recurses only within the declared mount roots, before and after the
session, so repositories cloned mid-session are still recognized. It does not
follow symlinks and prunes common dependency and build directories.

An unknown network-origin repository is offered for tracking **only** if
end-of-session analysis reports substantive continuation-worthy work there.
Discovering, listing, or casually reading one never prompts. Declining records a
caravan-wide ignored decision; the work still reaches the machine handoff.

Repositories with no origin or a local-only origin can be tracked only by explicit
command, and linked on another machine only by naming an existing Project ID.

Nested repositories attribute work to the nearest enclosing tracked repository.

### 1.8 Handoffs

After a session that produced a new transcript, the same agent is asked to resume
the conversation and write a short structured continuation note. Satchel — not the
agent — files it into the Sync Repo.

The note is injected into the next session's starting context for that Project,
including on another machine.

One visible Project at launch scope gets a single note. Multi-repository sessions
can produce one note per Project actually worked in plus one machine-scope note
for everything outside them.

The writer is deliberately starved: only the agent's own conversation home and an
empty filesystem at the original working directory. No project contents, no
`/host`, no SSH socket, no clipboard, no MCP tools, no skills, no machine state.

It runs the agent's normal default model at low reasoning effort, under a
four-minute limit.

### 1.9 Machine knowledge

Three tiers per machine:

- **Notes** — concise current operational truth, injected into every session on
  that machine, 750-word soft limit.
- **Inventory** — a broad dated system reference, listed by path and generation
  time, read on demand.
- **Guides** — substantial reusable procedures, one current file per topic, listed
  by path and title, read on demand.

Every session can write its own machine's knowledge and read every other
machine's, read-only.

The **Machine Baseline** is an optional first inventory. An authenticated agent
inspects the real host through a read-only mount, shows the user its proposed
files for approval, and writes into the synced machine directory. Offered once per
machine; deferrable and permanently suppressible.

### 1.10 Skills

Exactly one skill library, shared by both agents and all machines, mounted
read-write at each agent's native skills path. Installing a skill is an agent
writing a complete folder there; there is no host-side install command and Satchel
owns no source format or update protocol.

At session exit every top-level entry is validated. Malformed attempts move to a
machine-local quarantine and never sync; a previously committed valid version is
restored in their place. Valid changes are listed, committed, and pushed even when
no handoff was written.

A newly installed skill can be assumed discoverable only from the next session.

### 1.11 MCP servers

Servers are registered once — name, URL, auth mode — and the registry syncs.
Tokens are stored separately and may be synced or kept machine-local, with local
winning. At every session start the registry replaces the managed portion of the
agent's native configuration.

### 1.12 Side effects, summarized

Creates and writes a private state directory; clones, commits to, and pushes a
user-specified Git repository; builds and removes a container image and
containers; creates and removes executable files on the user's `PATH`; may
generate an SSH keypair and copy it to Unraid flash; edits the Unraid boot script
within a delimited block; makes outbound HTTPS requests to the GitHub API, the raw
content host, and every registered MCP endpoint; changes ownership of a small
exact allowlist of its own directories.

Narration goes to stderr; report output goes to stdout.

---

## 2. External contracts that must be preserved

Everything below is depended on by something outside the program.

### 2.1 CLI grammar

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

The three session options are consumed by Satchel and never forwarded. All other
agent arguments retain their order.

Version line:

```text
satchel 2.0.0
```

Message prefixes:

```text
satchel: ...
satchel: warning: ...
satchel: error: ...
```

Colour is decided independently for stdout and stderr. Precedence: a non-empty
`NO_COLOR` disables it unconditionally; `TERM=dumb` disables it; otherwise
`CLICOLOR_FORCE=1` forces it on; otherwise colour requires that descriptor to be a
terminal.

### 2.2 Installation entry point

```sh
curl -fsSL https://raw.githubusercontent.com/SwaggyMike/satchel/main/install.sh | bash
```

Installer inputs:

```text
SATCHEL_BIN=<install-directory>      # a directory, not the executable path
SATCHEL_DIR=<state-directory>
SATCHEL_SHIMS=y|<anything-else>      # exact "y" enables shims
```

Directory precedence, used identically by the installer and by `satchel link`:

1. `$SATCHEL_BIN` if set
2. the directory containing the resolved command, if a `.satchel` directory sits
   beside it
3. `/usr/local/bin` if writable
4. `$HOME/.local/bin`

The installer must refuse a `SATCHEL_BIN` whose last component is `satchel` when
its parent is on `PATH` — that would make the shell resolve a directory as the
command. The installed script is mode `755`.

### 2.3 Host environment variables

Read at runtime:

```text
SATCHEL_DIR SATCHEL_BIN SATCHEL_ENGINE SATCHEL_SSH SATCHEL_CLIPBOARD
SATCHEL_UID SATCHEL_GID SATCHEL_HOST SATCHEL_NO_HANDOFF SATCHEL_SELF
SATCHEL_UNRAID_MARKER SATCHEL_UNRAID_BOOT_DIR SATCHEL_UNRAID_LIVE_BIN_DIR
HOME PATH TERM TMPDIR NO_COLOR CLICOLOR_FORCE
SSH_AUTH_SOCK GIT_SSH_COMMAND
WAYLAND_DISPLAY XDG_RUNTIME_DIR DISPLAY XAUTHORITY
```

The three Unraid path overrides and `SATCHEL_SELF` exist so the behavior is
testable off that platform. Whether they are public API is an **open question**.
`SATCHEL_HOST` and `SATCHEL_NO_HANDOFF` are undocumented — see §6.5.

### 2.4 Shim file format

Exactly three lines, path shell-quoted:

```bash
#!/usr/bin/env bash
# satchel shim
exec /mnt/user/appdata/satchel/satchel claude "$@"
```

Two recognition rules must both survive:

- **Generic ownership** (enough to report or replace, not to delete): a line
  matching `^# satchel shim$`, **or** a legacy line matching the extended regular
  expression `^exec[[:space:]]+satchel[[:space:]]+(claude|codex)([[:space:]]|$)`.
- **Exact ownership** (required before deleting): the file contains, as a whole
  line, the literal `exec %q <agent> "$@"` this installation would generate for its
  own resolved path. A lexical sibling spelling is accepted only while it resolves
  to the same installed command — this exists so a distribution aliasing `/home` to
  `/var/home` does not break uninstall.

### 2.5 State directory

Selected in order: a non-empty `SATCHEL_DIR`; a real `.satchel` directory beside
the resolved command; `$HOME/.satchel`. Created mode `700`.

```text
config                       machine-local settings, sourced as Bash
sync/                        the Sync Repo clone
home/claude/                 persistent Claude login, config, SSH trust, transcripts
home/codex/                  persistent Codex login, config, SSH trust, transcripts
mcp-tokens.local.env         machine-only MCP tokens, mode 600
script-sha                   full installed commit SHA plus newline
install-path                 resolved absolute command path plus newline
image-agents                 "claude <version>, codex <version>" plus newline
update-check                 decimal Unix timestamp
quarantine/skills/           invalid skill attempts, retained locally
recovery/sync-<UTCSTAMP>/    content preserved from an interrupted clone destination
```

Quarantine and recovery stamps use `%Y%m%dT%H%M%SZ` in UTC.

### 2.6 Machine config file

Written by setup, sourced by every run, values shell-escaped:

```bash
# Satchel config — plain bash, sourced by satchel.
# See and change settings with 'satchel settings'; this file is the
# machine-local layer (it wins over the synced settings.env).
MACHINE=debianlaptop
SYNC_URL=git@example.com:user/satchel-sync.git
# SATCHEL_ENGINE=  # force docker or podman (default: auto-detect)
# SATCHEL_SSH=1  # forward the host's ssh-agent into sessions so git push works (0 = off)
# SATCHEL_CLIPBOARD=1  # forward the desktop clipboard socket so pasting images works (0 = off)
# SATCHEL_UID=  # user id inside session containers (default: your uid; 1000 if root)
# SATCHEL_GID=  # group id inside session containers (default: SATCHEL_UID)
```

The supported setting keys are exactly:

```text
SATCHEL_ENGINE SATCHEL_SSH SATCHEL_CLIPBOARD SATCHEL_UID SATCHEL_GID
```

Precedence: built-in default < synced `settings.env` < machine `config`. Both files
use the same shell-assignment format and both are **sourced as executable Bash** —
see §6.4.

Machine names and Project IDs both match:

```text
^[A-Za-z0-9][A-Za-z0-9._-]*$
```

### 2.7 Sync Repo layout

```text
profile.md                              global context; first line not injected
preferences.md                          global context; first line not injected
repositories.json                       sole authority for repository identity
mcp.json                                MCP server registry
mcp-tokens.env                          synced tokens, mode 600
settings.env                            synced settings layer
.gitignore                              must contain: /skills/shared/.system/
skills/shared/                          the one shared skill library
skills/shared/.gitkeep
skills/shared/skills-lock.json          optional, installer-owned, valid JSON
projects/<id>/handoffs/                 per-Project handoffs
projects/<id>/handoffs/.gitkeep
machines/<name>/notes.md
machines/<name>/inventory.md
machines/<name>/guides/<topic>.md
machines/<name>/projects.json           machine-local checkout path cache
machines/<name>/environment.json        published runtime versions
machines/<name>/handoffs/               machine-scope handoffs
machines/<name>/.baseline-skip          presence disables the baseline offer
```

Default context files are created as:

```markdown
# Profile
```

```markdown
# Preferences
```

Content from line 2 onward is concatenated as global context, Profile first.

`projects/<id>/` contains **only** `handoffs/`. The directory name *is* the Project
ID. A `project.json` inside a Project directory is a hard schema violation.
Project directories and machine directories must not be symlinks.

Baseline suppression file content:

```text
suppressed at 2026-07-25T12:34:56Z
```

### 2.8 `repositories.json`

```json
{
  "github.com/example/project": { "status": "tracked", "project": "project-id" },
  "github.com/example/ignored": { "status": "ignored" }
}
```

Empty file is `{}`. Rules:

- root is an object; every key a non-empty canonical identity string; every value
  an object
- `status` is exactly `"tracked"` or `"ignored"`
- a tracked entry has a non-empty string `project` naming an existing Project
- no two tracked origins may use the same Project ID
- every key must already be canonical — re-canonicalizing it is a no-op
- **unknown fields must be accepted**, so a newer version elsewhere in the caravan
  cannot brick older machines

The documented rule that ignored entries carry no Project is **not enforced** —
see §6.10.

### 2.9 Canonical origin form

Portable origins begin with `ssh://`, `git://`, `http://`, or `https://`, or match
the SCP-like `user@host:path`. Canonicalization applies, in order:

1. Remove everything from the first `#` or `?` onward.
2. Remove one trailing `/`.
3. For scheme URLs: drop the scheme, drop user information through the last `@` in
   the authority, lowercase the hostname, retain any `:<port>`, join authority and
   path with `/`.
4. For SCP-like forms: drop the user portion, lowercase the host, change the first
   separator from `:` to `/`.
5. Remove one trailing lowercase `.git`.
6. Remove one trailing `/`.
7. For identities beginning `github.com/`, `gitlab.com/`, or `bitbucket.org/`,
   lowercase the entire identity.

```text
git@github.com:Example/Repo.git
https://github.com/example/repo
=> github.com/example/repo

https://token@example.com/Owner/Repo.git?x=secret
=> example.com/Owner/Repo
```

No credential may ever reach the registry, a candidate listing, or a handoff.

### 2.10 `machines/<machine>/projects.json`

```json
{ "paths": { "/absolute/checkout": { "project": "project-id" } } }
```

Empty file is `{"paths":{}}`. Path keys must be absolute; `project` is required and
must name an existing Project; unknown fields accepted.

### 2.11 `mcp.json`

```json
{
  "servers": {
    "homeassistant": { "url": "http://host:8123/api/mcp", "auth": "bearer" },
    "public":        { "url": "https://example.test/mcp",  "auth": "none" }
  }
}
```

Empty file is `{ "servers": {} }`. Server names match `^[A-Za-z0-9_-]+$`. `url`
must be a non-empty string whose every code point is `>= 32` and is not `34` (`"`),
`92` (`\`), or `127` — so it can be embedded verbatim in a TOML double-quoted
string. `auth` is exactly `"bearer"` or `"none"`. Unknown fields accepted.

### 2.12 Token files

`mcp-tokens.env` (synced) and `mcp-tokens.local.env` (machine-only):

```text
homeassistant=<token bytes through end of line>
another_server=<token bytes through end of line>
```

The first exact `<server>=` line wins within a file; the local file is consulted
before the synced one. Writers set mode `0600`, which Git does not preserve across
machines.

### 2.13 `machines/<machine>/environment.json`

```json
{
  "satchel": "2.0.0",
  "commit": "7179842",
  "engine": "docker",
  "agents": "claude 2.1.217, codex 0.145.0"
}
```

All four values are strings; `satchel` must be non-empty; the others may be empty
when unavailable. `commit` is the first 7 hex characters of the recorded install
SHA. `agents` has the exact shape `claude <version>, codex <version>`. Unknown
fields accepted. The file is rewritten only when its content actually changes, so
ordinary sessions produce no commit churn.

### 2.14 Handoff files

```text
projects/<project-id>/handoffs/YYYY-MM-DDTHH-MM-SSZ--<machine>.md
machines/<machine>/handoffs/YYYY-MM-DDTHH-MM-SSZ.md
```

The stamp is UTC `%Y-%m-%dT%H:%M:%SZ` with every `:` replaced by `-`, so filenames
sort lexically in chronological order. Filenames are the durable ordering key;
nothing may depend on parsing a date out of the body.

```markdown
<!-- satchel-handoff project=<project-id-or-> machine=<machine> date=2026-07-25T20:36:15Z -->
## Goal
## Done
## In flight
## Next steps
## Gotchas
```

`project=-` denotes machine scope. All five headings must appear as complete
lines. Retention is the newest **100** files per scope; older ones are removed from
the working tree and remain in Git history.

### 2.15 Multi-scope writer protocol

```text
=== project: <project-id> ===
=== candidate: candidate-<integer> ===
=== machine ===
```

The exact no-op response:

```text
NO_HANDOFF
```

Chunks are filed only if they contain all five headings. Chunks naming a scope not
on the roster are dropped. Multiple chunks for one scope are merged into a single
file rather than overwriting each other.

### 2.16 Machine Baseline marker

First line of the inventory:

```html
<!-- satchel-machine-baseline version=2 generated=2026-07-25T12:34:56Z -->
```

For migration, a version-1 marker is recognized in the inventory, or in the notes
file when the inventory is absent:

```html
<!-- satchel-machine-baseline version=1 generated=2026-07-25T12:34:56Z -->
```

### 2.17 Skill Library contract

The synchronized library is `skills/shared/`. Skill names match
`^[A-Za-z0-9][A-Za-z0-9._-]*$`. Every user skill is a real top-level directory
containing `SKILL.md`, with no nested `.git`, no top-level symlink, and no broken
or escaping symlink.

The only allowed top-level metadata file is `skills/shared/skills-lock.json`. Its
schema is installer-owned; Satchel requires only a real non-symlink file
containing valid JSON, never interprets or rewrites it, and never reports it as a
skill.

Required ignore line:

```gitignore
/skills/shared/.system/
```

Quarantined names:

```text
<UTC YYYYMMDDTHHMMSSZ>--<original-name>
<UTC YYYYMMDDTHHMMSSZ>--<original-name>-<collision-number>
```

### 2.18 Agent-native MCP materialization

**Claude** — `<agent home>/.claude.json`, unrelated root fields retained, the
entire `mcpServers` property replaced:

```json
{
  "mcpServers": {
    "server": {
      "type": "http",
      "url": "https://example.test/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

Servers without a token omit `headers`.

**Codex** — `<agent home>/.codex/config.toml`, exactly one managed marker pair,
inserted before the first TOML table:

```toml
# >>> satchel mcp >>>
# managed by satchel — rebuilt every session start
[mcp_servers.server]
url = "https://example.test/mcp"
bearer_token_env_var = "SATCHEL_MCP_TOKEN_SERVER"
# <<< satchel mcp <<<
```

Content outside the markers must survive. A missing, duplicate, nested, or unclosed
marker pair is an error that leaves the file byte-identical.

The token variable name is `SATCHEL_MCP_TOKEN_<SERVER_NAME>`, with lowercase ASCII
uppercased and `-` becoming `_`. Other permitted characters are retained — see
§6.24 for the collision this creates.

### 2.19 Generated session instructions

```text
Claude: /home/satchel/.claude/CLAUDE.md
Codex:  /home/satchel/.codex/AGENTS.md
```

Exact first line:

```markdown
# Managed by Satchel — rewritten at every session start; do not edit.
```

Section headings, in order, present when applicable:

```markdown
## Where you are running
## Satchel Skill Library
## Machine Notes (<machine>)
## Global context
## Tracked projects in this session
## Handoff from the previous session on this project (machine <name>, <date>)
## Handoff from the previous session on this machine outside any project (machine <name>, <date>)
```

Behavioral requirements, treated as a public interface:

- Every path named must be **absolute**. Never `~` — a Host Session runs as root
  and `~` resolves to the wrong place.
- A sandboxed session's text must say other machine files are *outside the
  sandbox*, so the agent answers that rather than "the file does not exist".
- A Host Session's text must say the container's bare `/etc`, `/usr`, `/var` are
  disposable and the real copies are under `/host`.
- The SSH paragraph must match the probed state and must not claim pushing works
  unless an identity is actually loaded.
- With no usable Sync Repo, the skill-library and machine-notes sections are
  omitted entirely.

### 2.20 Container image

Tag `localhost/satchel:latest`.

```dockerfile
FROM docker.io/library/node:22-bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git curl wget ca-certificates jq ripgrep less procps openssh-client \
      python3 make g++ bubblewrap wl-clipboard xclip \
 && rm -rf /var/lib/apt/lists/*
RUN npm install -g @anthropic-ai/claude-code @openai/codex
ENV HOME=/home/satchel
RUN mkdir -p /home/satchel && chmod 0777 /home/satchel
RUN sed -Ei 's#^((root|node):[^:]*:[^:]*:[^:]*:[^:]*:)[^:]*:#\1/home/satchel:#' /etc/passwd
WORKDIR /home/satchel
```

Nothing is pinned; every machine builds its own from floating tags. Builds pass
`--pull`.

Ownership label carried by every container Satchel creates:

```text
io.github.swaggymike.satchel.managed=true
```

Handoff helper container name:

```text
satchel-handoff-<host-process-id>
```

### 2.21 Mount and environment contract

| Host source | Container destination | Mode |
| --- | --- | --- |
| agent home | `/home/satchel` | rw |
| `sync/machines/<machine>` | `/home/satchel/machine` | rw |
| `sync/projects` | `/home/satchel/projects` | ro |
| `sync/machines` | `/home/satchel/machines` | ro |
| `sync/skills/shared` | `/home/satchel/.claude/skills` or `/home/satchel/.codex/skills` | rw |
| `$SSH_AUTH_SOCK` | `/run/ssh-agent.sock` | rw |
| Wayland socket | `/run/satchel/wayland-0` | rw |
| `/tmp/.X11-unix` | `/tmp/.X11-unix` | rw |
| `$XAUTHORITY` | `/run/satchel/Xauthority` | ro |
| project directory | the same absolute path | rw |
| each extra directory | the same absolute path | rw |
| `/` (Host Session) | `/host` | rw |
| `/` (Machine Baseline) | `/host` | ro |

Environment inside a session:

```text
HOME=/home/satchel
TERM=<host TERM, default xterm-256color>
DISABLE_AUTOUPDATER=1
SATCHEL_SESSION=1
SATCHEL_SESSION_MODE=sandbox|host
SATCHEL_SKILLS_DIR=/home/satchel/.claude/skills   (or the codex path)
SSH_AUTH_SOCK=/run/ssh-agent.sock
GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=accept-new
WAYLAND_DISPLAY=/run/satchel/wayland-0
DISPLAY=<host DISPLAY>
XAUTHORITY=/run/satchel/Xauthority
SATCHEL_MCP_TOKEN_<NAME>=<token>
```

`SATCHEL_SESSION`, `SATCHEL_SESSION_MODE`, and `SATCHEL_SKILLS_DIR` are a
documented contract for skill installers to detect the runtime.

MCP token variables must be passed **by name only** (`-e NAME`), never
`-e NAME=value`, so values never appear in the host process list.

Engine flags, sandboxed:

```text
--init --user <uid>:<gid> --cap-drop ALL --security-opt no-new-privileges
```

Engine flags, Host Session:

```text
--privileged --pid=host --network=host --user 0:0 -v /:/host
```

No `--init` in Host Session mode — it needs a private PID namespace. **No `--pid`
flag at all** in sandboxed mode — Docker rejects `--pid=private`.

SELinux hosts add `--security-opt label=disable`. Rootless Podman adds:

```text
--userns=keep-id --passwd-entry '$USERNAME:*:$UID:$GID::/home/satchel:/bin/bash'
```

The handoff writer additionally gets, and **only** gets:

```text
--tmpfs <original-cwd>:rw,nosuid,nodev,noexec,mode=1777
-w <original-cwd>
```

### 2.22 Agent CLI invocations

Contracts with third-party CLIs; preserve verbatim unless those CLIs change.

```text
# interactive
claude <user args>
codex -c 'sandbox_mode="danger-full-access"' -c check_for_update_on_startup=false <user args>

# handoff writer
claude --continue --strict-mcp-config --tools "" --effort low -p "<prompt>"
codex exec resume --last --skip-git-repo-check --ignore-user-config --ignore-rules \
  -c 'sandbox_mode="danger-full-access"' -c 'model_reasoning_effort="low"' "<prompt>"

# machine baseline
claude "<prompt>"
codex -c 'sandbox_mode="danger-full-access"' -c check_for_update_on_startup=false "<prompt>"
```

Version probe, run inside the image:

```sh
printf "claude %s, codex %s" "$(claude --version 2>/dev/null | cut -d" " -f1)" "$(codex --version 2>/dev/null | cut -d" " -f2)"
```

Login detection and import paths:

```text
Claude:  ~/.claude/.credentials.json          (presence proves login)
         ~/.claude.json                       (login only if .oauthAccount or
                                               .primaryApiKey is non-empty —
                                               mere existence proves nothing,
                                               because MCP materialization
                                               creates one before any login)
Codex:   ~/.codex/auth.json
```

Transcript directories watched to decide whether a conversation happened:

```text
<agent home>/.claude/projects
<agent home>/.codex/sessions
```

### 2.23 Automatic commit subjects

Users read these in Git history, so they are a contract:

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

### 2.24 Unraid contract

```text
/etc/unraid-version          detection marker
/boot/config/go              boot script
/boot/config/go.satchel-bak  last version that parsed
/boot/config/ssh/root/       flash key directory
/usr/local/bin               live link directory
```

Managed block, every path shell-escaped:

```bash
# >>> satchel boot persistence >>>
ln -sf <installed-satchel> [<owned-claude-shim> <owned-codex-shim>] /usr/local/bin/
mkdir -p /root/.ssh && chmod 700 /root/.ssh
cp <boot-key-directory>/id_ed25519* /root/.ssh/ 2>/dev/null && chmod 600 /root/.ssh/id_ed25519
cp <boot-key-directory>/known_hosts /root/.ssh/ 2>/dev/null
```

Only shims this installation owns appear on the `ln` line. Staging file pattern
`/boot/config/go.satchel-tmp.XXXXXX`, always in the same directory so the swap is a
rename. This content must exist in exactly one place — it was previously duplicated
in the installer and the README, and the copies drifted.

### 2.25 Network endpoints

Satchel exposes no service API. Outbound:

```text
https://api.github.com/repos/SwaggyMike/satchel/commits/main
https://api.github.com/repos/SwaggyMike/satchel/contents/satchel?ref=main
https://api.github.com/repos/SwaggyMike/satchel/compare/<old>...<new>
https://raw.githubusercontent.com/SwaggyMike/satchel/<commit-or-main>/satchel
https://raw.githubusercontent.com/SwaggyMike/satchel/main/install.sh
```

Plus the configured Sync Repo `origin` and each registered MCP URL.

### 2.26 Exit codes

| Code | Meaning |
| --- | --- |
| `0` | success |
| `1` | generic failure |
| `2` | bad usage of the build tooling |
| `130` | SIGINT — must propagate out of every long operation |
| `131` | handoff deliberately skipped via SIGQUIT |

Diagnostics exit non-zero when any check reported a hard failure. Warnings do not
cause failure.

---

## 3. Real-world constraints

### 3.1 Platform and dependencies

- **Linux only.** Targets: Debian/Ubuntu, Fedora (SELinux), Unraid.
- **Bash**, using arrays, process substitution, `$'…'` quoting, named traps —
  effectively 4.4 or newer.
- Host commands: `git`, `jq`, `curl`, OpenSSH client utilities, and common GNU
  utilities including `timeout`, `readlink`, `find`, `stat`, `sed`, `awk`, `grep`,
  `mktemp`, `chmod`. Root-host SSH fallback additionally requires `setpriv` from
  util-linux. `sudo` is used only as a fallback for removals and the boot swap.
- Docker or Podman. Docker is preferred when both are present **and its daemon
  answers**; Podman is selected on mere command presence — see §6.39.
- Sessions require only `git` and `jq` on the host. Reporting commands must work
  with no container engine at all.
- Running Satchel inside another application container is supported only when the
  selected engine sees the same host paths.
- The image targets Node 22 on Debian Bookworm slim with latest agent packages at
  build time. Codex native-skill compatibility was verified against **0.145.0**.

### 3.2 Permission and isolation model

- A sandboxed session never runs as root inside the container by default; a
  root-run host falls back to `1000:1000`. (UID 0 is nonetheless accepted — §6.6.)
- Sandboxed sessions drop all capabilities and set `no-new-privileges`; Host
  Sessions deliberately do neither.
- The container is packaging, not protection, in Host Session mode — this must be
  announced. Normal launches must be silent, because agent TUIs immediately repaint
  the screen and a routine banner only flashes.
- Ownership repair is restricted to an **exact allowlist**: the two agent homes,
  the shared skill library, and this machine's synced knowledge directory. Success
  is silent. It must never touch project files or arbitrary host paths.
- SSH forwarding authorizes signing with every identity in the agent for the life
  of the session. Key bytes never enter the container, but the session can
  authenticate anywhere those identities are authorized.
- Clipboard forwarding exposes content copied *while* a session runs, including
  passwords. On some Wayland compositors the socket grants more than clipboard.
- A Host Session under rootless Podman maps container root to the unprivileged host
  user, so root-owned host paths still reject writes. That is a host property, not
  something the program can work around.

### 3.3 Must-never-happen invariants

- The Sync Repo must never prevent an agent from starting. Every mount, read, and
  push is conditional on a single "syncing is usable" predicate that can be turned
  off for the rest of a run.
- The clone must never be left mid-rebase for the user to untangle.
- Satchel must never resolve a conflict on the user's behalf.
- Agent login credentials and transcripts must never sync.
- Bearer token values must never appear in container-engine arguments.
- SSH private key files must never enter a session mount.
- A sandboxed session must never mount `$HOME`, an ancestor of it, `/`, or
  Satchel's state directory — the last not even with the override flag.
- Shims, containers, images, arbitrary scripts, and state trees must never be
  deleted without proven ownership or an exact user-named target.
- A malformed boot script must never be installed, and the real file must never be
  truncated in place.
- Purge must never delete the upstream repository.
- Malformed or uncertain user data must be quarantined or preserved, never
  silently deleted.
- Baseline secret scanning must never echo a suspected secret.

### 3.4 Ordering and atomicity

- SSH preparation must precede the first Sync Repo network operation, or an empty
  desktop agent produces a misleading "cannot reach the Sync Repo" warning moments
  before the key is loaded.
- Interrupted-operation recovery must be checked **before** the upstream check — a
  rebase detaches `HEAD`, so the upstream expression stops resolving in exactly the
  state the guard exists to catch.
- Synchronized state must be pulled and validated before being mounted or
  materialized.
- Instructions and native MCP config must be regenerated before the agent starts.
- Argument composition must precede the final ownership repair, because composition
  creates missing mount roots.
- Ownership normalization runs immediately before a normal session, and again after
  a Host Session so an unprivileged handoff writer can read the transcript.
- Repository discovery runs both before and after the interactive agent, and
  post-session discovery must precede attribution and candidate decisions.
- The interrupt trap must be installed **before** startup work, not just before the
  engine runs.
- After the interactive engine exits, interrupts must be **ignored**, not merely
  caught — a caught handler resets to default in child processes, and cleanup
  spawns children.
- Changes must be committed locally before any best-effort push, so an offline or
  rejected push leaves a recoverable commit.
- Machine registration must integrate remote history before pushing, so an ordinary
  non-fast-forward is not misreported as a read-only deploy key.
- Replacement of the installed command and of the boot script must be staged in the
  destination directory and installed by same-filesystem rename.
- Self-update: the **new** artifact must own the image rebuild.
- Uninstall retirement must complete upstream before any local removal begins.

### 3.5 Timeouts and bounds

| Operation | Bound |
| --- | --- |
| Session-start Sync Repo pull | 20 s |
| Session-end best-effort pull and push | 30 s each |
| Retirement pull and push | 30 s each |
| Diagnostics remote reachability | 10 s |
| MCP endpoint probe (per attempt) | 5 s |
| Daily update probe | 5 s |
| Handoff writer | 240 s |
| Update-check frequency | at most once per 86 400 s |

The update-check timestamp is written **before** the probe, so an offline day costs
one failed request rather than one per session. Not every network operation is
bounded — see §6.34.

### 3.6 Policy constants

- Handoff retention: **100** files per Project and per machine
- Machine notes soft ceiling: **750** words
- Machine Baseline version: **2**

These are guardrails, not data-loss rules — essential information should be
consolidated or moved to a guide rather than discarded to satisfy a count.

### 3.7 External-system constraints

- **Unraid** rebuilds `/`, `/usr/local/bin`, and `/root` from flash at boot. State
  must live on persistent `/mnt` storage; links and SSH material must be restored
  through the boot script. Flash is unencrypted FAT and is a single point of failure
  for the entire array configuration.
- **Git 2.35+** rejects repositories owned by a different user unless explicitly
  marked safe — routine on root-run hosts whose sessions use UID 1000.
- **The same private repo is written from multiple machines.** Whole-file registries
  make ordinary concurrent edits conflict even when the machines changed different
  logical entries.
- **Each machine's floating image build can contain different agent versions.**
  Drift is expected and is reported, never auto-corrected.

---

## 4. Edge cases and failure modes currently handled

Stated as "when X happens, the program must Y."

### 4.1 Installation and initialization

- When a required host command is missing, the installer must stop and name it.
- When Unraid is detected with no persistent install directory supplied, an
  interactive installer must ask; a non-interactive one must refuse the volatile
  default and print the exact variable form required.
- When the parent of an Unraid install directory does not exist, the installer must
  stop rather than build a misleading chain on the RAM filesystem.
- When the chosen install directory would occupy the `satchel` command path inside a
  `PATH` directory, installation must stop before creating it.
- When an existing `claude` or `codex` path is unrelated — **including a dangling
  symlink** — installation or linking must skip it and continue.
- When an install is already initialized, the installer must ensure the image
  exists; if that build fails, the command must remain installed and the output must
  give one exact retry command.
- When the clone destination is a non-Git empty directory, it must be removed and
  retried cleanly.
- When it is a non-Git directory containing data, that data must be moved under
  timestamped recovery storage, its new location reported, and the clone retried at
  a clean path — never deleted or overwritten.
- When it is a symlink or a non-directory file, initialization must refuse to move,
  follow, or replace it.
- When initialization is re-run with a URL textually different from the existing
  origin, it must stop **before** changing either the clone or the config.
- When an SSH clone fails, initialization must preserve Git's error, explain the
  observed agent/key state, optionally generate and print a key, and allow an
  in-place retry or a choice to continue without sync.
- When a local Sync Repo target is absent, empty, or a non-Git directory,
  interactive setup must offer to initialize a bare repository there.
- When machine registration cannot push, the local clone and machine state must be
  retained and the user directed to fix access and run explicit sync.

### 4.2 Session launch and runtime

- When no working container engine exists, a session must fail clearly; status and
  settings must still report.
- When Satchel is itself containerized and the daemon cannot bind-mount its real
  local state, launch must stop with an unsupported nested-container explanation.
- When the primary path is unsafe, an interactive launch must default to refusal and
  offer Host Mode; a non-interactive launch must fail with an explanation of what
  would have been mounted.
- When an extra mount is unsafe, nonexistent, `/`, home-containing, or overlapping
  private state, launch must fail before starting a container. Symlinks are resolved
  before these decisions.
- When a root host's mounted work paths are not writable by the session UID, launch
  must warn with the affected paths, the exact `chown`, and the alternatives, while
  still allowing the read-only session.
- When a host Git identity appears after an agent config already exists, only the
  missing fields are copied; existing values are never overwritten.
- When startup is interrupted during SSH prompting, pulling, or the update check,
  status 130 must propagate and later launch work must stop.
- When the interactive agent exits non-zero, cleanup and best-effort handoff/sync
  must still run, then the original status is returned.
- When the engine becomes temporarily unhealthy after an interrupted run, cleanup
  must continue with the already-selected engine rather than re-detecting.
- When repeated interrupts arrive during cleanup, handoff generation, or syncing,
  they must be ignored and the work must complete, in a separate process group.
- When a Host Session or root-run operation leaves persistent files owned by root,
  the next lifecycle must normalize only the allowlisted internal paths.
- When the session produced no new transcript, no handoff is attempted and the
  previous one is preserved.

### 4.3 SSH and clipboard

- When forwarding is disabled, launch must stay quiet about missing SSH and forward
  no socket.
- When the socket is absent, not a socket, or has no responding agent, it must not
  be mounted.
- When the agent answers with no identities, the socket must **still** be mounted,
  so keys added on the host mid-session become usable immediately.
- When a reachable agent is empty and a standard host key exists, that key is loaded
  first. Supported names, in preference order: `id_ed25519`, `id_ecdsa`, `id_rsa`.
- When no usable agent exists but a standard key does, a temporary per-session agent
  is started — and it must be started **as the UID the session will run as**, not as
  root with a chowned socket.
- When the temporary agent starts but does not answer as that UID, readiness must
  not be claimed; the agent must be torn down and failure reported.
- When a root-owned shared agent cannot serve an unprivileged session UID, it must be
  set aside deliberately **and the reason stated** — otherwise the fallback message
  contradicts what the user can see.
- When `setpriv` is missing on a root host, the program must say so plainly rather
  than report "no key" for a key that is present.
- When no usable identity can be provided, an interactive launch must explain that
  SSH pushes will fail and wait for acknowledgement; a non-interactive launch warns
  and continues.
- When a passphrase prompt is interrupted, 130 must propagate and no temporary agent
  may be left behind.
- Loading an unencrypted standard key must produce no output at all.
- The temporary agent survives until after the session-end push, then is destroyed.
  The handoff writer never receives its socket.
- When a Wayland socket is valid, it must be preferred over X11 and exposed at the
  fixed absolute path.
- When the compositor variables name no real socket, clipboard forwarding must
  quietly do nothing.

### 4.4 Synchronization

- When the Sync Repo is unconfigured, sessions must still run and say nothing will
  sync.
- When synchronized state is malformed at startup, the session must continue with
  syncing disabled and the reason explained. (Currently violated for one registry —
  §6.2.)
- When the same state is met by explicit sync or status, the command must fail and
  name the invalid contract.
- When a best-effort pull is offline or times out without leaving an operation in
  progress, startup must warn and continue from local state.
- When a best-effort pull is *interrupted*, startup must stop rather than misclassify
  the interrupt as being offline.
- When a pull conflicts, the operation must be aborted, unmerged state removed, the
  local commit and pre-existing tracked edits preserved, a warning issued that
  Satchel did not guess, and the session continued.
- When a rebase started with autostash is aborted, pre-existing edits must be left
  restored; the tree must not be reset merely to look clean, because those edits may
  be the only surviving copy of interrupted work.
- When automatic recovery cannot return the clone to a usable state, syncing must
  degrade for that run.
- When a session-end push or pull fails, the commit must remain on the local branch
  and the user directed to explicit sync.
- When status sees commits ahead of or behind upstream, it must report both counts.
- When synchronized JSON has unknown fields but valid required ones, older versions
  must continue.
- When one tracked origin points at a missing Project, two origins claim one Project
  ID, a path cache points at a missing Project, a Project or machine name is unsafe,
  or obsolete per-Project metadata exists, strict validation must fail rather than
  repair identity.

### 4.5 Projects and handoffs

- When a path is not inside a Git repository, explicit tracking must fail.
- When a repository has no portable origin, candidate prompting must not occur;
  explicit tracking must still work.
- When one origin appears at multiple paths or machines, all must resolve to one
  Project.
- When two unrelated origins share a basename, generated IDs must remain distinct
  (`-2`, `-3`, …).
- When a requested Project ID already belongs to another origin, tracking must fail
  rather than merge identities.
- When an origin changes, the old path cache must be invalidated until the new
  origin gets its own global decision.
- When a repository lies only behind a symlink outside the declared roots, it must
  not be discovered or offered.
- When a candidate is named by the writer in an interactive terminal, Satchel must
  ask whether to track it; when it is not named, it must not prompt.
- When candidate enrollment fails, its work must be reassigned to the machine
  handoff rather than discarded.
- When operation is non-interactive, candidate work becomes machine-handoff content
  while the origin stays undecided.
- When a chunk names an unknown scope, it must be dropped without creating state for
  the invented scope.
- When multiple chunks resolve to one scope at one timestamp, they must be combined
  into one file rather than overwrite one another.
- When the writer returns `NO_HANDOFF` after exiting successfully, the prior handoff
  remains.
- When the writer exits non-zero, times out, or returns incomplete formatting, the
  prior handoff remains and the warning must **distinguish process failure from
  format failure** — a broken container must never read as a rambling model. A
  process failure must include the writer's own last error line.
- When the skip signal cancels the writer, its helper container must be stopped and
  removed only after its ownership label is verified.
- When an unrelated container already owns the predicted helper name, cleanup must
  not delete it.
- When a handoff header is truncated but its filename is valid, it must still
  participate in latest-selection and retention.
- When retention is exceeded, the lexically oldest filenames are removed first.

### 4.6 Machine Baseline

- When neither agent is authenticated, no offer appears.
- When the requested invocation begins with a native version or help flag, the offer
  must not replace that informational request.
- When only one agent is authenticated during an explicit refresh, it is selected and
  the reason stated.
- When both are, the user chooses, defaulting to Claude.
- When the user chooses "not now", the requested session continues.
- When the user chooses "don't ask again", a synchronized suppression marker is
  written and the requested session continues.
- When the user accepts the automatic first-launch offer, success, failure, or
  interruption returns directly to the shell without a second agent launch.
- When the baseline exits cleanly but does not create or change the inventory, it is
  a failure.
- When the inventory lacks the exact version marker, automatic syncing must stop and
  the user be told to review the machine knowledge.
- When newly added content resembles a secret, the suspected value must not be
  printed and automatic syncing must stop.
- When notes exceed the soft limit, content is retained and a consolidation warning
  shown.
- When a peer machine exists but has published no runtime report, diagnostics must
  say comparison data is missing rather than report agreement.

### 4.7 MCP

- When a name contains disallowed characters, add and remove must fail.
- When a URL is empty or contains a quote, backslash, control character, or DEL,
  validation must fail before either agent configuration is touched.
- When a required field is missing or auth is neither `bearer` nor `none`,
  validation fails; unknown fields are ignored.
- When a bearer token is missing, interactive materialization offers synced or local
  storage and allows skipping.
- When local and synced tokens both exist, local wins.
- When Codex's marker pair is malformed, materialization must leave the file
  byte-identical and remove its scratch files.
- When Codex has written learned tool-approval or project-trust tables inside the
  managed area, rematerialization must rescue them and re-emit them **outside** the
  rebuilt block.
- When a probe receives 404, TLS-only success, HTTP-only success for an HTTPS URL, or
  no response, each distinct condition must be reported distinctly.
- When diagnostics find an unreachable endpoint it counts as a hard failure; a merely
  absent token is a warning.

### 4.8 Skills

- When a top-level entry is unsafely named, not a real directory, a symlink, missing
  `SKILL.md`, contains nested Git metadata, or holds a broken or escaping symlink, it
  must be quarantined locally and never synced.
- When it is a top-level file other than a valid lock file, the warning must note it
  may be installer metadata rather than a skill.
- When the invalid entry replaced a committed valid skill or lock file, the committed
  copy must be restored after quarantine.
- When that committed copy is also invalid, it too is quarantined and not synced.
- When the agent's runtime-owned system tree appears, it stays local, absent from
  Sync Repo changes and from user-skill reports.
- When a named skill does not exist or the name is unsafe, removal fails without
  deleting anything else.
- When interactive removal is cancelled or the number invalid, the library is
  unchanged.
- When the pre-removal pull is interrupted, removal must not proceed.
- When lock metadata still mentions a removed skill, removal completes but warns and
  leaves the lock file untouched.
- A named or numbered removal **is** the authorization — no second confirmation — and
  Git history is the recovery path.

### 4.9 Unraid, updates, diagnostics, retirement, uninstall

- When the boot block has no closing marker, update and removal must report it and
  leave the whole file unchanged — never silently repaired.
- When a proposed boot file is empty, has duplicate markers, contains an unresolved
  link target, or fails a syntax check, it must not replace the current one.
- When a valid boot file is replaced, the last syntactically valid version is kept as
  the backup.
- When state lives outside persistent storage on Unraid, diagnostics must emit a hard
  failure, not a warning.
- When the commit API is unavailable during update, it must warn and fall back to the
  branch, noting the content may be minutes stale.
- When update cannot stage beside the installed command, it must leave the running
  script untouched and fail with a writability explanation.
- When the download does not parse, the installed command is unchanged.
- When the script is unchanged, update must still rebuild the image and may backfill
  the commit record.
- When the image build fails after replacement, the commit record must not advance.
- When uninstall cannot prove the running script is an installed command, or the state
  path is not a Satchel state tree, it must refuse.
- When purge would discard uncommitted, unpushed, or no-upstream work, it must warn
  specifically before deletion.
- When a stopped labeled container exists, uninstall may remove it; active, paused, or
  unverifiable ones must be left alone.
- When image deletion fails, the engine's actual error and an engine-appropriate
  inspection command must be printed and the container preserved.
- When interactive retirement of the current machine starts from a dirty clone, it must
  stop before mutation. When its commit or push fails after mutation, it must restore
  the prior local state and stop before removing local files.
- When the current machine is retired directly, the command must explain that local
  state remains and ask separately before deleting it.
- Non-interactive uninstall must never retire a machine.

### 4.10 Reporting

- When no engine is installed, reporting commands must print full output and exit
  successfully.
- When peers exist but none have reported, the drift check must say so rather than
  report agreement from an empty data set.
- When the caravan is a single machine, no drift line is printed at all.

---

## 5. Non-obvious domain knowledge

Each exists because something outside the program behaves in a way that is not
obvious.

**An SSH-agent socket's ownership and mode do not determine which users it serves.**
OpenSSH checks peer credentials and accepts only root or the agent process's own
effective UID. A temporary agent for a UID-1000 session must itself run as UID 1000;
chowning the socket is insufficient. Root-run hosts previously announced an agent
that reset every in-session connection.

**A reachable agent proves nothing about identities.** The common real-world failure
is a forwarded agent that answers but was never given a key, so states must be probed
and distinguished. Exit codes are load-bearing: `0` identities loaded, `1` reachable
but empty, `2` nothing answering.

**A reachable agent also does not mean every Git remote will work.** The session gets
identities but not the host's SSH client config, so aliases, ports, usernames, and
per-host key selection disappear. This distinction exists to stop agents debugging
credentials only the host user can change.

**Private key material must never be copied to a readable path.** Feeding a key to
the agent through a descriptor opened before privileges drop gets it there without it
ever existing anywhere the sandbox could read.

**OpenSSH resolves home through the passwd database, not `$HOME`.** Both root and the
image's normal user need `/home/satchel` as their passwd home, or SSH trust records
land in disposable paths and evaporate every session — defeating trust-on-first-use.
On Unraid, a root Host Session additionally tripped over the host's dangling
`/root/.ssh` symlink inside the container.

**A numeric session UID may have no passwd account name.** Privilege-dropping tools
requiring a login name cannot serve an arbitrary configured UID, which is why a
numeric-ID-aware utility is required.

**Debian's account-management tool refuses to modify the active root account** when
the build shell is root/PID 1 under Docker's legacy builder. The passwd home fields
must therefore be rewritten by direct text edit.

**Rootless Podman invents a passwd record for keep-ID users.** Its home must be
explicitly templated so passwd-aware tools agree with the mounted home.

**Unattended Git cannot answer a first-contact host-key prompt.** Trust-on-first-use
must accept and record an unseen key, or background syncing hangs before
authenticating.

**Git 2.35+ treats a repository owned by another UID as unsafe.** Readability is not
enough; the session must declare its exact mounts trusted. Creating that trust file
also creates the agent's Git config — so keying the identity check off the file's
existence permanently suppressed identity seeding on any machine that later gained a
host Git config, producing "Author identity unknown" on every commit forever. The
check must key off the identity values themselves.

**SELinux relabeling is unsafe for this workload.** It mutates labels on arbitrary
host directories including the user's project, and still cannot cover the agent
socket. Disabling label separation for the session is the supported tradeoff and
leaves the rest of the sandbox intact.

**Wayland accepts an absolute display value**, so the socket can be mounted at a fixed
path without reproducing the host runtime directory inside the container.

**X11 access is strictly broader than Wayland** — any client can observe input — so it
is only a fallback.

**Codex's inner sandbox cannot create its namespaces inside the session container**,
so it is disabled; the outer container is the intended boundary.

**Codex accepts MCP bearer tokens only by environment-variable name**, which is why
only the name reaches the engine's arguments. `-e NAME=value` would expose the secret
through process inspection.

**Codex can persist learned TOML tables immediately before a trailing comment.** If
the managed close marker is that trailing comment, project-trust and per-tool
approval tables land inside the managed area and would be destroyed on rewrite. They
must be rescued, and the block placed before the first table so future tables stay
outside it.

**Codex's non-interactive resume rejects non-Git working directories** unless its
repository check is explicitly skipped — sessions may start in ordinary directories.

**Both agents select which conversation to resume partly by its original working
directory.** The handoff writer therefore needs that exact path to exist even though
it must not see the project; an empty filesystem satisfies the lookup, and one engine
also rejects a nonexistent working directory outright.

**Killing a container-engine client does not guarantee the container stops.** A
timed-out or cancelled helper keeps running and spending tokens, so it needs a
predictable name and a verified ownership label before force cleanup.

**Repeated interrupts outlive the foreground agent.** They strike cleanup in the gaps
after the UI exits, which is why durable cleanup runs in a separate process group that
ignores the interrupt signal while a distinct signal remains the deliberate escape.

**A smaller model that answers correctly standalone can still fail or drift out of a
strict output format when resuming a long transcript.** Pinning one was tried and
removed; the fallback run cost more than it saved. The lever that works is low
reasoning effort on the agent's own default model.

**A Git rebase detaches `HEAD`, making the usual upstream expression unavailable.**
Recovery detection must precede the upstream check, or it is skipped in exactly the
broken state it exists for.

**An empty remote has no upstream branch**, so initial registration must distinguish
a new remote from an offline or damaged one.

**Aborting a rebase started with autostash restores pre-existing tracked edits.**
Cleanup must not reset afterwards merely to get a clean-looking tree, or it destroys
the only copy of those edits.

**Whole-file synchronized registries conflict under ordinary independent edits.** Two
machines adding different entries still collide, which is why conflicts are expected
rather than exceptional and the response is to back out rather than merge.

**Exact-key validation of synced state turns one machine's upgrade into a caravan-wide
outage.** Validating only what is read, and ignoring unknown fields, is a hard
requirement.

**Raw branch URLs on the content host are cached for roughly five minutes.** Resolving
to a commit and downloading by immutable SHA is the only way to be sure.

**Replacing a running Bash script can make Bash resume at an old byte offset inside
new content.** Bash reads incrementally and seeks between top-level commands. Two
consequences: the program's final line must be a single line that invokes its entry
point and exits, so no later offset exists; and replacement must be a same-filesystem
rename, because a cross-device move copies into the existing inode. That is the normal
layout where the temporary directory is a RAM disk and the program lives on array
storage.

**A running shell does not acquire logic from the script that replaces it.** The newly
installed command must perform the image rebuild, or old in-memory behavior builds an
environment inconsistent with the downloaded program.

**Unraid's root filesystem and root home are RAM-backed**, and its boot script starts
the web UI. Replacements must be syntax-checked, staged on flash, installed
atomically, and backed up, because a partial or malformed write can require repairing
the flash drive from another computer.

**Unraid commonly stores container layers in a fixed-size virtual disk.** Rebuilding
floating packages strands roughly gigabytes of old layers, so a superseded untagged
image is reclaimed — but only when no other tag still names it.

**Agent version information lives inside the image**, so asking costs a container
start. Caching it at build time is why every session can publish it for free.

**Filename order is the durable handoff chronology.** A truncated header must not make
a newer file immortal or invisible; the timestamp spelling sorts lexically after
replacing filename-invalid colons.

**Bash treats tab as IFS whitespace.** A record emitted as `<value>\t<path>` with an
empty first field parses as one field, silently shifting values — which caused undated
handoffs to be skipped by ranking, never counted toward retention, and never pruned,
so the directory grew unbounded.

**Negating a command exempts it from errexit.** A negative assertion written that way
can never fail; this invalidated a large number of "must fail" checks at once.

**A loop whose final test is false becomes the function's return status**, and under
pipefail that propagates into an enclosing command substitution. Functions whose
"found nothing" answer is normal must return success explicitly.

**A fatal exit inside a command substitution terminates the substitution before any
fallback outside it can run.** Placing the fallback wrong turns graceful degradation
into a fatal abort — this made a reporting command print one line and exit non-zero on
a host with no container engine.

**Existence tests are false for dangling symlinks**, so treating only existence as
"present" made a redirect follow a missing target and abort.

**Directory-printing find extensions are not portable**, so ownership repair must not
depend on them.

**Rootless Podman can hide ancestor PID values even inside a private PID namespace**,
so namespace privacy cannot be detected by PID count alone; the identity of PID 1 must
be consulted too.

**Skill discovery is an agent-startup behavior.** A skill written mid-session is
durable immediately but may not enter the running agent's index; a fresh session is
the compatibility boundary.

**A diagnostic with no peer reports has not demonstrated agreement.** Missing evidence
must be distinguished from matching evidence, because prior behavior reported "no
drift" from an empty comparison set.

**A read-only host bind does not make special files inert.** A readable socket or
device exposed under the mount may still permit side effects.

---

## 6. Known weaknesses, ambiguities, and open questions

Ordered roughly by severity. Every claim below was verified against the current
behavior.

### Contradicted promises

**6.1 — No-sync behavior is contradictory.** Setup states that handoffs, MCP, and
skills "stay on this machine" when no Sync Repo is configured. In fact sessions mount
no local skill library, MCP management refuses to run, and handoff generation is
skipped entirely. **Open question:** should these work locally, or should the message
say they are unavailable?

**6.2 — MCP startup violates the fail-open guarantee.** A session can detect malformed
synchronized state, announce that syncing is disabled for the run, and then validate
the MCP registry again while writing the agent's configuration — where a malformed
registry is fatal. A bad registry therefore **kills the session after Satchel promised
to continue**. Conversely, a valid registry is still consumed after some *other*
registry caused degradation. The authority of the degraded-state boundary is ambiguous
and this is the one live violation of the project's central invariant.

**6.3 — A whole setting scope is unreachable.** The catalog defines machine-local
versus caravan-wide, and the setter implements both, including a synced layer read on
every run. **No setting is actually declared caravan-wide.** So `--local` is a no-op
for every key, nothing writes the synced layer through a supported path, and both the
help text and README claim caravan-wide behavior that never occurs.

**6.4 — Synchronized settings are executable shell code.** Both the synced and local
settings layers are *sourced* before strict validation of synchronized state. A syntax
error, a Git conflict marker, or a malicious edit in the Sync Repo can stop launch or
execute host commands — directly contradicting "no Sync Repo condition may block a
session."

**6.5 — Two behavior-changing environment variables are undocumented.** Any non-empty
value — including the string `0` — enables a fully privileged Host Session via one, and
suppresses handoffs via the other. Neither appears in help, README, or the settings
catalog. Their support status and truth-value semantics are **open questions**.

**6.6 — A nominally sandboxed session can be configured to run as root.** A zero
session UID is accepted, and is even *recommended in a warning message* as a workaround
for root-owned worktrees — contradicting the claim that normal agents run unprivileged.
**Open question:** is UID 0 a supported safety exception?

**6.7 — Misleading advice when refusing to start in the state directory.** The
interactive refusal suggests re-running with the override flag, which deliberately does
not bypass that particular refusal. The non-interactive path gets this right.

### Verified bugs

**6.8 — Unraid key persistence and restoration disagree.** Persistence selects the
first of the three standard key types found, but the boot block restores only the
Ed25519 pattern. A machine with only an ECDSA or RSA key reports a successful flash
backup that will **not** be restored at boot. Persistence also assumes the matching
public key file already exists.

**6.9 — Non-strict retirement can leave the clone mid-rebase.** That path pulls with
rebase and, on conflict, exits fatally without invoking recovery — contradicting the
project-wide invariant that the clone is never left mid-operation.

**6.10 — The ignored-entry invariant is not enforced.** The documented schema says
ignored entries carry no Project, but validation accepts any ignored entry regardless of
a stale Project field.

**6.11 — "Clear a setting" does not clear it.** Passing an empty value writes an
explicit empty assignment and the source continues to report as local or synced rather
than reverting to the default. **Open question:** is preserving empty overrides the
compatible behavior, or is the documented clearing behavior?

**6.12 — A custom session UID is not honored on a non-root host.** UID switching and
agent probing happen only when the invoking process is root. A non-root user who
configures a different session UID gets an agent reported usable for the *host* UID even
though it may reject the container UID.

**6.13 — Removing a nonexistent MCP server reports success.** A syntactically valid name
is accepted even when nothing was removed, so scripts cannot distinguish deletion from
absence.

**6.14 — `auth: "none"` does not suppress a stale token.** Re-adding a server without
authentication does not remove a previously stored token, and materialization attaches
any token it finds without consulting the current auth mode.

**6.15 — Installation overwrites an unrelated existing command.** Redirect shims have
ownership checks; the main command destination is replaced unconditionally.

**6.16 — Diagnostics have side effects.** They refresh the local cached version file,
contact the update host and every registered endpoint, and do not run every
synchronized-state validator before reporting success.

**6.17 — Engine detection is asymmetric.** Docker must answer a health query to be
selected; mere presence of the Podman command is enough. Installation checks only
command presence for either.

### Security and trust boundaries

**6.18 — The persistent agent home is not a secret-isolation boundary.** A session
receives the agent's entire durable home plus network access — transcripts, OAuth state,
native MCP configuration, and any other credentials stored there — so it can transmit
those materials even though project and host mounts are restricted. Whether this is an
accepted trust assumption is never stated.

**6.19 — Host Git configuration is imported wholesale into a new agent home.** It may
contain absolute host paths, conditional includes, credential helpers, or signing
programs that do not exist or are inappropriate inside the session. The resulting
behavior is undefined.

**6.20 — The baseline's enforced access exceeds its stated boundary.** It can write the
machine's entire synchronized area, not only approved knowledge files, and retains
network access, live clipboard access, persistent agent credentials, and native MCP
configuration. The prompt text is the only control preventing unrelated edits or
disclosure.

**6.21 — Baseline safety decisions are process-local and non-transactional.** A detected
secret or invalid marker blocks syncing only in the current process. The changed files
remain in the worktree, and a later session or explicit sync can commit them **without
repeating the secret scan**. A failed, interrupted, or declined baseline likewise leaves
partial edits in place rather than restoring its starting snapshot.

**6.22 — The baseline secret scan is heuristic.** It scans only newly added lines, so a
pre-existing secret is never caught; it can miss secrets not matching its patterns and
can block harmless long hashes, encoded data, or prose.

**6.23 — Token values remain visible to same-user process inspection.** Keeping values
out of engine arguments closes one channel, but an inherited environment is not a general
secret store.

**6.24 — Codex token variable names can collide.** Server names differing only by case,
or by hyphen versus underscore, map to the same variable — so one server can receive
another's token.

**6.25 — Install and update trust remote content without signature or pinned digest.**
Syntax validation catches corruption that breaks parsing, but authenticates nothing
beyond the transport.

**6.26 — The image is unreproducible.** The base tag and both agent packages float, so
rebuilds at different times change behavior with no source change. Drift is only
reported after another session publishes it.

### Correctness and robustness

**6.27 — Handoff freshness is described two different ways.** The generated instructions
tell the agent to find the latest handoff by the date in its first line, while actual
selection and retention use filenames precisely so truncated headers stay valid. Which is
authoritative must be settled.

**6.28 — Handoff chronology depends on host locale.** Filename ordering is intended as
lexical UTC ordering, but the sorting inherits the process locale. Whether every
supported locale preserves the expected order is not established. Relatedly, latest-file
selection relies on glob expansion order in one place and an explicit sort in another;
today they agree only incidentally.

**6.29 — Handoff filenames can collide.** Two handoffs for the same machine and scope in
the same UTC second overwrite the same path.

**6.30 — Handoff format enforcement is weaker than the prompt.** Only the presence of the
five headings as complete lines is checked — not order, uniqueness, the stated line
limit, or well-formed content per scope. Merging two chunks for one scope therefore
produces a file with the headings twice, which still passes.

**6.31 — A changed transcript is only a proxy for meaningful work.** Generation can be
skipped after useful work that did not update the expected transcript, or attempted after
a change containing nothing worth handing off.

**6.32 — Candidate classification is delegated to model output.** A repository prompts
only if the resumed agent emits the exact delimiter, so substantive work can be missed and
casual work can prompt, depending on model behavior.

**6.33 — The pre-launch writability test is an approximation.** It considers ownership and
basic mode bits at the mount root only — no ACLs, immutable attributes, supplementary
groups, or unwritable descendants — so a warning can be missing or misleading.

**6.34 — Not every network operation is timeout-bounded.** Startup syncing is bounded, but
explicit sync, some initialization and registration work, and non-strict retirement can
wait indefinitely on Git, SSH, DNS, or credential prompts.

**6.35 — Automatic syncing commits every change in the clone.** A session-end sync stages
and publishes unrelated manual edits that happened to be present, not only state the
session generated.

**6.36 — Update has no rollback transaction.** The script is replaced before the image is
built. If the build fails the new script remains active while the recorded commit
deliberately stays old.

**6.37 — Continuing after a failed clone leaves ambiguous configuration.** The run behaves
as unsynchronized, but the URL remains configured, so a later launch sees a configured URL
with no usable clone and follows a different failure path. This is also the source of the
two different definitions of "already initialized" used by the installer and the program.

**6.38 — Uninstall can leave an inaccessible image behind.** Program and state removal can
complete even when image deletion fails, so the command needed to inspect or retry may
already be gone.

**6.39 — Claude MCP materialization replaces the entire native server object.** Entries
added outside Satchel are silently removed at the next session, and malformed Claude JSON
has no tailored preservation path comparable to the Codex marker handling.

**6.40 — Codex configuration preservation is heuristic, not a TOML merge.** It recognizes
table headers textually, can reorder rescued tables, and may not survive future Codex
write patterns.

**6.41 — MCP probing is reachability-only.** It sends no token, performs no protocol
handshake, and treats every non-404 response — including authorization and server errors —
as healthy. An unreachable endpoint is nonetheless a hard diagnostic failure, unlike every
other network condition in the program, which is a warning.

**6.42 — A missing bearer token can abort a non-interactive session.** The interactive path
can ask whether to store or skip, but an unanswered or failed prompt can propagate as a
launch failure instead of simply omitting that server.

**6.43 — Skill validation proves package boundaries, not semantics.** It does not validate
frontmatter, instructions, declared references, executable safety, or the existence of
every file the skill names.

**6.44 — Skill repair is asymmetric.** At session start malformed entries are quarantined
but no previously valid version is restored; at session end restoration does happen. A
skill quarantined at startup therefore disappears from the session about to use it.
**Open question:** deliberate, to avoid touching Git at startup, or an oversight?

**6.45 — The reserved runtime skill area has an unclear trust boundary.** It is
colocated with the shared library and hidden from Git and user reports, but may still be
visible to another agent receiving the library mount.

**6.46 — Runtime drift data is incomplete and can be stale.** The published report contains
source-commit and engine fields that diagnostics never compare, and reports refresh only
after a session — so a machine can appear current after an update until another session
publishes. The commit field is empty for any hand-installed copy.

### Interface and validation gaps

**6.47 — Satchel-owned flag names cannot be passed through to the agent.** There is no
end-of-options escape, so an existing or future agent option named `--host`,
`--unsafe-home`, or `--with` is inaccessible — and would be silently swallowed, not
reported.

**6.48 — Several parsers accept unintended input.** Linking can create an arbitrary command
name that later invokes an unknown Satchel command; some registry, settings,
initialization, and retirement forms ignore extra arguments or unrecognized
optional-position values instead of rejecting them. The authentication override on server
registration is only honored as a third positional argument, and only meaningfully when
the first two were supplied.

**6.49 — Setting values lack semantic validation.** UID and GID need not be numeric,
Boolean settings disable only on exact `0`, and the engine value can name any executable.
Failures surface later and confusingly.

**6.50 — Origin validation is incomplete.** A registry key need only be non-empty and
stable under canonicalization; it need not resemble a network origin. IPv6 authorities,
uppercase `.GIT`, percent-encoding, path normalization, and forge URLs with ports have
ambiguous or inconsistent identities.

**6.51 — Remote migration is unsupported.** Setup requires textual equality with the
existing origin, so equivalent spellings are refused and moving a caravan between remotes
has no defined workflow.

**6.52 — Local/no-origin Project linking rests only on user assertion.** There is no
portable identity proof that two local repositories linked to one Project ID are the same
repository.

**6.53 — Host Session Project visibility uses the path cache without scanning.** Stale
cached paths can appear visible or affect attribution until a normal scoped discovery
refreshes them.

**6.54 — Host Sessions validate extra-mount arguments they then ignore.** An invalid path
blocks launch even though the whole host is already exposed and no additional mount would
be created.

**6.55 — Generated identifiers have no length limit.** Very long origin-derived or
user-supplied identifiers can approach filesystem component limits and break path creation
after passing validation.

**6.56 — Bare-path mounting contradicts the Host Session instructions.** The working
directory is mounted at its real absolute path even in Host Sessions, so a Host Session
launched from a system directory makes that one bare path refer to the real host while the
generated instructions call bare system paths disposable.

### Structural

**6.57 — Machine-knowledge content rules are advisory.** The notes limit is only warned
about, and the distinctions between current fact, history, inventory, and guide are prompt
instructions rather than validated contracts.

**6.58 — The baseline exit status becomes the command's exit status.** A caller cannot
distinguish "the baseline did not complete" from "the session failed", and the two mean
very different things.

**6.59 — Whole-file registry conflicts remain a routine cost.** The current policy
preserves data and avoids guessing but requires manual reconciliation even when machines
changed unrelated logical entries. A one-file-per-entry layout would make adds and removes
structurally conflict-free and is simpler than merging; it was not adopted because it needs
a simultaneous migration across every machine.

**6.60 — Compatibility is intentionally hostile to one older format.** The presence of the
obsolete per-Project metadata file is a hard error with no automatic migration. Version-1
baseline markers get a read fallback; no other historical format does.

**6.61 — The host-only plugin report is informational and incomplete.** Plugins are neither
mounted nor synced, and the report depends on one host directory shape. It is the one item
in the report that describes something no session can use.

**6.62 — There is no release channel besides the default branch.** Updates change all
machines independently, with no stable-version selection, downgrade command, release
manifest, or declared schema version for synchronized state.

---

## 7. Collected open questions

1. Should synchronized capabilities work locally without a Sync Repo, or should the
   messaging say they are unavailable? (§6.1)
2. Where exactly is the fail-open boundary? A malformed MCP registry currently kills a
   session that was already told it would continue. (§6.2)
3. Should caravan-wide settings exist? Today the scope is implemented but unused, and the
   documentation describes behavior that never occurs. (§6.3)
4. Should synchronized settings remain executable shell? (§6.4)
5. Are the two undocumented environment variables supported API, and should they use
   truth-value rather than non-empty semantics? (§6.5)
6. Is a zero session UID a supported safety exception? (§6.6)
7. Is preserving an empty setting override the compatible behavior, or is clearing? (§6.11)
8. Which is authoritative for handoff freshness — the header date the instructions
   describe, or the filename the implementation uses? (§6.27, §6.28)
9. Is the start-of-session versus end-of-session asymmetry in skill repair intentional?
   (§6.44)
10. Should an unreachable MCP endpoint be a hard failure or a warning, given every other
    network condition is a warning? (§6.41)
11. Should the published container-engine field be compared, or dropped? (§6.46)
12. Is exposing the baseline's exit status as the command's exit status intended? (§6.58)
13. Are the Unraid path overrides and the self-path override public API, or test-only
    seams? (§2.3)
14. Is cross-agent visibility of the reserved runtime skill area intended? (§6.45)
