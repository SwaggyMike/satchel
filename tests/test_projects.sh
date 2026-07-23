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

# Keep pure project tests independent of the host container engine.
podman_rootless() { return 1; }
SSH_STATE=none

# Projects are Git repositories. Portable origins drive global decisions;
# local/no-origin repositories remain available through explicit tracking.
git init -q -b main "$tmp/work/app"
git -C "$tmp/work/app" remote add origin git@github.com:Example/App.git
id="$(enroll_project "$tmp/work/app" sample)"
[ "$id" = sample ]
[ "$(project_for_path "$tmp/work/app/src")" = sample ]
[ "$(jq -r '.paths | to_entries[0].value.project' "$(machine_projects_file)")" = sample ]
[ "$(jq -r '.paths | to_entries[0].value | keys | join(",")' "$(machine_projects_file)")" = project ]
[ ! -e "$SATCHEL_DIR/sync/projects/sample/project.json" ]
[ -d "$SATCHEL_DIR/sync/projects/sample/handoffs" ]
[ "$(repository_decision github.com/example/app)" = tracked ]
[ "$(project_for_identity github.com/example/app)" = sample ]
[ "$(jq -r '."github.com/example/app".project' "$(repository_registry_file)")" = sample ]
[ -z "$(jq -r '."github.com/example/app".origin // empty' "$(repository_registry_file)")" ]
[ "$(canonical_remote 'git@github.com:Example/Repo.git')" = "$(canonical_remote 'https://github.com/example/repo')" ]
[ "$(canonical_remote 'https://token@example.com/Owner/Repo.git?x=secret')" = example.com/Owner/Repo ]
! grep -q token "$(repository_registry_file)"
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
[[ " ${RUN_ARGS[*]} " == *"--label io.github.swaggymike.satchel.managed=true"* ]]
[[ " ${RUN_ARGS[*]} " == *"/machines/testbox:/home/satchel/machine"* ]]
write_memory_file claude "$tmp/home_c" "" "$tmp/work/app" 2>/dev/null
grep -q '/home/satchel/machine/notes.md' "$tmp/home_c/.claude/CLAUDE.md"
# Absolute paths only: a Host Session runs as root, where '~' resolves to
# /root and sent an agent looking for /root/machine/notes.md once.
! grep -q '~/machine\|~/projects' "$tmp/home_c/.claude/CLAUDE.md"
printf 'USE PODMAN NOT DOCKER ON TESTBOX\n' > "$SATCHEL_DIR/sync/machines/testbox/notes.md"
printf '<!-- satchel-machine-baseline version=2 generated=2026-07-23T01:02:03Z -->\n# Inventory\nINVENTORY_DETAIL_SHOULD_NOT_LOAD\n' \
  > "$SATCHEL_DIR/sync/machines/testbox/inventory.md"
mkdir -p "$SATCHEL_DIR/sync/machines/testbox/guides"
printf '# Time Machine\nGUIDE_DETAIL_SHOULD_NOT_LOAD\n' \
  > "$SATCHEL_DIR/sync/machines/testbox/guides/time-machine.md"
write_memory_file claude "$tmp/home_c" "" "$tmp/work/app" 2>/dev/null
grep -q 'USE PODMAN NOT DOCKER ON TESTBOX' "$tmp/home_c/.claude/CLAUDE.md"
grep -q '/home/satchel/machine/inventory.md (generated 2026-07-23T01:02:03Z)' "$tmp/home_c/.claude/CLAUDE.md"
grep -q '/home/satchel/machine/guides/time-machine.md.*Time Machine' "$tmp/home_c/.claude/CLAUDE.md"
! grep -q 'INVENTORY_DETAIL_SHOULD_NOT_LOAD\|GUIDE_DETAIL_SHOULD_NOT_LOAD' "$tmp/home_c/.claude/CLAUDE.md"
grep -q 'Resolved one-time fixes belong nowhere' "$tmp/home_c/.claude/CLAUDE.md"
write_memory_file claude "$tmp/home_c" sample "$tmp/work/app" 2>/dev/null
grep -q 'USE PODMAN NOT DOCKER ON TESTBOX' "$tmp/home_c/.claude/CLAUDE.md"

