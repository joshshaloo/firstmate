#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
fm_test_tmproot TMP_ROOT fm-spawn-worktree-settle

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    elif [ -f "${FM_FAKE_PANE_PATH_FILE:-}" ]; then
      cat "$FM_FAKE_PANE_PATH_FILE"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_TREEHOUSE_OUTPUT:-}" ]; then
      for arg in "$@"; do
        case "$arg" in
          *'treehouse get'*) bash -c "$arg" >> "$FM_FAKE_TREEHOUSE_OUTPUT" 2>&1 ;;
          exit) [ -z "${FM_FAKE_PANE_PATH_FILE:-}" ] || printf '%s\n' "$FM_FAKE_PROJECT" > "$FM_FAKE_PANE_PATH_FILE" ;;
        esac
      done
    fi
    exit 0 ;;
  capture-pane)
    [ -f "${FM_FAKE_TREEHOUSE_OUTPUT:-}" ] || exit 0
    if [ -n "${FM_FAKE_PANE_FOLD:-}" ]; then
      fold -w "$FM_FAKE_PANE_FOLD" "$FM_FAKE_TREEHOUSE_OUTPUT"
    else
      cat "$FM_FAKE_TREEHOUSE_OUTPUT"
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

POOL_FULL_MESSAGE="all 16 worktrees are in use or dirty (max_trees = 16). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml"

# write_failing_treehouse <fakebin>: the first FM_TEST_TREEHOUSE_GRANTS calls
# move the pane into FM_FAKE_WORKTREE; every later call prints the optional
# FM_TEST_TREEHOUSE_PRELUDE and then FM_TEST_TREEHOUSE_ERROR, and fails.
write_failing_treehouse() {
  cat > "$1/treehouse" <<'SH'
#!/usr/bin/env bash
n=0
[ ! -f "$FM_TEST_TREEHOUSE_CALLS" ] || n=$(cat "$FM_TEST_TREEHOUSE_CALLS")
n=$((n + 1))
printf '%s\n' "$n" > "$FM_TEST_TREEHOUSE_CALLS"
if [ "$n" -le "${FM_TEST_TREEHOUSE_GRANTS:-0}" ]; then
  printf '%s\n' "$FM_FAKE_WORKTREE" > "$FM_FAKE_PANE_PATH_FILE"
  exit 0
fi
[ -z "${FM_TEST_TREEHOUSE_PRELUDE:-}" ] || printf '%s\n' "$FM_TEST_TREEHOUSE_PRELUDE"
printf '%s\n' "$FM_TEST_TREEHOUSE_ERROR" >&2
exit 1
SH
  chmod +x "$1/treehouse"
}

# claim_settle_slot <task-id> <worktree>: record <worktree> as another task's.
claim_settle_slot() {
  fm_write_meta "$HOME_DIR/state/$1.meta" \
    "window=firstmate:fm-$1" \
    "endpoint_task_id=$1" \
    "worktree=$2" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "tasktmp=/tmp/fm-$1" \
    "model=default" \
    "effort=default"
}

# run_failing_get <id> <error> [env...]: spawn against write_failing_treehouse
# with the pane starting in the project and no inter-poll sleep.
run_failing_get() {
  local id=$1 message=$2
  shift 2
  printf '%s\n' "$PROJ_DIR" > "$HOME_DIR/pane-path"
  rm -f "$HOME_DIR/pane-output" "$HOME_DIR/treehouse-calls" "$COUNTFILE"
  write_failing_treehouse "$FAKEBIN_DIR"
  (
    # shellcheck disable=SC2163  # the extra arguments are NAME=value assignments.
    export "$@" FM_TEST_TREEHOUSE_ERROR="$message" FM_TEST_TREEHOUSE_CALLS="$HOME_DIR/treehouse-calls" \
      FM_FAKE_TREEHOUSE_OUTPUT="$HOME_DIR/pane-output" FM_FAKE_PANE_PATH_FILE="$HOME_DIR/pane-path" \
      FM_FAKE_PROJECT="$PROJ_DIR" FM_FAKE_WORKTREE="$WT_DIR" FM_SPAWN_WORKTREE_POLL_INTERVAL=0
    run_settle_spawn "$id"
  )
}

first_error_line() {  # <output>
  printf '%s\n' "$1" | grep -m1 '^error:'
}

