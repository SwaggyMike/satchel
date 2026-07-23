
# Colors are enabled only for a terminal, unless CLICOLOR_FORCE=1 is set.
# NO_COLOR always wins so logs and automation can opt out explicitly.
color_enabled() {
  local fd="$1"
  [ -z "${NO_COLOR:-}" ] || return 1
  [ "${TERM:-}" != dumb ] || return 1
  [ "${CLICOLOR_FORCE:-0}" = 1 ] || [ -t "$fd" ]
}

if color_enabled 1; then
  OUT_RESET=$'\033[0m'; OUT_BOLD=$'\033[1m'
  OUT_CYAN=$'\033[36m'; OUT_BLUE=$'\033[34m'; OUT_GREEN=$'\033[32m'
  OUT_YELLOW=$'\033[33m'; OUT_RED=$'\033[31m'
else
  OUT_RESET=""; OUT_BOLD=""; OUT_CYAN=""; OUT_BLUE=""
  OUT_GREEN=""; OUT_YELLOW=""; OUT_RED=""
fi
if color_enabled 2; then
  ERR_RESET=$'\033[0m'; ERR_BOLD=$'\033[1m'
  ERR_CYAN=$'\033[36m'; ERR_BLUE=$'\033[34m'; ERR_GREEN=$'\033[32m'
  ERR_YELLOW=$'\033[33m'; ERR_RED=$'\033[31m'
else
  ERR_RESET=""; ERR_BOLD=""; ERR_CYAN=""; ERR_BLUE=""
  ERR_GREEN=""; ERR_YELLOW=""; ERR_RED=""
fi

info() { printf '%s%s%s\n' "$ERR_CYAN" "satchel: $*" "$ERR_RESET" >&2; }
warn() { printf '%s%s%s\n' "$ERR_YELLOW" "satchel: warning: $*" "$ERR_RESET" >&2; }
die()  { printf '%s%s%s\n' "$ERR_RED$ERR_BOLD" "satchel: error: $*" "$ERR_RESET" >&2; exit 1; }
success() { printf '%s%s%s\n' "$ERR_GREEN" "satchel: $*" "$ERR_RESET" >&2; }

prompt_text() { printf '%s%s%s' "$ERR_BOLD$ERR_BLUE" "$1" "$ERR_RESET"; }
out_header() { printf '%s%s%s\n' "$OUT_BOLD$OUT_CYAN" "$*" "$OUT_RESET"; }
out_section() { printf '%s%s%s\n' "$OUT_BOLD$OUT_BLUE" "$*" "$OUT_RESET"; }

confirm() { # confirm "question"  → returns 0 on yes; default no (for destructive asks)
  local reply
  read -r -p "$(prompt_text "$1 [y/N] ")" reply
  [[ "$reply" == [yY]* ]]
}

confirm_yes() { # default yes (for asks almost everyone wants)
  local reply
  read -r -p "$(prompt_text "$1 [Y/n] ")" reply
  [[ ! "$reply" == [nN]* ]]
}

choose_baseline() { # yes | later | never; baseline access is privileged enough to default later
  local reply
  explain_machine_baseline
  read -r -p "$(prompt_text "take an initial baseline of this system now? [y]es/[N]ot now/[d]on't ask again: ")" reply
  case "$reply" in
    [yY]*) printf 'yes' ;;
    [dD]*) printf 'never' ;;
    *)     printf 'later' ;;
  esac
}

explain_machine_baseline() {
  info "machine baseline: an authenticated agent will inspect this system's specs, OS, hardware, storage, network, services, containers, and operational quirks"
  info "the host is mounted read-only at /host; the agent shows you a proposed inventory and concise operational notes before saving approved content to your private Sync Repo"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"
}

valid_machine_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# Where shims live — same priority as install.sh so 'satchel link' puts them
# where the installer would have.
