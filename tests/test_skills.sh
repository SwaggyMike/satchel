#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_dir/tests/lib.sh"
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
  [[ "$args" == *" SATCHEL_SESSION_MODE=sandbox "* ]]
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
printf '{"skills":{"stable":{"source":"example/stable"}}}\n' \
  > "$SATCHEL_DIR/sync/skills/shared/skills-lock.json"
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
printf '{"installer":"example"}\n' \
  > "$SATCHEL_DIR/sync/skills/shared/installer-state.json"
ln -s "$tmp/outside" "$SATCHEL_DIR/sync/skills/shared/escape/outside"
printf 'generated\n' > "$SATCHEL_DIR/sync/skills/shared/.system/generated/runtime"
rm -f "$SATCHEL_DIR/sync/skills/shared/stable/SKILL.md"
printf '{broken\n' > "$SATCHEL_DIR/sync/skills/shared/skills-lock.json"

repair_output="$(repair_skill_library 1 2>&1)"
[ -f "$SATCHEL_DIR/sync/skills/shared/good/SKILL.md" ]
[ -f "$SATCHEL_DIR/sync/skills/shared/stable/SKILL.md" ]
[ ! -e "$SATCHEL_DIR/sync/skills/shared/missing" ]
[ ! -e "$SATCHEL_DIR/sync/skills/shared/nested" ]
[ ! -e "$SATCHEL_DIR/sync/skills/shared/escape" ]
[ ! -e "$SATCHEL_DIR/sync/skills/shared/.hidden" ]
[ ! -e "$SATCHEL_DIR/sync/skills/shared/installer-state.json" ]
[ "$(jq -r '.skills.stable.source' "$SATCHEL_DIR/sync/skills/shared/skills-lock.json")" = example/stable ]
[ -n "$(find "$SKILL_QUARANTINE_DIR" -mindepth 1 -maxdepth 1 -name '*--skills-lock.json' -print -quit)" ]
[ -n "$(find "$SKILL_QUARANTINE_DIR" -mindepth 1 -maxdepth 1 -name '*--installer-state.json' -print -quit)" ]
grep -q "unexpected Skill Library file 'installer-state.json' was quarantined; it may be installer metadata rather than a skill" \
  <<< "$repair_output"
[ "$(find "$SKILL_QUARANTINE_DIR" -mindepth 1 -maxdepth 1 | wc -l)" = 7 ]
if git -C "$SATCHEL_DIR/sync" status --short | grep -q 'skills/shared/.system'; then
  fail "Codex .system skills leaked into the Sync Repo"
fi
grep -q 'quarantined locally: 7' <(cmd_status 2>/dev/null)
printf '{"skills":{"stable":{"source":"example/stable"},"good":{"source":"example/good"}}}\n' \
  > "$SATCHEL_DIR/sync/skills/shared/skills-lock.json"
skill_changes="$(report_skill_changes 2>&1)"
grep -q 'skills installed: good' <<< "$skill_changes"
refute grep -q 'skills-lock.json' <<< "$skill_changes"
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

# The host CLI lists active skills and supports both exact and numbered
# caravan-wide removal. Pull happens first; lock metadata is never rewritten.
for name in alpha zeta; do
  mkdir -p "$SATCHEL_DIR/sync/skills/shared/$name"
  printf '%s\n' '---' "name: $name" "description: $name" '---' \
    > "$SATCHEL_DIR/sync/skills/shared/$name/SKILL.md"
done
printf '{"skills":{"alpha":{"source":"example/alpha"},"good":{"source":"example/good"}}}\n' \
  > "$SATCHEL_DIR/sync/skills/shared/skills-lock.json"
git_sync add -A
git_sync commit -qm "skills command baseline"

pull_log="$tmp/skills-pulls"
push_log="$tmp/skills-pushes"
quiet_pull() { printf 'pull\n' >> "$pull_log"; }
quiet_push() {
  git_sync add -A
  git_sync diff --cached --quiet || git_sync commit -qm "$1"
  printf '%s\n' "$1" >> "$push_log"
}

cmd_skills > "$tmp/skills-list" 2> "$tmp/skills-list-err"
[ "$(cat "$tmp/skills-list")" = $'  alpha\n  good\n  zeta' ]
grep -q "7 quarantined skill attempt(s).*satchel status" "$tmp/skills-list-err"
cmd_skills list > "$tmp/skills-list-explicit" 2> /dev/null
cmp "$tmp/skills-list" "$tmp/skills-list-explicit"

lock_hash="$(git hash-object "$SATCHEL_DIR/sync/skills/shared/skills-lock.json")"
cmd_skills remove alpha > "$tmp/remove-alpha-out" 2> "$tmp/remove-alpha-err"
[ ! -e "$SATCHEL_DIR/sync/skills/shared/alpha" ]
[ "$(git_sync log -1 --format=%s)" = "skills: remove alpha" ]
grep -q "skills-lock.json still appears to reference 'alpha'" "$tmp/remove-alpha-err"
[ "$(git hash-object "$SATCHEL_DIR/sync/skills/shared/skills-lock.json")" = "$lock_hash" ]

cmd_skills remove <<< 2 > "$tmp/remove-picker-out" 2> "$tmp/remove-picker-err"
[ ! -e "$SATCHEL_DIR/sync/skills/shared/zeta" ]
grep -q '1).*good' "$tmp/remove-picker-err"
grep -q '2).*zeta' "$tmp/remove-picker-err"
[ "$(git_sync log -1 --format=%s)" = "skills: remove zeta" ]
grep -q '^skills: remove alpha$' "$push_log"
grep -q '^skills: remove zeta$' "$push_log"

if (cmd_skills remove missing >/dev/null 2>&1); then
  printf 'missing skill removal unexpectedly succeeded\n' >&2
  exit 1
fi
if (cmd_skills remove ../good >/dev/null 2>&1); then
  printf 'unsafe skill name unexpectedly succeeded\n' >&2
  exit 1
fi
quiet_pull() { return 1; }
if (cmd_skills remove good >/dev/null 2>&1); then
  printf 'skill removal continued after pull recovery failure\n' >&2
  exit 1
fi
[ -d "$SATCHEL_DIR/sync/skills/shared/good" ]
[ "$(wc -l < "$pull_log")" -ge 6 ]

# Without a Sync Repo Satchel still identifies itself, but must not claim a
# shared/persistent Skill Library exists.
SYNC_URL=""
compose_run_args codex "$tmp/home_unsynced" "$tmp/work"
args=" ${RUN_ARGS[*]} "
[[ "$args" == *" SATCHEL_SESSION=1 "* ]]
[[ "$args" == *" SATCHEL_SESSION_MODE=sandbox "* ]]
[[ "$args" != *" SATCHEL_SKILLS_DIR="* ]]
write_memory_file codex "$tmp/home_unsynced" "" "$tmp/work"
refute grep -q '^## Satchel Skill Library$' "$tmp/home_unsynced/.codex/AGENTS.md"

printf 'ok: Satchel-native Skill Library runtime contract\n'
