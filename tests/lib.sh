#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, a hermetic base PATH, fakebin/PATH-shim
# helpers, deterministic git identity and fixture builders, state/<id>.meta
# writers, and the common string/exit-code/file assertions. It deliberately does
# NOT bundle the behavior-specific fake tmux/treehouse/no-mistakes mocks: those
# encode terminal and lifecycle assumptions that differ per suite and belong
# with the tests that own them.
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

# --- backgrounded real processes --------------------------------------------
#
# A test that starts a real background process (a watcher, an arm, a daemon,
# any long-running fixture) and only kills it at the bottom of the test
# function leaks that process - with its fixture directory removed out from
# under it - whenever an assertion between spawn and cleanup calls fail(), or
# the suite is interrupted. Two independent mechanisms close that:
#
#   fm_test_track_bg_pid / fm_test_track_fixture_bg_pid
#       guaranteed TERM-then-KILL of exactly that one process on ANY exit path
#       (normal completion, fail()'s exit 1, or a signal), via fm_test_at_exit.
#   fm_test_assert_no_process_for_env / fm_test_prove_env_clear_at_exit
#       an independent, read-only process-table proof that nothing is still
#       running against a fixture, rather than trusting a test's own pid
#       bookkeeping to say so.
#
# Everything here is scoped to one pid or to one exact fixture environment
# assignment - never a pattern or a process sweep - so it can never reach a
# sibling fixture's process, let alone a live firstmate home's watcher.

FM_TEST_BG_PIDS=()
FM_TEST_BG_IDENTITIES=()
FM_TEST_BG_COUNT=0
FM_TEST_ENV_PROOFS=()
FM_TEST_ENV_PROOF_COUNT=0
FM_TEST_ENV_REAPS=()
FM_TEST_ENV_REAP_COUNT=0
FM_TEST_PID_IDENTITY_SUPPORTED=0
# TERM budget before escalating to KILL. It has to exceed the reaped tree's OWN
# cleanup budget, or the escalation orphans exactly the child this mechanism
# exists to catch: bin/fm-watch-arm.sh's signal handler TERMs its forked
# bin/fm-watch.sh and then waits for it, and that child's `trap 'exit 1'` only
# runs once its in-flight foreground command returns (a `sleep $FM_SIGNAL_GRACE`,
# or a custom check that merely records the signal as pending). The loop below
# stops the moment the process is gone, so a generous cap is free on every path
# except the genuinely wedged one - and the suite is exiting anyway.
FM_TEST_BG_TERM_GRACE_SECS=${FM_TEST_BG_TERM_GRACE_SECS:-5}

# fm_test_pid_stat_fields <pid>: everything after the final comm delimiter in
# proc stat, i.e. field 3 onward. Index 0 is field 3 (process state), index 19
# is field 22 (starttime, ticks since boot). Single owner of this parse.
fm_test_pid_stat_fields() {
  local pid=$1 stat_line
  [ -r "/proc/$pid/stat" ] || return 1
  stat_line=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
  printf '%s\n' "${stat_line##*)}"
}

# fm_test_pid_state <pid>: the process state the OS reports - S/R/D/Z, or T for
# a SIGSTOPped process. Empty and non-zero when the pid cannot be read at all.
fm_test_pid_state() {
  local pid=$1 fields out
  local -a stat_fields
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if fields=$(fm_test_pid_stat_fields "$pid"); then
    read -r -a stat_fields <<< "$fields"
    [ "${#stat_fields[@]}" -ge 1 ] || return 1
    printf '%s\n' "${stat_fields[0]}"
    return 0
  fi
  out=$(LC_ALL=C ps -p "$pid" -o stat= 2>/dev/null | sed 's/^[[:space:]]*//')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# fm_test_pid_ignores_term <pid>: true only when the kernel states outright that
# SIGTERM is in this process's ignored-signal mask (what bash's `trap "" TERM`
# installs - tests/fm-pr-check-security.test.sh's custom-check child does exactly
# that). Such a process cannot exit on TERM no matter how long the grace is, so
# waiting one out is pure dead time at teardown. Where the mask cannot be read
# this answers false, which keeps the full grace - the safe default.
fm_test_pid_ignores_term() {
  local pid=$1 sigign low
  [ -r "/proc/$pid/status" ] || return 1
  sigign=$(awk '$1 == "SigIgn:" { print $2; exit }' "/proc/$pid/status" 2>/dev/null)
  [ "${#sigign}" -ge 4 ] || return 1
  low=${sigign: -4}
  case "$low" in
    *[!0-9a-fA-F]*) return 1 ;;
  esac
  # SIGTERM is signal 15, i.e. bit 14 of the mask.
  [ $(( (0x$low >> 14) & 1 )) -eq 1 ]
}

