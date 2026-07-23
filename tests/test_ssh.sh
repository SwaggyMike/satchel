#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# A real unix socket for the -S check; a stubbed ssh-add controls what the
# probe sees on it (0 = keys loaded, 1 = empty, 2 = nothing answering).
eval "$(ssh-agent -a "$tmp/agent.sock")" >/dev/null
export SSH_AUTH_SOCK="$tmp/agent.sock"
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
rm "$HOME/.ssh/id_ed25519"

# The socket is mounted only when an agent answers on it.
SSH_STATE=ready ssh_forwarding
SSH_STATE=empty ssh_forwarding
! SSH_STATE=dead  ssh_forwarding
! SSH_STATE=none  ssh_forwarding
! SSH_STATE=off   ssh_forwarding

SSH_STATE=empty compose_run_args claude "$tmp/home_c" "$tmp/work/app"
[[ " ${RUN_ARGS[*]} " == *"/run/ssh-agent.sock"* ]]
SSH_STATE=dead compose_run_args claude "$tmp/home_c" "$tmp/work/app"
[[ " ${RUN_ARGS[*]} " != *"/run/ssh-agent.sock"* ]]

# The session preamble must match the probed state.
preamble() { SSH_STATE="$1" write_memory_file claude "$tmp/home_c" "" "$tmp/work/app"; cat "$tmp/home_c/.claude/CLAUDE.md"; }
grep -q 'works normally' <(preamble ready)
grep -q 'Permission denied (publickey)' <(preamble empty)
grep -q 'ssh-add' <(preamble empty)
! grep -q 'works normally' <(preamble empty)
grep -q 'cannot authenticate' <(preamble dead)
grep -q 'cannot authenticate' <(preamble none)
grep -q 'cannot authenticate' <(preamble off)

# Preflight automatically loads standard keys. If none is usable it explains
# the impact before continuing; ready and opted-out sessions stay calm.
set_ssh_add_rc 1
grep -q 'git push over SSH will not work' <(SSH_STATE=empty ssh_preflight </dev/null 2>&1)
start_temporary_ssh_agent() { SSH_STATE=ready; TEMP_SSH_AGENT_PID=123; return 0; }
touch "$HOME/.ssh/id_ed25519"
[ -z "$(SSH_STATE=none TEMP_SSH_AGENT_PID= ssh_preflight 2>&1)" ]
rm "$HOME/.ssh/id_ed25519"
start_temporary_ssh_agent() { return 1; }
grep -q 'git push over SSH will not work' <(SSH_STATE=dead ssh_preflight </dev/null 2>&1)
[ -z "$(SSH_STATE=ready ssh_preflight 2>&1)" ]
[ -z "$(SSH_STATE=off ssh_preflight 2>&1)" ]

# SSH-home fix: ssh resolves ~ via /etc/passwd, not $HOME, so the image must
# align the passwd homes of node and root with the mounted agent home. A direct
# field rewrite works while root is Docker's active PID 1; usermod does not.
grep -q "RUN sed -Ei .*root|node.* /etc/passwd" "$repo_dir/satchel"
! grep -q 'usermod -d /home/satchel root' "$repo_dir/satchel"
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
