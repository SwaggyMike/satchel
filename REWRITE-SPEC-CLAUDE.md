# Satchel — Rewrite Requirements Specification

This document describes the observable behavior, external contracts, and
operating constraints of Satchel as it exists today. It is written for someone
building a replacement from scratch. It records *what* the program does and
*what it must keep doing*, not how the current implementation does it.

Anywhere the current behavior is unclear, contradictory, or looks accidental, it
is flagged as an **Open question** rather than resolved by guessing.

---

## 1. What the program does

### 1.1 Purpose

Satchel is a single-user command-line tool for Linux. It runs AI coding agent
CLIs — Claude Code and Codex — inside disposable containers scoped to one
directory, and carries a small amount of state between the user's machines
through a private Git repository the user owns and hosts themselves.

There is no daemon, no database, and no service. Everything is plain files, Git,
and a container engine. The user's collection of machines is called a *caravan*.

### 1.2 Command surface

Global flags, accepted **before** the command name:

- `--host` — run a Host Session (sandbox deliberately off)
- `--unsafe-home` — permit a sandboxed session in `$HOME` or above
- `--with <dir>` — mount an additional directory into the session (repeatable)

The environment variable `SATCHEL_HOST`, if set to any non-empty value, also
turns on Host Session mode.

Commands:

| Command | Observable behavior |
| --- | --- |
| `satchel claude [args]` | Run Claude Code in a container scoped to `$PWD`; remaining args pass to the agent |
| `satchel codex [args]` | Same for Codex |
| `satchel init` | Interactively name this machine and connect the Sync Repo |
| `satchel sync` | Commit, pull, and push the Sync Repo; report conflicts |
| `satchel status [--ignored]` | Print a report of engine, image, shims, sync state, caravan roster, projects, MCP servers, skills |
| `satchel doctor` | Run end-to-end health checks; exit non-zero if any check fails |
| `satchel track [id]` | Explicitly enroll the enclosing Git repository as a tracked Project |
| `satchel untrack [id]` | Globally ignore a Project and delete its active handoffs |
| `satchel skills [list]` | List user-installed skills |
| `satchel skills remove [name]` | Remove a skill everywhere; interactive numbered picker when no name given |
| `satchel mcp [list\|add\|remove]` | Manage the MCP server registry; bare `add`/`remove` are interactive |
| `satchel settings` | Print all settings, their values, and their source |
| `satchel settings <KEY> <value> [--local]` | Change a setting |
| `satchel key [--persist]` | Print this machine's SSH public keys, generating one if absent |
| `satchel retire [machine]` | Remove a machine's folder from the Sync Repo; interactive picker without a name |
| `satchel import claude\|codex` | Copy the host user's agent login into Satchel's agent home |
| `satchel image [--rebuild]` | Build the shared container image if missing, or force a rebuild |
| `satchel update` | Self-update from the upstream default branch and rebuild the image |
| `satchel link [claude\|codex]` | Create shim commands that redirect `claude`/`codex` through Satchel |
| `satchel unlink [claude\|codex]` | Remove those shims |
| `satchel uninstall [--purge] [--yes]` | Remove the program, shims, and image; optionally purge local state |
| `satchel version` / `--version` | Print the version |
| `satchel help` / `--help` / `-h` | Print usage |

An unrecognized command is a fatal error naming the command and suggesting
`satchel help`.

`--host`, `--unsafe-home`, and `--with` are also accepted **after** the agent
name, so `claude --host` behaves identically to `satchel --host claude`. They are
plucked out of the argument list before the remaining arguments are handed to the
agent CLI.

### 1.3 Shims

Two thin wrapper commands, `claude` and `codex`, may be installed on the user's
`PATH`. Each execs Satchel with the corresponding agent name, so typing `claude`
in a project directory starts a sandboxed session there. Users can install and
remove them at any time.

Satchel recognizes a shim as its own only by exact content, and refuses to
overwrite or delete anything it cannot prove it created.

### 1.4 A session, observably

Running `satchel claude` in a project directory:

1. Refuses outright if the directory is `$HOME`, an ancestor of `$HOME`, `/`, or
   Satchel's own private state directory — offering a Host Session instead when a
   terminal is attached.
2. Validates and normalizes any `--with` directories under the same rules.
3. Selects a container engine, builds the shared image if it does not exist
   (announcing that this takes a few minutes), and verifies the engine can
   actually bind-mount Satchel's local files.
4. Determines whether an SSH agent will be reachable from inside the container,
   loading a standard host key or starting a temporary agent if needed, and
   pausing for acknowledgement if `git push` over SSH will not work.
5. Pulls the Sync Repo (best-effort; never blocking).
6. Validates the synced state; on any problem, disables syncing for this run and
   continues.
7. Repairs the shared skill library, quarantining malformed entries.
8. Prunes handoff directories to their retention bound.
9. Checks at most once per day whether a newer version exists upstream and prints
   a one-line notice if so.
10. Discovers Git repositories inside the mounted roots and maps them to tracked
    Projects.
11. On an agent's first normal launch after it authenticates, offers a one-time
    Machine Baseline inspection. Accepting makes the baseline the entire command
    and returns to the shell; declining continues into the requested session.
12. Seeds a Git identity into the agent home from the host's, without ever
    overwriting an existing value.
13. Materializes the MCP registry into the agent's native configuration format.
14. Writes a generated instruction file into the agent home describing where the
    agent is running, the skill library contract, this machine's notes, global
    context, visible projects, and the previous handoff.
15. Declares the mounted directories trusted for Git and warns, with an exact
    `chown` command, if the session's user will not be able to write them.
16. Runs the agent interactively in the container.
17. After the agent exits: repairs ownership of Satchel's own writable state.
18. If the agent produced new conversation transcripts, re-discovers repositories
    and runs an unattended handoff writer, then files the resulting note(s).
19. Re-validates the skill library, publishes this machine's runtime
    environment, and commits and pushes the Sync Repo.

Nothing in steps 5–8 or 17–19 can prevent step 16 from happening.

### 1.5 Handoffs

After a session in which real work happened, an unattended agent run resumes the
just-finished conversation and is asked to produce a short structured note: goal,
what was done, what is in flight, next steps, gotchas. Satchel — not the agent —
writes that note into the Sync Repo.

The note is injected into the next session's starting context for the same
Project, including on a different machine.

Filing follows a path-attribution rule: one note per tracked Project the session
actually worked in, regardless of how the session was launched. Work outside every
tracked Project is filed under the machine instead.

When a session can see several tracked Projects, or any unknown Git repositories,
the writer is asked for a multi-scope note using explicit delimiters, and Satchel
splits it. Unknown repositories become *candidates*: if the writer reports
substantive work in one, the user is asked once whether to track it. Answering yes
enrolls it caravan-wide; answering no ignores it caravan-wide. Merely opening,
listing, or reading a repository never prompts, and ordinary non-Git directories
never prompt at all.

The writer is deliberately starved: it gets only the agent's own conversation home
and an empty filesystem at the original working directory. It cannot read the
project, the host, the SSH agent, the clipboard, MCP servers, skills, or machine
state.

### 1.6 Machine knowledge

Each machine has three tiers of synced knowledge:

