#!/usr/bin/env bash
# Generated from src/*.sh by scripts/build.sh; do not edit directly.
# satchel — Satchel: run AI coding agents (Claude Code, Codex) in
# disposable containers, with handoffs, MCP servers, and skills synced
# between machines through a private git repo.
#
# One script, no daemon, plain files. See CONTEXT.md for the vocabulary
# (Session, Sync Repo, Handoff, MCP Registry, Skill Library, Host Session)
# and docs/adr/ for why things are the way they are.
set -euo pipefail

SATCHEL_VERSION="2.0.0"
SATCHEL_REPO="SwaggyMike/satchel"

# State defaults to ~/.satchel, but a .satchel directory next to the script
# wins: that makes an install self-contained and relocatable, for OSes whose
# rootfs is rebuilt at boot (Unraid & co) — script, shims, and state then
# sit together on persistent storage. An explicit SATCHEL_DIR beats both.
if [ -z "${SATCHEL_DIR:-}" ] && [ -d "$(dirname "$(readlink -f "$0")")/.satchel" ]; then
  SATCHEL_DIR="$(dirname "$(readlink -f "$0")")/.satchel"
fi
SATCHEL_DIR="${SATCHEL_DIR:-$HOME/.satchel}"
CONFIG_FILE="$SATCHEL_DIR/config"
SYNC_DIR="$SATCHEL_DIR/sync"
HOMES_DIR="$SATCHEL_DIR/home"
LOCAL_TOKENS_FILE="$SATCHEL_DIR/mcp-tokens.local.env"
SCRIPT_SHA_FILE="$SATCHEL_DIR/script-sha"
INSTALL_PATH_FILE="$SATCHEL_DIR/install-path"
SKILL_QUARANTINE_DIR="$SATCHEL_DIR/quarantine/skills"
IMAGE_AGENTS_FILE="$SATCHEL_DIR/image-agents"
IMAGE="localhost/satchel:latest"
MANAGED_CONTAINER_LABEL="io.github.swaggymike.satchel.managed=true"

# Set by load_config / flags.
MACHINE=""
SYNC_URL=""
SATCHEL_UID=""
SATCHEL_GID=""
HOST_MODE=0
UNSAFE_HOME=0
WITH_DIRS=()
ENGINE=""
BASELINE_VERSION=2
MACHINE_NOTES_WORD_LIMIT=750
HANDOFF_RETENTION=10
SYNC_BLOCK_REASON=""
# Set when the Sync Repo is broken beyond automatic repair. Sessions still run;
# only syncing stops. See degrade_sync.
SYNC_DEGRADED=0
SESSION_STAMP=""
BASELINE_LAUNCH_OUTCOME="continue"
BASELINE_LAUNCH_STATUS=0

# ---------------------------------------------------------------- helpers
