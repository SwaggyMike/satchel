#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_dir/tests/lib.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export SATCHEL_DIR="$tmp/state"
mkdir -p "$HOME" "$SATCHEL_DIR"
printf 'MACHINE=testbox\nSYNC_URL=\n' > "$SATCHEL_DIR/config"

# Load functions without invoking main. Inside the sourced functions $0 is
# this test file, so script_blob hashes it - the stub below plays GitHub.
source <(sed '$d' "$repo_dir/satchel")
load_config

stub="$tmp/bin"; mkdir -p "$stub"; export PATH="$stub:$PATH"
export STUB_HIT="$tmp/hit"
set_remote_blob() {
  printf '#!/bin/sh\ntouch "$STUB_HIT"\necho "{\\"sha\\":\\"%s\\"}"\n' "$1" > "$stub/curl"
  chmod +x "$stub/curl"
}

# Newer script on GitHub: announce it.
set_remote_blob 0000000000000000000000000000000000000000
first_output="$(update_check 2>&1)"
grep -q "satchel update" <<< "$first_output"
refute grep -q 'No such file or directory' <<< "$first_output"

# Second call the same day: silent, and no network probe at all.
rm -f "$STUB_HIT"
[ -z "$(update_check 2>&1)" ]
[ ! -f "$STUB_HIT" ]

# Stale stamp but matching content: probe runs, nothing announced.
printf '0' > "$SATCHEL_DIR/update-check"
set_remote_blob "$(git hash-object "$0")"
[ -z "$(update_check 2>&1)" ]
[ -f "$STUB_HIT" ]

# Offline probe: silent, not fatal.
printf '0' > "$SATCHEL_DIR/update-check"
printf '#!/bin/sh\nexit 7\n' > "$stub/curl"; chmod +x "$stub/curl"
[ -z "$(update_check 2>&1)" ]

# Ctrl-C is not an offline condition: propagate it so session launch stops.
printf '0' > "$SATCHEL_DIR/update-check"
printf '#!/bin/sh\nexit 130\n' > "$stub/curl"; chmod +x "$stub/curl"
rc=0
update_check >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 130 ]

# `image --rebuild` is the narrow entry point used by the newly installed
# artifact during self-update.
export REBUILD_HIT="$tmp/rebuild-hit"
build_image() { : > "$REBUILD_HIT"; }
cmd_image --rebuild
[ -f "$REBUILD_HIT" ]
rm "$REBUILD_HIT"

# Replacing a running Bash script does not replace its loaded functions. The
# updater must invoke the downloaded artifact for the rebuild, and stamp the
# update only after that child succeeds.
fake_self="$tmp/installed-satchel"
download="$tmp/downloaded-satchel"
old_recipe_hit="$tmp/old-recipe-hit"
export NEW_RECIPE_HIT="$tmp/new-recipe-hit"
printf '#!/usr/bin/env bash\nprintf old\n' > "$fake_self"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[ "$1" = image ] && [ "$2" = --rebuild ]' \
  ': > "$NEW_RECIPE_HIT"' \
  > "$download"
chmod 755 "$fake_self" "$download"
readlink() { printf '%s\n' "$fake_self"; }
UPDATE_SHA=1111111111111111111111111111111111111111
curl() {
  local arg out=""
  case " $* " in
    *"/commits/main"*) printf '{"sha":"%s"}\n' "$UPDATE_SHA"; return 0 ;;
  esac
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    if [ "$arg" = -o ]; then out="$1"; shift; fi
  done
  cp "$download" "$out"
}
need_cmd() { :; }
print_update_log() { :; }
build_image() { : > "$old_recipe_hit"; }
image_agent_versions() { :; }

# Replacing the running script is safe only when the download is staged beside
# it. If that directory is not writable, falling back to /tmp can turn mv into
# a cross-filesystem copy over the inode Bash is still executing. Refuse the
# update and leave the installed artifact intact.
mktemp_bin="$(command -v mktemp)"
mktemp() {
  case "${1:-}" in
    */.satchel-update.*) return 1 ;;
    *) "$mktemp_bin" "$@" ;;
  esac
}
before_update="$(cat "$fake_self")"
refute cmd_update
[ "$(cat "$fake_self")" = "$before_update" ]
[ ! -e "$NEW_RECIPE_HIT" ]
unset -f mktemp

cmd_update >/dev/null 2>&1
[ -f "$NEW_RECIPE_HIT" ]
[ ! -e "$old_recipe_hit" ]
[ "$(cat "$SCRIPT_SHA_FILE")" = 1111111111111111111111111111111111111111 ]

UPDATE_SHA=2222222222222222222222222222222222222222
printf '#!/usr/bin/env bash\nexit 7\n' > "$download"
chmod 755 "$download"
refute cmd_update
[ "$(cat "$SCRIPT_SHA_FILE")" = 1111111111111111111111111111111111111111 ]
unset -f readlink curl need_cmd print_update_log build_image image_agent_versions

printf 'ok: update checks and new-artifact rebuild\n'