- **Notes** — small, current, topical operational truth. Injected into every
  session's starting context. Soft ceiling of 750 words.
- **Inventory** — a broad, dated system reference. Sessions are told its path and
  generation time, and read it on demand.
- **Guides** — substantial reusable procedures, one current file per topic.
  Sessions are given a list of titles and paths, and read them on demand.

Every session on a machine can write that machine's own knowledge directory, and
can read every other machine's, read-only.

The **Machine Baseline** is an optional first inventory. An authenticated agent
inspects the real host through a read-only mount, shows the user its proposed
files for approval, and writes only into the synced machine directory. It is
offered once per machine, and can be deferred or permanently disabled.

### 1.7 Skills

There is exactly one skill library, shared by both agents and all machines. It is
mounted read-write into every session at the agent's own native skills path, so
installing a skill is nothing more than an agent writing a folder there.

At session exit Satchel validates every top-level entry. Malformed attempts are
moved to a machine-local quarantine and never synced; a previously committed valid
version is restored in their place. Valid installs, updates, and removals are
listed, committed, and pushed even when no handoff was written.

### 1.8 MCP servers

The user registers MCP servers once — name, URL, auth mode — and the registry
syncs. Tokens are stored separately and may be synced or kept machine-local. At
every session start the registry is materialized into whichever native
configuration format the agent uses.

### 1.9 Side effects, summarized

- Creates and writes a private state directory on the host.
- Clones, commits to, and pushes a user-specified Git repository.
- Builds and removes a container image; starts and removes containers.
- Creates, and removes, executable shim files on the user's `PATH`.
- Generates an SSH keypair on request, and may copy it to Unraid flash storage.
- Edits the Unraid boot script, within an explicitly delimited block.
- Makes outbound HTTPS requests to the GitHub API and raw content host, and to
  each registered MCP endpoint during probes.
- Changes ownership of a small, exact allowlist of its own directories.

All narration goes to stderr; report output (status, settings, doctor, help,
skill lists) goes to stdout.

---

## 2. External contracts that must be preserved

This is the section where literal detail matters. Everything below is depended on
by something outside the program: an installed shim, a synced file another machine
will read, an agent CLI, a container image, or a user's boot script.

### 2.1 Installation entry point

```sh
curl -fsSL https://raw.githubusercontent.com/SwaggyMike/satchel/main/install.sh | bash
```

Installer environment variables:

- `SATCHEL_BIN` — a **directory** for a self-contained install (script, shims, and
  a sibling state directory). Not a path to the executable.
- `SATCHEL_DIR` — override the state directory location.
- `SATCHEL_SHIMS` — set to anything other than `y` to skip shim installation.

Installation directory precedence, used identically by the installer and by
`satchel link`:

1. `$SATCHEL_BIN` if set
2. the directory containing the resolved `satchel` executable, if a `.satchel`
   directory sits beside it
3. `/usr/local/bin` if writable
4. `$HOME/.local/bin`

The installer must refuse a `SATCHEL_BIN` whose last path component is `satchel`
when its parent is on `PATH`, because that would make the shell resolve a
directory as the `satchel` command.

The installed script is mode `755`.

### 2.2 Shim file format

A shim is exactly three lines. The absolute path is shell-quoted:

```bash
#!/usr/bin/env bash
# satchel shim
exec /mnt/user/appdata/satchel/satchel claude "$@"
```

Two recognition rules must both be preserved:

- **Generic ownership** (enough to replace or report, not to delete): a line
  matching `^# satchel shim$`, **or** a legacy line matching the extended regular
  expression `^exec[[:space:]]+satchel[[:space:]]+(claude|codex)([[:space:]]|$)`.
- **Exact ownership** (required before deleting): the file contains, as a whole
  line, the literal `exec %q <agent> "$@"` this installation would generate for
  its own resolved path. A lexical sibling spelling is accepted only while it
  resolves to the same installed command — this exists so that a distribution
  aliasing `/home` to `/var/home` does not break uninstall.

### 2.3 State directory

Default `$HOME/.satchel`. A `.satchel` directory beside the resolved script wins
over the default; an explicit `SATCHEL_DIR` wins over both. Created mode `700`.

| Path | Contents |
| --- | --- |
| `config` | Machine-local settings, sourced as Bash |
| `sync/` | The Sync Repo clone |
| `home/claude/`, `home/codex/` | Agent homes, mounted as `/home/satchel` |
| `mcp-tokens.local.env` | Machine-only MCP tokens, mode `600` |
| `script-sha` | Full commit SHA of the installed script |
| `install-path` | Absolute path of the installed command |
| `image-agents` | Cached agent version string from image build time |
| `update-check` | Unix epoch seconds of the last upstream check |
| `quarantine/skills/<UTCSTAMP>--<name>[-N]` | Rejected skill-library entries |
| `recovery/sync-<UTCSTAMP>[-N]/` | Files preserved from an interrupted clone |

Quarantine and recovery stamps use `date -u +%Y%m%dT%H%M%SZ`.

### 2.4 Machine config file

Written by `init`, sourced by every run. Values are shell-quoted.

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

Settings precedence: built-in default < synced `settings.env` < machine `config`.

`settings.env` in the Sync Repo has the same `KEY=value` form with shell-quoted
values. See §6 for a contradiction around its intended scope.

Machine names and Project IDs must both match:

```
^[A-Za-z0-9][A-Za-z0-9._-]*$
```

### 2.5 Sync Repo layout

```
profile.md                              # global; first line skipped on injection
preferences.md                          # global; first line skipped on injection
repositories.json                       # sole authority for repo identity
mcp.json                                # MCP server registry
mcp-tokens.env                          # synced tokens, mode 600
settings.env                            # synced settings layer
.gitignore                              # must contain the line: /skills/shared/.system/
skills/shared/                          # the one shared skill library
skills/shared/.gitkeep
skills/shared/skills-lock.json          # optional, installer-owned, must be valid JSON
projects/<id>/handoffs/                 # per-Project handoffs
projects/<id>/handoffs/.gitkeep
machines/<name>/notes.md
machines/<name>/inventory.md
machines/<name>/guides/<topic>.md
machines/<name>/projects.json           # machine-local checkout path cache
machines/<name>/environment.json        # published runtime versions
machines/<name>/handoffs/               # machine-scope handoffs
machines/<name>/.baseline-skip          # presence disables the baseline offer
```

`projects/<id>/` contains **only** `handoffs/`. The directory name *is* the
Project ID. A `project.json` inside a Project directory is a schema violation and
must be rejected.

Project directories must not be symbolic links.

### 2.6 `repositories.json`

A flat object keyed by credential-free canonical Git origin:

```json
{
  "github.com/example/project": { "status": "tracked", "project": "project" },
  "github.com/example/ignored": { "status": "ignored" }
}
```

Empty file is `{}`.

Validation rules, enforced before use and before syncing:

- top level is an object
- every key is a non-empty string, and is already canonical (re-canonicalizing it
  is a no-op)