# fm_test_pid_identity <pid>: the fact that tells a live process apart from a
# later, unrelated process that merely reused its pid - when it started. Start
# time is fixed at fork; the command line is not, because it only becomes the
# tracked program's once the child execs. A pid captured from "$!" is tracked
# before that exec lands, so folding the command line in here would make every
# freshly forked process fail its own identity check a moment later and go
# unreaped. bin/fm-wake-lib.sh's fm_pid_identity answers the same question for
# the production watcher, which records itself after exec and can therefore
# combine both; that library cannot be sourced here anyway, since it resolves
# FM_HOME/STATE and creates a state directory as a side effect that every test
# file would inherit.
#
# Exit status distinguishes the two ways this can come back empty, because they
# mean opposite things to a caller:
#   0  identified; the identity is on stdout
#   1  the pid is gone or already a zombie - there is nothing left to leak
#   2  the pid names a LIVE process this mechanism could not identify, i.e. the
#      mechanism itself is broken and must never be treated as "nothing to do"
fm_test_pid_identity() {
  local pid=$1 fields out
  local -a stat_fields
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if fields=$(fm_test_pid_stat_fields "$pid"); then
    read -r -a stat_fields <<< "$fields"
    [ "${#stat_fields[@]}" -ge 20 ] || return 2
    [ "${stat_fields[0]}" != Z ] || return 1
    case "${stat_fields[19]}" in
      ''|*[!0-9]*) return 2 ;;
    esac
    printf 'starttime=%s\n' "${stat_fields[19]}"
    return 0
  fi
  # Pin LC_ALL=C so lstart's rendering cannot vary with the ambient locale
  # between the capture and the re-check.
  out=$(LC_ALL=C ps -p "$pid" -o stat= -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//')
  if [ -n "$out" ]; then
    case "$out" in
      Z*) return 1 ;;
    esac
    printf 'lstart=%s\n' "$out"
    return 0
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  return 2
}

# Refuse ONCE, loudly, on a platform where neither identity source answers, so
# the mechanism can never quietly degrade into a no-op that reports success
# while protecting nothing. The test runner's own pid is a process that is
# definitionally live, so it is the honest probe.
fm_test_require_pid_identity() {
  [ "$FM_TEST_PID_IDENTITY_SUPPORTED" -eq 0 ] || return 0
  if fm_test_pid_identity "$$" >/dev/null 2>&1; then
    FM_TEST_PID_IDENTITY_SUPPORTED=1
    return 0
  fi
  fail "background-process tracking is not supported on this platform: neither /proc/<pid>/stat nor 'ps -p <pid> -o stat= -o lstart=' identifies the test runner itself, so a tracked process could not be reaped safely"
}

fm_test_bg_pid_is_tracked() {
  local pid=$1 identity=$2 now
  now=$(fm_test_pid_identity "$pid") || return 1
  [ "$now" = "$identity" ]
}

# fm_test_track_bg_pid <pid>: register <pid> for guaranteed TERM-then-KILL
# cleanup on ANY exit path. Call it immediately after capturing the pid (right
# after "... &"; pid=$!), before any assertion that could fail. The process's
# identity is captured now and re-verified before every signal, and the
# registration is consumed the first time it fires, so a pid the kernel later
# hands to an unrelated process can never be signalled by a stale hook.
#
# A pid that is already gone registers nothing and is not an error - there is
# nothing left to leak. A pid that is alive but unidentifiable fails the suite
# on the spot rather than returning as if tracking had succeeded: a safety net
# that silently catches nothing is the same defect this mechanism exists to fix.
fm_test_track_bg_pid() {
  local pid=$1 slot identity rc=0
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  # Never the suite's own shell or its parent: a fixture pid read back from a
  # lock file can legitimately be the test runner (tests seed $$ into a lock to
  # stand in for a rival holder), and reaping that would kill the suite mid-run.
  [ "$pid" != "$$" ] && [ "$pid" != "${BASHPID:-$$}" ] && [ "$pid" != "${PPID:-0}" ] \
    || return 0
  fm_test_require_pid_identity
  identity=$(fm_test_pid_identity "$pid") || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) fail "fm_test_track_bg_pid: pid $pid is alive but its process identity could not be read, so it cannot be tracked for guaranteed cleanup" ;;
  esac
  slot=$FM_TEST_BG_COUNT
  FM_TEST_BG_COUNT=$((FM_TEST_BG_COUNT + 1))
  FM_TEST_BG_PIDS[slot]=$pid
  FM_TEST_BG_IDENTITIES[slot]=$identity
  fm_test_at_exit "fm_test_reap_bg_pid $slot"
}

