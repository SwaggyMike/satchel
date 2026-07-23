# Forward the host's ssh-agent into sessions

Sessions mount the host's `$SSH_AUTH_SOCK` at `/run/ssh-agent.sock`, on by
default, so `git push`/`pull` over SSH works inside the sandbox. Key files
never enter the container; the socket only lets the session ask the host
agent to sign. `SATCHEL_SSH=0` (machine setting) turns it off.

## Context

The sandbox deliberately carries no credentials, so a session working on a
git project could commit but never push — every push meant leaving for a
host terminal. That friction hit hardest on satchel's own repo, where the
sandbox is the primary workplace. Alternatives considered:

- **Per-session flag (`--ssh`) or per-project remembered opt-in** — safer
  defaults, but rejected as cumbersome: the flag is a toll on every git
  session, and the remembered setting is machinery for a distinction (trusted
  vs untrusted project) that in practice is almost always "trusted".
- **Deploy key / fine-grained PAT in config** — a real credential at rest
  that a session could exfiltrate, plus per-repo setup. Strictly worse than a
  socket that expires with the session.
- **Host-side push broker** — most contained, most machinery. Not worth it
  for a single-user caravan.

## Decision

- `ssh_agent_state` probes the agent with `ssh-add -l` at session start and
  classifies it: `ready` (identities loaded), `empty` (agent answers, no
  identities), `dead` (socket but nothing answering), `none` (no socket),
  `off` (`SATCHEL_SSH=0`). A socket alone proves nothing - the common
  failure is a forwarded agent that answers but was never given a key.
- `compose_run_args` forwards the socket when the agent answers (`ready` or
  `empty`; keys added on the host mid-session become usable inside
  immediately). Dead sockets are not mounted. Both sandboxed and Host
  Sessions get it.
- A launch preflight tries to make the common case automatic. If the existing
  agent is empty, Satchel loads standard host identities (`id_ed25519`,
  `id_ecdsa`, `id_rsa`) with `ssh-add`. If no usable agent exists but one of
  those keys does, Satchel starts a temporary per-session agent and loads it.
  Passphrase entry occurs in the host terminal. The key file itself is never
  mounted; only the temporary socket reaches the container, and the agent is
  stopped when the session ends.
- If no standard key can be loaded, launch explains the concrete impact
  (`git push` over SSH will not work) and pauses for acknowledgement before
  continuing. `SATCHEL_SSH=0` is the explicit quiet opt-out.
- `GIT_SSH_COMMAND=ssh -o StrictHostKeyChecking=accept-new` is set alongside:
  first contact with a git host records its key in the persistent agent home
  instead of dying on an interactive prompt no tool call can answer; later
  sessions verify against that record (trust-on-first-use).
- The session preamble (CLAUDE.md/AGENTS.md) states what the agent can
  actually do: push works (`ready`), push fails until the user runs
  `ssh-add` (`empty`), or SSH auth is unavailable (everything else). It
  only claims git-over-SSH works when an identity is loaded.

## Consequences

- A running session can *authenticate* as the user — push to any repo the
  agent's keys reach — for as long as it runs. It still cannot read, copy, or
  persist a key. This is a deliberate widening of the sandbox: contained
  mess, not contained identity. `ssh-add -c` on the host restores per-use
  confirmation for the cautious.
- On root hosts (Unraid), a host agent socket may be inaccessible to the
  normal session UID. Satchel therefore prefers its temporary per-session
  socket and grants only that socket directory to `SATCHEL_UID`.
- Hosts without an agent or standard key may still continue after the visible
  warning: commit in-session, then push from the host.
