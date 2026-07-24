#!/usr/bin/env bash
set -euo pipefail

# Unraid behavior had no coverage at all, because detection was a hardcoded
# read of /etc/unraid-version and the flash paths were literals. Both are now
# overridable, so the whole boot-persistence lifecycle can be exercised on an
# ordinary machine with a fake Unraid root.

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export HOME="$tmp/home"
export SATCHEL_DIR="$tmp/state"
mkdir -p "$HOME/.ssh" "$SATCHEL_DIR" "$tmp/boot" "$tmp/bin"
printf 'MACHINE=tower\nSYNC_URL=\n' > "$SATCHEL_DIR/config"

export SATCHEL_UNRAID_MARKER="$tmp/unraid-version"
export SATCHEL_UNRAID_BOOT_DIR="$tmp/boot"

source <(sed '$d' "$repo_dir/satchel")
load_config

# Detection is off until the marker exists, so ordinary machines are untouched.
# (Note the `if` form: `is_unraid && fail ...` would itself trip `set -e`.)
if is_unraid; then fail "is_unraid must be false without the marker"; fi
ensure_unraid_boot_block >/dev/null 2>&1 || fail "must be a no-op off Unraid"
[ ! -e "$tmp/boot/go" ] || fail "wrote a boot block on a non-Unraid host"
: > "$SATCHEL_UNRAID_MARKER"
is_unraid || fail "is_unraid must be true once the marker exists"

# Pretend this installation lives in a self-contained directory with a shim.
install_dir="$tmp/bin"
cp "$repo_dir/satchel" "$install_dir/satchel"; chmod 755 "$install_dir/satchel"
mkdir -p "$install_dir/.satchel"
export SATCHEL_BIN="$install_dir"
self="$install_dir/satchel"
printf '#!/usr/bin/env bash\n# satchel shim\nexec %q claude "$@"\n' "$self" > "$install_dir/claude"
chmod 755 "$install_dir/claude"
# The boot-block code resolves the installed command via satchel_self, which
# honours SATCHEL_SELF; without it $0 would be this test script.
export SATCHEL_SELF="$self"

go="$(unraid_go_file)"
[ "$go" = "$tmp/boot/go" ] || fail "go file path not derived from the boot dir: $go"
[ "$(unraid_key_dir)" = "$tmp/boot/ssh/root" ] || fail "key dir not derived from the boot dir"

# Creating the block from scratch, the way 'satchel init' now does.
printf '#!/bin/bash\n# pre-existing unraid go script\n/usr/local/emhttp/webGui/scripts/start\n' > "$go"
before="$(cat "$go")"
write_unraid_boot_block "$go" || fail "write_unraid_boot_block failed"
grep -qF "$BOOT_BLOCK_BEGIN" "$go" || fail "begin marker missing"
grep -qF "$BOOT_BLOCK_END" "$go" || fail "end marker missing"
grep -qF '/usr/local/emhttp/webGui/scripts/start' "$go" || fail "clobbered the user's existing go content"

# The block must restore the command, the key, AND known_hosts. The missing
# known_hosts line is the exact drift that existed between install.sh and
# satchel; asserting it here is what stops that recurring.
grep -q "^ln -sf .*$install_dir/satchel.* /usr/local/bin/$" "$go" || fail "block does not relink satchel"
grep -q 'mkdir -p /root/.ssh' "$go" || fail "block does not create /root/.ssh"
grep -qF "cp $tmp/boot/ssh/root/id_ed25519* /root/.ssh/" "$go" || fail "block does not restore the key"
grep -qF "cp $tmp/boot/ssh/root/known_hosts /root/.ssh/" "$go" || fail "block does not restore known_hosts"

# Rewriting is idempotent: exactly one block, no stacking on repeated runs.
write_unraid_boot_block "$go"
write_unraid_boot_block "$go"
[ "$(grep -cF "$BOOT_BLOCK_BEGIN" "$go")" = 1 ] || fail "boot block stacked on rewrite"
[ "$(grep -cF "$BOOT_BLOCK_END" "$go")" = 1 ] || fail "boot block end marker stacked"
[ "$(grep -cF '/usr/local/emhttp/webGui/scripts/start' "$go")" = 1 ] || fail "user content duplicated"

# A hand-edited block whose closing marker is gone is ambiguous: rewriting it
# could swallow the user's own lines, so it is reported and left alone.
cp "$go" "$go.bak"
printf '#!/bin/bash\n%s\nln -sf /somewhere/satchel /usr/local/bin/\nuser_line_after_broken_block\n' \
  "$BOOT_BLOCK_BEGIN" > "$go"
out="$(sync_unraid_boot_block 2>&1)"
grep -q 'no closing marker' <<< "$out" || fail "unterminated block must be reported"
grep -qF 'user_line_after_broken_block' "$go" || fail "unterminated block must be left alone"
[ "$(grep -cF "$BOOT_BLOCK_END" "$go")" = 0 ] || fail "must not silently repair the block"
out="$(remove_unraid_boot_block 2>&1)"
grep -q 'no closing marker' <<< "$out" || fail "removal must report an unterminated block too"
grep -qF 'user_line_after_broken_block' "$go" || fail "removal must not touch an unterminated block"
cp "$go.bak" "$go"

# Removal takes the block out and leaves the rest of the go script intact.
remove_unraid_boot_block >/dev/null 2>&1
if grep -qF "$BOOT_BLOCK_BEGIN" "$go"; then fail "block survived removal"; fi
grep -qF '/usr/local/emhttp/webGui/scripts/start' "$go" || fail "removal ate the user's go content"

# Key persistence copies to flash only what exists, and is idempotent.
persist_unraid_ssh quiet
[ ! -e "$tmp/boot/ssh/root/id_ed25519" ] || fail "persisted a key that does not exist"
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C test
printf 'github.com ssh-ed25519 AAAA\n' > "$HOME/.ssh/known_hosts"
persist_unraid_ssh quiet
[ -f "$tmp/boot/ssh/root/id_ed25519" ] || fail "private key not persisted to flash"
[ -f "$tmp/boot/ssh/root/id_ed25519.pub" ] || fail "public key not persisted to flash"
[ -f "$tmp/boot/ssh/root/known_hosts" ] || fail "known_hosts not persisted to flash"
persist_unraid_ssh quiet   # must not fail on a second run

# Doctor reports the Unraid facts rather than staying silent about them.
DOCTOR_PROBLEMS=0
report="$(cmd_doctor 2>&1)" || true
grep -q 'unraid: sync SSH key is backed up to flash' <<< "$report" \
  || fail "doctor did not report the persisted key"
grep -q 'no boot-persistence block' <<< "$report" \
  || fail "doctor did not report the missing boot block"
write_unraid_boot_block "$go"
DOCTOR_PROBLEMS=0
report="$(cmd_doctor 2>&1)" || true
grep -q 'boot persistence block present' <<< "$report" \
  || fail "doctor did not report the restored boot block"

# State that lives on the RAM disk is a hard failure, not a warning: it is
# silently destroyed at the next reboot.
grep -q 'is not under /mnt' <<< "$report" \
  || fail "doctor did not flag non-persistent state on Unraid"

printf 'ok: unraid detection, boot persistence, and key backup\n'