# Signal the tracked process's own process group when - and only when - it leads
# one, so a KILL escalation cannot strand a child it forked. Guarded on pgid ==
# pid: a process backgrounded by a non-interactive shell inherits that shell's
# group, and signalling THAT group would reach the test runner itself.
fm_test_signal_bg_group() {
  local pid=$1 signal=$2 pgid
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  [ "$pgid" = "$pid" ] || return 0
  kill "-$signal" "-$pid" 2>/dev/null || true
}

fm_test_reap_bg_pid() {
  local slot=$1 pid identity
  pid=${FM_TEST_BG_PIDS[slot]:-}
  identity=${FM_TEST_BG_IDENTITIES[slot]:-}
  # Consume the registration: a tracked process is signalled at most once.
  FM_TEST_BG_PIDS[slot]=
  FM_TEST_BG_IDENTITIES[slot]=
  [ -n "$pid" ] || return 0
  fm_test_reap_identified_pid "$pid" "$identity"
}

# fm_test_reap_identified_pid <pid> [identity]: TERM-then-KILL exactly the
# process that <identity> names, re-verifying before every signal so a pid the
# kernel has since handed to something else can never be reached. An empty
# identity means "capture it now" - the caller resolved this pid moments ago.
fm_test_reap_identified_pid() {
  local pid=$1 identity=${2:-} i=0 grace state
  [ -n "$identity" ] || identity=$(fm_test_pid_identity "$pid") || return 0
  fm_test_bg_pid_is_tracked "$pid" "$identity" || return 0
  grace=$((FM_TEST_BG_TERM_GRACE_SECS * 50))
  kill -TERM "$pid" 2>/dev/null || true
  fm_test_signal_bg_group "$pid" TERM
  # The grace exists so a process can run its OWN TERM cleanup - which is what
  # keeps the children it forked from being orphaned. Two tracked shapes can
  # never use it: a SIGSTOPped process cannot run a handler until something
  # continues it, and a process that ignores TERM never runs one at all. Continue
  # the first so it can honour the signal; for the second the grace is dead time,
  # so go straight to the KILL escalation.
  state=$(fm_test_pid_state "$pid" 2>/dev/null) || state=
  case "$state" in
    T*|t*) kill -CONT "$pid" 2>/dev/null || true ;;
  esac
  if fm_test_pid_ignores_term "$pid"; then
    grace=0
  fi
  while [ "$i" -lt "$grace" ] && fm_test_bg_pid_is_tracked "$pid" "$identity"; do
    sleep 0.02
    i=$((i + 1))
  done
  if fm_test_bg_pid_is_tracked "$pid" "$identity"; then
    fm_test_signal_bg_group "$pid" KILL
    kill -KILL "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 50 ] && fm_test_bg_pid_is_tracked "$pid" "$identity"; do
      sleep 0.02
      i=$((i + 1))
    done
  fi
  wait "$pid" 2>/dev/null || true
}

# fm_test_scan_env_proofs <NAME=value>...: ONE pass over the live process table,
# printing "<index> <pid>" for every process whose OWN environment carries the
# <index>'th assignment (0-based). However many fixtures are asked about, this
# forks `ps -A` once and reads each candidate's environment once, so a suite
# that registers dozens of fixtures still pays for a single sweep.
#
# Read-only - it never signals anything - and matched on the process's real
# environment, so it can only ever name a process belonging to one of the exact
# fixtures asked about, never a sibling fixture's or a live firstmate home's.
# Candidates are narrowed first by the cheap process-table fields (a firstmate
# program, or a command line naming one of the fixture paths).
fm_test_scan_env_proofs() {
  local pid args env_text entry idx candidate
  while read -r pid args; do
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$pid" != "$$" ] && [ "$pid" != "${BASHPID:-$$}" ] && [ "$pid" != "${PPID:-0}" ] \
      || continue
    candidate=0
    case "$args" in
      *fm-*) candidate=1 ;;
    esac
    if [ "$candidate" -eq 0 ]; then
      for entry in "$@"; do
        case "$args" in
          *"${entry#*=}"*) candidate=1; break ;;
        esac
      done
    fi
    [ "$candidate" -eq 1 ] || continue
    if [ -r "/proc/$pid/environ" ]; then
      env_text=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null || true)
    else
      env_text=$(ps -E -p "$pid" -o command= 2>/dev/null | tr ' ' '\n' || true)
    fi
    idx=0
    for entry in "$@"; do
      case "
