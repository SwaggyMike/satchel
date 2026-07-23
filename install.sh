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

# Both current marked shims and the original `exec satchel <agent>` wrappers
# belong to Satchel. Keep this predicate aligned with the installed command.
is_satchel_shim() {
  [ -f "$1" ] || return 1
  grep -qs '^# satchel shim$' "$1" \
    || grep -qsE '^exec[[:space:]]+satchel[[:space:]]+(claude|codex)([[:space:]]|$)' "$1"
}

# Unraid-only messages get their own prefix: they concern the flash-backed
# boot config, not the normal install flow, and should read as such.
usay() { printf 'install (unraid): %s\n' "$*" >&2; }
uask() { printf 'install (unraid): %s' "$*" >&2; }

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
  # SATCHEL_BIN names a directory. Putting a directory named "satchel" inside
  # a PATH entry makes shells resolve that directory as the satchel command.
  candidate="${SATCHEL_BIN%/}"
  if [ "${candidate##*/}" = satchel ]; then
    candidate_parent="${candidate%/*}"
    [ "$candidate_parent" != "$candidate" ] || candidate_parent=.
    old_ifs="$IFS"; IFS=:
    for path_dir in $PATH; do
      if [ "${path_dir%/}" = "${candidate_parent%/}" ]; then
        IFS="$old_ifs"
        die "SATCHEL_BIN names a directory, but $candidate occupies the 'satchel' command path. Omit SATCHEL_BIN for a normal install, or choose a self-contained directory outside PATH (for example, \$HOME/.local/share/satchel)."
      fi
    done
    IFS="$old_ifs"
  fi
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
mkdir -p "$STATE_DIR"
printf '%s\n' "$(readlink -f "$BIN/satchel")" > "$STATE_DIR/install-path"
say "installed $BIN/satchel${sha:+ (commit ${sha:0:7})}"

shims_installed=()
install_shims="${SATCHEL_SHIMS:-y}"
if [ "$install_shims" = y ] && { : </dev/tty; } 2>/dev/null; then
  printf 'install: %s' "Redirect claude and codex commands through Satchel? [Y/n] " >&2
  IFS= read -r shim_reply </dev/tty || shim_reply=""
  case "$shim_reply" in [Nn]*) install_shims=n ;; esac
  if [ "$install_shims" = y ]; then
    say "  When enabled, typing 'claude' or 'codex' will launch Satchel sessions."
    say "  You can change this later with 'satchel link' and 'satchel unlink'."
  fi
fi
if [ "$install_shims" = y ]; then
  for agent in claude codex; do
    shim="$BIN/$agent"
    # -e is false for dangling symlinks. Treat -L as existing too, otherwise
    # redirecting into one follows its missing target and aborts the installer.
    if { [ -e "$shim" ] || [ -L "$shim" ]; } && ! is_satchel_shim "$shim"; then
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
else
  say "skipped shims — run 'satchel link' later to redirect claude/codex through Satchel"
fi

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
  say "already initialized — ensuring the container image is ready…"
  if ! "$BIN/satchel" image; then
    printf -v retry '%q image' "$BIN/satchel"
    say "ERROR: Satchel was installed, but the container image build failed."
    say "retry: $retry"
    exit 1
  fi
  say "done — ready to launch claude or codex"
elif { : </dev/tty; } 2>/dev/null; then
  say "starting setup…"
  "$BIN/satchel" init </dev/tty || say "setup did not finish — fix the issue above and run: satchel init"
else
  say "done. next: satchel init"
fi