- every value is an object
- `status` is exactly `"tracked"` or `"ignored"`; anything else is invalid
- `"tracked"` requires a non-empty string `project`
- `"ignored"` carries no Project
- no two origins may claim the same Project ID
- every tracked Project must have an existing `projects/<id>/` directory
- **unknown keys must be accepted** — a newer version elsewhere in the caravan
  must be able to add a field without breaking older machines

**Canonical origin form.** Both `git@github.com:Example/Repo.git` and
`https://token@github.com/example/repo?x=secret` must normalize to
`github.com/example/repo`. The rules:

- strip a `#fragment` and a `?query`
- strip a trailing `/`
- for `scheme://` URLs: drop the scheme, drop `user[:password]@`, lowercase only
  the host portion of the authority, keep any port, join host and path with `/`
- for `user@host:path` SCP-style: drop `user@`, lowercase the host, join with `/`
- strip a trailing `.git`
- lowercase the **whole** identity only for `github.com/`, `gitlab.com/`, and
  `bitbucket.org/` prefixes; otherwise the path keeps its case

An origin is *portable* only if it looks like `ssh://…`, `git://…`, `http://…`,
`https://…`, or `user@host:path`. Local and missing origins are not portable and
can only be linked by explicitly naming an existing Project ID.

No credential may ever reach this file, a candidate listing, or a handoff.

### 2.7 `machines/<name>/projects.json`

A disposable per-machine cache of absolute checkout paths:

```json
{ "paths": { "/home/user/repos/project": { "project": "project" } } }
```

Empty file is `{"paths":{}}`. Validation: top level is an object; `.paths` is an
object; every key is a string starting with `/`; every value is an object with a
non-empty string `project` pointing at an existing Project directory. Unknown
extra keys are accepted.

### 2.8 `mcp.json`

```json
{
  "servers": {
    "homeassistant": {
      "url": "http://host:8123/api/mcp",
      "auth": "bearer"
    }
  }
}
```

Empty file is `{ "servers": {} }`.

