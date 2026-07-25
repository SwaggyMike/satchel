# Shared test assertions.
#
# `! some_command` cannot fail a test. POSIX exempts a command from `set -e`
# when its return value is being inverted with `!`, so every negative assertion
# written that way is decorative: it runs, its result is discarded, and the
# suite passes whatever happens. Satchel's tests had 71 of them.
#
# refute() restores the intended meaning by failing explicitly.

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

refute() { # refute <command...> — the command must NOT succeed
  # The subshell matters: most of what gets refuted here fails by calling die,
  # which exits. Run directly, that would take the whole test file with it —
  # silently, since output is suppressed.
  if ( "$@" ) >/dev/null 2>&1; then
    fail "expected failure, but this succeeded: $*"
  fi
  return 0
}

refute_grep() { # refute_grep <pattern> <file> — the pattern must NOT appear
  if grep -q -- "$1" "$2" 2>/dev/null; then
    fail "expected not to find '$1' in $2"
  fi
  return 0
}

assert_grep() { # assert_grep <pattern> <file>
  grep -q -- "$1" "$2" 2>/dev/null || fail "expected to find '$1' in $2"
  return 0
}
