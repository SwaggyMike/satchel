#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_dir/tests/lib.sh"

source "$repo_dir/scripts/session-smoke.sh"

# Some rootless engines hide ancestor PIDs even though their init is PID 1 in
# a private namespace. Engines that expose the nesting remain supported too.
pid_namespace_is_private 1 podman-init
pid_namespace_is_private 1 catatonit
pid_namespace_is_private 1 docker-init
pid_namespace_is_private 1 tini
pid_namespace_is_private 2 arbitrary-init
refute pid_namespace_is_private 1 systemd

printf 'test_session_smoke: ok\n'
