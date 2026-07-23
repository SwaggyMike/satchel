#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_home="$(mktemp -d)"
trap 'rm -rf "$test_home"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$2" >&2; exit 1; }

# The installer only checks that a container engine command exists; stub one
# so the tests run on machines without docker/podman.
stub_bin="$test_home/stub-bin"
mkdir -p "$stub_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ -n "${SATCHEL_TEST_ENGINE_LOG:-}" ]; then' \
  '  printf "%s\n" "$*" >> "$SATCHEL_TEST_ENGINE_LOG"' \
  '  case "${1:-} ${2:-}" in' \
  '    "image inspect") [ -f "$SATCHEL_TEST_IMAGE_STATE" ]; exit ;;' \
  '    "image rm") rm -f "$SATCHEL_TEST_IMAGE_STATE"; exit 0 ;;' \
  '  esac' \
  '  if [ "${1:-}" = build ]; then' \
  '    [ "${SATCHEL_TEST_BUILD_FAIL:-0}" != 1 ] || exit 42' \
  '    touch "$SATCHEL_TEST_IMAGE_STATE"' \
  '  fi' \
  'fi' \
  'exit 0' > "$stub_bin/docker"
chmod 755 "$stub_bin/docker"
export PATH="$stub_bin:$PATH"

# --- a dangling existing agent symlink is skipped, not fatal ---------------

mkdir -p "$test_home/.local/bin"
ln -s "$test_home/missing-node/lib/codex.js" "$test_home/.local/bin/codex"

set +e
output="$(HOME="$test_home" SATCHEL_BIN="$test_home/.local/bin" \
  bash "$repo_dir/install.sh" </dev/null 2>&1)"
rc=$?
set -e

[ "$rc" -eq 0 ] || fail "installer rejected a dangling existing codex symlink (rc=$rc)" "$output"
grep -q "SKIPPED shim 'codex'" <<< "$output" \
  || fail "installer did not report the dangling codex symlink as skipped" "$output"

printf 'ok: installer handles dangling agent shims\n'

# --- SATCHEL_BIN makes a self-contained, relocatable install ---------------

bin="$test_home/appdata/satchel"
mkdir -p "$test_home/appdata"

set +e
output="$(HOME="$test_home" SATCHEL_BIN="$bin" bash "$repo_dir/install.sh" </dev/null 2>&1)"
rc=$?
set -e

[ "$rc" -eq 0 ] || fail "installer failed with SATCHEL_BIN (rc=$rc)" "$output"
[ -x "$bin/satchel" ] || fail "satchel was not installed into SATCHEL_BIN" "$output"
[ -d "$bin/.satchel" ] || fail "sibling .satchel state dir was not created" "$output"
[ "$(cat "$bin/.satchel/install-path")" = "$bin/satchel" ] \
  || fail "installer did not record the installed script path" "$output"
for shim in claude codex; do
  [ -x "$bin/$shim" ] || fail "shim '$shim' was not installed into SATCHEL_BIN" "$output"
  grep -q "satchel shim" "$bin/$shim" || fail "shim '$shim' is missing the satchel-shim marker"
  grep -q "$bin/satchel" "$bin/$shim" || fail "shim '$shim' does not exec satchel by absolute path"
done

printf 'ok: SATCHEL_BIN install is self-contained\n'

# --- initialized installs leave the shared agent image ready ---------------

ready_bin="$test_home/image-ready"
ready_state="$ready_bin/.satchel"
ready_log="$test_home/image-ready.log"
ready_marker="$test_home/image-ready.marker"
mkdir -p "$ready_state/sync/.git"
printf 'MACHINE=image-ready\nSYNC_URL=git@example.test:sync.git\n' > "$ready_state/config"

set +e
output="$(HOME="$test_home" SATCHEL_BIN="$ready_bin" SATCHEL_SHIMS=n \
  SATCHEL_TEST_ENGINE_LOG="$ready_log" SATCHEL_TEST_IMAGE_STATE="$ready_marker" \
  bash "$repo_dir/install.sh" </dev/null 2>&1)"
rc=$?
set -e

[ "$rc" -eq 0 ] || fail "initialized installer did not prepare the image (rc=$rc)" "$output"
[ -f "$ready_marker" ] || fail "initialized installer did not create the image marker" "$output"
[ "$(grep -c '^build ' "$ready_log")" -eq 1 ] \
  || fail "initialized installer did not build one missing image" "$(cat "$ready_log")"
grep -q 'ready to launch claude or codex' <<< "$output" \
  || fail "installer did not report the initialized installation as ready" "$output"

: > "$ready_log"
output="$(HOME="$test_home" SATCHEL_BIN="$ready_bin" SATCHEL_SHIMS=n \
  SATCHEL_TEST_ENGINE_LOG="$ready_log" SATCHEL_TEST_IMAGE_STATE="$ready_marker" \
  bash "$repo_dir/install.sh" </dev/null 2>&1)"
