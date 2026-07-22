#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export SATCHEL_DIR="$tmp/state"
mkdir -p "$HOME" "$SATCHEL_DIR/sync/.git" "$tmp/work/app/src" "$tmp/work/downloads/important"
printf 'MACHINE=testbox\nSYNC_URL=test\n' > "$SATCHEL_DIR/config"

# Load functions without invoking main.
source <(sed '$d' "$repo_dir/satchel")
load_config

id="$(enroll_project "$tmp/work/app" sample)"
[ "$id" = sample ]
[ "$(project_for_path "$tmp/work/app/src")" = sample ]
[ "$(jq -r '.paths | to_entries[0].value.status' "$(machine_projects_file)")" = tracked ]
[ -f "$SATCHEL_DIR/sync/projects/sample/project.json" ]
[ "$(canonical_remote 'git@github.com:Example/Repo.git')" = "$(canonical_remote 'https://github.com/example/repo')" ]
printf '<!-- satchel-handoff project=sample machine=a date=2026-01-01T00:00:00Z -->\n' \
  > "$SATCHEL_DIR/sync/projects/sample/handoffs/old.md"
printf '<!-- satchel-handoff project=sample machine=b date=2026-02-01T00:00:00Z -->\n' \
  > "$SATCHEL_DIR/sync/projects/sample/handoffs/new.md"
[ "$(basename "$(latest_handoff sample)")" = new.md ]

# Empty project id selects the machine scope: untracked and Host Sessions
# keep their handoffs under machines/<name>/handoffs/.
[ -z "$(latest_handoff "")" ]
mkdir -p "$SATCHEL_DIR/sync/machines/testbox/handoffs"
printf '<!-- satchel-handoff project=- machine=testbox date=2026-01-05T00:00:00Z -->\n' \
  > "$SATCHEL_DIR/sync/machines/testbox/handoffs/first.md"
printf '<!-- satchel-handoff project=- machine=testbox date=2026-02-05T00:00:00Z -->\n' \
  > "$SATCHEL_DIR/sync/machines/testbox/handoffs/second.md"
[ "$(basename "$(latest_handoff "")")" = second.md ]
[ "$(basename "$(latest_handoff sample)")" = new.md ]

# Machine Notes: mounted into sessions, injected into the preamble, and the
# standing instruction is present even before any notes exist.
compose_run_args claude "$tmp/home_c" "$tmp/work/app"
[[ " ${RUN_ARGS[*]} " == *"/machines/testbox:/home/satchel/machine"* ]]
write_memory_file claude "$tmp/home_c" "" "$tmp/work/app" 2>/dev/null
grep -q 'machine/notes.md' "$tmp/home_c/.claude/CLAUDE.md"
printf 'USE PODMAN NOT DOCKER ON TESTBOX\n' > "$SATCHEL_DIR/sync/machines/testbox/notes.md"
write_memory_file claude "$tmp/home_c" "" "$tmp/work/app" 2>/dev/null
grep -q 'USE PODMAN NOT DOCKER ON TESTBOX' "$tmp/home_c/.claude/CLAUDE.md"
write_memory_file claude "$tmp/home_c" sample "$tmp/work/app" 2>/dev/null
grep -q 'USE PODMAN NOT DOCKER ON TESTBOX' "$tmp/home_c/.claude/CLAUDE.md"

# --with: extras are validated, normalized, mounted at their real paths,
# and listed in the preamble; home and / are refused.
wd="$(readlink -f "$tmp/work/downloads")"
WITH_DIRS=("$tmp/work/downloads/../downloads")
with_dirs_guard
[ "${WITH_DIRS[0]}" = "$wd" ]
compose_run_args claude "$tmp/home_c" "$tmp/work/app"
[[ " ${RUN_ARGS[*]} " == *" $wd:$wd "* ]]
write_memory_file claude "$tmp/home_c" sample "$tmp/work/app" 2>/dev/null
grep -q "$wd" "$tmp/home_c/.claude/CLAUDE.md"
WITH_DIRS=("$HOME");           ! (with_dirs_guard 2>/dev/null)
WITH_DIRS=("$tmp/no-such-dir"); ! (with_dirs_guard 2>/dev/null)
WITH_DIRS=(/);                 ! (with_dirs_guard 2>/dev/null)
WITH_DIRS=()

