
# ------------------------------------------------------------------ image

image_exists() {
  local e; e="$(engine)"
  "$e" image inspect "$IMAGE" >/dev/null 2>&1
}

ensure_image() {
  image_exists && return 0
  info "container image not found — building it (takes a few minutes)"
  build_image
}

cmd_image() {
  case "${1:-}" in
    "")
      if image_exists; then
        info "container image already built; nothing to do"
      else
        ensure_image
      fi
      ;;
    --rebuild)
      [ $# -eq 1 ] || die "usage: satchel image [--rebuild]"
      build_image
      ;;
    *) die "usage: satchel image [--rebuild]" ;;
  esac
}

build_image() {
  local e ctx old_id=""; e="$(engine)"
  # Remember the outgoing image so the superseded one can be reclaimed. Unraid
  # keeps images in a fixed-size vdisk, and '--pull' plus two npm globals means
  # every rebuild otherwise strands ~2GB of dangling layers.
  old_id="$("$e" image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
  ctx="$(mktemp -d)"
  # The whole environment agents run in. Agent CLIs are baked in; logins,
  # transcripts, and skills live in mounts, so rebuilding is always safe.
  "$e" build --pull -t "$IMAGE" -f - "$ctx" <<'DOCKERFILE'
FROM docker.io/library/node:22-bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git curl wget ca-certificates jq ripgrep less procps openssh-client \
      python3 make g++ bubblewrap wl-clipboard xclip \
 && rm -rf /var/lib/apt/lists/*
RUN npm install -g @anthropic-ai/claude-code @openai/codex
ENV HOME=/home/satchel
RUN mkdir -p /home/satchel && chmod 0777 /home/satchel
# OpenSSH resolves ~ through /etc/passwd, not $HOME: without this, sessions
# read/write .ssh under /home/node or /root — ephemeral container paths — so
# known_hosts never persists and root Host Sessions can hit dangling host
# symlinks. Rewrite only the passwd home field: Docker's legacy builder runs
# this shell as root/PID 1, so usermod refuses to alter the active root account.
RUN sed -Ei 's#^((root|node):[^:]*:[^:]*:[^:]*:[^:]*:)[^:]*:#\1/home/satchel:#' /etc/passwd
WORKDIR /home/satchel
DOCKERFILE
  rm -rf "$ctx"
  local new_id; new_id="$("$e" image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
  if [ -n "$old_id" ] && [ -n "$new_id" ] && [ "$old_id" != "$new_id" ]; then
    # Only an untagged leftover: never remove an image someone else still names.
    if [ -z "$("$e" image inspect -f '{{join .RepoTags ","}}' "$old_id" 2>/dev/null || true)" ]; then
      "$e" image rm "$old_id" >/dev/null 2>&1 \
        && info "reclaimed the superseded image ${old_id#sha256:}" || true
    fi
  fi
  record_image_agents
  info "image built: $IMAGE"
}

# Agent versions come from inside the image, so asking costs a container start.
# Cache the answer at build time: every session wants to publish it, and none
# of them should pay for it.
record_image_agents() {
  local av; av="$(image_agent_versions)"
  [ -n "$av" ] || return 0
  mkdir -p "$SATCHEL_DIR"
  printf '%s\n' "$av" > "$IMAGE_AGENTS_FILE"
  return 0
}

cached_image_agents() {
  [ -f "$IMAGE_AGENTS_FILE" ] || return 0
  tr -d '\n' < "$IMAGE_AGENTS_FILE"
}
