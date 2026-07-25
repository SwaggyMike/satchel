#!/usr/bin/env bash
set -euo pipefail

# Unraid behavior had no coverage at all, because detection was a hardcoded
# read of /etc/unraid-version and the flash paths were literals. Both are now
# overridable, so the whole boot-persistence lifecycle can be exercised on an
# ordinary machine with a fake Unraid root.

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_dir/tests/lib.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export HOME="$tmp/home"
export SATCHEL_DIR="$tmp/state"
mkdir -p "$HOME/.ssh" "$SATCHEL_DIR" "$tmp/boot" "$tmp/bin" "$tmp/live-bin"
printf 'MACHINE=tower\nSYNC_URL=\n' > "$SATCHEL_DIR/config"

export SATCHEL_UNRAID_MARKER="$tmp/unraid-version"
export SATCHEL_UNRAID_BOOT_DIR="$tmp/boot"
export SATCHEL_UNRAID_LIVE_BIN_DIR="$tmp/live-bin"

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
[ -L "$tmp/live-bin/satchel" ] || fail "current-boot command link was not written inside the fixture"
[ "$(readlink "$tmp/live-bin/satchel")" = "$self" ] || fail "fixture command link points at the wrong install"

# The block must restore the command, the key, AND known_hosts. The missing
# known_hosts line is the exact drift that existed between install.sh and
# satchel; asserting it here is what stops that recurring.
grep -q "^ln -sf .*$install_dir/satchel.* /usr/local/bin/$" "$go" || fail "block does not relink satchel"
grep -q 'mkdir -p /root/.ssh' "$go" || fail "block does not create /root/.ssh"
grep -qF "cp $tmp/boot/ssh/root/id_ed25519* /root/.ssh/" "$go" || fail "block does not restore the key"
grep -qF "cp $tmp/boot/ssh/root/known_hosts /root/.ssh/" "$go" || fail "block does not restore known_hosts"

# Every path in the generated root boot script is shell data, not shell syntax.
# Exercise the emitted commands with paths containing spaces and inspect the
# argv seen by stubbed commands.
saved_boot_dir="$UNRAID_BOOT_DIR"
UNRAID_BOOT_DIR="$tmp/boot with spaces"
spaced_self="$tmp/install with spaces/satchel"
spaced_shim="$tmp/install with spaces/claude"
spaced_block="$(unraid_boot_block_body "$spaced_self" "$spaced_shim")"
UNRAID_BOOT_DIR="$saved_boot_dir"
link_line="$(sed -n '1p' <<< "$spaced_block")"
link_args="$(bash -c 'ln() { printf "<%s>\\n" "$@"; }; eval "$1"' _ "$link_line")"
[ "$link_args" = "$(printf '<-sf>\n<%s>\n<%s>\n</usr/local/bin/>' "$spaced_self" "$spaced_shim")" ] \
  || fail "boot link paths were split by the shell"
key_line="$(sed -n '3p' <<< "$spaced_block")"
key_args="$(bash -c 'cp() { printf "<%s>\\n" "$@"; }; chmod() { :; }; eval "$1"' _ "$key_line")"
[ "$key_args" = "$(printf '<%s>\n</root/.ssh/>' "$tmp/boot with spaces/ssh/root/id_ed25519*")" ] \
  || fail "boot key path was split by the shell"

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

# --- the go script is boot-critical, so writing it has three guarantees ---
printf '#!/bin/bash\n# pristine user go\n/usr/local/sbin/emhttp &\n' > "$go"
rm -f "$(unraid_go_backup)"

# 1. The replacement is staged in the SAME directory, so installing it is a
#    rename on the flash and never a truncate-then-write of the real file.
staged="$(stage_beside_go "$go")"
[ "$(dirname "$staged")" = "$(dirname "$go")" ] || fail "replacement staged on another filesystem"
rm -f "$staged"

# 2. A copy of the last version that parsed is kept beside it.
write_unraid_boot_block "$go" || fail "write failed"
[ -f "$(unraid_go_backup)" ] || fail "no backup was taken"
grep -qF '/usr/local/sbin/emhttp' "$(unraid_go_backup)" || fail "backup lost the user's content"
if grep -qF "$BOOT_BLOCK_BEGIN" "$(unraid_go_backup)"; then
  fail "backup should predate Satchel's first block"
fi
# and it is refreshed on later writes, but never with something broken
write_unraid_boot_block "$go"
grep -qF "$BOOT_BLOCK_BEGIN" "$(unraid_go_backup)" || fail "backup not refreshed on a later write"
cp "$(unraid_go_backup)" "$tmp/good-backup"
printf 'if then fi ((( \n' > "$go"          # a go file that cannot parse
write_unraid_boot_block "$go" >/dev/null 2>&1 || true
cmp -s "$(unraid_go_backup)" "$tmp/good-backup" \
  || fail "a broken go file overwrote the known-good backup"

