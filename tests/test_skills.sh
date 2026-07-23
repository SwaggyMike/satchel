#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export SATCHEL_DIR="$tmp/state"
mkdir -p "$HOME" "$SATCHEL_DIR/sync" "$tmp/work"
git init -q -b main "$SATCHEL_DIR/sync"
git -C "$SATCHEL_DIR/sync" config user.name test
git -C "$SATCHEL_DIR/sync" config user.email test@example.com
printf 'MACHINE=testbox\nSYNC_URL=test\n' > "$SATCHEL_DIR/config"

# Load functions without invoking main.
source <(sed '$d' "$repo_dir/satchel")
load_config

# Keep the mount test independent of the host's container engine.
podman_rootless() { return 1; }
SSH_STATE=none

# One source of truth drives the mount, environment contract, and generated
# instructions for each agent.
for agent in claude codex; do
  case "$agent" in
    claude) skills_dir=/home/satchel/.claude/skills; memory=.claude/CLAUDE.md ;;
    codex)  skills_dir=/home/satchel/.codex/skills;  memory=.codex/AGENTS.md ;;
  esac
  agent_home="$tmp/home_$agent"

  compose_run_args "$agent" "$agent_home" "$tmp/work"
  args=" ${RUN_ARGS[*]} "
  [[ "$args" == *" SATCHEL_SESSION=1 "* ]]
  [[ "$args" == *" $SATCHEL_DIR/sync/skills/shared:$skills_dir "* ]]
  [[ "$args" == *" SATCHEL_SKILLS_DIR=$skills_dir "* ]]

  write_memory_file "$agent" "$agent_home" "" "$tmp/work"
  preamble="$agent_home/$memory"
  grep -q '^## Satchel Skill Library$' "$preamble"
  grep -q "mounted read-write" "$preamble"
  grep -q "$skills_dir" "$preamble"
  grep -q 'Claude and Codex sessions on every' "$preamble"
  grep -q 'Preserve the whole bundle' "$preamble"
  grep -q 'commits and pushes Skill' "$preamble"
  grep -q 'Start a new session' "$preamble"
done

# Runtime-owned Codex system skills stay local, while complete user skills
# remain eligible for sync.
ensure_skill_library
grep -Fqx '/skills/shared/.system/' "$SATCHEL_DIR/sync/.gitignore"
mkdir -p "$SATCHEL_DIR/sync/skills/shared/stable"
printf '%s\n' '---' 'name: stable' 'description: stable' '---' \
  > "$SATCHEL_DIR/sync/skills/shared/stable/SKILL.md"
git -C "$SATCHEL_DIR/sync" add -A
git -C "$SATCHEL_DIR/sync" commit -qm baseline

mkdir -p \
  "$SATCHEL_DIR/sync/skills/shared/good" \
  "$SATCHEL_DIR/sync/skills/shared/missing" \
  "$SATCHEL_DIR/sync/skills/shared/nested/.git" \
  "$SATCHEL_DIR/sync/skills/shared/escape" \
  "$SATCHEL_DIR/sync/skills/shared/.hidden" \
  "$SATCHEL_DIR/sync/skills/shared/.system/generated"
printf '%s\n' '---' 'name: good' 'description: good' '---' \
  > "$SATCHEL_DIR/sync/skills/shared/good/SKILL.md"
printf '%s\n' '---' 'name: nested' 'description: nested' '---' \
  > "$SATCHEL_DIR/sync/skills/shared/nested/SKILL.md"
printf '%s\n' '---' 'name: escape' 'description: escape' '---' \
  > "$SATCHEL_DIR/sync/skills/shared/escape/SKILL.md"
printf '%s\n' '---' 'name: hidden' 'description: hidden' '---' \
  > "$SATCHEL_DIR/sync/skills/shared/.hidden/SKILL.md"
ln -s "$tmp/outside" "$SATCHEL_DIR/sync/skills/shared/escape/outside"
printf 'generated\n' > "$SATCHEL_DIR/sync/skills/shared/.system/generated/runtime"
rm -f "$SATCHEL_DIR/sync/skills/shared/stable/SKILL.md"

repair_skill_library 1 >/dev/null 2>&1
[ -f "$SATCHEL_DIR/sync/skills/shared/good/SKILL.md" ]
[ -f "$SATCHEL_DIR/sync/skills/shared/stable/SKILL.md" ]
[ ! -e "$SATCHEL_DIR/sync/skills/shared/missing" ]
[ ! -e "$SATCHEL_DIR/sync/skills/shared/nested" ]
[ ! -e "$SATCHEL_DIR/sync/skills/shared/escape" ]
[ ! -e "$SATCHEL_DIR/sync/skills/shared/.hidden" ]
[ "$(find "$SKILL_QUARANTINE_DIR" -mindepth 1 -maxdepth 1 | wc -l)" = 5 ]
! git -C "$SATCHEL_DIR/sync" status --short | grep -q 'skills/shared/.system'
grep -q 'quarantined locally: 5' <(cmd_status 2>/dev/null)
grep -q 'skills installed: good' <(report_skill_changes 2>&1)
printf '\nupdated\n' >> "$SATCHEL_DIR/sync/skills/shared/stable/SKILL.md"
grep -q 'skills updated: stable' <(report_skill_changes 2>&1)
rm -rf -- "$SATCHEL_DIR/sync/skills/shared/stable"
grep -q 'skills removed: stable' <(report_skill_changes 2>&1)

# Ownership preparation targets only the two synced directories that agents
# may edit. Successful preparation is always quiet.
owned=()
fix_home_ownership() { owned+=("$1"); }
fix_synced_write_ownership
[ "${owned[0]}" = "$SATCHEL_DIR/sync/skills/shared" ]
[ "${owned[1]}" = "$SATCHEL_DIR/sync/machines/testbox" ]

# Without a Sync Repo Satchel still identifies itself, but must not claim a
# shared/persistent Skill Library exists.
SYNC_URL=""
compose_run_args codex "$tmp/home_unsynced" "$tmp/work"
args=" ${RUN_ARGS[*]} "
[[ "$args" == *" SATCHEL_SESSION=1 "* ]]
[[ "$args" != *" SATCHEL_SKILLS_DIR="* ]]
write_memory_file codex "$tmp/home_unsynced" "" "$tmp/work"
! grep -q '^## Satchel Skill Library$' "$tmp/home_unsynced/.codex/AGENTS.md"

printf 'ok: Satchel-native Skill Library runtime contract\n'
