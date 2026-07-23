# Satchel

Run AI coding agents (Claude Code, Codex) in disposable Docker/Podman
containers, with session handoffs, MCP servers, and skills synced between
your machines through a private git repo you own.

One bash script. No daemon, no database, no cloud — plain files and plain
git. Built for home-lab Linux boxes, Unraid included. Deliberately not
production-grade: simple, readable, boring.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/SwaggyMike/satchel/main/install.sh | bash
```

The installer chains straight into `satchel init`, which names the machine
and connects your private Sync Repo (self-hosted Gitea, private GitHub repo,
a bare repo on any SSH box, or a local bare repo on a shared NFS mount). Then,
in any directory:

```sh
claude        # Claude Code in a throwaway container, scoped to this directory
```

The container sees only the project directory, runs as a non-root user, and
is deleted when the session ends — and the agent is told exactly that, so it
answers "that file is outside the sandbox" instead of pretending your
machine's files don't exist (in a Host Session it knows the machine lives
at `/host`). The host's ssh-agent is forwarded in as a socket, so `git push`
works in-session while key files never enter the container (the
`SATCHEL_SSH` setting turns it off — see ADR 0005). On a graphical host the
compositor socket is forwarded the same way, so pasting an image from the
clipboard works (`SATCHEL_CLIPBOARD` turns it off — see ADR 0007). Log in once (or `satchel import claude` to
copy the host's login); every session after that starts authenticated. After
an agent has authenticated, its next normal launch offers to build a machine
baseline. If accepted, the agent inspects the real host through a read-only
`/host` mount and shows its proposed files for approval. The broad, dated
snapshot goes in `inventory.md`; only concise operational facts go in
`notes.md`; substantial reusable procedures may go in topic guides. It then
continues into the session you originally requested. The prompt can be
deferred or disabled; `satchel init` offers a later refresh for an
already-initialized machine.

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
flag for more); home directories and / are refused as extras, same as the
primary mount. You can also just launch from a parent directory that holds
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
PATH links in `/usr/local/bin` and the sync SSH key in `/root/.ssh`. The
installer offers to append a marked block to `/boot/config/go` that restores
both, and `init` keeps a copy of the key it generates in
`/boot/config/ssh/root/` for that block to restore. Accept the prompt and
reboots just work. If you'd rather manage `go` yourself, the block it would
have added is:

```sh
# >>> satchel boot persistence >>>
ln -sf /mnt/user/appdata/satchel/satchel /mnt/user/appdata/satchel/claude /usr/local/bin/
mkdir -p /root/.ssh && chmod 700 /root/.ssh
cp /boot/config/ssh/root/id_ed25519* /root/.ssh/ 2>/dev/null && chmod 600 /root/.ssh/id_ed25519
# <<< satchel boot persistence <<<
```

(Only shims the installer actually created are linked — an existing non-satchel
`codex` in `/usr/local/bin` is never clobbered. And the flash drive is
unencrypted FAT — fine for a key scoped to your private sync repo; use your
judgment.)

## Skill Library

Satchel has one Skill Library for both agents and every machine. Inside a
session it is mounted read-write at `/home/satchel/.claude/skills` for Claude
or `/home/satchel/.codex/skills` for Codex. The generated session instructions
identify that path as Satchel-managed, and `SATCHEL_SKILLS_DIR` exposes it to
installers.

Ask the agent to install a skill and it writes the complete folder there,
including `SKILL.md` and any referenced `references/`, `scripts/`, or `assets/`
files. Satchel validates the result when the session exits. A malformed skill
(missing `SKILL.md`, nested Git metadata, an unsafe name, or an escaping
symlink) is preserved locally under `.satchel/quarantine/skills/` instead of
being synced; an existing valid version is restored. Valid installs, updates,
and removals are listed, committed, and pushed even when there is no handoff;
`satchel sync` retries a failed/offline push.

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
| `satchel key` | show this machine's SSH public key (generates one if needed) |
| `satchel retire [machine]` | remove a machine from the caravan — interactive picker without a name |
| `satchel import claude\|codex` | copy the host's agent login into satchel's sessions |
| `satchel mcp add\|list\|remove` | manage the MCP Registry (configured once, wired into every session) |
| `satchel settings` | show every setting and its value; `satchel settings <KEY> <value>` sets it caravan-wide, `--local` for one machine |
| `satchel doctor` | check this machine's setup end to end — engine, image, key, sync, MCP endpoints |
| `satchel update` | self-update from `main` (lists the commits it pulls in) and rebuild the agent image |
| `satchel uninstall` | remove Satchel and its shims while preserving local state; `--purge` also deletes local state |

`satchel uninstall` asks for confirmation, removes the installed command,
Satchel-owned shims, and the Satchel container image, while keeping the local
Sync Repo clone, agent logins, and transcripts so a reinstall can resume where
it left off. `satchel uninstall --purge` explicitly deletes that local state
too (not the remote Sync Repo); `--yes` makes either form non-interactive.

## What syncs, what doesn't

The Sync Repo's root `profile.md`, `preferences.md`, and `repositories.json`
are global. Project identity and bounded timestamped handoffs live under
`projects/`; checkout paths, notes, inventory, and guides live under
`machines/<machine>/`. Global skills live under `skills/shared/`.

Handoffs, MCP registry + tokens (private repo, your SSH keys — see
[ADR 0002](docs/adr/0002-mcp-tokens-in-sync-repo.md)), and the shared
skill library ([ADR 0004](docs/adr/0004-one-shared-skill-library.md))
sync. Agent logins and transcripts never do.

Vocabulary lives in [CONTEXT.md](CONTEXT.md); decisions in [docs/adr/](docs/adr/).