[ "$(grep -c '^build ' "$ready_log" || true)" -eq 0 ] \
  || fail "installer rebuilt an image that already existed" "$(cat "$ready_log")"

printf 'ok: initialized install ensures one missing image\n'

# A failed build leaves the installed command available and gives one exact,
# deterministic retry instead of deferring another surprise to first launch.
failed_bin="$test_home/image-failed"
failed_state="$failed_bin/.satchel"
failed_log="$test_home/image-failed.log"
failed_marker="$test_home/image-failed.marker"
mkdir -p "$failed_state/sync/.git"
printf 'MACHINE=image-failed\nSYNC_URL=git@example.test:sync.git\n' > "$failed_state/config"

set +e
output="$(HOME="$test_home" SATCHEL_BIN="$failed_bin" SATCHEL_SHIMS=n \
  SATCHEL_TEST_ENGINE_LOG="$failed_log" SATCHEL_TEST_IMAGE_STATE="$failed_marker" \
  SATCHEL_TEST_BUILD_FAIL=1 bash "$repo_dir/install.sh" </dev/null 2>&1)"
rc=$?
set -e

[ "$rc" -ne 0 ] || fail "installer reported success after the image build failed" "$output"
[ -x "$failed_bin/satchel" ] || fail "failed image build removed the installed command" "$output"
grep -q "retry: $failed_bin/satchel image" <<< "$output" \
  || fail "failed image build did not print the exact retry command" "$output"

printf 'ok: failed install image build is retryable\n'

# SATCHEL_BIN is a directory, so a value occupying PATH's `satchel` command
# slot must be rejected before it creates the crate-test collision.
collision_home="$test_home/collision-home"
collision_bin="$collision_home/.local/bin"
mkdir -p "$collision_bin"
set +e
output="$(HOME="$collision_home" PATH="$collision_bin:$PATH" \
  SATCHEL_BIN="$collision_bin/satchel" bash "$repo_dir/install.sh" </dev/null 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "installer accepted a SATCHEL_BIN directory in the satchel command slot" "$output"
[ ! -e "$collision_bin/satchel" ] || fail "installer created the colliding satchel directory" "$output"
grep -q "names a directory" <<< "$output" \
  || fail "SATCHEL_BIN collision error did not explain the directory semantics" "$output"

printf 'ok: installer rejects SATCHEL_BIN command-path collisions\n'

# --- satchel finds sibling state without env or \$HOME ----------------------

printf 'MACHINE=sibling-detected\nSYNC_URL=\n' > "$bin/.satchel/config"
status_out="$(HOME="$test_home" "$bin/satchel" status 2>&1 || true)"
grep -q "on sibling-detected" <<< "$status_out" \
  || fail "installed satchel did not pick up the sibling .satchel state dir" "$status_out"
grep -q "linked" <<< "$status_out" \
  || fail "self-contained install did not find its sibling shims without SATCHEL_BIN" "$status_out"

printf 'ok: sibling .satchel state dir is detected\n'

# --- installer skips shims when user answers 'n' ----------------------------

skip_bin="$test_home/appdata/satchel-skip"
mkdir -p "$test_home/appdata"

set +e
output="$(HOME="$test_home" SATCHEL_BIN="$skip_bin" SATCHEL_SHIMS=n bash "$repo_dir/install.sh" </dev/null 2>&1)"
rc=$?
set -e

[ "$rc" -eq 0 ] || fail "installer failed when declining shims (rc=$rc)" "$output"
[ -x "$skip_bin/satchel" ] || fail "satchel was not installed when declining shims" "$output"
for shim in claude codex; do
  [ ! -e "$skip_bin/$shim" ] || fail "shim '$shim' was installed despite user declining" "$output"
done
grep -q "skipped shims" <<< "$output" \
  || fail "installer did not report that shims were skipped" "$output"

printf 'ok: installer respects shim opt-out\n'

# --- satchel link / unlink --------------------------------------------------

link_bin="$test_home/link-test-bin"
mkdir -p "$link_bin"
cp "$repo_dir/satchel" "$link_bin/satchel"
chmod 755 "$link_bin/satchel"
mkdir -p "$link_bin/.satchel"
printf 'MACHINE=link-test\nSYNC_URL=\n' > "$link_bin/.satchel/config"

# link both
set +e
output="$(HOME="$test_home" SATCHEL_BIN="$link_bin" "$link_bin/satchel" link 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "satchel link failed (rc=$rc)" "$output"
for agent in claude codex; do
  [ -x "$link_bin/$agent" ] || fail "'$agent' shim was not created by link" "$output"
  grep -q "satchel shim" "$link_bin/$agent" || fail "'$agent' shim missing marker after link"
