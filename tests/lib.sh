#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <var> <prefix> creates a fresh temp dir, assigns it to <var>,
# and registers it for removal on EXIT, HUP, INT, and TERM. FM_TEST_KEEP_TMP=1
# preserves registered dirs and prints each kept path for debugging.
#
# This library is the single owner of the EXIT/HUP/INT/TERM traps for any suite
# that uses it. A suite that needs extra teardown (killing a daemon, returning a
# worktree, tearing down a herdr lab session) registers it with
# fm_test_at_exit <command> instead of installing its own trap: registered
# handlers run in reverse registration order BEFORE the temp roots are removed,
# so a handler can still reach its fixture. A handler that must fail the suite
# assigns FM_TEST_EXIT_STATUS instead of calling exit, which would skip the
# handlers and temp removal still queued behind it. An EXIT trap installed
# before the first fm_test_tmproot call is adopted as a handler; installing one
# afterwards silently drops this library's cleanup and is rejected by
# tests/fm-test-tmp-cleanup.test.sh.

FM_TEST_CLEANUP_DIRS=()
FM_TEST_EXIT_HOOKS=()
FM_TEST_EXIT_HOOK_COUNT=0
FM_TEST_CLEANUP_TRAP_INSTALLED=0
FM_TEST_EXIT_STATUS=0

# Remove (or, under FM_TEST_KEEP_TMP=1, report) every registered temp root.
# Idempotent: the registry is emptied, so a suite that calls this itself does
# not make the trap-driven call remove anything twice.
fm_test_cleanup() {
  local d
  if [ "${FM_TEST_KEEP_TMP:-}" = 1 ]; then
    for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
      [ -n "$d" ] && printf 'keeping test tmp: %s\n' "$d" >&2
    done
    FM_TEST_CLEANUP_DIRS=()
    return 0
  fi
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf -- "$d"
  done
  FM_TEST_CLEANUP_DIRS=()
}

# fm_test_at_exit <command>: register suite teardown with the library instead of
# installing a competing EXIT trap. Handlers run newest-first, before the
# registered temp roots are removed.
fm_test_at_exit() {
  fm_test_install_cleanup_trap
  FM_TEST_EXIT_HOOKS[FM_TEST_EXIT_HOOK_COUNT]=$1
  FM_TEST_EXIT_HOOK_COUNT=$((FM_TEST_EXIT_HOOK_COUNT + 1))
}

fm_test_run_exit_hooks() {
  local i=$FM_TEST_EXIT_HOOK_COUNT
  FM_TEST_EXIT_HOOK_COUNT=0
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    eval "${FM_TEST_EXIT_HOOKS[$i]}" || true
  done
  FM_TEST_EXIT_HOOKS=()
}

fm_test_exit_handler() {
  FM_TEST_EXIT_STATUS=$?
  fm_test_run_exit_hooks
  fm_test_cleanup
  exit "$FM_TEST_EXIT_STATUS"
}

# Signal handlers clear only the signal traps and exit, so the EXIT trap - and
# with it every registered suite handler - still runs on Ctrl-C or SIGTERM.
fm_test_cleanup_signal() {
  local code=$1
  trap - HUP INT TERM
  exit "$code"
}

fm_test_trap_command() {
  trap -p "$1" | sed "s/^trap -- '\(.*\)' $1$/\1/"
}

fm_test_install_cleanup_trap() {
  local old_exit
  [ "$FM_TEST_CLEANUP_TRAP_INSTALLED" -eq 0 ] || return 0
  FM_TEST_CLEANUP_TRAP_INSTALLED=1
  old_exit=$(fm_test_trap_command EXIT)
  if [ -n "$old_exit" ]; then
    FM_TEST_EXIT_HOOKS[FM_TEST_EXIT_HOOK_COUNT]=$old_exit
    FM_TEST_EXIT_HOOK_COUNT=$((FM_TEST_EXIT_HOOK_COUNT + 1))
  fi
  trap fm_test_exit_handler EXIT
  trap 'fm_test_cleanup_signal 129' HUP
  trap 'fm_test_cleanup_signal 130' INT
  trap 'fm_test_cleanup_signal 143' TERM
}

fm_test_tmproot() {
  local __fm_var=$1 __fm_prefix=${2:-fm-test} __fm_root __fm_tmpbase
  case "$__fm_var" in
    ""|[!A-Za-z_]*|*[!A-Za-z0-9_]*) fail "fm_test_tmproot requires a simple variable name" ;;
    __fm_*) fail "fm_test_tmproot cannot fill '$__fm_var': __fm_* names are the helper's own locals" ;;
  esac
  __fm_tmpbase=$(CDPATH='' cd -- "${TMPDIR:-/tmp}" && pwd -P) \
    || fail "fm_test_tmproot could not resolve TMPDIR (${TMPDIR:-/tmp})"
  [ -n "$__fm_tmpbase" ] || fail "fm_test_tmproot could not resolve TMPDIR (${TMPDIR:-/tmp})"
  __fm_root=$(mktemp -d "$__fm_tmpbase/${__fm_prefix}.XXXXXX") \
    || fail "fm_test_tmproot could not create a temp dir under $__fm_tmpbase"
  [ -n "$__fm_root" ] || fail "fm_test_tmproot could not create a temp dir under $__fm_tmpbase"
  FM_TEST_CLEANUP_DIRS+=("$__fm_root")
  fm_test_install_cleanup_trap
  eval "$__fm_var=\$__fm_root"
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_test_base_path [extra-tool...] echoes the hermetic base PATH for suites that
# prepend a fakebin. FM_TEST_BASE_PATH remains an explicit override. Otherwise
# the base PATH is a private bin directory containing only the allowlisted real
# system tools symlinked by name. That keeps host-installed tools such as herdr,
# tmux, gh, or node from satisfying a test that meant to fake or omit them.
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

