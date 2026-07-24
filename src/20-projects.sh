
slugify() { # project dir name → safe file name
  printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/-/g'
}

valid_project_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

machine_projects_file() { printf '%s/machines/%s/projects.json' "$SYNC_DIR" "$MACHINE"; }
repository_registry_file() { printf '%s/repositories.json' "$SYNC_DIR"; }

ensure_project_registry() {
  local f; f="$(machine_projects_file)"
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || printf '{"paths":{}}\n' > "$f"
}

ensure_repository_registry() {
  local f; f="$(repository_registry_file)"
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || printf '{}\n' > "$f"
}

git_root_for_path() { git -C "$1" rev-parse --show-toplevel 2>/dev/null || true; }
project_remote() { git -C "$1" remote get-url origin 2>/dev/null || true; }

network_remote() { # true when an origin is portable across machines
  case "$1" in
    ssh://*|git://*|http://*|https://*|*@*:*) return 0 ;;
    *) return 1 ;;
  esac
}

canonical_remote() { # credential-free identity shared by common SSH/HTTPS forms
  local remote="$1" authority path host
  remote="${remote%%\#*}"; remote="${remote%%\?*}"; remote="${remote%/}"
  case "$remote" in
    *://*)
      remote="${remote#*://}"
      authority="${remote%%/*}"; path="${remote#*/}"
      [ "$path" = "$remote" ] && path=""
      authority="${authority##*@}"
      host="${authority%%:*}"
      authority="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')${authority#"$host"}"
      remote="$authority${path:+/$path}"
      ;;
    *@*:*)
      authority="${remote%%:*}"; path="${remote#*:}"
      authority="${authority##*@}"
      remote="$(printf '%s' "$authority" | tr '[:upper:]' '[:lower:]')/$path"
      ;;
  esac
  remote="${remote%.git}"; remote="${remote%/}"
  case "$remote" in
    github.com/*|gitlab.com/*|bitbucket.org/*) remote="$(printf '%s' "$remote" | tr '[:upper:]' '[:lower:]')" ;;
  esac
  printf '%s' "$remote"
}

project_identity() { # project_identity <repo-root> → portable normalized origin, or empty
  local remote; remote="$(project_remote "$1")"
  network_remote "$remote" || return 0
  canonical_remote "$remote"
}

repository_decision() { # repository_decision <identity> → tracked | ignored | empty
  local f; f="$(repository_registry_file)"; [ -f "$f" ] || return 0
  jq -r --arg r "$1" '.[$r].status // empty' "$f"
}

project_for_identity() {
  local f; f="$(repository_registry_file)"; [ -f "$f" ] || return 0
  jq -r --arg r "$1" '.[$r] | select(.status == "tracked") | .project // empty' "$f"
}

origin_for_project() {
  local f; f="$(repository_registry_file)"; [ -f "$f" ] || return 0
  jq -r --arg id "$1" \
    'to_entries[] | select(.value.status == "tracked" and .value.project == $id) | .key' "$f"
}

set_repository_decision() { # set_repository_decision <identity> <tracked|ignored> [project]
  local identity="$1" status="$2" id="${3:-}" f
  ensure_repository_registry; f="$(repository_registry_file)"
  jq --arg r "$identity" --arg status "$status" --arg id "$id" \
    '.[$r]={status:$status} + (if $id == "" then {} else {project:$id} end)' \
    "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

validate_project_state() {
  ensure_repository_registry
  local registry project_dir id origin f
  registry="$(repository_registry_file)"

  # Validate what Satchel reads, and ignore keys it does not know: a newer
  # Satchel on another machine must be able to add a field without bricking
  # every older machine in the caravan on its next command.
  jq -e '
    type == "object"
    and all(to_entries[];
      (.key | type == "string" and length > 0)
      and (.value | type == "object")
      and if .value.status == "tracked" then
        (.value.project | type == "string" and length > 0)
      elif .value.status == "ignored" then true
      else false end)
    and (([to_entries[] | select(.value.status == "tracked") | .value.project] | length)
      == ([to_entries[] | select(.value.status == "tracked") | .value.project] | unique | length))
  ' "$registry" >/dev/null \
    || die "invalid repositories.json — expected one unique tracked Project per canonical origin, or an ignored decision"

  while IFS= read -r origin; do
    [ "$(canonical_remote "$origin")" = "$origin" ] \
      || die "repository identity '$origin' is not canonical"
  done < <(jq -r 'keys[]' "$registry")

  while IFS=$'\t' read -r origin id; do
    valid_project_id "$id" || die "repository '$origin' has unsafe Project id '$id'"
    [ -d "$SYNC_DIR/projects/$id" ] \
      || die "repository '$origin' points to missing Project '$id'"
  done < <(jq -r 'to_entries[] | select(.value.status == "tracked") | [.key,.value.project] | @tsv' "$registry")

  for project_dir in "$SYNC_DIR"/projects/*/; do
    [ -d "$project_dir" ] || continue
    [ ! -L "${project_dir%/}" ] || die "Project directories cannot be symlinks: ${project_dir%/}"
    id="$(basename "$project_dir")"
    valid_project_id "$id" || die "unsafe Project directory '$id'"
    [ -d "$project_dir/handoffs" ] || die "Project '$id' is missing its handoffs directory"
    [ ! -e "$project_dir/project.json" ] \
      || die "Project '$id' contains obsolete project.json metadata"
  done

  for f in "$SYNC_DIR"/machines/*/projects.json; do
    [ -f "$f" ] || continue
    jq -e '
      type == "object" and (.paths | type == "object")
      and all(.paths | to_entries[];
        (.key | type == "string" and startswith("/"))
        and (.value | type == "object")
        and (.value.project | type == "string" and length > 0))
    ' "$f" >/dev/null || die "invalid machine Project cache: $f"
    while IFS= read -r id; do
      valid_project_id "$id" || die "machine cache $f has unsafe Project id '$id'"
      [ -d "$SYNC_DIR/projects/$id" ] \
        || die "machine cache $f points to missing Project '$id'"
    done < <(jq -r '.paths[].project' "$f")
  done
}

remove_project_path() {
  local path f; path="$(readlink -f "$1")"; ensure_project_registry; f="$(machine_projects_file)"
  jq --arg p "$path" 'del(.paths[$p])' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

map_project_path() { # map_project_path <repo-root> <project-id>
  local path id="$2" f
  path="$(readlink -f "$1")"; ensure_project_registry; f="$(machine_projects_file)"
  jq --arg p "$path" --arg id "$id" \
    '.paths[$p]={project:$id}' \
    "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

repository_roots() { # repository_roots <mounted-root>... → every Git working tree, once
  local root top marker repo seen=$'\n'
  for root in "$@"; do
    root="$(readlink -f "$root")"; [ -d "$root" ] || continue
    top="$(git_root_for_path "$root")"
    if [ -n "$top" ] && [[ "$seen" != *$'\n'"$top"$'\n'* ]]; then
      seen+="$top"$'\n'; printf '%s\n' "$top"
    fi
    while IFS= read -r -d '' marker; do
      repo="$(dirname "$marker")"
      [[ "$seen" != *$'\n'"$repo"$'\n'* ]] || continue
      seen+="$repo"$'\n'; printf '%s\n' "$repo"
    done < <(find -P "$root" \
      \( -type d \( -name node_modules -o -name .cache -o -name .venv -o -name venv -o -name target \) -prune \) -o \
      \( -name .git \( -type d -o -type f \) -print0 -prune \) 2>/dev/null)
  done
}

session_roots() {
  local root
  printf '%s\n' "$(readlink -f "$1")"
  for root in "${WITH_DIRS[@]}"; do printf '%s\n' "$(readlink -f "$root")"; done
}

path_overlaps_roots() {
  local path="$1" root
  shift
  for root in "$@"; do
    case "$path" in "$root"|"$root"/*) return 0 ;; esac
    case "$root" in "$path"/*) return 0 ;; esac
  done
  return 1
}

refresh_project_paths() { # discover/match repositories inside the explicit session roots
  local launch="$1" roots=() root path id identity actual f
  sync_ready || return 0
  ensure_project_registry; ensure_repository_registry
  validate_project_state
  [ "$HOST_MODE" -eq 0 ] || return 0
  while IFS= read -r root; do roots+=("$root"); done < <(session_roots "$launch")
  f="$(machine_projects_file)"

  # Remove stale cached checkouts only when they overlap this session's
  # explicit roots. Paths elsewhere on the machine are deliberately untouched.
  while IFS=$'\t' read -r path id; do
    path_overlaps_roots "$path" "${roots[@]}" || continue
    actual="$(git_root_for_path "$path")"
    if [ "$actual" != "$path" ] || [ ! -d "$SYNC_DIR/projects/$id" ]; then remove_project_path "$path"; fi
  done < <(jq -r '.paths | to_entries[] | "\(.key)\t\(.value.project // empty)"' "$f")

  while IFS= read -r path; do
    identity="$(project_identity "$path")"
    if [ -n "$identity" ]; then
      id="$(project_for_identity "$identity")"
      if [ -n "$id" ] && [ -d "$SYNC_DIR/projects/$id" ]; then
        map_project_path "$path" "$id"
      else
        # An origin change or a global ignore invalidates a former path cache.
        remove_project_path "$path"
      fi
    fi
    # Local/no-origin repositories retain only an explicit existing mapping.
  done < <(repository_roots "${roots[@]}")
}

project_for_path() { # project_for_path <path> → id; nearest tracked ancestor wins
  local path="$1" f current id
  f="$(machine_projects_file)"; [ -f "$f" ] || return 0
  current="$(readlink -f "$path")"
  while :; do
    id="$(jq -r --arg p "$current" '.paths[$p].project // empty' "$f")"
    if [ -n "$id" ]; then printf '%s' "$id"; return 0; fi
    [ "$current" = / ] && break
    current="$(dirname "$current")"
  done
}

# Attribution rule: work belongs to whichever tracked project's directory it
# happened in, regardless of how the session was launched. These enumerate
# the roster entries a session can actually reach - the launch dir and its
# subtree, --with extras, or (Host Session) everything on the machine.
visible_projects() { # visible_projects <launch-dir> → "path<TAB>id" per visible tracked project
  local f roots=() path id r
  f="$(machine_projects_file)"; [ -f "$f" ] || return 0
  roots=("$(readlink -f "$1")" "${WITH_DIRS[@]}")
  while IFS=$'\t' read -r path id; do
    [ -n "$id" ] || continue
    if [ "$HOST_MODE" -eq 1 ]; then printf '%s\t%s\n' "$path" "$id"; continue; fi
    for r in "${roots[@]}"; do
      case "$path" in "$r"|"$r"/*) printf '%s\t%s\n' "$path" "$id"; break ;; esac
    done
  done < <(jq -r '.paths | to_entries[] | "\(.key)\t\(.value.project // empty)"' "$f")
}

visible_candidates() { # visible_candidates <launch-dir> → path<TAB>portable-origin
  [ "$HOST_MODE" -eq 0 ] || return 0
  local roots=() root path identity decision
  while IFS= read -r root; do roots+=("$root"); done < <(session_roots "$1")
  while IFS= read -r path; do
    identity="$(project_identity "$path")"; [ -n "$identity" ] || continue
    decision="$(repository_decision "$identity")"
    [ -z "$decision" ] && printf '%s\t%s\n' "$path" "$identity"
  done < <(repository_roots "${roots[@]}")
  return 0
}

session_path() { # real path → the path the agent sees for it in this session
  if [ "$HOST_MODE" -eq 1 ]; then printf '/host%s' "$1"; else printf '%s' "$1"; fi
}

unique_project_id() {
  local wanted id n=2
  wanted="$(slugify "$1")"; [ -n "$wanted" ] || wanted=project
  valid_project_id "$wanted" || wanted="project$wanted"
  id="$wanted"
  while [ -e "$SYNC_DIR/projects/$id" ]; do id="$wanted-$n"; n=$((n + 1)); done
  printf '%s' "$id"
}

enroll_project() { # enroll_project <path> [id] → prints id
  local path id identity existing assigned_origin
  path="$(git_root_for_path "$1")"
  [ -n "$path" ] || die "$(readlink -f "$1") is not inside a Git repository"
  ensure_project_registry
  ensure_repository_registry
  validate_project_state
  identity="$(project_identity "$path")"
  id="${2:-}"
  if [ -n "$identity" ]; then
    existing="$(project_for_identity "$identity")"
    [ -z "$existing" ] || id="$existing"
  fi
  if [ -z "$id" ]; then id="$(unique_project_id "$(basename "$path")")"; fi
  id="$(slugify "$id")"
  valid_project_id "$id" \
    || die "project id must start with a letter or number and contain only letters, numbers, dots, underscores, and hyphens"
  if [ -n "$identity" ]; then
    assigned_origin="$(origin_for_project "$id")"
    if [ -n "$assigned_origin" ] && [ "$assigned_origin" != "$identity" ]; then
      die "Project '$id' belongs to $assigned_origin, not $identity"
    fi
  fi
  mkdir -p "$SYNC_DIR/projects/$id/handoffs"
  touch "$SYNC_DIR/projects/$id/handoffs/.gitkeep"
  [ -z "$identity" ] || set_repository_decision "$identity" tracked "$id"
  map_project_path "$path" "$id"
  validate_project_state
  printf '%s' "$id"
}

ignore_repository() { # ignore_repository <portable-origin>
  set_repository_decision "$1" ignored
}

git_sync() { git -C "$SYNC_DIR" "$@"; }

# A freshly cloned empty Sync Repo has no upstream yet: skip pulls until the
# first push (-u) creates it.
has_upstream() { git_sync rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; }

# Satchel owns the Sync Repo's commits, so they must work on a machine where
# git was never configured: give the clone a repo-local identity named after
# the machine. A user's global identity, if present, wins.
ensure_sync_identity() {
  git_sync config user.name  >/dev/null 2>&1 || git_sync config user.name "satchel on $MACHINE"
  git_sync config user.email >/dev/null 2>&1 || git_sync config user.email "satchel@$MACHINE"
  return 0
}
