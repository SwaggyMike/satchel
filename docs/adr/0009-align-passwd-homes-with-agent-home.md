# ADR 0009: Align container passwd homes with the agent home

The image rewrites the passwd homes of `node` and `root` to `/home/satchel`,
and rootless-podman sessions template keep-id's invented passwd entry the
same way. Sessions additionally mount `sync/machines` read-only at
`/home/satchel/machines` so any session can read sibling machines' notes.

## Context

Sessions set `HOME=/home/satchel` and mount the persistent agent home there,
but OpenSSH resolves `~` through `getpwuid()`, not `$HOME`. The image's
passwd said `/home/node` (UID 1000) and `/root` (root Host Sessions), so ssh
kept its state in ephemeral container paths: known_hosts written there
evaporated with the container, defeating ADR 0005's trust-on-first-use
record, and on Unraid a root Host Session tripped over the host's
`/root/.ssh` symlink dangling inside the container. Every machine in the
caravan hit some form of this; Apollo carried a guide of explicit
`-o`/`-i` workarounds.

Separately, sessions could read their own machine's knowledge and every
project's handoffs, but not sibling machines' notes — even when a pending
task on this machine was documented on another ("the fix is in apollo's
notes"). The only reader of a machine's notes was that machine itself.

## Decision

- `build_image` rewrites only the home field of the `node` and `root` records
  in `/etc/passwd`: every tool that consults passwd (ssh foremost) now agrees
  with `$HOME` about where home is. A direct field rewrite is required because
  Docker's legacy builder runs the build shell as root/PID 1, and Debian's
  `usermod` refuses to alter an account currently in use. This covers the whole
  caravan — sandboxed sessions run as UID 1000, root Host Sessions as UID 0.
- Rootless podman launches add
  `--passwd-entry '$USERNAME:*:$UID:$GID::/home/satchel:/bin/bash'` beside
  `--userns=keep-id`, so a custom `SATCHEL_UID` absent from the image's
  passwd gets the same home. Docker with a custom UID keeps today's
  behavior (no passwd entry at all); accepted — no caravan machine does that.
- Host key files are still never copied into a session. Authentication stays
  behind a forwarded agent socket; ADR 0005 permits Satchel's host process to
  load a standard key into a temporary per-session agent. This passwd fix is
  about ssh's *state directory*, not exposing credentials.
- `compose_run_args` mounts `$SYNC_DIR/machines` read-only at
  `/home/satchel/machines`, and the preamble points to it. Writes still go
  only through the machine's own rw `/home/satchel/machine` mount, so
  authorship stays local while readership is caravan-wide.

## Consequences

- known_hosts (and anything else ssh drops in `~/.ssh`) now lands in the
  persistent agent home and survives across sessions; first-contact hosts
  are recorded once per machine instead of once per session.
- Machine-specific outbound-SSH workarounds are unnecessary when a standard
  host key is present: ADR 0005 supplies it through a temporary agent without
  mounting the key.
- The fix rides the normal `satchel update` (which always rebuilds the
  image); machines that skip the update keep the old behavior, nothing
  breaks harder than before.
- A session can now read every machine's notes; the sync repo already
  syncs them to every machine, so this widens visibility inside sessions,
  not the set of machines holding the data.