# Normal launches are quiet; the materially dangerous Host Session warning
# remains visible.
HOST_MODE=0
[ -z "$(announce_session_mode 2>&1)" ]
HOST_MODE=1
grep -q 'HOST SESSION' <<< "$(announce_session_mode 2>&1)"
HOST_MODE=0

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
ln -s "$HOME" "$tmp/work/home-link"
! (cd "$tmp/work/home-link" && session_mount_guard claude </dev/null 2>/dev/null)
! (cd "$SATCHEL_DIR" && session_mount_guard claude </dev/null 2>/dev/null)
WITH_DIRS=("$SATCHEL_DIR")
! (with_dirs_guard 2>/dev/null)
WITH_DIRS=()
UNSAFE_HOME=1
(cd "$HOME" && session_mount_guard claude </dev/null)
UNSAFE_HOME=0

# Ordinary directories never become Projects, even explicitly. A local Git
# repo can be explicitly tracked but is not an automatic prompt candidate.
! (enroll_project "$tmp/work/downloads" nope 2>/dev/null)
git init -q -b main "$tmp/work/local"
local_id="$(enroll_project "$tmp/work/local" local-only)"
[ "$local_id" = local-only ]
[ -z "$(project_identity "$tmp/work/local")" ]
[ -z "$(visible_candidates "$tmp/work/local")" ]
! (enroll_project "$tmp/work/local" .. 2>/dev/null)
! (enroll_project "$tmp/work/local" .git 2>/dev/null)
! (untrack_project .. 2>/dev/null)
[ ! -e "$SATCHEL_DIR/sync/handoffs" ]
[ ! -e "$SATCHEL_DIR/sync/project.json" ]

# Discovery recursively recognizes globally tracked origins without a prior
# path mapping on this machine, and ignored/unknown origins stay distinct.
mkdir -p "$tmp/work/nested/app2"
git init -q -b main "$tmp/work/nested/app2"
git -C "$tmp/work/nested/app2" remote add origin https://github.com/example/app2.git
id2="$(enroll_project "$tmp/work/nested/app2" sample2)"
[ "$id2" = sample2 ]
remove_project_path "$tmp/work/nested/app2"
[ -z "$(project_for_path "$tmp/work/nested/app2")" ]
refresh_project_paths "$tmp/work"
[ "$(project_for_path "$tmp/work/nested/app2")" = sample2 ]

mkdir -p "$tmp/work/nested/junk" "$tmp/work/newrepo"
git init -q -b main "$tmp/work/nested/junk"
git -C "$tmp/work/nested/junk" remote add origin git@github.com:example/junk.git
ignore_repository github.com/example/junk
refresh_project_paths "$tmp/work"
[ "$(repository_decision github.com/example/junk)" = ignored ]
[ -z "$(project_for_path "$tmp/work/nested/junk")" ]
! visible_candidates "$tmp/work" | grep -q junk

git init -q -b main "$tmp/work/newrepo"
git -C "$tmp/work/newrepo" remote add origin https://user:password@example.com/team/newrepo.git
candidate="$(visible_candidates "$tmp/work")"
[ "$candidate" = "$(printf '%s\texample.com/team/newrepo' "$(readlink -f "$tmp/work/newrepo")")" ]
! grep -q 'user\|password' <<< "$candidate"
mkdir -p "$tmp/work/newrepo-copy"
git init -q -b main "$tmp/work/newrepo-copy"
git -C "$tmp/work/newrepo-copy" remote add origin git@example.com:team/newrepo.git
[ "$(visible_candidates "$tmp/work" | grep -c $'\texample.com/team/newrepo$')" = 2 ]
mkdir -p "$tmp/outside-repo"
git init -q -b main "$tmp/outside-repo"
git -C "$tmp/outside-repo" remote add origin https://example.com/outside/repo.git
ln -s "$tmp/outside-repo" "$tmp/work/outside-link"
! visible_candidates "$tmp/work" | grep -q 'example.com/outside/repo'