done
printf 'ok: satchel link creates shims\n'

# link again is a no-op
set +e
output="$(HOME="$test_home" SATCHEL_BIN="$link_bin" "$link_bin/satchel" link 2>&1)"
set -e
grep -q "already linked" <<< "$output" \
  || fail "satchel link did not report already-linked" "$output"
printf 'ok: satchel link is idempotent\n'

# unlink both
set +e
output="$(HOME="$test_home" SATCHEL_BIN="$link_bin" "$link_bin/satchel" unlink 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "satchel unlink failed (rc=$rc)" "$output"
for agent in claude codex; do
  [ ! -e "$link_bin/$agent" ] || fail "'$agent' shim still exists after unlink" "$output"
done
printf 'ok: satchel unlink removes shims\n'

# unlink again is a no-op
set +e
output="$(HOME="$test_home" SATCHEL_BIN="$link_bin" "$link_bin/satchel" unlink 2>&1)"
set -e
grep -q "not linked" <<< "$output" \
  || fail "satchel unlink did not report not-linked" "$output"
printf 'ok: satchel unlink is idempotent\n'

# link a single agent
set +e
output="$(HOME="$test_home" SATCHEL_BIN="$link_bin" "$link_bin/satchel" link claude 2>&1)"
set -e
[ -x "$link_bin/claude" ] || fail "claude shim was not created by single-agent link"
[ ! -e "$link_bin/codex" ] || fail "codex shim was created when only claude was requested"
printf 'ok: satchel link accepts a single agent\n'

# unlink refuses to remove a non-satchel binary
printf '#!/usr/bin/env bash\necho real\n' > "$link_bin/codex"
chmod 755 "$link_bin/codex"
set +e
output="$(HOME="$test_home" SATCHEL_BIN="$link_bin" "$link_bin/satchel" unlink codex 2>&1)"
set -e
[ -x "$link_bin/codex" ] || fail "unlink removed a non-satchel binary"
grep -q "not a Satchel shim" <<< "$output" \
  || fail "unlink did not warn about non-satchel binary" "$output"
printf 'ok: satchel unlink refuses non-satchel binaries\n'

# link refuses to overwrite a non-satchel binary
set +e
output="$(HOME="$test_home" SATCHEL_BIN="$link_bin" "$link_bin/satchel" link codex 2>&1)"
set -e
grep -q "not a Satchel shim" <<< "$output" \
  || fail "link did not warn about existing non-satchel binary" "$output"
printf 'ok: satchel link refuses to overwrite non-satchel binaries\n'

# status shows link state
rm -f "$link_bin/codex"
set +e
output="$(HOME="$test_home" SATCHEL_BIN="$link_bin" "$link_bin/satchel" status 2>&1)"
set -e
grep -q "linked" <<< "$output" || fail "status does not show link state" "$output"
grep -q "not linked" <<< "$output" || fail "status does not show unlinked state" "$output"
printf 'ok: satchel status shows link state\n'

# --- satchel uninstall preserves state by default ---------------------------

uninstall_bin="$test_home/uninstall-keep"
mkdir -p "$uninstall_bin/.satchel/home/codex"
cp "$repo_dir/satchel" "$uninstall_bin/satchel"
chmod 755 "$uninstall_bin/satchel"
printf 'MACHINE=uninstall-keep\nSYNC_URL=\n' > "$uninstall_bin/.satchel/config"
printf '%s\n' "$uninstall_bin/satchel" > "$uninstall_bin/.satchel/install-path"
printf 'login state\n' > "$uninstall_bin/.satchel/home/codex/auth.json"
HOME="$test_home" "$uninstall_bin/satchel" link >/dev/null 2>&1

set +e
output="$(HOME="$test_home" "$uninstall_bin/satchel" uninstall --yes 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "satchel uninstall failed (rc=$rc)" "$output"
[ ! -e "$uninstall_bin/satchel" ] || fail "satchel uninstall left the command behind" "$output"
[ ! -e "$uninstall_bin/claude" ] || fail "satchel uninstall left the claude shim behind" "$output"
[ ! -e "$uninstall_bin/codex" ] || fail "satchel uninstall left the codex shim behind" "$output"
[ -f "$uninstall_bin/.satchel/home/codex/auth.json" ] \
  || fail "satchel uninstall deleted preserved local state" "$output"
grep -q 'state remains' <<< "$output" \
  || fail "satchel uninstall did not report preserved state" "$output"
grep -q 'removed container image' <<< "$output" \
  || fail "satchel uninstall did not remove its container image" "$output"

printf 'ok: satchel uninstall preserves local state\n'

