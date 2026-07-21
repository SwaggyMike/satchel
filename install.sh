#!/usr/bin/env bash
# ContextCrate installer:
#   curl -fsSL https://raw.githubusercontent.com/SwaggyMike/contextcrate/main/install.sh | bash
#
# Installs the `crate` script plus the `claude` and `codex` shims (thin
# wrappers that exec `crate claude` / `crate codex`, so sessions feel like
# the real CLIs).
set -euo pipefail

RAW="https://raw.githubusercontent.com/SwaggyMike/contextcrate/main"

say() { printf 'install: %s\n' "$*" >&2; }
die() { printf 'install: error: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v git  >/dev/null 2>&1 || die "git is required"
command -v jq   >/dev/null 2>&1 || die "jq is required"
command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 \
  || die "docker or podman is required"

if [ -w /usr/local/bin ]; then BIN=/usr/local/bin
else BIN="$HOME/.local/bin"; mkdir -p "$BIN"; fi

# When run from a checkout, install the local copy; otherwise download main.
tmp="$(mktemp)"
src="$(cd "$(dirname "${BASH_SOURCE[0]:-/nonexistent}")" 2>/dev/null && pwd || true)"
if [ -n "$src" ] && [ -f "$src/crate" ]; then
  cp "$src/crate" "$tmp"
  say "installing from local checkout"
else
  curl -fsSL "$RAW/crate" -o "$tmp"
fi
bash -n "$tmp" || die "downloaded crate script does not parse"
install -m 755 "$tmp" "$BIN/crate"
rm -f "$tmp"
say "installed $BIN/crate"

for agent in claude codex; do
  shim="$BIN/$agent"
  if [ -e "$shim" ] && ! grep -q "exec crate" "$shim" 2>/dev/null; then
    say "SKIPPED shim '$agent': $shim exists and is not a crate shim."
    say "  remove it (or the host CLI it points to) and rerun to route '$agent' through crate."
    continue
  fi
  printf '#!/usr/bin/env bash\nexec crate %s "$@"\n' "$agent" > "$shim"
  chmod 755 "$shim"
  say "installed shim $shim"
done

case ":$PATH:" in
  *":$BIN:"*) : ;;
  *)
    say "NOTE: $BIN is not on your PATH yet."
    say "  run:  export PATH=\"$BIN:\$PATH\""
    say "  (on Debian/Ubuntu a fresh login picks it up automatically once the directory exists)"
    ;;
esac

# Chain straight into setup. Under `curl | bash` stdin is the script itself,
# so give init the real terminal; skip when non-interactive (CI) or already
# set up (this is an update run).
initialized=0
if [ -f "$HOME/.contextcrate/config" ]; then
  SYNC_URL=""
  # crate's own config, plain sourceable bash
  . "$HOME/.contextcrate/config" 2>/dev/null || true
  # a configured sync URL without a clone means a previous init didn't finish
  if [ -z "$SYNC_URL" ] || [ -d "$HOME/.contextcrate/sync/.git" ]; then initialized=1; fi
fi
if [ "$initialized" -eq 1 ]; then
  say "done — already initialized ('crate status' to check the fleet)"
elif { : </dev/tty; } 2>/dev/null; then
  say "starting setup…"
  "$BIN/crate" init </dev/tty || say "setup did not finish — fix the issue above and run: crate init"
else
  say "done. next: crate init"
fi
