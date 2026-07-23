
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
  [ $# -eq 0 ] || die "usage: satchel image"
  if image_exists; then
    info "container image already built; nothing to do"
  else
    ensure_image
  fi
}

build_image() {
  local e ctx; e="$(engine)"
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
  info "image built: $IMAGE"
}