# Legacy shims and shims owned by another installation are ambiguous. An
# uninstall must leave both untouched instead of breaking another command.
legacy_home="$test_home/legacy-home"
legacy_path="$legacy_home/.local/bin"
legacy_install="$legacy_path/satchel"
mkdir -p "$legacy_install/.satchel"
cp "$repo_dir/satchel" "$legacy_install/satchel"
chmod 755 "$legacy_install/satchel"
printf 'MACHINE=legacy-uninstall\nSYNC_URL=\n' > "$legacy_install/.satchel/config"
printf '%s\n' "$legacy_install/satchel" > "$legacy_install/.satchel/install-path"
printf '#!/usr/bin/env bash\nexec satchel claude "$@"\n' > "$legacy_path/claude"
printf '#!/usr/bin/env bash\n# satchel shim\nexec %q codex "$@"\n' \
  "$legacy_home/other-install/satchel" > "$legacy_path/codex"
chmod 755 "$legacy_path/codex" "$legacy_path/claude"

set +e
output="$(HOME="$legacy_home" "$legacy_install/satchel" uninstall --yes 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "legacy-layout uninstall failed (rc=$rc)" "$output"
[ -x "$legacy_path/codex" ] || fail "uninstall removed another installation's codex shim" "$output"
[ -x "$legacy_path/claude" ] || fail "uninstall removed an ambiguous legacy claude shim" "$output"
[ ! -e "$legacy_install/satchel" ] || fail "legacy-layout uninstall left its command behind" "$output"
[ -d "$legacy_install/.satchel" ] || fail "legacy-layout uninstall did not preserve state" "$output"
grep -q "left ambiguous Satchel shim $legacy_path/codex" <<< "$output" \
  || fail "other-installation shim preservation was not reported" "$output"
grep -q "left ambiguous Satchel shim $legacy_path/claude" <<< "$output" \
  || fail "legacy shim preservation was not reported" "$output"

printf 'ok: satchel uninstall preserves shims it cannot prove it owns\n'

# A plain uninstall remains confirmation-gated.
cancel_bin="$test_home/uninstall-cancel"
mkdir -p "$cancel_bin/.satchel"
cp "$repo_dir/satchel" "$cancel_bin/satchel"
chmod 755 "$cancel_bin/satchel"
printf 'MACHINE=uninstall-cancel\nSYNC_URL=\n' > "$cancel_bin/.satchel/config"
printf '%s\n' "$cancel_bin/satchel" > "$cancel_bin/.satchel/install-path"
set +e
output="$(printf 'n\n' | HOME="$test_home" "$cancel_bin/satchel" uninstall 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "declining satchel uninstall failed (rc=$rc)" "$output"
[ -x "$cancel_bin/satchel" ] || fail "declining uninstall still removed the command" "$output"
grep -q 'cancelled' <<< "$output" || fail "declined uninstall was not reported as cancelled" "$output"

printf 'ok: satchel uninstall is confirmation-gated\n'

# --- --purge requires and removes an exact Satchel state tree ---------------

purge_bin="$test_home/uninstall-purge"
mkdir -p "$purge_bin/.satchel/home/codex"
cp "$repo_dir/satchel" "$purge_bin/satchel"
chmod 755 "$purge_bin/satchel"
printf 'MACHINE=uninstall-purge\nSYNC_URL=\n' > "$purge_bin/.satchel/config"
printf '%s\n' "$purge_bin/satchel" > "$purge_bin/.satchel/install-path"
printf 'login state\n' > "$purge_bin/.satchel/home/codex/auth.json"
HOME="$test_home" "$purge_bin/satchel" link >/dev/null 2>&1

set +e
output="$(HOME="$test_home" "$purge_bin/satchel" uninstall --purge --yes 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "satchel uninstall --purge failed (rc=$rc)" "$output"
[ ! -e "$purge_bin/satchel" ] || fail "purge left the command behind" "$output"
[ ! -e "$purge_bin/.satchel" ] || fail "purge left the state directory behind" "$output"
grep -q 'remote Sync Repo was not deleted' <<< "$output" \
  || fail "purge did not distinguish local state from the remote Sync Repo" "$output"

printf 'ok: satchel uninstall --purge removes local state\n'

# --- uninstall refuses to delete an arbitrary checkout ----------------------

foreign_state="$test_home/foreign-state"
mkdir -p "$foreign_state"
set +e
output="$(HOME="$test_home" SATCHEL_DIR="$foreign_state" "$repo_dir/satchel" uninstall --yes 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "uninstall accepted an arbitrary checkout" "$output"
[ -f "$repo_dir/satchel" ] || fail "uninstall deleted the project checkout's script" "$output"
grep -q 'refusing to remove a checkout' <<< "$output" \
  || fail "uninstall refusal did not explain the safety boundary" "$output"

printf 'ok: satchel uninstall refuses arbitrary scripts\n'
