#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_dir/tests/lib.sh"
tmp="$(mktemp -d)"
cleanup() { [ -n "${SSH_AGENT_PID:-}" ] && kill "$SSH_AGENT_PID" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

export HOME="$tmp/home"
export SATCHEL_DIR="$tmp/state"
mkdir -p "$HOME" "$SATCHEL_DIR/sync/.git" "$tmp/work/app"
printf 'MACHINE=testbox\nSYNC_URL=test\n' > "$SATCHEL_DIR/config"

# Load functions without invoking main.
source <(sed '$d' "$repo_dir/satchel")
load_config
ENGINE=test-engine

# A real unix socket for the -S check; a stubbed ssh-add controls what the
# probe sees on it (0 = keys loaded, 1 = empty, 2 = nothing answering).
eval "$(ssh-agent -a "$tmp/agent.sock")" >/dev/null
export SSH_AUTH_SOCK="$tmp/agent.sock"

# Automatically loading an unencrypted standard key is a routine success path
# and must not flash ssh-add's "Identity added" message during every launch.
mkdir -p "$HOME/.ssh"
ssh-keygen -q -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
original_sock="$SSH_AUTH_SOCK"
original_pid="$SSH_AGENT_PID"
SSH_STATE=none
start_temporary_ssh_agent > "$tmp/quiet-ssh-add" 2>&1
[ ! -s "$tmp/quiet-ssh-add" ]
stop_temporary_ssh_agent
export SSH_AUTH_SOCK="$original_sock"
export SSH_AGENT_PID="$original_pid"
rm "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ed25519.pub"

stub="$tmp/bin"; mkdir -p "$stub"; export PATH="$stub:$PATH"
set_ssh_add_rc() { printf '#!/bin/sh\nexit %s\n' "$1" > "$stub/ssh-add"; chmod +x "$stub/ssh-add"; }

[ "$(SATCHEL_SSH=0 ssh_agent_state)" = off ]
[ "$(SSH_AUTH_SOCK= ssh_agent_state)" = none ]
[ "$(SSH_AUTH_SOCK=$tmp/no-such-sock ssh_agent_state)" = none ]
set_ssh_add_rc 0; [ "$(ssh_agent_state)" = ready ]
set_ssh_add_rc 1; [ "$(ssh_agent_state)" = empty ]
set_ssh_add_rc 2; [ "$(ssh_agent_state)" = dead ]

# A temporary agent uses only a standard private key, exposes a socket, and is
# removed cleanly at the session boundary. ssh-add is stubbed so no real key
# material is needed for the lifecycle check.
mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/id_ed25519"
set_ssh_add_rc 0
start_temporary_ssh_agent
[ "$SSH_STATE" = ready ]
[ -S "$SSH_AUTH_SOCK" ]
temp_sock="$SSH_AUTH_SOCK"
stop_temporary_ssh_agent
[ ! -e "$temp_sock" ]
[ -z "$TEMP_SSH_AGENT_PID" ]

# Interrupting passphrase entry stops launch and cleans up the agent.
set_ssh_add_rc 130
rc=0
start_temporary_ssh_agent >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 130 ]
[ -z "$TEMP_SSH_AGENT_PID" ]
[ -z "$TEMP_SSH_AGENT_DIR" ]
rm "$HOME/.ssh/id_ed25519"

# ssh-agent serves only peers whose euid is 0 or matches its own uid, so an
# agent started by root is unreachable from a uid-SATCHEL_UID session no matter
# who owns the socket. Satchel used to chown the socket and call that solved,
# which announced a dead-on-arrival agent to the session as working.
# These checks pin the two halves of the fix: the agent is started through the
# privilege drop, and "ready" is only claimed after proving it answers there.
agent_start_line="$(grep -n 'ssh-agent -a "\$sock"' "$repo_dir/satchel" | head -n 1)"
[ -n "$agent_start_line" ] || fail "could not find the temporary agent's start line"
case "$agent_start_line" in
  *as_session_uid*) ;;
  *) fail "the temporary ssh-agent must start via as_session_uid: $agent_start_line" ;;
esac
refute_grep 'chown "\$SATCHEL_UID:\$SATCHEL_GID" "\$TEMP_SSH_AGENT_DIR" "\$sock"' "$repo_dir/satchel"

# A root-run host without setpriv cannot own an agent as the session's uid;
# claiming otherwise is the failure mode this whole path exists to avoid.
id() { echo 0; }
HOST_MODE=0
command() { if [ "${2:-}" = setpriv ]; then return 1; fi; builtin command "$@"; }
refute can_serve_session_uid
refute start_temporary_ssh_agent
unset -f command
# With setpriv present the capability check passes again.
can_serve_session_uid
unset -f id
HOST_MODE=0

# "ready" must survive only when the agent actually answers as the session uid.
# A key that loads but an agent that refuses the probe is not a usable agent.
mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/id_ed25519"
printf '#!/bin/sh\ncase "$1" in -l) exit 2 ;; esac\nexit 0\n' > "$stub/ssh-add"
chmod +x "$stub/ssh-add"
SSH_STATE=none
rc=0
start_temporary_ssh_agent >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'start_temporary_ssh_agent claimed success while the agent refused the session-uid probe'
[ "$SSH_STATE" != ready ] || fail 'SSH_STATE must not be ready when the agent is unreachable'
[ -z "$TEMP_SSH_AGENT_PID" ] || fail 'a rejected agent must be cleaned up'
rm "$HOME/.ssh/id_ed25519"

