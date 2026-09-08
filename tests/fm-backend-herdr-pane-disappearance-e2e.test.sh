#!/usr/bin/env bash
# Isolated real-Herdr regression coverage for disappeared panes and restart husks.
# Every lifecycle, destructive, and pane-setup Herdr CLI call goes through
# bin/fm-herdr-lab.sh. The classifier reads are read-only calls made by their
# owner, the herdr backend adapter in bin/backends/herdr.sh, always targeting the
# lab session explicitly so nothing escapes the lab.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs entirely against its own isolated lab session, so the Herdr
# pane identity inherited from the terminal it was launched in must not follow
# it in (tests/herdr-test-safety.sh owns that variable set).
herdr_forget_inherited_pane

HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name firstmate-herdr-pane-disappearance-lab) \
  || { echo "skip: could not generate a Herdr lab session name"; exit 0; }
CLEANED=0
cleanup_all() {
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null \
    || {
      printf 'not ok - guarded Herdr lab teardown failed for %s\n' "$HERDR_LAB_SESSION" >&2
      FM_TEST_EXIT_STATUS=1
    }
}
fm_test_at_exit cleanup_all

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

fm_test_tmproot SCRATCH fm-herdr-pane-disappearance

WS_OUT=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create \
  --cwd "$SCRATCH" --label fm-lab-pane-disappearance --no-focus) \
  || fail "workspace create failed in the isolated Herdr lab"
WS_ID=$(printf '%s' "$WS_OUT" | jq -r '.result.workspace.workspace_id // empty')
[ -n "$WS_ID" ] || fail "workspace create did not return a workspace id: $WS_OUT"

create_pane() { # <label> <pane-var>
  local label=$1 pane_var=$2 out tab pane
  out=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab create \
    --workspace "$WS_ID" --cwd "$SCRATCH" --label "$label" --no-focus) \
    || fail "tab create failed for $label"
  tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty')
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$tab" ] && [ -n "$pane" ] || fail "tab create for $label did not return tab and pane ids: $out"
  printf -v "$pane_var" '%s' "$pane"
}

record_done_line() { # <pane>
  local pane=$1
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$pane" \
    "printf 'done: lab recipe complete\\n'" >/dev/null \
    || fail "could not write done line in pane $pane"
  sleep 0.2
}

report_idle_agent() { # <pane> <agent>
  local pane=$1 agent=$2
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane report-agent "$pane" \
    --source fm-pane-disappearance-e2e --agent "$agent" --state idle >/dev/null \
    || fail "could not register idle agent state for pane $pane"
  wait_for_pane_state "$pane" live \
    || fail "pane $pane did not classify live after registering agent $agent"
}

assert_states() { # <recipe> <pane> <want-pane-agent-state> <want-agent-state>
  local recipe=$1 pane=$2 want_detail=$3 want_mapping=$4 detail mapping
  detail=$(fm_backend_herdr_pane_agent_state "$HERDR_LAB_SESSION" "$pane")
  mapping=$(fm_backend_herdr_agent_state "$HERDR_LAB_SESSION:$pane")
  [ "$detail" = "$want_detail" ] \
    || fail "$recipe: expected pane classifier $want_detail, got $detail"
  [ "$mapping" = "$want_mapping" ] \
    || fail "$recipe: expected recovery mapping $want_mapping, got $mapping"
  printf 'ok - %s: pane classifier=%s recovery mapping=%s\n' "$recipe" "$detail" "$mapping"
}

wait_for_pane_state() { # <pane> <want> [<attempts>]
  local pane=$1 want=$2 remaining=${3:-50} state
  while [ "$remaining" -gt 0 ]; do
    state=$(fm_backend_herdr_pane_agent_state "$HERDR_LAB_SESSION" "$pane")
    [ "$state" = "$want" ] && return 0
    sleep 0.1
    remaining=$((remaining - 1))
  done
  return 1
}

wait_for_idle_shell_proof() { # <pane>
  local pane=$1 remaining=50
  while [ "$remaining" -gt 0 ]; do
    fm_backend_herdr_pane_process_is_idle_shell "$HERDR_LAB_SESSION" "$pane" && return 0
    sleep 0.1
    remaining=$((remaining - 1))
  done
  return 1
}

wait_for_lab_stopped() {
  local remaining=50 running
  while [ "$remaining" -gt 0 ]; do
    running=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" session list --json 2>/dev/null \
      | jq -r --arg name "$HERDR_LAB_SESSION" \
        '.sessions[]? | select(.name == $name) | .running' 2>/dev/null)
    [ "$running" = false ] && return 0
    sleep 0.1
    remaining=$((remaining - 1))
  done
  return 1
}

# Recipe 1: the worker has produced its final done line, then the exact pane is closed.
create_pane fm-lab-explicit-close EXPLICIT_PANE
record_done_line "$EXPLICIT_PANE"
report_idle_agent "$EXPLICIT_PANE" fm-lab-explicit-close-agent
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane close "$EXPLICIT_PANE" >/dev/null 2>&1 || true
wait_for_pane_state "$EXPLICIT_PANE" dead \
  || fail "explicit close did not make pane $EXPLICIT_PANE disappear"
assert_states "explicit pane close after done line" "$EXPLICIT_PANE" dead missing

# Recipe 2: only the shell pid from this lab pane is killed, proving Herdr's shell-reap shape.
create_pane fm-lab-shell-reap SHELL_PANE
wait_for_idle_shell_proof "$SHELL_PANE" \
  || fail "pane $SHELL_PANE never satisfied the backend idle-shell proof; refusing to kill anything"
INFO=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane process-info --pane "$SHELL_PANE") \
  || fail "could not read process info for shell-reap pane"
INFO_PANE=$(printf '%s' "$INFO" | jq -r '.result.process_info.pane_id // empty')
SHELL_PID=$(printf '%s' "$INFO" | jq -r '.result.process_info.shell_pid // empty')
[ "$INFO_PANE" = "$SHELL_PANE" ] || fail "process-info returned pane $INFO_PANE, expected $SHELL_PANE"
case "$SHELL_PID" in ''|*[!0-9]*) fail "refusing to kill non-numeric shell pid '$SHELL_PID'" ;; esac
[ "$SHELL_PID" -gt 1 ] \
  || fail "refusing to kill shell pid '$SHELL_PID': not a single process the backend would accept"
kill -KILL "$SHELL_PID" || fail "could not kill lab pane shell pid $SHELL_PID"
wait_for_pane_state "$SHELL_PANE" dead \
  || fail "killing shell pid $SHELL_PID did not make pane $SHELL_PANE disappear"
assert_states "shell reap by killing own pane shell pid" "$SHELL_PANE" dead missing

# Recipe 3: a registered pane survives a session restart as a husk with no agent.
create_pane fm-lab-restart-husk HUSK_PANE
record_done_line "$HUSK_PANE"
report_idle_agent "$HUSK_PANE" fm-lab-restart-husk-agent
"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not stop the isolated Herdr lab for the restart-husk recipe"
wait_for_lab_stopped \
  || fail "the isolated Herdr lab did not report stopped before the restart-husk re-provision"
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not restart the isolated Herdr lab for the restart-husk recipe"
wait_for_pane_state "$HUSK_PANE" no-agent 100 \
  || fail "session restart did not restore pane $HUSK_PANE as an agent-less husk"
assert_states "session restart husk" "$HUSK_PANE" no-agent dead

pass "Herdr pane disappearance recipes use one classifier and map vanished panes to missing, husks to dead"
