#!/usr/bin/env bash
# Regression test for the shared fixture-home cleanup contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot PARENT_TMP firstmate-cleanup-proof
mkdir -p "$PARENT_TMP/root-override"

run_sample() {
  local suite=$1 survivors
  env -u FM_TEST_KEEP_TMP TMPDIR="$PARENT_TMP" FM_ROOT_OVERRIDE="$PARENT_TMP/root-override" bash "$ROOT/tests/$suite" >/dev/null
  survivors=$(find "$PARENT_TMP" -mindepth 1 -maxdepth 1 -type d -name 'fm-*' -print)
  [ -z "$survivors" ] || fail "$suite left fm-* temp dirs:"$'\n'"$survivors"
}

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

pass "sample suites clean their fm-* temp dirs"
