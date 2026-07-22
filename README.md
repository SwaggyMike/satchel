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
or a bare repo on any SSH box). Then, in any directory:

```sh
claude        # Claude Code in a throwaway container, scoped to this directory
```

The container sees only the project directory, runs as a non-root user, and
is deleted when the session ends — and the agent is told exactly that, so it
answers "that file is outside the sandbox" instead of pretending your
machine's files don't exist (in a Host Session it knows the machine lives
at `/host`). The host's ssh-agent is forwarded in as a socket, so `git push`
works in-session while key files never enter the container (the
`SATCHEL_SSH` setting turns it off — see ADR 0005). Log in once (or `satchel import claude` to
copy the host's login); every session after that starts authenticated. After
an agent has authenticated, its next normal launch offers to build baseline
machine notes. If accepted, the agent inspects the real host through a
read-only `/host` mount, shows its proposed notes for approval, writes only
to the machine notes, and then continues into the session you originally
requested. The prompt can be deferred or disabled; `satchel init` offers a
later refresh for an already-initialized machine.

After the first meaningful session in a new directory, Satchel asks once whether
to track it as a project. If accepted, the agent writes a short handoff; the
next session on that project — on any machine — picks it up. Rejected paths
are remembered on that machine and their child directories remain eligible.
Sessions that stay outside any project (a Host Session in /root, say) still
write a handoff, kept per machine and loaded by the next such session there.
Use `satchel track [name]` or `satchel untrack` to change the choice.

Working across repos that influence each other? `satchel claude --with
../other-repo` mounts the extra directory alongside the project (repeat the
flag for more); home directories and / are refused as extras, same as the
primary mount. You can also just launch from a parent directory that holds
several tracked projects. Either way, work is filed by where it happened:
at session end each tracked project you touched gets its own handoff, and
work outside every project goes under the machine. Multi-project sessions
see the list of visible projects and read each one's latest handoff on
demand instead of loading them all up front.

Each machine also has notes (`machines/<name>/notes.md` in the sync repo):
durable facts and procedures for that machine, shown to every session on it
and editable from inside any session at `/home/satchel/machine/notes.md`. Agents record
the right way to do machine-specific tasks as they find it and clean out
entries that go stale; you can edit the file by hand too.

### Unraid (and other RAM-backed root filesystems)

Unraid rebuilds `/`, `/usr/local/bin`, and `/root` from flash at every boot,
so a default install vanishes on reboot. The installer detects Unraid and
asks for a persistent directory instead (default
`/mnt/user/appdata/satchel`); non-interactively, set it yourself:

```sh
curl -fsSL https://raw.githubusercontent.com/SwaggyMike/satchel/main/install.sh | SATCHEL_BIN=/mnt/user/appdata/satchel bash
```

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

## Commands

| command | what it does |
| --- | --- |
| `satchel claude` / `satchel codex` | run a session in `$PWD` (the `claude`/`codex` shims do the same) |
| `satchel track [name]` | explicitly track the current directory as a project |
| `satchel untrack` | stop tracking the current path on this machine; children remain eligible |
| `satchel --host claude` | Host Session: sandbox off, host `/` at `/host` — for fixing the machine itself |
| `satchel init` | name this machine, connect the Sync Repo |
| `satchel sync` | commit, pull, push the Sync Repo |
| `satchel status` | fleet roster, handoffs, MCP servers, skills |
| `satchel key` | show this machine's SSH public key (generates one if needed) |
| `satchel retire [machine]` | remove a machine from the fleet — interactive picker without a name |
| `satchel import claude\|codex` | copy the host's agent login into satchel's sessions |
| `satchel mcp add\|list\|remove` | manage the MCP Registry (configured once, wired into every session) |
| `satchel settings` | show every setting and its value; `satchel settings <KEY> <value>` sets it fleet-wide, `--local` for one machine |
| `satchel doctor` | check this machine's setup end to end — engine, image, key, sync, MCP endpoints |
| `satchel update` | self-update from `main` (lists the commits it pulls in) and rebuild the agent image |

## What syncs, what doesn't

The Sync Repo's root `profile.md` and `preferences.md` are global. Project
identity and timestamped handoffs live under `projects/`; host paths and
tracking decisions live under `machines/<machine>/projects.json`. Global
skills live under `skills/shared/`.

Handoffs, MCP registry + tokens (private repo, your SSH keys — see
[ADR 0002](docs/adr/0002-mcp-tokens-in-sync-repo.md)), and the shared
skill library ([ADR 0004](docs/adr/0004-one-shared-skill-library.md))
sync. Agent logins and transcripts never do.

Vocabulary lives in [CONTEXT.md](CONTEXT.md); decisions in [docs/adr/](docs/adr/).