# 3. Content that would be malformed is never installed. An unresolved satchel
#    path used to emit a bare `ln -sf  /usr/local/bin/` into the boot script.
printf '#!/bin/bash\n# pristine user go\n/usr/local/sbin/emhttp &\n' > "$go"
cp "$go" "$tmp/before-malformed"
SATCHEL_SELF="$tmp/does-not-exist" write_unraid_boot_block "$go" >/dev/null 2>&1 \
  && fail "wrote a block with an unresolvable satchel path"
cmp -s "$go" "$tmp/before-malformed" || fail "go was modified despite the refusal"

out="$(SATCHEL_SELF="$tmp/does-not-exist" write_unraid_boot_block "$go" 2>&1 || true)"
grep -q 'could not resolve the installed satchel command' <<< "$out" \
  || fail "refusal was not explained"

# The install step refuses malformed content on its own, not only because the
# caller happened to catch it first — this is the last gate before a boot
# script is replaced, so it has to hold independently.
printf 'if then fi (((\n' > "$tmp/malformed-staged"
cp "$go" "$tmp/before-install"
if install_go_file "$tmp/malformed-staged" "$go" >/dev/null 2>&1; then
  fail "install_go_file accepted content that does not parse"
fi
cmp -s "$go" "$tmp/before-install" || fail "go was modified by a refused install"
[ ! -e "$tmp/malformed-staged" ] || fail "refused staged file was left behind"

# The sanity gate itself: malformed content is rejected, valid content passes.
printf '#!/bin/bash\nln -sf  /usr/local/bin/\n' > "$tmp/bad-link"
if boot_script_sane "$tmp/bad-link"; then fail "empty link target must be rejected"; fi
printf 'if then fi (((\n' > "$tmp/bad-syntax"
if boot_script_sane "$tmp/bad-syntax"; then fail "unparseable script must be rejected"; fi
: > "$tmp/empty"
if boot_script_sane "$tmp/empty"; then fail "empty script must be rejected"; fi
printf '#!/bin/bash\necho ok\n' > "$tmp/fine"
boot_script_sane "$tmp/fine" || fail "a valid script must be accepted"

# No temp files are left beside the boot script after any of that.
leftover="$(find "$(dirname "$go")" -maxdepth 1 -name '*.satchel-tmp.*' -print -quit)"
[ -z "$leftover" ] || fail "left a staged temp file beside the boot script: $leftover"

# Hand the next section a go script with no Satchel block, as it expects.
printf '#!/bin/bash\n# pristine user go\n/usr/local/sbin/emhttp &\n' > "$go"

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

# Drift reporting must distinguish "compared and agreed" from "nothing to
# compare". Reporting green off an empty data set is the failure this check
# exists to prevent, and it did exactly that on first real use.
sync_dir_for_drift="$SATCHEL_DIR/sync"
mkdir -p "$sync_dir_for_drift/machines/tower"
SYNC_URL=x; git init -q "$sync_dir_for_drift" 2>/dev/null || true
sync_ready || fail "drift fixture is not sync_ready"

# Publishing identical runtime facts must not replace the synced file on every
# session. Content equality is observable as the same inode surviving.
printf 'claude 1, codex 2\n' > "$IMAGE_AGENTS_FILE"
publish_machine_environment
published_environment="$(machine_environment_file)"
published_inode="$(stat -c %i "$published_environment")"
publish_machine_environment
[ "$(stat -c %i "$published_environment")" = "$published_inode" ] \
  || fail "unchanged machine environment was replaced"

# The `|| true` must sit OUTSIDE the substitution: die() exits the subshell,
# so an inner guard never runs. This has been the single most repeated
# mistake in this codebase.
drift_report() { DOCTOR_PROBLEMS=0; cmd_doctor 2>&1; }

# A single-machine caravan says nothing at all — there is no peer to compare to.
report="$(drift_report)" || true
if grep -q 'caravan:' <<< "$report"; then fail "single-machine caravan should stay quiet"; fi

# A peer that has never reported must not read as agreement.
mkdir -p "$sync_dir_for_drift/machines/laptop"
report="$(drift_report)" || true
grep -q 'have not reported versions yet' <<< "$report" \
  || fail "an unreported peer must not be reported as no-drift"
if grep -q 'no drift across' <<< "$report"; then fail "claimed agreement with no data"; fi

# Once it reports and matches, that is a real green.
printf '{"satchel":"%s","commit":"abc","engine":"docker","agents":"claude 1, codex 2"}\n' \
  "$SATCHEL_VERSION" > "$sync_dir_for_drift/machines/laptop/environment.json"
printf 'claude 1, codex 2\n' > "$IMAGE_AGENTS_FILE"
report="$(drift_report)" || true
grep -q 'no drift across 1 reporting machine' <<< "$report" \
  || fail "matching versions should report agreement"

# A genuine difference is named.
printf '{"satchel":"%s","commit":"abc","engine":"docker","agents":"claude 9, codex 9"}\n' \
  "$SATCHEL_VERSION" > "$sync_dir_for_drift/machines/laptop/environment.json"
report="$(drift_report)" || true
grep -q 'laptop has \[claude 9, codex 9\]' <<< "$report" \
  || fail "agent drift was not named"

printf 'ok: unraid detection, boot persistence, and key backup\n'