$env_text
" in
        *"
$entry
"*) printf '%s %s\n' "$idx" "$pid" ;;
      esac
      idx=$((idx + 1))
    done
  done <<EOF
$(ps -A -o pid=,args= 2>/dev/null)
EOF
}

# fm_test_pids_with_env <NAME=value>: pids of live processes whose OWN
# environment carries exactly this assignment.
fm_test_pids_with_env() {
  local idx pid hits=''
  while read -r idx pid; do
    [ -n "$pid" ] || continue
    hits="$hits $pid"
  done <<EOF
$(fm_test_scan_env_proofs "$1")
EOF
  printf '%s' "$hits"
}

# fm_test_assert_no_process_for_env <NAME=value> <label>: prove, right now and
# independently of the test's own bookkeeping, that no live process still runs
# against this fixture.
fm_test_assert_no_process_for_env() {
  local hits
  hits=$(fm_test_pids_with_env "$1")
  [ -z "$hits" ] || fail "$2: live process(es)$hits still running with $1"
}

# fm_test_prove_env_clear_at_exit <NAME=value> [label]: the same proof, deferred
# to suite exit and applied to every registered fixture in one sweep.
#
# Ordering is structural, not a matter of registration order: fm_test_exit_handler
# calls fm_test_run_env_proofs only after fm_test_run_exit_hooks has returned, so
# the proof always grades every fm_test_track_bg_pid reap instead of racing one.
# A leak fails the suite by assigning FM_TEST_EXIT_STATUS rather than calling
# exit, which would skip the teardown still queued behind it.
fm_test_prove_env_clear_at_exit() {
  local assignment=$1 label=${2:-$1} entry
  fm_test_install_cleanup_trap
  for entry in "${FM_TEST_ENV_PROOFS[@]:-}"; do
    [ -n "$entry" ] || continue
    [ "${entry%%	*}" != "$assignment" ] || return 0
  done
  FM_TEST_ENV_PROOFS[FM_TEST_ENV_PROOF_COUNT]="$assignment	$label"
  FM_TEST_ENV_PROOF_COUNT=$((FM_TEST_ENV_PROOF_COUNT + 1))
}

fm_test_run_env_proofs() {
  local entry idx pid i
  local -a assignments=() labels=() hits=()
  for entry in "${FM_TEST_ENV_PROOFS[@]:-}"; do
    [ -n "$entry" ] || continue
    assignments+=("${entry%%	*}")
    labels+=("${entry#*	}")
    hits+=("")
  done
  FM_TEST_ENV_PROOFS=()
  FM_TEST_ENV_PROOF_COUNT=0
  [ "${#assignments[@]}" -gt 0 ] || return 0
  while read -r idx pid; do
    [ -n "$pid" ] || continue
    hits[idx]="${hits[idx]} $pid"
  done <<EOF
$(fm_test_scan_env_proofs "${assignments[@]}")
EOF
  i=0
  while [ "$i" -lt "${#assignments[@]}" ]; do
    if [ -n "${hits[i]}" ]; then
      printf 'not ok - %s: leaked process(es)%s still running with %s\n' \
        "${labels[i]}" "${hits[i]}" "${assignments[i]}" >&2
      FM_TEST_EXIT_STATUS=1
    fi
    i=$((i + 1))
  done
}

# fm_test_track_fixture_bg_pid <pid> <NAME=value> [label]: both mechanisms for a
# process started against a test fixture - guaranteed reaping of that exact
# process, plus the independent end-of-suite proof that nothing is left running
# against that fixture.
fm_test_track_fixture_bg_pid() {
  fm_test_prove_env_clear_at_exit "$2" "${3:-$2}"
  fm_test_track_bg_pid "$1"
}

