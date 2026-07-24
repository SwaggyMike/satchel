#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export SATCHEL_DIR="$tmp/state"
mkdir -p "$HOME" "$SATCHEL_DIR/sync/.git" "$tmp/agent-home/.codex"
printf 'MACHINE=testbox\nSYNC_URL=test\n' > "$SATCHEL_DIR/config"

# Load functions without invoking main.
source <(sed '$d' "$repo_dir/satchel")
load_config

# URLs must be directly representable in Codex's generated TOML. Invalid
# synced state fails before either agent config is touched.
printf '{"servers":{"ok":{"url":"https://example.test/mcp","auth":"none"}}}\n' > "$MCP_FILE"
validate_mcp_state
mcp_url_valid "https://example.test/mcp"
! mcp_url_valid 'https://example.test/"bad'
! mcp_url_valid 'https://example.test/\bad'
printf '{"servers":{"bad":{"url":"https://example.test/\\"bad","auth":"none"}}}\n' > "$MCP_FILE"
! (validate_mcp_state 2>/dev/null)
printf '{"servers":{"bad":{"url":"https://example.test/\\nbad","auth":"none"}}}\n' > "$MCP_FILE"
! (validate_mcp_state 2>/dev/null)

# The registry is synced, so a newer Satchel on another machine may add fields
# this version does not know. Unknown keys are ignored; required ones are still
# enforced, so a genuinely broken entry cannot slip through.
printf '{"servers":{"ok":{"url":"https://example.test/mcp","auth":"none","timeout":30}},"version":2}\n' > "$MCP_FILE"
validate_mcp_state
printf '{"servers":{"ok":{"auth":"none"}}}\n' > "$MCP_FILE"
! (validate_mcp_state 2>/dev/null)                       # url is still required
printf '{"servers":{"ok":{"url":"https://example.test/mcp","auth":"basic"}}}\n' > "$MCP_FILE"
! (validate_mcp_state 2>/dev/null)                       # auth is still constrained

# A valid managed block is replaced while unrelated settings on both sides
# remain intact.
printf '{"servers":{"ok":{"url":"https://example.test/mcp","auth":"none"}}}\n' > "$MCP_FILE"
codex_home="$tmp/codex"
mkdir -p "$codex_home/.codex"
cat > "$codex_home/.codex/config.toml" <<'EOF'
sandbox_mode = "workspace-write"
# >>> satchel mcp >>>
old managed content
# <<< satchel mcp <<<
model_reasoning_effort = "low"
EOF
materialize_mcp codex "$codex_home"
grep -q '^sandbox_mode = "workspace-write"$' "$codex_home/.codex/config.toml"
grep -q '^model_reasoning_effort = "low"$' "$codex_home/.codex/config.toml"
grep -q '^url = "https://example.test/mcp"$' "$codex_home/.codex/config.toml"
! grep -q 'old managed content' "$codex_home/.codex/config.toml"

# An interrupted or manually damaged marker pair never causes the tail of the
# user's Codex config to be discarded.
cat > "$codex_home/.codex/config.toml" <<'EOF'
sandbox_mode = "workspace-write"
# >>> satchel mcp >>>
incomplete managed content
model_reasoning_effort = "high"
EOF
cp "$codex_home/.codex/config.toml" "$tmp/config-before"
! (materialize_mcp codex "$codex_home" 2>/dev/null)
cmp "$tmp/config-before" "$codex_home/.codex/config.toml"
[ ! -e "$codex_home/.codex/config.toml.tmp" ]
[ ! -e "$codex_home/.codex/config.toml.rescued" ]
[ ! -e "$codex_home/.codex/config.toml.new" ]

printf '{"servers":{"homeassistant":{"url":"https://ha.example.test/api/mcp","auth":"none"}}}\n' \
  > "$MCP_FILE"

# Codex persists settings it learns during a session immediately before a
# trailing comment. When Satchel's managed marker is the final comment, those
# settings can land inside the managed block. Re-materialization must rescue
# them rather than deleting project trust and per-tool approval choices.
cat > "$tmp/agent-home/.codex/config.toml" <<'EOF'
model = "test-model"
# >>> satchel mcp >>>
# managed by satchel — rebuilt every session start
[mcp_servers.homeassistant]
url = "https://old.example.test/api/mcp"

[mcp_servers.homeassistant.tools.todo_get_items]
approval_mode = "approve"

[projects."/work/project"]
trust_level = "trusted"
# <<< satchel mcp <<<
EOF

materialize_mcp codex "$tmp/agent-home"
cfg="$tmp/agent-home/.codex/config.toml"

[ "$(grep -c '^# >>> satchel mcp >>>$' "$cfg")" -eq 1 ]
[ "$(grep -c '^# <<< satchel mcp <<<$' "$cfg")" -eq 1 ]
[ "$(grep -c '^url = "https://ha.example.test/api/mcp"$' "$cfg")" -eq 1 ]
grep -q '^\[mcp_servers\.homeassistant\.tools\.todo_get_items\]$' "$cfg"
grep -q '^approval_mode = "approve"$' "$cfg"
grep -q '^\[projects\."/work/project"\]$' "$cfg"
grep -q '^trust_level = "trusted"$' "$cfg"

close_line="$(grep -n '^# <<< satchel mcp <<<$' "$cfg" | cut -d: -f1)"
tool_line="$(grep -n '^\[mcp_servers\.homeassistant\.tools\.todo_get_items\]$' "$cfg" | cut -d: -f1)"
project_line="$(grep -n '^\[projects\."/work/project"\]$' "$cfg" | cut -d: -f1)"
[ "$close_line" -lt "$tool_line" ]
[ "$close_line" -lt "$project_line" ]

cp "$cfg" "$tmp/once.toml"
materialize_mcp codex "$tmp/agent-home"
cmp -s "$tmp/once.toml" "$cfg"

# Bearer values enter Codex through inherited variables by name, never through
# the container engine's process arguments. A local token still overrides sync.
printf '{"servers":{"homeassistant":{"url":"https://ha.example.test/api/mcp","auth":"bearer"}}}\n' \
  > "$MCP_FILE"
printf 'homeassistant=synced-secret\n' > "$SYNC_TOKENS_FILE"
RUN_ARGS=()
compose_codex_mcp_env
args=" ${RUN_ARGS[*]} "
[[ "$args" == *" -e SATCHEL_MCP_TOKEN_HOMEASSISTANT "* ]]
[[ "$args" != *"synced-secret"* ]]
[ "$SATCHEL_MCP_TOKEN_HOMEASSISTANT" = synced-secret ]

printf 'homeassistant=local-secret\n' > "$LOCAL_TOKENS_FILE"
RUN_ARGS=()
compose_codex_mcp_env
[[ " ${RUN_ARGS[*]} " != *"local-secret"* ]]
[ "$SATCHEL_MCP_TOKEN_HOMEASSISTANT" = local-secret ]

rm -f "$LOCAL_TOKENS_FILE" "$SYNC_TOKENS_FILE"
RUN_ARGS=()
compose_codex_mcp_env
[ -z "${SATCHEL_MCP_TOKEN_HOMEASSISTANT+x}" ]
[[ " ${RUN_ARGS[*]} " != *" SATCHEL_MCP_TOKEN_HOMEASSISTANT "* ]]

printf 'ok: MCP validation, materialization, and runtime env secrecy\n'
