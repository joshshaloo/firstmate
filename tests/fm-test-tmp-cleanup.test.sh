#!/usr/bin/env bash
# Regression test for the shared fixture-home cleanup contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot PARENT_TMP firstmate-cleanup-proof
mkdir -p "$PARENT_TMP/root-override"

run_sample() {
  local suite=$1 survivors
  env -u FM_TEST_KEEP_TMP TMPDIR="$PARENT_TMP" FM_ROOT_OVERRIDE="$PARENT_TMP/root-override" \
    bash "$ROOT/tests/$suite" >/dev/null \
    || fail "$suite failed under the scratch TMPDIR"
  survivors=$(find "$PARENT_TMP" -mindepth 1 -maxdepth 1 -type d -name 'fm-*' -print)
  [ -z "$survivors" ] || fail "$suite left fm-* temp dirs:"$'\n'"$survivors"
}

# The two heaviest fixture-home leakers before the shared contract landed
# (fm-afk-launch: 35 roots, fm-test-run: 9) lead the sample deliberately: they
# are the suites the contract has to hold for.
run_sample fm-afk-launch.test.sh
run_sample fm-test-run.test.sh
run_sample fm-spawn-worktree-claim.test.sh
run_sample fm-backend-herdr.test.sh
run_sample fm-bearings-snapshot.test.sh
run_sample fm-fleet-snapshot-view.test.sh
run_sample fm-teardown.test.sh
run_sample fm-watch-triage.test.sh

keep_out="$PARENT_TMP/keep.out"
keep_err="$PARENT_TMP/keep.err"
# shellcheck disable=SC2016 # Inner bash expands $1 and $T.
env FM_TEST_KEEP_TMP=1 TMPDIR="$PARENT_TMP" bash -c \
  '. "$1/tests/lib.sh"; fm_test_tmproot T fm-keep-proof; printf "%s\n" "$T"' \
  _ "$ROOT" >"$keep_out" 2>"$keep_err"
keep_dir=$(sed -n '1p' "$keep_out")
[ -d "$keep_dir" ] || fail "FM_TEST_KEEP_TMP=1 did not keep the registered temp dir"
grep -F "keeping test tmp: $keep_dir" "$keep_err" >/dev/null \
  || fail "FM_TEST_KEEP_TMP=1 did not print the kept temp dir"
rm -rf "$keep_dir"

pass "sample suites clean their fm-* temp dirs"

# tests/lib.sh owns EXIT for every suite that uses it: an EXIT trap installed
# after the first fm_test_tmproot call replaces the library's handler, silently
# dropping both the temp removal and the FM_TEST_KEEP_TMP=1 escape hatch. Such a
# suite must register its teardown with fm_test_at_exit instead. Heredoc bodies
# are skipped so traps inside fixture scripts written by a suite do not count.
offenders=$(
  for suite in "$ROOT"/tests/*.test.sh; do
    awk '
      { line = $0; sub(/^[ \t]+/, "", line) }
      heredoc != "" { if (line == heredoc) heredoc = ""; next }
      match($0, /<<-?[ \t]*'"'"'[^'"'"']+'"'"'/) {
        d = substr($0, RSTART, RLENGTH); sub(/^<<-?[ \t]*'"'"'/, "", d); sub(/'"'"'$/, "", d)
        heredoc = d; next
      }
      match($0, /<<-?[ \t]*"[^"]+"/) {
        d = substr($0, RSTART, RLENGTH); sub(/^<<-?[ \t]*"/, "", d); sub(/"$/, "", d)
        heredoc = d; next
      }
      match($0, /<<-?[A-Za-z_][A-Za-z0-9_]*/) {
        d = substr($0, RSTART, RLENGTH); sub(/^<<-?/, "", d); heredoc = d; next
      }
      first == 0 && $0 ~ /fm_test_tmproot[ \t]/ { first = NR; next }
      first != 0 && line ~ /^trap[ \t]/ && $0 ~ /EXIT/ {
        printf "%s:%d: %s\n", FILENAME, NR, line
      }
    ' "$suite"
  done
)
[ -z "$offenders" ] || fail \
  "suites must register teardown with fm_test_at_exit, not install an EXIT trap after fm_test_tmproot:"$'\n'"$offenders"

pass "no suite installs its own EXIT trap after fm_test_tmproot"