Validation: `servers` is an object; every server name matches
`^[A-Za-z0-9_-]+$`; every value is an object with a non-empty string `url` whose
every code point is `>= 32` and is not `34` (`"`), `92` (`\`), or `127`; `auth`
is exactly `"bearer"` or `"none"`. Unknown keys are accepted.

The character restriction exists so the URL can be embedded verbatim in a TOML
double-quoted string.

### 2.9 Token files

`mcp-tokens.env` (synced) and `mcp-tokens.local.env` (machine-only) are plain
`name=value` lines, one per server, mode `600`. The local file takes precedence
over the synced one.

Removing a server deletes its line from both files, and the user is told that a
previously synced token remains in Git history and should be rotated at the
source if that matters.

### 2.10 `machines/<name>/environment.json`

```json
{"satchel":"2.0.0","commit":"7179842","engine":"docker","agents":"claude 2.1.217, codex 0.145.0"}
```

- `satchel` — required, non-empty string
- `commit` — required string; first 7 hex characters of the recorded install SHA;
  empty when no SHA was ever recorded
- `engine` — required string
- `agents` — required string, exactly the format
  `claude <version>, codex <version>`

If the file exists but is a symlink, or is not a regular file, or fails these
checks, the machine state is invalid. Unknown fields are accepted. The file is
rewritten only when its content actually changes, so ordinary sessions produce no
commit churn.

### 2.11 Handoff files

Project scope:

```
projects/<id>/handoffs/2026-07-25T20-36-15Z--debianlaptop.md
```

Machine scope:

```
machines/<name>/handoffs/2026-07-25T20-36-15Z.md
```

The timestamp is `date -u +%Y-%m-%dT%H:%M:%SZ` with every `:` replaced by `-`.
Filenames are the durable ordering key — both naming schemes sort lexically in
date order, and nothing may depend on parsing a date out of the body.

Line 1 is exactly:

```
<!-- satchel-handoff project=<id-or-hyphen> machine=<machine> date=2026-07-25T20:36:15Z -->
```

`project=-` denotes machine scope. The body follows from line 2 and must contain
all five headings, each on its own line:

```
## Goal
## Done
## In flight
## Next steps
## Gotchas
```

Retention is the newest **100** files per Project directory and per machine
directory; older files are deleted from the working tree and remain recoverable
from Git history.

### 2.12 Multi-scope handoff protocol

The unattended writer is asked to emit delimiters at the start of a line:

```
=== project: <project-id> ===
=== machine ===
=== candidate: candidate-1 ===
```

An internal `=== end ===` terminator is appended before parsing. Chunks are only
filed if they contain all five required headings. Chunks naming a scope not on the
roster are dropped with a warning. Multiple chunks for the same scope are merged
into one file rather than overwriting each other at the same timestamp.

The writer may instead output exactly `NO_HANDOFF` and nothing else, meaning
"nothing worth handing off". This is a valid outcome, accepted only from a writer
that exited successfully.

### 2.13 Machine Baseline marker

Line 1 of the inventory (and, for version-1 machines, of the notes file):

```
<!-- satchel-machine-baseline version=2 generated=2026-07-23T22:12:17Z -->
```

The current baseline version is `2`. A version-1 marker found in the notes file
must still be recognized, so existing machines report as v1 rather than as
never-onboarded.

### 2.14 Generated session instructions

Written into the agent home at `.claude/CLAUDE.md` or `.codex/AGENTS.md`,
rewritten at every session start. First line exactly:

```
# Managed by Satchel — rewritten at every session start; do not edit.
```

Section headings, in order, present when applicable:

```
## Where you are running
## Satchel Skill Library
## Machine Notes (<machine>)
## Global context
## Tracked projects in this session
## Handoff from the previous session on this project (machine <name>, <date>)
## Handoff from the previous session on this machine outside any project (machine <name>, <date>)
```

Behavioral requirements of this text, treated as a public interface:

- Every path it names must be **absolute**. It must never use `~`, because a Host
  Session runs as root and `~` resolves to the wrong place.
- A sandboxed session's text must say the machine's other files are outside the
  sandbox, so the agent answers "that is outside the sandbox" rather than "that
  file does not exist".
- A Host Session's text must say the container's own `/etc`, `/usr`, `/var` are
  disposable and the machine's copies live under `/host`.
- The SSH paragraph must match the probed agent state and must **not** claim
  pushing "works normally" unless an identity is actually loaded.
- When no Sync Repo is usable, the skill-library and machine-notes sections are
  omitted entirely.

### 2.15 Agent-native MCP materialization

**Claude** — `<agent home>/.claude.json`, key `mcpServers` replaced wholesale:

```json
{
  "mcpServers": {
    "homeassistant": {
      "type": "http",
      "url": "http://host:8123/api/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

Servers without a token omit `headers`.

**Codex** — `<agent home>/.codex/config.toml`, only the region between exact
markers is rewritten:

```toml
# >>> satchel mcp >>>
# managed by satchel — rebuilt every session start
[mcp_servers.homeassistant]
url = "http://host:8123/api/mcp"
bearer_token_env_var = "SATCHEL_MCP_TOKEN_HOMEASSISTANT"
# <<< satchel mcp <<<
```

The managed block must be placed **before the first TOML table** in the file, so
that tables Codex writes later stay outside it. Any non-`[mcp_servers.*]` table
found inside the markers must be rescued and re-emitted after the closing marker.

The environment variable name is the server name with lowercase letters uppercased
and `-` replaced by `_`, prefixed `SATCHEL_MCP_TOKEN_`.

### 2.16 Container image

Tag: `localhost/satchel:latest`

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

Nothing is version-pinned; every machine builds its own from floating upstream
tags. Builds pass `--pull`.

Every container Satchel creates carries the ownership label:

```
io.github.swaggymike.satchel.managed=true
```

### 2.17 Container mount and environment contract

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
| each `--with` directory | the same absolute path | rw |
| `/` (Host Session) | `/host` | rw |
| `/` (Machine Baseline) | `/host` | ro |

Environment variables set inside a session:

```
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

MCP token variables must be passed to the engine **by name only** (`-e NAME`),
never as `-e NAME=value`, so token values never appear in the host process list.

Engine flags, sandboxed session:

```
--init --user <uid>:<gid> --cap-drop ALL --security-opt no-new-privileges
```

Engine flags, Host Session:

```
--privileged --pid=host --network=host --user 0:0 -v /:/host
```

No `--init` in Host Session mode (it requires a private PID namespace). **No
`--pid` flag at all** in sandboxed mode — Docker rejects `--pid=private`.

On SELinux hosts, add `--security-opt label=disable`.

On rootless Podman, add:

```
--userns=keep-id --passwd-entry '$USERNAME:*:$UID:$GID::/home/satchel:/bin/bash'
```

The handoff writer container is named `satchel-handoff-<pid>` and additionally
gets:

```
--tmpfs <original-cwd>:rw,nosuid,nodev,noexec,mode=1777
-w <original-cwd>
```

and **nothing else** — no project, no `--with` dirs, no `/host`, no SSH socket,
no skills, no Sync Repo, no clipboard, no MCP tokens.

### 2.18 Agent CLI invocations

These are contracts with third-party CLIs and must be preserved verbatim unless
those CLIs change.

Interactive session:

```
claude <user args>
codex -c 'sandbox_mode="danger-full-access"' -c check_for_update_on_startup=false <user args>
```

Handoff writer:

```
claude --continue --strict-mcp-config --tools "" --effort low -p "<prompt>"
codex exec resume --last --skip-git-repo-check --ignore-user-config --ignore-rules -c 'sandbox_mode="danger-full-access"' -c 'model_reasoning_effort="low"' "<prompt>"
```

Machine Baseline:

```
claude "<prompt>"
codex -c 'sandbox_mode="danger-full-access"' -c check_for_update_on_startup=false "<prompt>"
```

Agent version probe, run inside the image:

```sh
printf "claude %s, codex %s" "$(claude --version 2>/dev/null | cut -d" " -f1)" "$(codex --version 2>/dev/null | cut -d" " -f2)"
```

Login detection:

- Claude is authenticated if `<home>/.claude/.credentials.json` exists, **or**
  `<home>/.claude.json` has a non-empty `.oauthAccount` or `.primaryApiKey`. The
  mere existence of `.claude.json` proves nothing, because MCP materialization
  creates one before any login.
- Codex is authenticated if `<home>/.codex/auth.json` exists.

Transcript directories, watched to decide whether a conversation happened:

```
<agent home>/.claude/projects
<agent home>/.codex/sessions
```

Host login import sources:

```
$HOME/.claude.json            → <agent home>/.claude.json
$HOME/.claude/.credentials.json → <agent home>/.claude/.credentials.json   (mode 600)
$HOME/.codex/auth.json        → <agent home>/.codex/auth.json              (mode 600)
```

### 2.19 Unraid contract

Detection marker: `/etc/unraid-version`
Boot config directory: `/boot/config`
Flash key directory: `/boot/config/ssh/root`
Live link directory: `/usr/local/bin`

All four are overridable — `SATCHEL_UNRAID_MARKER`, `SATCHEL_UNRAID_BOOT_DIR`,
`SATCHEL_UNRAID_LIVE_BIN_DIR` — solely so the behavior is testable off the
platform.

The boot block written into `/boot/config/go`, with every path shell-quoted:

```
# >>> satchel boot persistence >>>
ln -sf /mnt/user/appdata/satchel/satchel /mnt/user/appdata/satchel/claude /mnt/user/appdata/satchel/codex /usr/local/bin/
mkdir -p /root/.ssh && chmod 700 /root/.ssh
cp /boot/config/ssh/root/id_ed25519* /root/.ssh/ 2>/dev/null && chmod 600 /root/.ssh/id_ed25519
cp /boot/config/ssh/root/known_hosts /root/.ssh/ 2>/dev/null
# <<< satchel boot persistence <<<
```

Only shims this installation actually owns are listed on the `ln` line.

Backup file: `/boot/config/go.satchel-bak`. Staging file pattern:
`/boot/config/go.satchel-tmp.XXXXXX`, always in the same directory so the swap is
a rename.

This block content must exist in exactly one place in the program. It was
previously duplicated in the installer and the README, and the copies drifted.

### 2.20 Network endpoints

```
https://api.github.com/repos/SwaggyMike/satchel/contents/satchel?ref=main   → .sha
https://api.github.com/repos/SwaggyMike/satchel/commits/main                → .sha
https://api.github.com/repos/SwaggyMike/satchel/compare/<old>...<new>       → .commits[]
https://raw.githubusercontent.com/SwaggyMike/satchel/<sha-or-main>/satchel
https://raw.githubusercontent.com/SwaggyMike/satchel/main/install.sh
```

Registered MCP URLs are probed with `curl` directly.

### 2.21 Exit codes

| Code | Meaning |
| --- | --- |
| `0` | success |
| `1` | generic failure |
| `2` | bad usage of the build tooling |
| `130` | SIGINT — must propagate out of every long operation |
| `131` | handoff deliberately skipped via SIGQUIT |

`satchel doctor` exits non-zero when any check reported a hard failure,
printing the problem count.

### 2.22 Colour and terminal contract

Precedence: `NO_COLOR` (any value) disables colour unconditionally; `TERM=dumb`
disables it; otherwise `CLICOLOR_FORCE=1` forces it on; otherwise colour is used
only when the relevant file descriptor is a terminal. Stdout and stderr are
evaluated independently.

### 2.23 Version identifier

`SATCHEL_VERSION` is currently `2.0.0`. `satchel version` prints `satchel 2.0.0`.
This value is published in `environment.json` and compared across machines.

---

## 3. Real-world constraints the code reveals

### 3.1 Platform targets

- **Linux only.** Home-lab machines: Debian/Ubuntu, Fedora (SELinux), and Unraid.
- **Bash.** Uses arrays, process substitution, `$'…'` quoting, and named traps.
  Practically this means Bash 4.4 or newer.
- Required host commands: `git`, `jq`, `curl`, `ssh`, `ssh-add`, `ssh-agent`,
  plus `docker` or `podman`. `setpriv` (util-linux) is additionally required on a
  root-run host. `sudo` is used only as a fallback for removals and the boot-script
  swap.
- Sessions require only `git` and `jq` on the host; reporting commands must work
  even with no container engine installed at all.

### 3.2 Permission and privilege model

- A sandboxed session **never runs as root** inside the container. On a root-run
  host the session falls back to uid/gid `1000:1000`, overridable per machine.
- Sandboxed sessions drop all capabilities and set `no-new-privileges`; Host
  Sessions deliberately do neither.
- The container is packaging, not protection, in Host Session mode. This must be
  announced with a warning before launch. Normal sandboxed launches must be
  silent — agent TUIs immediately repaint the screen, so a routine banner only
  flashes.
- Ownership repair is restricted to an **exact allowlist**: the two agent homes,
  the shared skill library, and this machine's synced knowledge directory.
  Success is silent. It must never touch project files or arbitrary host paths,
  and must never be described as doing so.
- A Host Session under rootless Podman maps container root to the unprivileged
  host user, so root-owned host paths still reject writes. That is a property of
  the host, not something the program can work around.

### 3.3 Things that must not happen

- The Sync Repo must never prevent an agent from starting. Every mount, read, and
  push is conditional on a single "syncing is usable" predicate that can be turned
  off for the rest of a run.
- The Sync Repo clone must never be left mid-rebase for the user to untangle.
- Satchel must never resolve a Sync Repo conflict on the user's behalf.
- Agent login credentials and conversation transcripts must never sync.
- Bearer token values must never appear in container-engine arguments.
- SSH private key files must never be copied into a container.
- A sandboxed session must never mount `$HOME`, an ancestor of `$HOME`, `/`, or
  Satchel's own state directory — the last of these not even with the override
  flag.
- Shims, containers, images, and files must never be deleted unless ownership can
  be proven or the user named the exact target.
- A malformed boot script must never be installed on Unraid, and the real file
  must never be truncated in place.
- Malformed or uncertain user data must be quarantined or preserved, never
  silently deleted.

### 3.4 Ordering requirements

- SSH preparation must happen **before** the first Sync Repo network operation.
  Otherwise an empty desktop agent produces a misleading "cannot reach the Sync
  Repo" warning moments before the key is loaded for the session.
- The interrupted-operation check must run **before** the upstream-branch check.
  A rebase detaches `HEAD`, so `@{u}` stops resolving in exactly the state the
  guard exists to catch.
- Argument composition must run **before** the final ownership repair, because
  composition creates missing mount roots.
- The runtime environment must be published **before** the session-end push.
- The interrupt trap must be installed **before** startup work begins, not just
  before the engine runs; startup does real work (pulling, repairing, chowning).
- After the interactive engine exits, interrupts must be **ignored**, not merely
  caught — a caught handler resets to default in child processes, and cleanup
  spawns children.
- A machine registration must integrate remote history before pushing, so an
  ordinary non-fast-forward is not misreported as a read-only deploy key.
- Self-update must replace the file with a same-filesystem rename, and the
  **new** artifact must own the image rebuild.

### 3.5 Timeouts and rate limits

| Operation | Bound |
| --- | --- |
| Session-start Sync Repo pull | 20 s |
| Best-effort commit/pull/push | 30 s each |
| Retirement pull and push | 30 s each |
| Doctor remote reachability probe | 10 s |
| MCP endpoint probe | 5 s |
| Upstream version probe | 5 s |
| Unattended handoff writer | 240 s |
| Upstream version check frequency | at most once per 86 400 s |

The version-check timestamp is written **before** the probe, so an offline day
costs one failed request rather than one per session.

### 3.6 Numeric policy constants

- Handoff retention: **100** files per Project and per machine
- Machine notes soft ceiling: **750** words
- Machine Baseline version: **2**

These are guardrails, not data-loss rules — essential information should be
consolidated or moved to an on-demand guide rather than discarded to satisfy a
count.

### 3.7 Quirks of external systems

- **ssh-agent** authenticates clients by peer credentials, serving a connection
  only when the peer's effective uid is `0` or equals the agent process's own uid.
  Chowning the socket cannot change this.
- **`ssh-add` exit codes** are load-bearing: `0` = identities loaded, `1` = agent
  reachable but empty, `2` (or anything else) = nothing answering.
- **OpenSSH resolves `~` through the passwd database, not `$HOME`.**
- **Git 2.35+** refuses to operate on a repository owned by another user.
- **Docker** rejects `--pid=private`. **Podman** rejects a `-w` directory that
  does not exist.
- **Docker's legacy builder** runs the build shell as root/PID 1, so `usermod`
  refuses to alter the active root account.
- **Rootless Podman** can hide ancestor PID values even inside a private PID
  namespace.
- **SELinux** confined containers cannot read bind-mounted host paths labelled
  `user_home_t`.
- **libwayland** accepts an absolute `WAYLAND_DISPLAY`, so no `XDG_RUNTIME_DIR` is
  needed inside the container.
- **The GitHub raw content host** sits behind roughly a five-minute CDN cache, so
  a branch-name URL can serve a stale script.
- **npm floating tags** mean two machines that both ran an update can legitimately
  hold different agent versions.
- **Unraid** rebuilds `/`, `/usr/local/bin`, and `/root` from flash at every boot,
  and its boot script starts the web UI.

---

## 4. Edge cases and failure modes currently handled

Stated as "when X happens, the program must Y".

### 4.1 Sync Repo

- When the clone is mid-rebase, mid-merge, mid-cherry-pick, mid-revert, or holds
  unmerged entries, the program must abandon that operation and return the tree to
  a clean state, keeping the local commit on the branch.
- When backing out succeeds, it must tell the user a conflict occurred, that
  nothing local was lost, and that reconciliation is theirs to do with ordinary
  Git — then continue.
- When backing out fails, it must disable syncing for the rest of the run and
  continue anyway.
- When a rebase started with autostash is aborted, pre-existing tracked edits must
  be left restored; the program must not reset afterwards merely to make the tree
  look clean, because those edits may be the only surviving copy of interrupted work.
- When the remote is unreachable during a session, it must warn once and continue
  with local state.
- When a push is rejected, it must say the work is committed locally and that
  `satchel sync` will retry.
- When synced state fails validation during a session, it must degrade syncing and
  continue; when the same happens under an explicit repo command, it must fail
  loudly.
- When a synced file carries a field this version does not know, it must be
  accepted.
- When two machines edited the same file, the program must never merge them.
- When the clone destination exists but is not a Git repository and is non-empty,
  it must move those files aside into a timestamped recovery directory and clone
  into a clean path — never deleting or overwriting them.
- When the clone destination is a symbolic link, it must refuse outright and tell
  the user to move it aside.
- When the clone destination exists and is empty, it must remove it silently.
- When `init` is re-run with a URL different from the existing clone's origin, it
  must stop **before** modifying either the config file or the clone.
- When the configured URL points at a local path that is not a Git repository, it
  must offer to create a bare repository there.
- When a clone fails, it must show SSH guidance, offer to generate and print a
  public key, and loop in place offering a retry — never tell the user to start
  over.
- When the Git repository has no committer identity configured, it must give the
  clone a repository-local one naming the machine, without overriding a global one.

### 4.2 SSH

- When `SATCHEL_SSH=0`, no socket is forwarded and the state is reported as off.
- When the socket variable is unset or is not a socket, the state is "none".
- When an agent answers with identities, the socket is forwarded and the session
  is told pushing works.
- When an agent answers with no identities, the socket is **still** forwarded —
  keys the user adds on the host mid-session become usable immediately — and the
  session is told pushing will fail until then.
- When the socket exists but nothing answers, nothing is mounted.
- When the agent is empty and a standard host key exists, that key is loaded
  first.
- When no usable agent exists but a standard key does, a temporary per-session
  agent is started, and it must be started **as the uid the session will run
  as** — not as root with a chowned socket.
- When the temporary agent starts but does not answer as the session's uid, the
  program must not claim readiness; it must tear the agent down and report failure.
- When the host runs as root and a session will not, a root-owned shared agent
  must be set aside deliberately, and the reason must be stated — otherwise the
  fallback message contradicts what the user can see.
- When `setpriv` is missing on a root host, the program must say so plainly rather
  than report "no key" for a key that is present.
- When no agent and no key are available, the program must warn concretely and,
  on a terminal, pause for acknowledgement before launching.
- When the user interrupts a passphrase prompt, `130` must propagate and abort the
  launch, leaving no temporary agent behind.
- Loading an unencrypted standard key must produce no output at all.
- The temporary agent must survive until after the session-end push, then be torn
  down; the handoff writer never receives its socket.

### 4.3 Sessions

- When the working directory is `$HOME`, an ancestor of it, or `/`, and a terminal
  is attached, the program must offer a Host Session, defaulting to **no**.
- When the same happens without a terminal, it must refuse fatally and explain
  what would have been mounted.
- When the working directory is Satchel's own state directory, it must refuse even
  with the override flag.
- When a `--with` path is not a directory, is `/`, is a home directory, or is
  Satchel's state directory, it must refuse — after resolving symlinks, so a link
  cannot bypass the check.
- When the container engine cannot bind-mount Satchel's own files (nested
  containers), it must stop with an explicit unsupported-setup message rather than
  continue into repeated mount errors.
- When project files are not writable by the session's uid on a root-run host, it
  must list the directories and print the exact `chown`, plus the two alternatives.
- When repeated interrupts arrive while cleanup, handoff generation, or syncing is
  running, they must be ignored and the work must complete.
- When cleanup subprocesses are spawned, they must run in a separate process group
  so a terminal interrupt stays with Satchel.
- When the engine CLI has force-exited, the engine choice must already be cached —
  re-probing at cleanup time can fail.
- When the session produced no new transcript files, no handoff is attempted and
  the previous handoff is preserved.

### 4.4 Handoffs

- When the writer exits non-zero, it must say so, include the last line of the
  writer's own error output, and keep the previous handoff.
- When the writer returns prose missing one of the five headings, it must say
  *that* instead — a broken container must never be reported as a rambling model.
- When the writer outputs `NO_HANDOFF` after exiting successfully, it must report
  no work to hand off and keep the previous handoff.
- When the user presses the skip key, the writer's process group must be
  terminated, `131` returned, and the previous handoff kept.
- When the writer is cancelled or times out, the named container must be removed —
  killing the CLI does not stop it, and it keeps spending tokens.
- When a container with the predictable name already exists but does not carry
  Satchel's ownership label, it must not be removed.
- When a multi-scope body names a scope not on the roster, that chunk is dropped
  with a warning.
- When two chunks name the same scope, they must be merged into one file.
- When enrolling a candidate fails, its work must still be preserved under the
  machine scope rather than lost.
- When the session is non-interactive, a candidate repository must be left
  undecided and its work filed under the machine.
- When a handoff file's first line is truncated or lacks a date, it must still
  participate in ordering, count toward retention, and be prunable.

### 4.5 Skills

- When a top-level entry has an unsafe name, is not a real directory, lacks
  `SKILL.md`, contains nested Git metadata, or holds a symlink pointing outside
  itself, it must be moved to the machine-local quarantine and never synced.
- When the quarantined entry has a previously committed valid version, that
  version must be restored.
- When the restored version is also invalid, it must be quarantined too.
- When the offending entry is a top-level file that is not the recognized lock
  file, the warning must note it may be installer metadata rather than a skill.
- When a lock file is present, it must be a real file containing valid JSON; it
  syncs, is never reported as a skill, and is never rewritten during removal.
- When a removed skill is still referenced by the lock file, the program must warn
  and leave the installer-owned file alone.
- When the agent's runtime-owned system skill tree appears, it must be ignored and
  excluded from syncing.
- When a skill removal is requested by exact name, that name **is** the
  authorization — no second confirmation — and the pull must happen first.

### 4.6 MCP

- When a registered server has no token on this machine, the session must prompt
  for it and offer synced or local-only storage.
- When the Codex configuration has malformed or unbalanced managed markers, the
  program must refuse and leave the file byte-identical, cleaning up its own
  temporary files.
- When Codex has written its own tables inside the managed region, they must be
  rescued and re-emitted outside it.
- When probing a URL: a non-`000` response means reachable; `404` means the host
  answers but the path is wrong; success only with certificate verification
  disabled means a self-signed certificate; an `https` URL that answers on plain
  `http` means the wrong scheme was registered.

### 4.7 Installation, update, uninstall

- When the download does not parse as a shell script, it must not be installed.
- When the directory containing the installed command is not writable, the update
  must refuse rather than stage elsewhere.
- When the update leaves the file unchanged, the recorded commit must still be
  backfilled.
- When the image rebuild after an update fails, the recorded commit must **not**
  be advanced.
- When the upstream API cannot resolve a commit, the update falls back to the
  branch name and warns that it may be minutes stale.
- When a shim path exists and is not recognizably Satchel's, it must be skipped
  with an explanation, never overwritten.
- When a shim is recognizably Satchel's but belongs to a different installation,
  it must be left in place with a warning.
- When uninstall is asked to remove something that is not an installed command, it
  must refuse rather than delete a checkout or arbitrary script.
- When purge is requested and the clone has uncommitted or unpushed work, that
  must be warned about specifically before confirming.
- When a container blocks image removal, the engine's actual error and an
  inspection command must be printed, and the container preserved.
- When a container carrying Satchel's label is stopped, it may be removed; when it
  is running, paused, or in an unverifiable state, it must be left alone.
- When retirement fails during an interactive uninstall, the uninstall must stop
  before removing anything.
- Non-interactive uninstall must never retire a machine.

### 4.8 Unraid

- When the boot script's Satchel block has no closing marker, it must be left
  byte-untouched with a warning — never silently repaired.
- When staged replacement content fails a syntax check, or contains a link line
  with an empty target, it must be refused and the existing file left alone.
- When the installed command's path cannot be resolved, no block is written.
- When the state directory is not under persistent storage, that is a hard failure
  in health checks, not a warning.
- When a machine already had an SSH key before Satchel was installed, only an
  explicit request copies it to flash.
- When the installer runs non-interactively on Unraid without a persistent
  directory specified, it must refuse with the exact variable to set.

### 4.9 Reporting

- When no container engine is installed, reporting commands must still print their
  full output and exit `0`; only a session may fail for that reason.
- When peer machines exist but none have published their runtime environment, the
  drift check must say so — it must **not** report agreement from an empty data
  set.
- When the caravan has only this machine, no drift line is printed at all.

---

## 5. Non-obvious domain knowledge encoded in the code

Each of these exists because something outside the program behaves in a way that
is not documented, not obvious, or actively surprising.

**ssh-agent peer-credential authentication.** An agent serves a connection only
when the peer's effective uid is `0` or matches the agent's own uid; otherwise it
closes the socket. A root-started agent is therefore unreachable from a
uid-1000 session no matter how the socket is owned. This is why the agent process
itself must be started as the session's uid, why every probe must be performed as
that uid, and why judging reachability as root once caused a dead-on-arrival socket
to be announced to sessions as working.

**A reachable socket proves nothing.** The common real-world failure is a
forwarded agent that answers but was never given a key — so states must be probed
and distinguished, not assumed.

**Private key material must never be copied to a readable path.** Feeding a key to
the agent through a file descriptor opened before privileges are dropped is how the
key reaches the agent without ever existing somewhere the sandbox could read.

**OpenSSH resolves `~` through the passwd database, not `$HOME`.** Without
rewriting the image's passwd entries, SSH state — notably `known_hosts` — lands in
ephemeral container paths and evaporates every session, defeating
trust-on-first-use. On Unraid it additionally tripped over the host's `/root/.ssh`
symlink dangling inside the container.

**`usermod` refuses to alter an account currently in use.** Docker's legacy builder
runs the build shell as root/PID 1, so the passwd home fields must be rewritten by
direct text edit.

**Bash seeks back into a script file between top-level commands.** Replacing a
running script with a longer one makes Bash resume at the old byte offset inside
the new file and execute a fragment of it. Two consequences: the program's final
line must be a single line that both invokes its entry point and exits, so no later
offset exists; and a self-update must be a same-filesystem rename, because a
cross-device move copies into the existing inode. This is the normal layout on
Unraid, where the temporary directory is a RAM disk and the program lives on the
array.

**The GitHub raw content host caches by branch name for roughly five minutes.**
Resolving the branch to a commit first and downloading by SHA is the only way to be
sure of getting the current file.

**Docker rejects `--pid=private`; Podman rejects a nonexistent `-w`.** The first is
why sandboxed sessions pass no PID flag at all rather than an explicit private one.
The second is why the handoff writer mounts an empty temporary filesystem at the
original working directory.

**Both agent CLIs select which conversation to resume partly by its original
working directory.** That is the entire reason the handoff writer needs that path
to exist — an empty filesystem satisfies the lookup without exposing any project
content.

**`codex exec` hard-fails outside a Git repository** unless told to skip the check;
interactive Codex remembers trust, but the non-interactive mode does not.

**Codex does not accept MCP bearer tokens inline.** Its configuration names an
environment variable instead, which is why the session must pass a token through
the environment — and why passing it as `-e NAME=value` would leak it into the host
process list, so only `-e NAME` is used with the value exported in Satchel's own
process. Each Satchel process owns its own variables, so concurrent sessions cannot
overwrite one another.

**Codex writes learned project-trust and per-tool approval tables immediately
before a trailing comment.** If the managed MCP block ends the file, those tables
land inside it and would be destroyed on the next rewrite. The managed block is
therefore placed before the first table, and anything non-MCP found inside the
markers is rescued out.

**A Git rebase detaches `HEAD`, so `@{u}` stops resolving.** Checking for an
upstream before checking for an interrupted operation skipped the recovery guard in
precisely the state it existed to catch, and produced a machine on which the agent
would not start until a human hand-resolved a rebase.

**Satchel's registries are rewritten wholesale by whichever machine touches them.**
Two machines changing *different* entries between syncs is the ordinary case, and
Git sees adjacent edits to the same region as a conflict. This is why conflicts are
expected rather than exceptional, and why the response is to back out rather than
to merge.

**Exact-key validation of synced state turns one machine's upgrade into a
caravan-wide outage.** Validating only the fields actually read, and ignoring
unknown ones, is a hard requirement rather than a nicety.

**Git 2.35 and later refuse to operate on a repository owned by another user.** On
a root-run host this makes every Git command inside a session fail with "detected
dubious ownership", which reads like the agent malfunctioning. Declaring the
mounted roots trusted costs nothing where the uid already matches.

**Creating that trust file also creates the agent's Git config file.** Keying the
identity check off the file's existence therefore permanently suppressed identity
seeding on any machine that gained a host Git config after its first session —
producing "Author identity unknown" on every commit forever. The check must key off
the identity values themselves.

**Relabelling bind mounts with SELinux `:z`/`:Z` is wrong here.** It rewrites
labels on arbitrary host directories — including the user's project — and cannot
cover the SSH agent socket. Disabling label separation for the session is the
documented way to mount host paths, and leaves the rest of the sandbox intact.

**X11 access is strictly wider than Wayland** — any X client can observe input — so
Wayland is preferred whenever a socket exists. On compositors without portal
gating, the forwarded socket can expose more than the clipboard.

**Bash treats tab as IFS *whitespace*.** A record emitted as `<value>\t<path>` with
an empty first field parses as a single field, silently shifting the values. This
caused undated handoffs to be skipped by ranking, never counted toward retention,
and never pruned — so the directory grew without bound.

**`!` exempts a command from `set -e`.** A negative assertion written that way can
never fail. This invalidated a large number of "must fail" checks at once.

**A loop whose last test is false becomes the function's return status**, and under
`pipefail` that propagates into an enclosing command substitution and takes `set -e`
with it. Functions whose "found nothing" answer is normal must return success
explicitly.

**`die`-style exits inside a command substitution terminate the substitution before
any `|| true` outside it can run.** Placing the fallback in the wrong position turns
a graceful degradation into a fatal abort — this made a reporting command print one
line and exit non-zero on a host with no container engine.

**`-e` is false for a dangling symlink.** Treating only `-e` as "exists" made a
redirect follow a missing target and abort.

**`find -printf` is not portable.** Ownership repair must not depend on it.

**Rootless Podman can hide ancestor PID values even inside a private PID
namespace**, so namespace privacy cannot be detected by PID count alone; the
identity of PID 1 must be consulted as well.

**Unraid's boot script starts the web UI.** A half-written or malformed one costs
the user a trip to the flash drive with another computer, which is why replacement
is a rename of a file staged in the same directory, the last version that parsed is
kept beside it, and content that fails a syntax check is refused rather than
installed. The flash drive is unencrypted FAT and is the single point of failure for
the entire array configuration.

**Unraid keeps container images in a fixed-size virtual disk.** Pulling on every
rebuild with two global npm packages otherwise strands roughly two gigabytes of
dangling layers per rebuild, so the superseded image is reclaimed — but only when it
carries no remaining tags.

**Agent version information lives inside the image**, so asking for it costs a
container start. Caching it at build time is why every session can publish it for
free.

**Agent-native skill discovery happens at startup.** An installation is durable
immediately, but a new session is the boundary at which a skill can be assumed
discoverable.

**Pinning a smaller model for the handoff writer was tried and removed.** A model
that answers correctly on its own can still fail or drift out of the required format
when resuming a long session transcript, and the fallback run cost more wall-clock
time than the smaller model saved. The lever that works is low reasoning effort on
whichever model the agent already defaults to.

**Automatic union-merging of the synced registries was implemented and then
removed.** It worked, but solved a conflict the user was not actually hitting, at
the cost of the single largest complexity addition in that change.

**A distribution that aliases `/home` to `/var/home`** makes lexical and resolved
paths differ, which is why shim ownership accepts a sibling spelling only while it
resolves to the same installed command.

**A version-drift check that collapses "no peers reported yet" into "peers agree"
reports a reassuring green result from an empty data set** — the exact failure mode
a drift check exists to prevent.

---

## 6. Known weaknesses

### 6.1 A whole setting scope is unreachable

The settings catalog defines a two-valued scope — machine-local versus
caravan-wide — and the setter has a complete branch for the caravan-wide case,
including a synced settings layer that is read on every run. **No setting is
actually declared caravan-wide.** Every entry is machine scope.

Consequences: the `--local` flag is a no-op for every setting that exists; the
synced settings file is read but nothing ever writes it through the supported
path; and the help text and README both state that `satchel settings <KEY>
<value>` "sets it caravan-wide", which is currently false for every key.

This is either a half-built feature or a feature whose last user was removed
without cleaning up. **Open question:** should caravan-wide settings exist at all,
and if so which ones?

### 6.2 Misleading advice when refusing to start in the state directory

When a session is refused because the working directory is Satchel's private state
directory, the interactive path still suggests re-running with the override flag.
That flag deliberately does **not** bypass the state-directory refusal, so the
advice cannot work. The non-interactive path gets this right and prints a distinct
message.

### 6.3 Inconsistent privilege handling in one SSH branch

The rewrite that made the temporary agent start as the session's uid did not extend
to the branch that loads a key into an already-running empty agent — that path still
runs the key-loading command as the current user. In practice the root case is
rewritten to a different state before reaching this branch, so it is currently
unreachable as root. **Open question:** is that reachability an intentional
invariant or an accident that a future change could silently break?

### 6.4 Feeding a passphrase-protected key through a descriptor

Keys are handed to the temporary agent through standard input so no copy touches
disk. The documented behavior is that passphrase-protected keys prompt on the host.
**Open question:** does the prompt actually reach the terminal reliably when the key
arrives on standard input rather than as a file path? The code comments assert the
security property but not this interaction.

### 6.5 The unattributable handoff scope

When a candidate repository cannot be resolved to either a Project or the machine,
the parser emits a scope marker that is, by construction, not on the valid roster —
so the very next step drops that chunk with an "unknown scope" warning. The work in
it is lost. **Open question:** is this an intended "cannot happen" branch, or a path
that silently discards a real note?

### 6.6 Reliance on dynamic scoping across function boundaries

The candidate-resolution step reads arrays that are local variables of its caller,
relying on Bash's dynamic scoping. This works but is invisible at the call site and
is fragile against any reorganization.

### 6.7 Ordering by glob rather than explicit sort

Selecting the newest handoff relies on shell glob expansion order rather than an
explicit sort, while pruning does sort explicitly. Glob order is locale-influenced.
The two must agree; today they agree only incidentally.

### 6.8 Endpoint probes make health checks fail

An unreachable registered MCP endpoint is reported as a hard failure, which makes
the health check exit non-zero. For a home-lab server that is simply switched off,
this is arguably a warning rather than a failure. Every other "the network is
unavailable" condition in the program is a warning.

### 6.9 Probe verdict is coarse

Any HTTP status other than `000` and `404` is reported as "reachable", including
`500`. A server that is up but broken reads as healthy.

### 6.10 Published environment field never compared

The runtime environment file publishes the container engine per machine, and the
schema validates it, but the drift check compares only the program version and the
agent version string. The engine field is written and read but never used.

### 6.11 Recorded commit is optional in practice

The published commit identifier is derived from a recorded install SHA, which only
exists when the program was installed through the installer from a clean checkout
or downloaded by SHA. A hand-installed copy publishes an empty commit and its
update log starts only at the next update. This is documented in a message but is a
silent hole in cross-machine comparison.

### 6.12 Asymmetric skill repair

At session start, malformed skill entries are quarantined but no previously valid
version is restored; at session end, restoration does happen. A skill quarantined at
startup therefore disappears from the session that was about to use it. **Open
question:** is the asymmetry deliberate (avoid touching Git at startup) or an
oversight?

### 6.13 Undocumented environment variable

A variable that suppresses handoff generation is honored at runtime but appears in
no help text, README, or settings catalog.

### 6.14 Host-only information in a caravan report

The status report lists agent plugins found in the **host user's** home directory.
Sessions never see that directory, so the list describes something no session can
use. It is labelled as host-only, but it is the one item in the report that is not
about Satchel's own state.

### 6.15 Baseline failure indistinguishable from session failure

When an accepted Machine Baseline fails, its status becomes the exit status of the
whole command. A caller cannot distinguish "the baseline did not complete" from
"the session failed", and the two have very different meanings.

### 6.16 Writability check ignores supplementary groups and ACLs

The pre-launch writability warning considers only owner, primary group, and other
permission bits. A directory writable through a supplementary group or a POSIX ACL
is reported as unwritable.

### 6.17 Non-enforced instructions to the writer

The handoff prompt asks for notes "under 30 lines". Nothing checks this. Only the
five required headings are enforced.

### 6.18 Duplicate-heading merge

When two chunks name the same scope, they are concatenated. The result contains the
five headings twice, which still passes the completeness check and produces a
structurally odd file.

### 6.19 Positional flag handling in server registration

The interactive server-registration path accepts an authentication override only as
a third positional argument, and only meaningfully when the first two were supplied.
Supplying it in any other combination silently does nothing.

### 6.20 Ambiguity between Satchel flags and agent flags

Satchel's own flags are recognized after the agent name on the reasoning that
neither agent CLI has flags by those names. That is a statement about third-party
software at a point in time, and it will silently break — with no error, just a
swallowed argument — if either CLI ever adds a matching flag.

### 6.21 Two definitions of "already initialized"

The installer treats an install as initialized when a config file exists and either
no sync URL is configured or a clone exists. The program's own predicate is stricter.
A machine configured with a URL but no clone is "not initialized" to the installer
and "sync not ready" to the program, and these produce different remediation
messages.

---

## 7. Collected open questions

1. Should caravan-wide settings exist? Today the scope is implemented but unused,
   and the documentation describes behavior that does not occur. (§6.1)
2. Is the unreachability of the root case in the empty-agent key-loading branch an
   invariant or an accident? (§6.3)
3. Does a passphrase prompt reach the terminal reliably when the key is supplied on
   standard input? (§6.4)
4. Is the "unknown scope" handoff branch unreachable by construction, or can it
   silently discard a note? (§6.5)
5. Is the start-of-session versus end-of-session asymmetry in skill repair
   intentional? (§6.12)
6. Should an unreachable MCP endpoint be a health-check failure or a warning, given
   that every other network condition is a warning? (§6.8)
7. Should the published container-engine field be compared, or dropped? (§6.10)
8. Is exposing the baseline's exit status as the command's exit status intended?
   (§6.15)
9. Handoff ordering depends on glob order in one place and an explicit sort in
   another. Which is authoritative? (§6.7)
