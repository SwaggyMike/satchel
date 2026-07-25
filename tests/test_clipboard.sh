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

# A real unix socket for the -S check (ssh-agent is a handy socket factory).
eval "$(ssh-agent -a "$tmp/wayland-1")" >/dev/null

clip() { RUN_ARGS=(); compose_clipboard_args; printf '%s' " ${RUN_ARGS[*]} "; }

# Wayland socket named relative to XDG_RUNTIME_DIR: mounted at a fixed path,
# WAYLAND_DISPLAY rewritten to that absolute path.
out="$(DISPLAY= WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR="$tmp" clip)"
[[ "$out" == *" $tmp/wayland-1:/run/satchel/wayland-0 "* ]]
[[ "$out" == *" WAYLAND_DISPLAY=/run/satchel/wayland-0 "* ]]

# An absolute WAYLAND_DISPLAY needs no XDG_RUNTIME_DIR.
out="$(DISPLAY= WAYLAND_DISPLAY="$tmp/wayland-1" XDG_RUNTIME_DIR= clip)"
[[ "$out" == *" $tmp/wayland-1:/run/satchel/wayland-0 "* ]]

# Opt-out and missing-socket hosts get nothing mounted.
out="$(SATCHEL_CLIPBOARD=0 DISPLAY= WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR="$tmp" clip)"
[[ "$out" != *wayland* ]]
out="$(DISPLAY= WAYLAND_DISPLAY=no-such-socket XDG_RUNTIME_DIR="$tmp" clip)"
[[ "$out" != *wayland* ]]

# X11 fallback only applies when the host really runs X; test where it does.
if [ -d /tmp/.X11-unix ]; then
  out="$(WAYLAND_DISPLAY= DISPLAY=:0 XAUTHORITY= clip)"
  [[ "$out" == *" /tmp/.X11-unix:/tmp/.X11-unix "* ]]
  [[ "$out" == *" DISPLAY=:0 "* ]]
fi

# Both ordinary and baseline sessions forward the socket.
SSH_STATE=none WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR="$tmp" DISPLAY= \
  compose_run_args claude "$tmp/home_c" "$tmp/work/app"
[[ " ${RUN_ARGS[*]} " == *"/run/satchel/wayland-0"* ]]
WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR="$tmp" DISPLAY= \
  compose_baseline_run_args claude "$tmp/home_c"
[[ " ${RUN_ARGS[*]} " == *"/run/satchel/wayland-0"* ]]

printf 'ok: clipboard socket forwarding\n'