# An origin change invalidates the checkout cache and requires a new decision.
git -C "$tmp/work/nested/app2" remote set-url origin https://github.com/example/app2-renamed.git
refresh_project_paths "$tmp/work"
[ -z "$(project_for_path "$tmp/work/nested/app2")" ]
git -C "$tmp/work/nested/app2" remote set-url origin https://github.com/example/app2.git
refresh_project_paths "$tmp/work"
[ "$(project_for_path "$tmp/work/nested/app2")" = sample2 ]

# Path-based attribution enumerates roster entries under the mounts, at any
# depth; a Host Session uses known paths without recursively scanning the host.
HOST_MODE=0 WITH_DIRS=()
[ "$(visible_projects "$tmp/work" | wc -l)" = 3 ]
[ "$(visible_projects "$tmp/work/app")" = "$(printf '%s\tsample' "$(readlink -f "$tmp/work/app")")" ]
WITH_DIRS=("$(readlink -f "$tmp/work/nested/app2")")
[ "$(visible_projects "$tmp/work/app" | wc -l)" = 2 ]
WITH_DIRS=()
HOST_MODE=1
[ "$(visible_projects "$tmp/work/app" | wc -l)" = 3 ]
[ "$(session_path /a/b)" = /host/a/b ]
HOST_MODE=0
[ "$(session_path /a/b)" = /a/b ]

# Multiple checkouts with one origin resolve to one Project ID while retaining
# both visible paths for attribution.
mkdir -p "$tmp/work/app-copy"
git init -q -b main "$tmp/work/app-copy"
git -C "$tmp/work/app-copy" remote add origin https://github.com/example/app.git
refresh_project_paths "$tmp/work"
[ "$(project_for_path "$tmp/work/app-copy")" = sample ]
[ "$(visible_projects "$tmp/work" | awk -F '\t' '$2 == "sample" {n++} END {print n}')" = 2 ]

# Sessions get the projects tree read-only, and a multi-project launch gets
# a table of contents instead of inlined handoffs.
compose_run_args claude "$tmp/home_c" "$tmp/work"
[[ " ${RUN_ARGS[*]} " == *"/projects:/home/satchel/projects:ro"* ]]
# Sibling machines' knowledge rides along read-only, and the preamble says so.
[[ " ${RUN_ARGS[*]} " == *"/machines:/home/satchel/machines:ro"* ]]
write_memory_file claude "$tmp/home_c" "" "$tmp/work" 2>/dev/null
grep -q '/home/satchel/machines/' "$tmp/home_c/.claude/CLAUDE.md"
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

# Candidate scopes trigger decisions only when the handoff model emits them.
# In a noninteractive run, preserve the work as one machine handoff and leave
# the repository undecided. Multiple machine chunks are combined, not lost to
# same-timestamp overwrites.
candidate_tokens=(candidate-1)
candidate_paths=("$tmp/work/newrepo")
candidate_identities=(example.com/team/newrepo)
cbody=$'=== candidate: candidate-1 ===\n## Goal\nCandidate work\n=== machine ===\n## Goal\nOther work'
resolve_candidate_handoffs "$cbody"
grep -q '^=== machine ===' <<< "$RESOLVED_HANDOFF_BODY"
[ -z "$RESOLVED_PROJECT_IDS" ]
[ -z "$(repository_decision example.com/team/newrepo)" ]
[ "$(file_multi_handoffs '2026-03-03T00:00:00Z' 'sample ' "$RESOLVED_HANDOFF_BODY" 2>/dev/null)" = 1 ]
machine_combined="$SATCHEL_DIR/sync/machines/testbox/handoffs/2026-03-03T00-00-00Z.md"
grep -q 'Candidate work' "$machine_combined"
grep -q 'Other work' "$machine_combined"

# Handoff directories are bounded continuation state, not an incident archive.
mkdir -p "$SATCHEL_DIR/sync/projects/retained/handoffs"
for i in $(seq -w 1 12); do
  file_handoff retained "2026-04-${i}T00:00:00Z" $'## Goal\nretention test' 2>/dev/null
done
[ "$(find "$SATCHEL_DIR/sync/projects/retained/handoffs" -type f -name '*.md' | wc -l)" = "$HANDOFF_RETENTION" ]
[ ! -f "$SATCHEL_DIR/sync/projects/retained/handoffs/2026-04-01T00-00-00Z--testbox.md" ]
[ -f "$SATCHEL_DIR/sync/projects/retained/handoffs/2026-04-12T00-00-00Z--testbox.md" ]