# The mount guard still hard-refuses home and / without a tty.
HOST_MODE=0 UNSAFE_HOME=0
! (cd "$HOME" && session_mount_guard claude </dev/null 2>/dev/null)
! (cd / && session_mount_guard claude </dev/null 2>/dev/null)
(cd "$tmp/work/app" && session_mount_guard claude </dev/null)
UNSAFE_HOME=1
(cd "$HOME" && session_mount_guard claude </dev/null)
UNSAFE_HOME=0

reject_project_path "$tmp/work/downloads"
[ "$(path_decision "$tmp/work/downloads")" = rejected ]
[ -z "$(path_decision "$tmp/work/downloads/important")" ]
[ -z "$(project_for_path "$tmp/work/downloads/important")" ]
is_utility_root "$HOME"
! is_utility_root "$tmp/work/downloads/important"

# Path-based attribution: visible_projects enumerates roster entries under
# the mounts, at any depth; a Host Session sees every tracked project.
mkdir -p "$tmp/work/nested/app2"
id2="$(enroll_project "$tmp/work/nested/app2" sample2)"
[ "$id2" = sample2 ]
HOST_MODE=0 WITH_DIRS=()
[ "$(visible_projects "$tmp/work" | wc -l)" = 2 ]
[ "$(visible_projects "$tmp/work/app")" = "$(printf '%s\tsample' "$(readlink -f "$tmp/work/app")")" ]
WITH_DIRS=("$(readlink -f "$tmp/work/nested/app2")")
[ "$(visible_projects "$tmp/work/app" | wc -l)" = 2 ]
WITH_DIRS=()
HOST_MODE=1
[ "$(visible_projects "$tmp/work/app" | wc -l)" = 2 ]
[ "$(session_path /a/b)" = /host/a/b ]
HOST_MODE=0
[ "$(session_path /a/b)" = /a/b ]

# Sessions get the projects tree read-only, and a multi-project launch gets
# a table of contents instead of inlined handoffs.
compose_run_args claude "$tmp/home_c" "$tmp/work"
[[ " ${RUN_ARGS[*]} " == *"/projects:/home/satchel/projects:ro"* ]]
write_memory_file claude "$tmp/home_c" "" "$tmp/work" 2>/dev/null
grep -q 'Tracked projects in this session' "$tmp/home_c/.claude/CLAUDE.md"
grep -q 'sample2' "$tmp/home_c/.claude/CLAUDE.md"
grep -q 'unreachable here' "$tmp/home_c/.claude/CLAUDE.md"
# Exactly one visible project: adopted as the session's project, no TOC.
write_memory_file claude "$tmp/home_c" "" "$tmp/work/nested" 2>/dev/null
! grep -q 'Tracked projects in this session' "$tmp/home_c/.claude/CLAUDE.md"
grep -q 'No handoff exists for this project yet' "$tmp/home_c/.claude/CLAUDE.md"

# file_multi_handoffs: files each well-formed chunk under its scope, drops
# unknown ids, reports how many it saved; no delimiters means zero.
body=$'=== project: sample ===\n## Goal\nA\n=== project: intruder ===\n## Goal\nX\n=== machine ===\n## Goal\nB'
[ "$(file_multi_handoffs '2026-03-01T00:00:00Z' 'sample sample2 ' "$body" 2>/dev/null)" = 2 ]
grep -q 'project=sample ' "$SATCHEL_DIR/sync/projects/sample/handoffs/2026-03-01T00-00-00Z--testbox.md"
grep -q '^## Goal' "$SATCHEL_DIR/sync/machines/testbox/handoffs/2026-03-01T00-00-00Z.md"
[ ! -d "$SATCHEL_DIR/sync/projects/intruder" ]
[ "$(file_multi_handoffs '2026-03-02T00:00:00Z' 'sample ' $'## Goal\nplain' 2>/dev/null)" = 0 ]

printf 'ok: project enrollment and machine path decisions\n'