# Exercise the sent command as well as the polling loop. A fake failed get
# leaves the pane in the project, just like an exhausted treehouse pool.
test_treehouse_failure_is_reported_immediately() {
  local rec id out status message
  id=settle-pool-full
  rec=$(make_settle_case pool-full "$id" 0)
  read_settle_record "$rec"
  claim_settle_slot occupant-pool "$WT_DIR"

  out=$(run_failing_get "$id" "$POOL_FULL_MESSAGE")
  status=$?
  expect_code 1 "$status" "pool exhaustion should stop spawn"
  [ "$(first_error_line "$out")" = "error: $POOL_FULL_MESSAGE" ] \
    || fail "treehouse error was not reported first and verbatim: $out"
  assert_contains "$out" "claimed by occupant-pool" "pool exhaustion dropped the protected-record context"
  assert_contains "$out" "Run 'treehouse status' in $PROJ_DIR and free or return a slot, or increase max_trees in treehouse.toml." \
    "missing capacity recovery hint"
  assert_not_contains "$out" "within 60 polls" "pool exhaustion fell through to timeout"
  [ "$(< "$COUNTFILE")" = 1 ] || fail "failed get was not detected on the first poll"
  assert_absent "$HOME_DIR/state/$id.meta" "failed get published metadata"
  pass "pool exhaustion fails on the first poll with the original treehouse error and the records holding slots"

  message="Error: cannot read treehouse.toml: permission denied"
  out=$(run_failing_get "$id" "$message")
  status=$?
  expect_code 1 "$status" "other treehouse failures should stop spawn"
  [ "$(first_error_line "$out")" = "error: $message" ] \
    || fail "generic treehouse error was not reported first and verbatim: $out"
  assert_contains "$out" "check that treehouse itself is working in $PROJ_DIR" "missing non-capacity recovery hint"
  assert_not_contains "$out" "free or return a slot" "non-capacity failure got slot advice"
  assert_not_contains "$out" "claimed by occupant-pool" "non-capacity failure blamed task records"
  [ "$(< "$COUNTFILE")" = 1 ] || fail "generic failure was not detected on the first poll"
  pass "non-pool treehouse failures are reported immediately without slot advice"
}

# A slot refused for its claim, then an exhausted pool on the re-ask, keeps the
# refusal report that names what this spawn was actually offered.
test_pool_full_after_refused_claim_keeps_refusal_report() {
  local rec id out status
  id=settle-pool-full-refused
  rec=$(make_settle_case pool-full-refused "$id" 0)
  read_settle_record "$rec"
  claim_settle_slot occupant-refused "$WT_DIR"

  out=$(run_failing_get "$id" "$POOL_FULL_MESSAGE" FM_TEST_TREEHOUSE_GRANTS=1)
  status=$?
  expect_code 1 "$status" "pool exhaustion after a refused slot should stop spawn"
  assert_contains "$out" "warning: treehouse offered" "first attempt did not refuse the claimed slot"
  [ "$(first_error_line "$out")" = "error: $POOL_FULL_MESSAGE" ] \
    || fail "treehouse error was not reported first and verbatim: $out"
  assert_contains "$out" "every worktree treehouse offered this spawn is already claimed" "refusal report was dropped"
  assert_contains "$out" "claimed by occupant-refused" "refusal report did not name the claimant"
  assert_not_contains "$out" "within 60 polls" "pool exhaustion fell through to timeout"
  [ "$(< "$HOME_DIR/treehouse-calls")" = 2 ] || fail "expected exactly one re-ask after the refused slot"
  assert_absent "$HOME_DIR/state/$id.meta" "failed get published metadata"
  pass "pool exhaustion on a re-ask keeps the refused-claim report"
}

# Non-tmux captures return visual rows. The failure marker carries the pane
# width, so the wrapped diagnostic is rejoined without absorbing other output.
test_wrapped_failure_is_rejoined() {
  local rec id out status
  id=settle-pool-full-wrapped
  rec=$(make_settle_case pool-full-wrapped "$id" 0)
  read_settle_record "$rec"

  out=$(run_failing_get "$id" "$POOL_FULL_MESSAGE" COLUMNS=40 FM_FAKE_PANE_FOLD=40 \
    FM_TEST_TREEHOUSE_PRELUDE="Looking for a free worktree")
  status=$?
  expect_code 1 "$status" "wrapped pool exhaustion should stop spawn"
  [ "$(first_error_line "$out")" = "error: $POOL_FULL_MESSAGE" ] \
    || fail "wrapped treehouse error was not rejoined verbatim: $out"
  assert_not_contains "$out" "Looking for a free worktree" "rejoin absorbed unrelated output"
  assert_contains "$out" "increase max_trees in treehouse.toml." "wrapped capacity failure lost its recovery hint"
  pass "a soft-wrapped treehouse diagnostic is reported whole"
}

test_plain_timeout_is_unchanged() {
  local rec id out status
  id=settle-timeout
  rec=$(make_settle_case timeout "$id" 0)
  read_settle_record "$rec"
  WT_DIR="$PROJ_DIR"
  # Keep the default 60 polls, eliminating only the sleep duration. Old error
  # text in scrollback must not be diagnosed as this command's failure.
  printf 'Error: old failure\n' > "$HOME_DIR/pane-output"
  out=$(FM_FAKE_TREEHOUSE_OUTPUT="$HOME_DIR/pane-output" \
    FM_SPAWN_WORKTREE_POLL_INTERVAL=0 run_settle_spawn "$id")
  status=$?
  expect_code 1 "$status" "a pane that never moves should time out"
  assert_contains "$out" "error: treehouse get did not enter a worktree within 60 polls; inspect window" "timeout diagnostic changed"
  [ "$(< "$COUNTFILE")" = 60 ] || fail "quiet get did not receive all 60 polls"
  assert_absent "$HOME_DIR/state/$id.meta" "timeout published metadata"
  pass "no failure output retains the complete timeout path"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_treehouse_failure_is_reported_immediately
test_pool_full_after_refused_claim_keeps_refusal_report
test_wrapped_failure_is_rejoined
test_plain_timeout_is_unchanged

echo "# all fm-spawn-worktree-settle tests passed"
