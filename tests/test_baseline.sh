#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export SATCHEL_DIR="$tmp/state"
mkdir -p "$HOME" "$SATCHEL_DIR/sync/.git" "$SATCHEL_DIR/sync/machines/testbox"
printf 'MACHINE=testbox\nSYNC_URL=test\nSATCHEL_UID=1000\nSATCHEL_GID=1000\n' > "$SATCHEL_DIR/config"

source <(sed '$d' "$repo_dir/satchel")
load_config
ENGINE=docker

# Init can detect an image that was just built and avoid asking to rebuild it.
fake_engine="$tmp/fake-engine"
printf '#!/usr/bin/env bash\n[ "$1 $2" = "image inspect" ]\n' > "$fake_engine"
chmod 755 "$fake_engine"
ENGINE="$fake_engine"
image_exists
ENGINE=docker

notes="$(baseline_notes_file)"
[ -z "$(baseline_marker_version)" ]
# Version 1 stored the marker in notes.md; keep recognizing it during the
# one-time migration to the split inventory/notes layout.
printf '<!-- satchel-machine-baseline version=1 generated=2026-07-22T00:00:00Z -->\n# Machine baseline\n' > "$notes"
[ "$(baseline_marker_version)" = 1 ]
inventory="$(baseline_inventory_file)"
printf '<!-- satchel-machine-baseline version=2 generated=2026-07-23T00:00:00Z -->\n# Inventory\n' > "$inventory"
[ "$(baseline_marker_version)" = 2 ]
[ "$(baseline_generated_at)" = 2026-07-23T00:00:00Z ]

mkdir -p "$tmp/claude/.claude" "$tmp/codex/.codex"
! baseline_authenticated claude "$tmp/claude"
# A .claude.json holding only materialized MCP config is not a login...
printf '{ "mcpServers": { "x": { "url": "http://x" } } }\n' > "$tmp/claude/.claude.json"
! baseline_authenticated claude "$tmp/claude"
# ...but auth material inside it is (API-key imports have no .credentials.json).
printf '{ "primaryApiKey": "not-a-real-key" }\n' > "$tmp/claude/.claude.json"
baseline_authenticated claude "$tmp/claude"
printf '{ "oauthAccount": { "emailAddress": "user@example.test" } }\n' > "$tmp/claude/.claude.json"
baseline_authenticated claude "$tmp/claude"
rm "$tmp/claude/.claude.json"
touch "$tmp/claude/.claude/.credentials.json" "$tmp/codex/.codex/auth.json"
baseline_authenticated claude "$tmp/claude"
baseline_authenticated codex "$tmp/codex"

# Baseline refreshes launched by `satchel init` must perform the same agent-
# home ownership repair as ordinary sessions before Codex reads config.toml.
repaired=()
fix_home_ownership() { repaired+=("$1"); }
prepare_baseline_home "$tmp/codex"
[ "${repaired[0]}" = "$tmp/codex" ]
[ "${repaired[1]}" = "$SATCHEL_DIR/sync/machines/testbox" ]

compose_baseline_run_args claude "$tmp/claude"
[[ " ${RUN_ARGS[*]} " == *" /:/host:ro "* ]]
[[ " ${RUN_ARGS[*]} " != *"SATCHEL_MCP_TOKEN"* ]]
[[ " ${RUN_ARGS[*]} " == *"/machines/testbox:/home/satchel/machine"* ]]
[[ " ${RUN_ARGS[*]} " != *" --privileged "* ]]
[[ " ${RUN_ARGS[*]} " != *" --pid=host "* ]]
[[ " ${RUN_ARGS[*]} " != *"docker.sock"* ]]

# A codex baseline session gets the registered MCP bearer tokens as env vars —
# its home carries the same materialized config.toml as ordinary sessions,
# and codex fails MCP startup when the named env var is missing.
printf '{ "servers": { "homeassistant": { "url": "http://ha.test", "auth": "bearer" } } }\n' > "$SATCHEL_DIR/sync/mcp.json"
printf 'homeassistant=sekrit\n' > "$SATCHEL_DIR/sync/mcp-tokens.env"
compose_baseline_run_args codex "$tmp/codex"
[[ " ${RUN_ARGS[*]} " == *" SATCHEL_MCP_TOKEN_HOMEASSISTANT=sekrit "* ]]

old="$tmp/old" new="$tmp/new"
printf '# Notes\n- hostname: testbox\n' > "$old"
printf '# Notes\n- hostname: testbox\n- storage: zfs\n' > "$new"
baseline_secret_scan "$old" "$new"
printf '# Notes\n- hostname: testbox\n- api_token = abcdefghijklmnopqrstuvwxyz012345\n' > "$new"
! baseline_secret_scan "$old" "$new"
printf '# Notes\n- hostname: testbox\n- https://admin:correct-horse-battery-staple@example.test\n' > "$new"
! baseline_secret_scan "$old" "$new"

# Baseline approval can now write inventory, notes, and guides; newly-added
# content in every knowledge tier gets the same secret scan.
old_tree="$tmp/old-tree" new_tree="$tmp/new-tree"
mkdir -p "$old_tree/guides" "$new_tree/guides"
printf '# Notes\n- use Podman\n' > "$old_tree/notes.md"
cp "$old_tree/notes.md" "$new_tree/notes.md"
printf '<!-- satchel-machine-baseline version=2 generated=2026-07-23T00:00:00Z -->\n# Inventory\n' > "$new_tree/inventory.md"
printf '# Time Machine\n- Verify the Avahi service after reboot.\n' > "$new_tree/guides/time-machine.md"
baseline_secret_scan_tree "$old_tree" "$new_tree"
printf '# Time Machine\n- password = definitely-not-safe\n' > "$new_tree/guides/time-machine.md"
! baseline_secret_scan_tree "$old_tree" "$new_tree"

printf 'ok: machine baseline state, mounts, auth, and secret scan\n'
