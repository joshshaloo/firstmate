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
printf '%s\\n%s\\n' "\$leak_pid" "\$leak" > "\$2"
$mode
i=0
while [ ! -e "\$3" ] && [ "\$i" -lt 200 ]; do
  sleep 0.05
  i=\$((i + 1))
done
[ -e "\$3" ] || { printf 'fixture never became ready\\n' >&2; exit 9; }
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
  # The negative-control fixture is untracked inside its own suite by design, so
  # this is its only safety net - it has to be armed before the first assertion
  # that can exit, exactly like every other spawn site in this change.
  fm_test_track_bg_pid "$BG_SUITE_PID"
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

# A process that leaks past its test is only dangerous if it never exits on its
# own - that is the whole shape of the 2026-09-21 incident, a watcher still
# burning CPU 13 days later against a deleted fixture. Everything else a suite
# backgrounds (a drain, a spawn, a bounded `sleep 30`) self-terminates long
# before it could matter. So the three rules below are deliberately narrow, and
# together they cover every instance the review of this change turned up:
#
#   A. Every background spawn whose own command contains an UNBOUNDED loop must
#      be tracked within four executable lines. This is per SITE, not per file:
#      a whole-file "does this suite track anything?" check goes blind the
#      moment a suite gains its first tracker, which is exactly how the original
#      untracked `( while :; do sleep 1; done ) &` could return to
#      fm-pr-check-security.test.sh unnoticed.
#   B. Any suite whose fixture text contains an unbounded loop must register at
#      least one tracker/reaper. This is the backstop for the class rule A
#      cannot see: a fake tool a suite writes for the program under test to
#      spawn, where this shell never holds a pid and only the fixture's own
#      environment marker can reach it.
#   C. Any background spawn of a real long-running firstmate program must be
#      tracked within four lines, or funnel through wake-helpers' wait_for_exit.
#
# Exemptions are per file and must state why the loop cannot outlive the suite.
bg_tracking_exempt() {  # <file> -> 0 when exempt
  case "${1##*/}" in
    # The unbounded loops here are string literals in policy test data - the
    # argument checker under test must DENY them; nothing ever executes them.
    fm-arm-pretool-check.test.sh) return 0 ;;
    # The heartbeat loop runs inside a Herdr pane, and cleanup_all - registered
    # with fm_test_at_exit before the pane starts - destroys that session on
    # every exit path, taking its panes with it.
    fm-backend-herdr-prune-safety-e2e.test.sh) return 0 ;;
  esac
  return 1
}