refute_state() { # a forwarded socket is used only when an agent answers on it
  if SSH_STATE="$1" ssh_forwarding; then fail "ssh_forwarding should be false for state $1"; fi
}

# The socket is mounted only when an agent answers on it.
SSH_STATE=ready ssh_forwarding
SSH_STATE=empty ssh_forwarding
refute_state dead
refute_state none
refute_state off

SSH_STATE=empty compose_run_args claude "$tmp/home_c" "$tmp/work/app"
[[ " ${RUN_ARGS[*]} " == *"/run/ssh-agent.sock"* ]]
SSH_STATE=dead compose_run_args claude "$tmp/home_c" "$tmp/work/app"
[[ " ${RUN_ARGS[*]} " != *"/run/ssh-agent.sock"* ]]

# The session preamble must match the probed state.
preamble() { SSH_STATE="$1" write_memory_file claude "$tmp/home_c" "" "$tmp/work/app"; cat "$tmp/home_c/.claude/CLAUDE.md"; }

# A reachable agent means git can sign — but NOT that every remote will work.
# The host's ~/.ssh/config is not mounted, so a remote depending on a per-host
# IdentityFile fails while others succeed. The preamble used to promise "git
# push/pull over SSH works normally", which sent agents off debugging
# credentials that cannot be fixed from inside the container.
grep -q 'ssh-agent is forwarded' <(preamble ready)
grep -q 'ssh/config is NOT mounted' <(preamble ready)
grep -q 'ssh-add -l' <(preamble ready)
grep -q 'Permission denied (publickey)' <(preamble ready)
refute grep -q 'works normally' <(preamble ready)

grep -q 'Permission denied (publickey)' <(preamble empty)
grep -q 'ssh-add' <(preamble empty)
grep -q 'ssh/config is not mounted' <(preamble empty)
refute grep -q 'works normally' <(preamble empty)
grep -q 'cannot authenticate' <(preamble dead)
grep -q 'cannot authenticate' <(preamble none)
grep -q 'cannot authenticate' <(preamble off)

# Preflight automatically loads standard keys. If none is usable it explains
# the impact before continuing; ready and opted-out sessions stay calm.
# Logical state tests use Host mode so a root-run test process does not
# intentionally replace a root-owned socket with a temporary normal-user one.
HOST_MODE=1
set_ssh_add_rc 1
grep -q 'git push over SSH will not work' <(SSH_STATE=empty ssh_preflight </dev/null 2>&1)
touch "$HOME/.ssh/id_ed25519"
set_ssh_add_rc 130
rc=0
SSH_STATE=empty ssh_preflight </dev/null >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 130 ]
rm "$HOME/.ssh/id_ed25519"
start_temporary_ssh_agent() { SSH_STATE=ready; TEMP_SSH_AGENT_PID=123; return 0; }
touch "$HOME/.ssh/id_ed25519"
[ -z "$(SSH_STATE=none TEMP_SSH_AGENT_PID= ssh_preflight 2>&1)" ]
rm "$HOME/.ssh/id_ed25519"
start_temporary_ssh_agent() { return 1; }
grep -q 'git push over SSH will not work' <(SSH_STATE=dead ssh_preflight </dev/null 2>&1)
[ -z "$(SSH_STATE=ready ssh_preflight 2>&1)" ]
[ -z "$(SSH_STATE=off ssh_preflight 2>&1)" ]
HOST_MODE=0

# SSH-home fix: ssh resolves ~ via /etc/passwd, not $HOME, so the image must
# align the passwd homes of node and root with the mounted agent home. A direct
# field rewrite works while root is Docker's active PID 1; usermod does not.
grep -q "RUN sed -Ei .*root|node.* /etc/passwd" "$repo_dir/satchel"
refute grep -q 'usermod -d /home/satchel root' "$repo_dir/satchel"
passwd_fixture="$tmp/passwd"
printf 'root:x:0:0:root:/root:/bin/bash\nnode:x:1000:1000::/home/node:/bin/bash\n' > "$passwd_fixture"
sed -Ei 's#^((root|node):[^:]*:[^:]*:[^:]*:[^:]*:)[^:]*:#\1/home/satchel:#' "$passwd_fixture"
[ "$(awk -F: '$1 == "root" { print $6 }' "$passwd_fixture")" = /home/satchel ]
[ "$(awk -F: '$1 == "node" { print $6 }' "$passwd_fixture")" = /home/satchel ]

# Custom SATCHEL_UID under rootless podman: keep-id's invented passwd entry
# must point home at /home/satchel; no such flag reaches other engines.
podman_rootless() { return 0; }
SSH_STATE=ready compose_run_args claude "$tmp/home_c" "$tmp/work/app"
[[ " ${RUN_ARGS[*]} " == *"--passwd-entry"* ]]
[[ " ${RUN_ARGS[*]} " == *":/home/satchel:"* ]]
podman_rootless() { return 1; }
SSH_STATE=ready compose_run_args claude "$tmp/home_c" "$tmp/work/app"
[[ " ${RUN_ARGS[*]} " != *"--passwd-entry"* ]]

printf 'ok: ssh-agent preflight states and session guidance\n'
