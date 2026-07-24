
# ----------------------------------------------------------------- update

# What this update brings: the commits between the recorded installed commit
# (script-sha, stamped by every update and by install.sh) and the one being
# installed. Best-effort — no record or an unreachable API never blocks the
# update itself.
print_update_log() { # print_update_log <old-sha> <new-sha>
  local old="$1" new="$2" log
  if [ -z "$new" ]; then return 0; fi
  if [ -z "$old" ]; then
    info "no record of the currently installed commit — the commit log starts with the next update"
    return 0
  fi
  if [ "$old" = "$new" ]; then return 0; fi
  log="$(curl -fsSL "https://api.github.com/repos/$SATCHEL_REPO/compare/$old...$new" 2>/dev/null \
        | jq -r '.commits[]? | "  " + .sha[0:7] + " " + (.commit.message | split("\n")[0])')" || log=""
  if [ -n "$log" ]; then
    info "new commits since ${old:0:7}:"
    printf '%s\n' "$log" >&2
  else
    warn "could not list commits ${old:0:7}..${new:0:7} via the GitHub API"
  fi
  return 0
}

cmd_update() {
  need_cmd curl; need_cmd jq
  local self tmp sha ref old=""
  self="$(readlink -f "$0")"
  # Resolve main to a commit first: the raw 'main' URL sits behind a ~5 min
  # CDN cache and will happily serve a stale script; a by-SHA URL cannot.
  sha="$(curl -fsSL "https://api.github.com/repos/$SATCHEL_REPO/commits/main" 2>/dev/null | jq -r '.sha // empty')" || sha=""
  ref="${sha:-main}"
  [ -z "$sha" ] && warn "could not resolve latest commit via the GitHub API — falling back to 'main' (may be up to ~5 min stale)"
  # Stage the download beside the installed command so the replacement is a
  # same-filesystem rename. A cross-device 'mv' copies into the existing inode
  # instead, and Bash — which reads a script incrementally and seeks back into
  # the file between top-level commands — then resumes at the old offset inside
  # the new, longer file and executes a fragment of it. That is the normal
  # layout on Unraid, where /tmp is tmpfs and Satchel lives on the array.
  tmp="$(mktemp "$(dirname "$self")/.satchel-update.XXXXXX")" \
    || tmp="$(mktemp)"
  trap 'rm -f -- "$tmp"' EXIT
  curl -fsSL "https://raw.githubusercontent.com/$SATCHEL_REPO/$ref/satchel" -o "$tmp" || die "download failed"
  bash -n "$tmp" || die "downloaded script does not parse — not installing it"
  [ -f "$SCRIPT_SHA_FILE" ] && old="$(cat "$SCRIPT_SHA_FILE")"
  if cmp -s "$tmp" "$self"; then
    rm -f "$tmp"; trap - EXIT
    info "satchel script already up to date (${sha:0:7})"
  else
    print_update_log "$old" "$sha"
    chmod 755 "$tmp"
    mv "$tmp" "$self" 2>/dev/null || { need_cmd sudo; sudo mv "$tmp" "$self"; }
    trap - EXIT
    info "satchel updated to commit ${sha:0:7} ($self)"
  fi
  # The new artifact must own the rebuild: this process still has the previous
  # build_image function in memory after replacing itself.
  info "rebuilding the container image to pick up new agent versions…"
  "$self" image --rebuild || return $?
  # Record the update only after its image build succeeds. The no-change path
  # also backfills records for installs that predate commit tracking.
  if [ -n "$sha" ]; then
    mkdir -p "$SATCHEL_DIR"
    printf '%s\n' "$sha" > "$SCRIPT_SHA_FILE"
  fi
  mkdir -p "$SATCHEL_DIR"
  printf '%s\n' "$self" > "$INSTALL_PATH_FILE"
  local av; av="$(image_agent_versions)"
  [ -n "$av" ] && info "agents in image: $av"
  return 0
}

image_agent_versions() { # prints "claude X, codex Y" or nothing
  "$(engine)" run --rm --label "$MANAGED_CONTAINER_LABEL" "$IMAGE" sh -c \
    'printf "claude %s, codex %s" "$(claude --version 2>/dev/null | cut -d" " -f1)" "$(codex --version 2>/dev/null | cut -d" " -f2)"' \
    2>/dev/null || true
}
