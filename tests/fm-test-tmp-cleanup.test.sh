#!/usr/bin/env bash
# Regression test for the shared fixture-home cleanup contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot PARENT_TMP firstmate-cleanup-proof
mkdir -p "$PARENT_TMP/root-override"

assert_no_fm_survivors() {
  local label=$1 survivors
  survivors=$(find "$PARENT_TMP" -mindepth 1 -maxdepth 1 -type d -name 'fm-*' -print)
  [ -z "$survivors" ] || fail "$label left fm-* temp dirs:"$'\n'"$survivors"
}

wait_for_file() {
  local file=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    [ -e "$file" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

run_bounded_sample() {
  local suite=$1 limit=${2:-60} out err pid start now rc
  out="$PARENT_TMP/$suite.out"
  err="$PARENT_TMP/$suite.err"
  start=$(date +%s)
  env -u FM_TEST_KEEP_TMP TMPDIR="$PARENT_TMP" FM_ROOT_OVERRIDE="$PARENT_TMP/root-override" \
    bash "$ROOT/tests/$suite" >"$out" 2>"$err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    if [ $((now - start)) -ge "$limit" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      assert_no_fm_survivors "$suite timeout cleanup"
      fail "$suite exceeded ${limit}s in the temp-cleanup regression"
    fi
    sleep 0.2
  done
  wait "$pid"
  rc=$?
  [ "$rc" -eq 0 ] || fail "$suite failed under the scratch TMPDIR; see $out and $err"
  assert_no_fm_survivors "$suite"
}

synthetic_suite="$PARENT_TMP/synthetic-cleanup-suite.sh"
cat > "$synthetic_suite" <<'SH'
#!/usr/bin/env bash
set -u
. "$1/tests/lib.sh"
fm_test_tmproot one fm-synthetic-one
fm_test_tmproot root fm-synthetic-root-name
mkdir -p "$one/nested" "$root/nested"
SH
chmod +x "$synthetic_suite"
bash "$synthetic_suite" "$ROOT" >/dev/null
assert_no_fm_survivors "synthetic cleanup suite"

signal_suite="$PARENT_TMP/synthetic-signal-suite.sh"
cat > "$signal_suite" <<'SH'
#!/usr/bin/env bash
set -u
. "$1/tests/lib.sh"
fm_test_tmproot root fm-synthetic-signal
printf ready > "$2"
mkfifo "$root/hold"
read _ < "$root/hold" || true
SH
chmod +x "$signal_suite"
ready="$PARENT_TMP/signal.ready"
bash "$signal_suite" "$ROOT" "$ready" >/dev/null &
signal_pid=$!
wait_for_file "$ready" || { kill -TERM "$signal_pid" 2>/dev/null || true; wait "$signal_pid" 2>/dev/null || true; fail "synthetic signal suite did not become ready"; }
kill -TERM "$signal_pid" 2>/dev/null || true
wait "$signal_pid" || signal_rc=$?
signal_rc=${signal_rc:-0}
[ "$signal_rc" -eq 143 ] || fail "synthetic signal suite exited $signal_rc instead of 143"
assert_no_fm_survivors "synthetic signal suite"

# Keep the real-suite sample intentionally small and fast: the synthetic suites
# above model the leak directly, while these prove ordinary converted suites run
# under a scratch TMPDIR without leaving fm-* roots.
run_bounded_sample fm-gotmp.test.sh 20
run_bounded_sample fm-documentation-audiences.test.sh 20
run_bounded_sample fm-tmux-submit-busy.test.sh 30

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

pass "bounded suites clean their fm-* temp dirs"

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