# fm_test_reap_env_at_exit <NAME=value> [label]: guaranteed cleanup for every
# process carrying this fixture's environment assignment, whoever forked it.
# fm_test_track_bg_pid needs a pid, so it structurally cannot cover a process a
# DESCENDANT spawns - a node plugin's child, a production script's fork, a fake
# binary a tool under test invokes. Those are reachable only by the fixture
# marker they inherit. Resolution and reaping stay bound to that exact
# assignment, so this can only ever reach a process belonging to this fixture,
# never a sibling's or a live firstmate home's. Registering also registers the
# independent proof, so the cleanup is always graded rather than assumed.
fm_test_reap_env_at_exit() {
  local assignment=$1 label=${2:-$1} entry
  fm_test_prove_env_clear_at_exit "$assignment" "$label"
  for entry in "${FM_TEST_ENV_REAPS[@]:-}"; do
    [ "$entry" != "$assignment" ] || return 0
  done
  FM_TEST_ENV_REAPS[FM_TEST_ENV_REAP_COUNT]=$assignment
  FM_TEST_ENV_REAP_COUNT=$((FM_TEST_ENV_REAP_COUNT + 1))
}

fm_test_run_env_reaps() {
  local entry idx pid
  local -a assignments=()
  for entry in "${FM_TEST_ENV_REAPS[@]:-}"; do
    [ -n "$entry" ] || continue
    assignments+=("$entry")
  done
  FM_TEST_ENV_REAPS=()
  FM_TEST_ENV_REAP_COUNT=0
  [ "${#assignments[@]}" -gt 0 ] || return 0
  while read -r idx pid; do
    [ -n "$pid" ] || continue
    fm_test_reap_identified_pid "$pid"
  done <<EOF
$(fm_test_scan_env_proofs "${assignments[@]}")
EOF
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
  fm_test_run_env_reaps
  fm_test_run_env_proofs
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
# fm_test_set_base_path <var> [extra-tool...] fills <var> with the hermetic base
# PATH for suites that prepend a fakebin. FM_TEST_BASE_PATH remains an explicit
# override. Otherwise the base PATH is a private bin directory holding only the
# allowlisted real system tools symlinked by name, plus the extra tools the
# caller opts into. That keeps host-installed tools such as herdr, tmux, gh, or
# node from satisfying a test that meant to fake or omit them.
#
# FM_TEST_BASE_TOOL_ALLOWLIST names core tools bin/ invokes unconditionally, so
# a missing one fails the suite. FM_TEST_BASE_TOOL_OPTIONAL_ALLOWLIST names the
# platform-variant tools bin/ chooses between with command -v (md5/md5sum,
# timeout/gtimeout); each is linked when the host has it and skipped when it does
# not, because no single host ships both halves of those pairs.
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

FM_TEST_DEFAULT_REAL_BASE_PATH='/usr/bin:/bin:/usr/sbin:/sbin'
FM_TEST_BASE_TOOL_ALLOWLIST='awk base64 basename bash cat chmod cksum cmp cp cut date dd dirname env find git grep head id kill ln ls mkdir mktemp mv od openssl paste perl printf ps pwd readlink realpath rm rmdir sed seq sh shasum sleep sort stat tail tee touch tr uname uniq wc xargs'
FM_TEST_BASE_TOOL_OPTIONAL_ALLOWLIST='gtimeout md5 md5sum timeout'
FM_TEST_CORE_BIN=
FM_TEST_CORE_BIN_KEY=

fm_test_find_real_tool() {
  local tool=$1 dir
  local search_path=${FM_TEST_REAL_BASE_PATH:-$FM_TEST_DEFAULT_REAL_BASE_PATH}
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
  key="${FM_TEST_REAL_BASE_PATH:-$FM_TEST_DEFAULT_REAL_BASE_PATH}|$*"
  if [ -z "$FM_TEST_CORE_BIN" ] || [ "$FM_TEST_CORE_BIN_KEY" != "$key" ]; then
    FM_TEST_CORE_BIN=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-base-path.XXXXXX") \
      || fail "fm_test_set_base_path could not create a private bin dir"
    FM_TEST_CORE_BIN_KEY=$key
    FM_TEST_CLEANUP_DIRS+=("$FM_TEST_CORE_BIN")
    fm_test_install_cleanup_trap
    for tool in $FM_TEST_BASE_TOOL_ALLOWLIST "$@"; do
      [ -n "$tool" ] || continue
      [ ! -e "$FM_TEST_CORE_BIN/$tool" ] || continue
      real=$(fm_test_find_real_tool "$tool") \
        || fail "fm_test_set_base_path could not find required real tool: $tool"
      ln -s "$real" "$FM_TEST_CORE_BIN/$tool"
    done
    for tool in $FM_TEST_BASE_TOOL_OPTIONAL_ALLOWLIST; do
      [ ! -e "$FM_TEST_CORE_BIN/$tool" ] || continue
      real=$(fm_test_find_real_tool "$tool") || continue
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