# Global untracking ignores a portable origin, clears every machine's path
# cache, and removes the active Project and handoffs.
mkdir -p "$tmp/work/remove-me"
git init -q -b main "$tmp/work/remove-me"
git -C "$tmp/work/remove-me" remote add origin https://github.com/example/remove-me.git
remove_id="$(enroll_project "$tmp/work/remove-me" remove-me)"
mkdir -p "$SATCHEL_DIR/sync/machines/other"
printf '{"paths":{"/other/remove-me":{"project":"remove-me"}}}\n' \
  > "$SATCHEL_DIR/sync/machines/other/projects.json"
untrack_project "$remove_id"
[ "$(repository_decision github.com/example/remove-me)" = ignored ]
[ ! -d "$SATCHEL_DIR/sync/projects/remove-me" ]
[ -z "$(project_for_path "$tmp/work/remove-me")" ]
[ "$(jq '.paths | length' "$SATCHEL_DIR/sync/machines/other/projects.json")" = 0 ]

# Folder names suggest IDs but never establish identity. Different origins
# with the same basename get unique global IDs; an explicit conflicting ID is
# rejected instead of merging repositories.
mkdir -p "$tmp/collisions/one/satchel" "$tmp/collisions/two/satchel" "$tmp/collisions/three/other"
git init -q -b main "$tmp/collisions/one/satchel"
git init -q -b main "$tmp/collisions/two/satchel"
git init -q -b main "$tmp/collisions/three/other"
git -C "$tmp/collisions/one/satchel" remote add origin https://example.com/one/satchel.git
git -C "$tmp/collisions/two/satchel" remote add origin https://example.com/two/satchel.git
git -C "$tmp/collisions/three/other" remote add origin https://example.com/three/other.git
collision_one="$(enroll_project "$tmp/collisions/one/satchel")"
collision_two="$(enroll_project "$tmp/collisions/two/satchel")"
[ "$collision_one" = satchel ]
[ "$collision_two" = satchel-2 ]
! (enroll_project "$tmp/collisions/three/other" satchel 2>/dev/null)
[ -z "$(repository_decision example.com/three/other)" ]

# Registry and cache conflicts fail explicitly. Satchel never guesses through
# duplicate origins, missing Projects, old metadata, or malformed path caches.
registry="$(repository_registry_file)"
jq '.["example.com/conflict"]={status:"tracked",project:"satchel"}' "$registry" \
  > "$registry.tmp" && mv "$registry.tmp" "$registry"
! (validate_project_state 2>/dev/null)
jq 'del(.["example.com/conflict"])' "$registry" > "$registry.tmp" && mv "$registry.tmp" "$registry"
touch "$SATCHEL_DIR/sync/projects/sample/project.json"
! (validate_project_state 2>/dev/null)
rm "$SATCHEL_DIR/sync/projects/sample/project.json"
printf '{"paths":{"/missing":{"project":"missing"}}}\n' \
  > "$SATCHEL_DIR/sync/machines/other/projects.json"
! (validate_project_state 2>/dev/null)
printf '{"paths":{}}\n' > "$SATCHEL_DIR/sync/machines/other/projects.json"
validate_project_state

# Status keeps active Project IDs/origins visible but collapses ignored repos
# unless the explicit detail flag is requested.
status="$(cmd_status 2>/dev/null)"
grep -q 'sample.*github.com/example/app' <<< "$status"
grep -q 'ignored repositories: 2.*status --ignored' <<< "$status"
! grep -q 'github.com/example/junk' <<< "$status"
ignored_status="$(cmd_status --ignored 2>/dev/null)"
grep -q 'github.com/example/junk' <<< "$ignored_status"
grep -q 'github.com/example/remove-me' <<< "$ignored_status"

# Explicit tracking reverses a global ignore.
junk_id="$(enroll_project "$tmp/work/nested/junk" junk)"
[ "$junk_id" = junk ]
[ "$(repository_decision github.com/example/junk)" = tracked ]
[ "$(project_for_path "$tmp/work/nested/junk")" = junk ]

printf 'ok: global project identity, discovery, and handoffs\n'
