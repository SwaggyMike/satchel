#!/usr/bin/env bash
# Satchel installer:
#   curl -fsSL https://raw.githubusercontent.com/SwaggyMike/satchel/main/install.sh | bash
#
# Installs the `satchel` script plus the `claude` and `codex` shims (thin
# wrappers that exec `satchel claude` / `satchel codex`, so sessions feel like
# the real CLIs).
set -euo pipefail

RAW="https://raw.githubusercontent.com/SwaggyMike/satchel"

say() { printf 'install: %s\n' "$*" >&2; }
die() { printf 'install: error: %s\n' "$*" >&2; exit 1; }

# Unraid-only messages get their own color and prefix: they concern the
# flash-backed boot config, not the normal install flow, and should be
# recognizable as such at a glance.
if [ -t 2 ] && [ "${TERM:-}" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
  U_ON=$'\033[1;33m'; U_OFF=$'\033[0m'
else
  U_ON=""; U_OFF=""
fi
usay() { printf '%s%s%s\n' "$U_ON" "install (unraid): $*" "$U_OFF" >&2; }
uask() { printf '%s%s%s' "$U_ON" "install (unraid): $*" "$U_OFF" >&2; }

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v git  >/dev/null 2>&1 || die "git is required"
command -v jq   >/dev/null 2>&1 || die "jq is required"
command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1 \
  || die "docker or podman is required"

# SATCHEL_BIN puts everything — script, shims, and a sibling .satchel state
# dir — into one directory, making the install self-contained and
# relocatable. For OSes whose rootfs is rebuilt at boot (Unraid & co):
# point it at persistent storage and only the PATH entry needs restoring.
#
# On Unraid don't wait for the user to know that: a default install lands on
# the RAM disk and vanishes at reboot, so ask for a persistent directory.
if [ -z "${SATCHEL_BIN:-}" ] && [ -f /etc/unraid-version ]; then
  default_bin=/mnt/user/appdata/satchel
  if { : </dev/tty; } 2>/dev/null; then
    usay "Unraid detected — / is rebuilt at every boot, so a default install would vanish."
    uask "install directory [$default_bin]: "
    IFS= read -r answer </dev/tty || answer=""
    SATCHEL_BIN="${answer:-$default_bin}"
  else
    die "Unraid detected: a default install is wiped at reboot — rerun with SATCHEL_BIN=$default_bin (or another persistent path)"
  fi
  # mkdir -p would happily build the whole chain on the RAM disk; creating
  # only the last component catches a stopped array or a typo.
  [ -d "$(dirname "$SATCHEL_BIN")" ] \
    || die "parent of $SATCHEL_BIN does not exist — is the array started?"
fi
if [ -n "${SATCHEL_BIN:-}" ]; then
  BIN="$SATCHEL_BIN"; mkdir -p "$BIN"
  STATE_DIR="${SATCHEL_DIR:-$BIN/.satchel}"
  mkdir -p "$STATE_DIR"  # existing sibling dir is what turns detection on
elif [ -w /usr/local/bin ]; then BIN=/usr/local/bin; STATE_DIR="${SATCHEL_DIR:-$HOME/.satchel}"
else BIN="$HOME/.local/bin"; mkdir -p "$BIN"; STATE_DIR="${SATCHEL_DIR:-$HOME/.satchel}"; fi

# When run from a checkout, install the local copy; otherwise download main.
# The installed commit is recorded in ~/.satchel/script-sha so 'satchel
# update' can show the commits each update brings.
tmp="$(mktemp)"
sha=""
src="$(cd "$(dirname "${BASH_SOURCE[0]:-/nonexistent}")" 2>/dev/null && pwd || true)"
if [ -n "$src" ] && [ -f "$src/satchel" ]; then
  cp "$src/satchel" "$tmp"
  say "installing from local checkout"
  # Only a clean checkout's HEAD truthfully describes the installed script.
  if git -C "$src" diff --quiet HEAD -- satchel 2>/dev/null; then
    sha="$(git -C "$src" rev-parse HEAD 2>/dev/null || true)"
  fi
else
  # Resolve main to a commit and download by SHA: the raw 'main' URL sits
  # behind a ~5 min CDN cache and will happily serve a stale script.
  sha="$(curl -fsSL "https://api.github.com/repos/SwaggyMike/satchel/commits/main" 2>/dev/null | jq -r '.sha // empty' || true)"
  curl -fsSL "$RAW/${sha:-main}/satchel" -o "$tmp"
fi
bash -n "$tmp" || die "downloaded satchel script does not parse"
install -m 755 "$tmp" "$BIN/satchel"
rm -f "$tmp"
if [ -n "$sha" ]; then
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$sha" > "$STATE_DIR/script-sha"
fi
say "installed $BIN/satchel${sha:+ (commit ${sha:0:7})}"

shims_installed=()
for agent in claude codex; do
  shim="$BIN/$agent"
  # -e is false for dangling symlinks. Treat -L as existing too, otherwise
  # redirecting into one follows its missing target and aborts the installer.
  if { [ -e "$shim" ] || [ -L "$shim" ]; } && ! grep -q "satchel shim\|exec satchel" "$shim" 2>/dev/null; then
    say "SKIPPED shim '$agent': $shim exists and is not a satchel shim."
    say "  remove it (or the host CLI it points to) and rerun to route '$agent' through satchel."
    continue
  fi
  # Absolute path, not PATH lookup: shims keep working from a boot script or
  # cron before the user's PATH is set up.
  printf '#!/usr/bin/env bash\n# satchel shim\nexec %q %s "$@"\n' "$BIN/satchel" "$agent" > "$shim"
  chmod 755 "$shim"
  say "installed shim $shim"
  shims_installed+=("$shim")
done

if [ -f /etc/unraid-version ] && [ "$BIN" != /usr/local/bin ]; then
  # Finish the job on Unraid: /usr/local/bin and /root/.ssh are rebuilt at
  # every boot, so the PATH links and the sync SSH key (which satchel keeps a
  # copy of on flash) must be restored by /boot/config/go. Offer to write
  # that block; the marker keeps reruns from stacking duplicates.
  go=/boot/config/go
  marker="# >>> satchel boot persistence >>>"
  add_go=n
  if grep -qsF "$marker" "$go"; then
    usay "boot persistence already set up in $go"
  elif { : </dev/tty; } 2>/dev/null; then
    uask "add boot persistence to $go (PATH links + sync SSH key restore)? [Y/n] "
    IFS= read -r reply </dev/tty || reply=""
    case "$reply" in [Nn]*) : ;; *) add_go=y ;; esac
  fi
  if [ "$add_go" = y ]; then
    {
      printf '\n%s\n' "$marker"
      printf 'ln -sf %s' "$BIN/satchel"
      for s in ${shims_installed[@]+"${shims_installed[@]}"}; do printf ' %s' "$s"; done
      printf ' /usr/local/bin/\n'
      printf 'mkdir -p /root/.ssh && chmod 700 /root/.ssh\n'
      printf 'cp /boot/config/ssh/root/id_ed25519* /root/.ssh/ 2>/dev/null && chmod 600 /root/.ssh/id_ed25519\n'
      printf '# <<< satchel boot persistence <<<\n'
    } >> "$go"
    usay "added boot persistence to $go"
    # Make this boot look like the next one will.
    ln -sf "$BIN/satchel" ${shims_installed[@]+"${shims_installed[@]}"} /usr/local/bin/ 2>/dev/null || true
  elif ! grep -qsF "$marker" "$go"; then
    usay "NOTE: to survive reboots, add to $go:"
    usay "  ln -sf $BIN/satchel ${shims_installed[*]-} /usr/local/bin/"
    usay "  (and persist the sync SSH key — see the Unraid section of the README)"
  fi
else
  case ":$PATH:" in
    *":$BIN:"*) : ;;
    *)
      say "NOTE: $BIN is not on your PATH yet."
      say "  run:  export PATH=\"$BIN:\$PATH\""
      say "  (on Debian/Ubuntu a fresh login picks it up automatically once the directory exists)"
      ;;
  esac
fi

# Chain straight into setup. Under `curl | bash` stdin is the script itself,
# so give init the real terminal; skip when non-interactive (CI) or already
# set up (this is an update run).
initialized=0
if [ -f "$STATE_DIR/config" ]; then
  SYNC_URL=""
  . "$STATE_DIR/config" 2>/dev/null || true
  # a configured sync URL without a clone means a previous init didn't finish
  if [ -z "$SYNC_URL" ] || [ -d "$STATE_DIR/sync/.git" ]; then initialized=1; fi
fi
if [ "$initialized" -eq 1 ]; then
  say "done — already initialized ('satchel status' to check the fleet)"
elif { : </dev/tty; } 2>/dev/null; then
  say "starting setup…"
  "$BIN/satchel" init </dev/tty || say "setup did not finish — fix the issue above and run: satchel init"
else
  say "done. next: satchel init"
fi