FM_TEST_BASE_TOOL_ALLOWLIST='awk base64 basename bash cat chmod cmp cp cut date dirname env find git grep head id kill ln ls mkdir mktemp mv openssl paste perl printf ps pwd readlink realpath rm rmdir sed seq sh shasum sleep sort stat tail tee touch tr uname wc xargs'
FM_TEST_CORE_BIN=
FM_TEST_CORE_BIN_KEY=

fm_test_find_real_tool() {
  local tool=$1 dir
  local search_path=${FM_TEST_REAL_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
  while [ -n "$search_path" ]; do
    dir=${search_path%%:*}
    if [ "$search_path" = "$dir" ]; then
      search_path=
    else
      search_path=${search_path#*:}
    fi
    [ -n "$dir" ] || continue
    if [ -x "$dir/$tool" ]; then
      printf '%s\n' "$dir/$tool"
      return 0
    fi
  done
  command -v "$tool" 2>/dev/null || return 1
}

fm_test_base_path() {
  local key tool real
  if [ -n "${FM_TEST_BASE_PATH:-}" ]; then
    printf '%s\n' "$FM_TEST_BASE_PATH"
    return 0
  fi
  key="${FM_TEST_REAL_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}|$*"
  if [ -n "$FM_TEST_CORE_BIN" ] && [ "$FM_TEST_CORE_BIN_KEY" = "$key" ]; then
    printf '%s\n' "$FM_TEST_CORE_BIN"
    return 0
  fi
  FM_TEST_CORE_BIN=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-base-path.XXXXXX") \
    || fail "fm_test_base_path could not create a private bin dir"
  FM_TEST_CORE_BIN_KEY=$key
  FM_TEST_CLEANUP_DIRS+=("$FM_TEST_CORE_BIN")
  fm_test_install_cleanup_trap
  for tool in $FM_TEST_BASE_TOOL_ALLOWLIST "$@"; do
    [ -n "$tool" ] || continue
    [ ! -e "$FM_TEST_CORE_BIN/$tool" ] || continue
    real=$(fm_test_find_real_tool "$tool") \
      || fail "fm_test_base_path could not find required real tool: $tool"
    ln -s "$real" "$FM_TEST_CORE_BIN/$tool"
  done
  printf '%s\n' "$FM_TEST_CORE_BIN"
}

fm_test_set_base_path() {
  local __fm_var=$1 key tool real
  shift
  case "$__fm_var" in
    ""|[!A-Za-z_]*|*[!A-Za-z0-9_]*) fail "fm_test_set_base_path requires a simple variable name" ;;
    __fm_*) fail "fm_test_set_base_path cannot fill '$__fm_var': __fm_* names are the helper's own locals" ;;
  esac
  if [ -n "${FM_TEST_BASE_PATH:-}" ]; then
    eval "$__fm_var=\$FM_TEST_BASE_PATH"
    return 0
  fi
  key="${FM_TEST_REAL_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}|$*"
  if [ -z "$FM_TEST_CORE_BIN" ] || [ "$FM_TEST_CORE_BIN_KEY" != "$key" ]; then
    FM_TEST_CORE_BIN=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-base-path.XXXXXX") \
      || fail "fm_test_base_path could not create a private bin dir"
    FM_TEST_CORE_BIN_KEY=$key
    FM_TEST_CLEANUP_DIRS+=("$FM_TEST_CORE_BIN")
    fm_test_install_cleanup_trap
    for tool in $FM_TEST_BASE_TOOL_ALLOWLIST "$@"; do
      [ -n "$tool" ] || continue
      [ ! -e "$FM_TEST_CORE_BIN/$tool" ] || continue
      real=$(fm_test_find_real_tool "$tool") \
        || fail "fm_test_base_path could not find required real tool: $tool"
      ln -s "$real" "$FM_TEST_CORE_BIN/$tool"
    done
  fi
  eval "$__fm_var=\$FM_TEST_CORE_BIN"
}

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects] [harness]: write the
# standard kind=secondmate meta block used across the secondmate suites. Window
# defaults to firstmate:fm-<id>, projects defaults to alpha, and harness defaults
# to echo to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 id window projects=${4:-alpha} harness=${5:-echo}
  id=$(basename "$file" .meta)
  window=${3:-firstmate:fm-$id}
  fm_write_meta "$file" \
    "window=$window" \
    "endpoint_task_id=$id" \
    "worktree=$home" \
    "project=$home" \
    "harness=$harness" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
