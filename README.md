# Satchel

Run AI coding agents (Claude Code, Codex) in disposable Docker/Podman
containers, with session handoffs, MCP servers, and skills synced between
your machines through a private git repo you own.

One self-contained Bash artifact. No daemon, no database, no cloud — plain
files and plain git. Built for home-lab Linux boxes, Unraid included.
Deliberately not production-grade: simple, readable, boring.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/SwaggyMike/satchel/main/install.sh | bash
```

The installer chains straight into `satchel init`, which names the machine
and connects your private Sync Repo (self-hosted Gitea, private GitHub repo,
a bare repo on any SSH box, or a local bare repo on a shared NFS mount). It
also ensures the shared agent container image is built before reporting that
an initialized installation is ready. If an interrupted older setup left
ordinary files at `.satchel/sync/` without a Git repository, init preserves
them under `.satchel/recovery/` and retries at a clean path; it never deletes
or overwrites the uncertain files. Re-running init with a different Sync Repo
URL stops before changing either the existing clone or machine config; moving
between remotes remains an explicit manual operation. Then, in any directory:

```sh
claude        # Claude Code in a throwaway container, scoped to this directory
```

The container sees only the project directory, runs as a non-root user, and
is deleted when the session ends — and the agent is told exactly that, so it
answers "that file is outside the sandbox" instead of pretending your
machine's files don't exist (in a Host Session it knows the machine lives
at `/host`). Satchel forwards a usable host ssh-agent socket so `git push`
works in-session while key files never enter the container. If no usable
agent exists but a standard host key (`id_ed25519`, `id_ecdsa`, or `id_rsa`)
does, Satchel starts a temporary agent for that session and asks `ssh-add` to
load it; passphrase-protected keys prompt on the host. Otherwise Satchel
explains that SSH pushes will fail and pauses before launch. The
`SATCHEL_SSH` setting turns this off (see ADR 0005). On a graphical host the
compositor socket is forwarded the same way, so pasting an image from the
clipboard works (`SATCHEL_CLIPBOARD` turns it off — see ADR 0007). Log in once (or `satchel import claude` to
copy the host's login); every session after that starts authenticated. After
an agent has authenticated, its next normal launch offers to build a machine
baseline. If accepted, the agent inspects the real host through a read-only
`/host` mount and shows its proposed files for approval. The broad, dated
snapshot goes in `inventory.md`; only concise operational facts go in
`notes.md`; substantial reusable procedures may go in topic guides. It then
returns to the shell; run the agent command again when you are ready for a
normal session. Choosing **Not now** or **Don't ask again** continues directly
into the session you originally requested. The prompt can be deferred or
disabled; `satchel init` offers a later refresh for an already-initialized
machine.

After substantive work in an unknown Git repository with a network `origin`,
Satchel asks once whether to track it as a Project. The decision follows the
normalized, credential-free origin across machines: tracked repos get their
own handoffs; ignored repos do not ask again. Merely opening, listing, or
casually reading a repo does not prompt, and ordinary directories never do.
Work outside tracked Projects—including work in ignored repos—still gets a
machine handoff. Use `satchel track [id]` to explicitly enroll the enclosing
Git repo, including one with a local/NFS or missing origin. Use `satchel
untrack [id]` to ignore it globally and remove its active Project handoffs.

Working across repos that influence each other? `satchel claude --with
../other-repo` mounts the extra directory alongside the project (repeat the
flag for more); home directories, `/`, and Satchel's private state are
refused as extras, same as the primary mount. Paths are resolved before
checking, so a symlink cannot bypass the boundary. You can also just launch
from a parent directory that holds
several repos. Satchel recursively discovers repositories only inside those
explicit mount roots, both before and after the session, so newly cloned repos
and checkouts never opened on that host are classified by origin. Either way,
work is filed by where it happened:
at session end each tracked project you touched gets its own handoff, and
work outside every project goes under the machine. Multi-project sessions
see the list of visible projects and read each one's latest handoff on
demand instead of loading them all up front. Nested work belongs to the nearest
enclosing repo; multiple checkouts with the same origin share one Project.
Each handoff directory keeps the latest ten files; older versions remain
recoverable through Sync Repo history.

The automatic handoff writer resumes the agent conversation with only that
agent's local conversation home mounted. An empty temporary filesystem at the
original project path preserves cwd-based conversation selection without
exposing project contents. It cannot read the project, `/host`, SSH agent,
clipboard, MCP tools, shared skills, or machine state; Satchel itself files
the returned note afterward. Repeated Ctrl-C used to exit the interactive
agent is ignored through session cleanup, handoff generation, and sync; press
Ctrl-\ while the handoff is being written to deliberately skip it.

Each machine has a small, always-loaded `notes.md` for enduring operational
facts and machine-wide risks, a dated `inventory.md` read only when system
detail matters, and optional `guides/*.md` for substantial reusable procedures.
They live under `machines/<name>/` in the Sync Repo and are available inside
sessions at `/home/satchel/machine/`. Notes are current truth, not incident
history: resolved one-time fixes are forgotten, stale entries are removed,
and detailed procedures stay out of the startup context. You can edit any of
these files by hand too.

### Unraid (and other RAM-backed root filesystems)

Unraid rebuilds `/`, `/usr/local/bin`, and `/root` from flash at every boot,
so a default install vanishes on reboot. The installer detects Unraid and
asks for a persistent directory instead (default
`/mnt/user/appdata/satchel`); non-interactively, set it yourself:

```sh
curl -fsSL https://raw.githubusercontent.com/SwaggyMike/satchel/main/install.sh | SATCHEL_BIN=/mnt/user/appdata/satchel bash
```

`SATCHEL_BIN` names the self-contained install directory, not the executable
file. On an ordinary machine omit it; do not use a command path such as
`~/.local/bin/satchel`, because that creates a directory where the shell
expects the `satchel` executable.

Either way that puts the script, the `claude`/`codex` shims, and all state (a sibling
`.satchel/` directory — config, sync clone, agent logins) in that one
directory, and satchel finds its state next to itself.

Two things do live on the RAM disk and need restoring at every boot: the
PATH links in `/usr/local/bin` and the sync SSH key and `known_hosts` in
`/root/.ssh`. `satchel init` offers to append a marked block to
`/boot/config/go` that restores them, and keeps a copy of the key in
`/boot/config/ssh/root/` for that block to use. Accept the prompt and reboots
just work.

Satchel is the only thing that writes that block — `satchel link` and
`satchel unlink` keep it in step, and `satchel uninstall` removes it. To see
exactly what it contains on your machine, look at `/boot/config/go`; this
README deliberately no longer reproduces it, because the copy here drifted out
of step with the real one.

(Only shims the installer actually created are linked — an existing non-satchel
`codex` in `/usr/local/bin` is never clobbered. And the flash drive is
unencrypted FAT — fine for a key scoped to your private sync repo; use your
judgment.) `satchel link` and `satchel unlink` rewrite this block, so a shim
added later survives the next reboot and an unlinked one stays gone. If the
machine already had an SSH key when Satchel was installed, `satchel key
--persist` copies it to flash — only keys Satchel generated itself were backed
up automatically.

Because Unraid runs as root while sandboxed sessions run as uid 1000, a project
whose files are owned by root is readable but not writable inside the session,
and Git refuses to operate on it at all. Satchel declares the mounted
directories trusted for Git and tells you at launch if the agent will not be
able to write, with the exact `chown` to fix it. `satchel doctor` also checks
that your state directory is really on persistent storage and that the boot
block and flash key copy exist.

## Skill Library

Satchel has one Skill Library for both agents and every machine. Inside a
session it is mounted read-write at `/home/satchel/.claude/skills` for Claude
or `/home/satchel/.codex/skills` for Codex. The generated session instructions
identify that path as Satchel-managed. `SATCHEL_SESSION=1` identifies the
runtime, `SATCHEL_SESSION_MODE=host|sandbox` identifies its safety boundary,
and `SATCHEL_SKILLS_DIR` exposes the shared path to installers.

Ask the agent to install a skill and it writes the complete folder there,
including `SKILL.md` and any referenced `references/`, `scripts/`, or `assets/`
files. Satchel validates the result when the session exits. A malformed skill
(missing `SKILL.md`, nested Git metadata, an unsafe name, or an escaping
symlink) is preserved locally under `.satchel/quarantine/skills/` instead of
being synced; an existing valid version is restored. Valid installs, updates,
and removals are listed, committed, and pushed even when there is no handoff;
`satchel sync` retries a failed/offline push.

`satchel skills` lists active user-installed skills. `satchel skills remove`
opens a numbered picker, while `satchel skills remove <name>` removes an exact
skill directly. Removal pulls first and immediately commits and pushes the
deletion caravan-wide. The named command is the authorization—there is no
second confirmation—and Git history remains the recovery path.

Installers may also maintain `skills-lock.json` beside the skill folders so
future updates work across machines. Satchel syncs it when it contains valid
JSON, quarantines malformed copies, and never reports it as a skill. Satchel
does not interpret or rewrite installer-owned lock metadata during removal; it
warns when the file still appears to reference the removed skill.

Codex's bundled `.system` skills are runtime files tied to the installed Codex
version, so they stay local and are ignored by the Sync Repo. Only
user-installed skills sync across the caravan. Start a new session before
relying on a newly installed skill being discovered automatically. `satchel
status` reports any locally quarantined attempts that still need attention.

## Commands

| command | what it does |
| --- | --- |
| `satchel claude` / `satchel codex` | run a session in `$PWD` (the `claude`/`codex` shims do the same) |
| `satchel track [id]` | explicitly track the enclosing Git repo; an existing ID links a local/no-origin checkout |
| `satchel untrack [id]` | globally ignore the enclosing or named Project and remove its active handoffs |
| `satchel --host claude` | Host Session: sandbox off, host `/` at `/host` — for fixing the machine itself |
| `satchel init` | name this machine, connect the Sync Repo |
| `satchel sync` | commit, pull, push the Sync Repo |
| `satchel status [--ignored]` | caravan roster, Project IDs/origins, ignored count or list, handoffs, MCP servers, skills |
| `satchel skills [list]` | list active user-installed skills |
| `satchel skills remove [name]` | remove a skill caravan-wide — numbered picker without a name |
| `satchel key [--persist]` | show this machine's SSH public key (generates one if needed); `--persist` copies an existing key to Unraid flash |
| `satchel retire [machine]` | remove a machine from the caravan — interactive picker without a name |
| `satchel import claude\|codex` | copy the host's agent login into satchel's sessions |
| `satchel mcp add\|list\|remove` | manage the MCP Registry (configured once, wired into every session) |
| `satchel settings` | show every setting and its value; `satchel settings <KEY> <value>` sets it caravan-wide, `--local` for one machine |
| `satchel doctor` | check this machine's setup end to end — including a real bind-mount probe, key, sync, and MCP endpoints |
| `satchel image` | build the shared agent image if it is missing |
| `satchel update` | self-update from `main` (lists the commits it pulls in) and rebuild the agent image |
| `satchel uninstall` | remove Satchel and choose whether to preserve or purge local state |

`satchel uninstall` asks whether to remove only the program or everything
local. Program-only removal deletes the installed command, Satchel-owned
shims, and the container image while keeping the Sync Repo clone, agent
logins, and transcripts for a future reinstall. Everything also permanently
deletes that local state, but never the remote Sync Repo. For automation,
`--yes` keeps local state and `--purge --yes` removes it. Purging loses any
uncommitted or unpushed work in the local Sync Repo clone.

Session and helper containers carry a Satchel ownership label. Uninstall
removes stopped containers bearing that label before removing the image, but
never stops an active session or an unrecognized container. If either blocks
image removal, Satchel preserves it and prints the container engine's actual
error and an inspection command.

During interactive uninstall, Satchel also offers to retire the current
machine when it is registered in the caravan. Retirement removes only that
machine's folder from the upstream Sync Repo; it leaves Projects, shared
state, other machines, and the repository itself untouched. Declining simply
continues uninstall, while a failed retirement stops before local removal.
Non-interactive `--yes` never retires a machine.

On root-run hosts and after Host Sessions, Satchel may need to make its own
agent homes, shared skills, and current-machine state writable by the normal
session UID. This preparation is silent when successful and is restricted to
those exact internal paths; it never changes project files or arbitrary host
paths.

Running Satchel inside another application container is supported only when
its Docker/Podman daemon can bind-mount Satchel's actual local files. Satchel
probes this directly and stops with a clear unsupported nested-container
message instead of continuing into repeated mount errors. Home Assistant
add-ons should generally use their native agent app, or run Satchel on the
underlying Linux host.

## When syncing goes wrong

The Sync Repo is bookkeeping; the session is the point. Nothing that happens to
it can stop an agent from starting.

Two machines changing different entries in the same shared file between syncs
is the ordinary case, so Satchel merges those itself: `repositories.json`,
`mcp.json`, `settings.env`, and `mcp-tokens.env` are union-merged, keeping every
entry from both sides and letting the local machine win a genuine tie. You see
one line saying it happened.

A conflict in something Satchel does not own — a skill, a handoff — is yours to
resolve, but the clone is never left mid-rebase waiting for you. Satchel puts it
back to a clean state, keeps your local commit, says so every session, and
carries on. `satchel doctor` shows what is still unreconciled.

If the synced state is unreadable for any other reason, the session still runs;
only syncing stops for that run, and Satchel says why. Registry files are
validated on the fields Satchel actually reads, so a newer Satchel on one
machine can add a field without breaking the older machines
([ADR 0012](docs/adr/0012-sync-failures-never-block-a-session.md)).

Because each machine builds its own container image from upstream's floating
tags, two machines can legitimately run different agent versions. Each machine
publishes what it has, and `satchel doctor` names the difference instead of
leaving you to discover it as "it works on the other box".

## What syncs, what doesn't

The Sync Repo's root `profile.md` and `preferences.md` are global.
`repositories.json` is the single authority mapping canonical Git origins to
tracked Project IDs or ignored decisions. Bounded timestamped handoffs live
under `projects/<id>/handoffs/`; machine-local checkout paths map only to those
global IDs under `machines/<machine>/projects.json`. Notes, inventory, and
guides are also machine-local. Global skills live under `skills/shared/`.

Handoffs, MCP registry + tokens (private repo, your SSH keys — see
[ADR 0002](docs/adr/0002-mcp-tokens-in-sync-repo.md)), and the shared
skill library ([ADR 0004](docs/adr/0004-one-shared-skill-library.md))
sync. Agent logins and transcripts never do.

Vocabulary lives in [CONTEXT.md](CONTEXT.md); decisions in [docs/adr/](docs/adr/).

## Development

Satchel's maintainable source lives in ordered subsystem modules under `src/`.
The installer still ships the generated, self-contained `satchel` artifact.
After changing a module, rebuild and run the complete verification:

```sh
bash scripts/build.sh
bash tests/run.sh
```

CI rejects source/artifact drift. See
[ADR 0010](docs/adr/0010-modular-source-single-artifact.md) and
[AGENTS.md](AGENTS.md) for the development contract.