LONG_RUNNING_PROGRAMS='fm-watch[.]sh|fm-watch-arm[.]sh|fm-supervise-daemon[.]sh'
unbounded_offenders=
untracked_spawns=
for suite in "$ROOT"/tests/*.sh; do
  bg_tracking_exempt "$suite" && continue
  hits=$(awk -v progs="$LONG_RUNNING_PROGRAMS" '
    # Single owner of "this loop never ends on its own". A test that also
    # carries a counter bound terminates regardless of what it is waiting for.
    function unbounded(t) {
      if (t ~ /while[[:space:]]*:/ || t ~ /while[[:space:]]+true/) return 1
      if (t ~ /-lt|-le|-gt|-ge/) return 0
      if (t ~ /while[[:space:]]*\[[^]]*![[:space:]]*-[efsd][[:space:]]/) return 1
      if (t ~ /until[[:space:]]*\[[^]]*[[:space:]]-[efsd][[:space:]]/) return 1
      if (t ~ /while[[:space:]]*\[[^]]*-z[[:space:]]/) return 1
      return 0
    }
    function tracked_after(n,   k, seen) {
      # Count only lines that could actually run: a comment cannot leak a
      # process, and spawn sites are routinely annotated.
      seen = 0
      for (k = n + 1; k <= NR && seen < 4; k++) {
        if (line[k] ~ /^[[:space:]]*(#|$)/) continue
        seen++
        if (line[k] ~ /fm_test_track_bg_pid|fm_test_track_fixture_bg_pid|wait_for_exit/) return 1
      }
      return 0
    }
    {
      line[NR] = $0
      body = $0; sub(/^[ \t]+/, "", body)
      # Heredoc bodies are the program under test being handed a fake tool, not
      # this shell backgrounding something - rule A cannot apply, rule B can.
      if (hd != "") {
        if (body == hd) hd = ""
        else if (unbounded($0)) spins = 1
        inhd[NR] = 1; next
      }
      # Rule B is about FIXTURE text - a loop a suite writes for something else
      # to run. A loop in statement position is this shell waiting on its own
      # work: if that never ends the suite hangs, which is a visible failure,
      # not a process still burning CPU after the suite is gone.
      if (unbounded($0) && body !~ /^(while|until)[[:space:]]/) spins = 1
      if ($0 ~ /fm_test_track_bg_pid|fm_test_track_fixture_bg_pid|fm_test_reap_env_at_exit/) registers = 1
      if (match($0, /<<-?[ \t]*\047[^\047]+\047/)) {
        d = substr($0, RSTART, RLENGTH); sub(/^<<-?[ \t]*\047/, "", d); sub(/\047$/, "", d); hd = d; next
      }
      if (match($0, /<<-?[ \t]*"[^"]+"/)) {
        d = substr($0, RSTART, RLENGTH); sub(/^<<-?[ \t]*"/, "", d); sub(/"$/, "", d); hd = d; next
      }
      # A suite names the long-running programs through a variable far more
      # often than inline, so resolve those assignments before rule C looks.
      if ($0 ~ "^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*=.*(" progs ")") {
        name = $0; sub(/^[[:space:]]*/, "", name); sub(/=.*$/, "", name); alias[name] = 1
      }
      if (match($0, /<<-?[A-Za-z_][A-Za-z0-9_]*/)) {
        d = substr($0, RSTART, RLENGTH); sub(/^<<-?/, "", d); hd = d; next
      }
    }
    END {
      if (spins && !registers) printf "B %s\n", FILENAME
      for (n = 1; n <= NR; n++) {
        if (inhd[n]) continue
        if (line[n] !~ /&[[:space:]]*$/ || line[n] ~ /&&[[:space:]]*$/) continue
        # Walk back to the start of the backgrounded command. A spawn spans
        # several lines in three shapes this tree uses: a `( ... ) &` subshell,
        # a multi-line `bash -c ... &` script, and backslash continuations.
        # Continuing while the joined text has an unclosed quote or paren, or
        # the line above continues, covers all three without parsing the shell.
        spawn = line[n]
        for (b = n - 1; b >= 1 && n - b < 40; b--) {
          probe = spawn; q = gsub(/\047/, "", probe)
          probe = spawn; o = gsub(/\(/, "", probe)
          probe = spawn; c = gsub(/\)/, "", probe)
          if (q % 2 == 0 && c <= o && line[b] !~ /\\$/) break
          spawn = line[b] " " spawn
        }
        named = (spawn ~ progs)
        for (name in alias)
          if (spawn ~ ("[$]\\{?" name "\\}?")) named = 1
        if (!named && !unbounded(spawn)) continue
        if (!tracked_after(n)) printf "%s %s:%d\n", (named ? "C" : "A"), FILENAME, n
      }
    }
  ' "$suite")
  while read -r kind where; do
    [ -n "$where" ] || continue
    case "$kind" in
      B) unbounded_offenders="$unbounded_offenders"$'\n'"  ${where#"$ROOT"/}" ;;
      *) untracked_spawns="$untracked_spawns"$'\n'"  ${where#"$ROOT"/}" ;;
    esac
  done <<EOF
$hits
EOF
done
[ -z "$unbounded_offenders" ] || fail \
  "suites whose fixture text spins forever must register cleanup (fm_test_track_bg_pid / fm_test_reap_env_at_exit) or be exempted in bg_tracking_exempt:$unbounded_offenders"
[ -z "$untracked_spawns" ] || fail \
  "background spawns of an unbounded fixture or a long-running firstmate program must be tracked within four executable lines or funnel through wait_for_exit:$untracked_spawns"

pass "every unbounded background fixture and long-running spawn registers cleanup"
