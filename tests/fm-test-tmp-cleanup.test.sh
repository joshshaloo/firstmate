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

# The whole point of fm_test_track_bg_pid is the path no ordinary suite ever
# takes: a fail() between spawning a real background process and the test's own
# cleanup line. Nothing exercised that path, so a regression that turned
# tracking back into a no-op would have restored the original leak with zero
# failures. These three synthetic suites drive it directly.

bg_fixture_suite() {  # <path> <track|no-track>
  local file=$1 mode=$2
  # The fixture's body comes from -c, never from a file under the suite's own
  # temp root: that root is rm -rf'd on the way out, and a child that had not
  # yet opened its script would die of the removal rather than of the cleanup
  # under test. Its argv still names an fm- program so the read-only
  # process-table proof narrows to it the same way it narrows to a real watcher.
  cat > "$file" <<SH
#!/usr/bin/env bash
set -u
. "\$1/tests/lib.sh"
fm_test_tmproot leak fm-synthetic-bg
# A pid that is already gone must register nothing and must NOT be mistaken for
# a broken mechanism - the suite has to get past this line.
sleep 0 &
gone=\$!
wait "\$gone" 2>/dev/null || true
fm_test_track_bg_pid "\$gone"
FM_TEST_LEAK_HOME="\$leak" \
  bash -c 'printf ready > "\$1"; while :; do sleep 1; done' fm-leak-fixture.sh "\$3" &
leak_pid=\$!
$mode
i=0
while [ ! -e "\$3" ] && [ "\$i" -lt 200 ]; do
  sleep 0.05
  i=\$((i + 1))
done
[ -e "\$3" ] || { printf 'fixture never became ready\\n' >&2; exit 9; }
printf '%s\\n%s\\n' "\$leak_pid" "\$leak" > "\$2"
fail "synthetic mid-test failure before any cleanup line"
SH
  chmod +x "$file"
}

run_bg_fixture_suite() {  # <path> <meta> -> BG_SUITE_RC / BG_SUITE_PID / BG_SUITE_HOME
  local file=$1 meta=$2 ready
  ready="$meta.ready"
  rm -f "$ready"
  : > "$meta"
  BG_SUITE_RC=0
  env TMPDIR="$PARENT_TMP" bash "$file" "$ROOT" "$meta" "$ready" \
    >"$PARENT_TMP/$(basename "$file").out" 2>"$PARENT_TMP/$(basename "$file").err" \
    || BG_SUITE_RC=$?
  BG_SUITE_PID=$(sed -n '1p' "$meta")
  BG_SUITE_HOME=$(sed -n '2p' "$meta")
  [ "$BG_SUITE_RC" -eq 1 ] \
    || fail "synthetic bg suite $(basename "$file") exited $BG_SUITE_RC instead of 1"
  [ -n "$BG_SUITE_PID" ] && [ -n "$BG_SUITE_HOME" ] \
    || fail "synthetic bg suite $(basename "$file") never recorded its fixture"
}

# Negative control first: without tracking, the fixture process really does
# survive its suite - so the positive case below is proving cleanup, not
# observing a process that was never going to outlive the shell anyway.
untracked_suite="$PARENT_TMP/synthetic-bg-untracked-suite.sh"
bg_fixture_suite "$untracked_suite" ':'
run_bg_fixture_suite "$untracked_suite" "$PARENT_TMP/bg-untracked.meta"
fm_test_track_bg_pid "$BG_SUITE_PID"
untracked_survivors=$(fm_test_pids_with_env "FM_TEST_LEAK_HOME=$BG_SUITE_HOME")
[ -n "$untracked_survivors" ] \
  || fail "negative control did not leak: an untracked fixture process was already gone"
kill -TERM "$BG_SUITE_PID" 2>/dev/null || true
untracked_wait=0
while [ "$untracked_wait" -lt 100 ] && kill -0 "$BG_SUITE_PID" 2>/dev/null; do
  sleep 0.05
  untracked_wait=$((untracked_wait + 1))
done
fm_test_assert_no_process_for_env "FM_TEST_LEAK_HOME=$BG_SUITE_HOME" \
  "negative control cleanup"
pass "an untracked background fixture really does outlive its suite's fail()"

tracked_suite="$PARENT_TMP/synthetic-bg-tracked-suite.sh"
bg_fixture_suite "$tracked_suite" \
  'fm_test_track_fixture_bg_pid "$leak_pid" "FM_TEST_LEAK_HOME=$leak"'
run_bg_fixture_suite "$tracked_suite" "$PARENT_TMP/bg-tracked.meta"
fm_test_assert_no_process_for_env "FM_TEST_LEAK_HOME=$BG_SUITE_HOME" \
  "tracked fixture process after fail()"
pass "a tracked background fixture is reaped when fail() fires before any cleanup line"

# fm_test_track_bg_pid must refuse LOUDLY rather than silently registering
# nothing whenever it cannot identify the process it was handed - a safety net
# that reports success while catching nothing is the defect it exists to fix.
identity_refusal_suite() {  # <path> <fm_test_pid_identity override body>
  local file=$1 override=$2
  cat > "$file" <<SH
#!/usr/bin/env bash
set -u
. "\$1/tests/lib.sh"
fm_test_tmproot t fm-synthetic-identity
sleep 300 &
doomed=\$!
printf '%s\\n' "\$doomed" > "\$2"
fm_test_pid_identity() { $override }
fm_test_track_bg_pid "\$doomed"
printf 'REACHED-PAST-TRACK\\n'
SH
  chmod +x "$file"
}

assert_identity_refusal() {  # <path> <meta> <expected stderr fragment> <label>
  local file=$1 meta=$2 fragment=$3 label=$4 rc=0 out err doomed
  out="$PARENT_TMP/$(basename "$file").out"
  err="$PARENT_TMP/$(basename "$file").err"
  : > "$meta"
  env TMPDIR="$PARENT_TMP" bash "$file" "$ROOT" "$meta" >"$out" 2>"$err" || rc=$?
  doomed=$(sed -n '1p' "$meta")
  [ -z "$doomed" ] || { kill -TERM "$doomed" 2>/dev/null || true; wait "$doomed" 2>/dev/null || true; }
  [ "$rc" -eq 1 ] || fail "$label: suite exited $rc instead of failing"
  assert_no_grep 'REACHED-PAST-TRACK' "$out" "$label: tracking returned instead of failing the suite"
  grep -F "$fragment" "$err" >/dev/null || fail "$label: missing loud refusal; stderr was: $(cat "$err")"
}

platform_suite="$PARENT_TMP/synthetic-identity-platform-suite.sh"
identity_refusal_suite "$platform_suite" 'return 2;'
assert_identity_refusal "$platform_suite" "$PARENT_TMP/identity-platform.meta" \
  'not supported on this platform' 'unsupported platform'
pass "tracking refuses loudly, once, on a platform with no process-identity source"

pid_suite="$PARENT_TMP/synthetic-identity-pid-suite.sh"
identity_refusal_suite "$pid_suite" \
  '[ "$1" = "$$" ] || return 2; printf "starttime=synthetic\\n";'
assert_identity_refusal "$pid_suite" "$PARENT_TMP/identity-pid.meta" \
  'is alive but its process identity could not be read' 'unidentifiable live pid'
pass "tracking fails the suite when a live pid cannot be identified"

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
