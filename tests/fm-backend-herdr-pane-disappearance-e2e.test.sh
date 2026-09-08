#!/usr/bin/env bash
# Isolated real-Herdr regression coverage for disappeared panes and restart husks.
# Every lifecycle and task-specific Herdr CLI call goes through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name firstmate-herdr-pane-disappearance-lab) \
  || { echo "skip: could not generate a Herdr lab session name"; exit 0; }
CLEANED=0
cleanup_all() {
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT HUP INT TERM

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision isolated Herdr lab session"

unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

fm_test_tmproot SCRATCH fm-herdr-pane-disappearance

WS_OUT=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create \
  --cwd "$SCRATCH" --label fm-lab-pane-disappearance --no-focus) \
  || fail "workspace create failed in the isolated Herdr lab"
WS_ID=$(printf '%s' "$WS_OUT" | jq -r '.result.workspace.workspace_id // empty')
[ -n "$WS_ID" ] || fail "workspace create did not return a workspace id: $WS_OUT"

create_pane() { # <label> -> tab<TAB>pane
  local label=$1 out tab pane
  out=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab create \
    --workspace "$WS_ID" --cwd "$SCRATCH" --label "$label" --no-focus) \
    || fail "tab create failed for $label"
  tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty')
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$tab" ] && [ -n "$pane" ] || fail "tab create for $label did not return tab and pane ids: $out"
  printf '%s\t%s\n' "$tab" "$pane"
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

wait_for_pane_state() { # <pane> <want>
  local pane=$1 want=$2 remaining=50 state
  while [ "$remaining" -gt 0 ]; do
    state=$(fm_backend_herdr_pane_agent_state "$HERDR_LAB_SESSION" "$pane")
    [ "$state" = "$want" ] && return 0
    sleep 0.1
    remaining=$((remaining - 1))
  done
  return 1
}

# Recipe 1: the worker has produced its final done line, then the exact pane is closed.
IFS=$'\t' read -r EXPLICIT_TAB EXPLICIT_PANE <<EOF
$(create_pane fm-lab-explicit-close)
EOF
[ -n "$EXPLICIT_TAB" ] || fail "explicit-close setup did not produce a tab id"
record_done_line "$EXPLICIT_PANE"
report_idle_agent "$EXPLICIT_PANE" fm-lab-explicit-close-agent
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane close "$EXPLICIT_PANE" >/dev/null 2>&1 || true
wait_for_pane_state "$EXPLICIT_PANE" dead \
  || fail "explicit close did not make pane $EXPLICIT_PANE disappear"
assert_states "explicit pane close after done line" "$EXPLICIT_PANE" dead missing

# Recipe 2: only the shell pid from this lab pane is killed, proving Herdr's shell-reap shape.
IFS=$'\t' read -r SHELL_TAB SHELL_PANE <<EOF
$(create_pane fm-lab-shell-reap)
EOF
[ -n "$SHELL_TAB" ] || fail "shell-reap setup did not produce a tab id"
INFO=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane process-info --pane "$SHELL_PANE") \
  || fail "could not read process info for shell-reap pane"
INFO_PANE=$(printf '%s' "$INFO" | jq -r '.result.process_info.pane_id // empty')
SHELL_PID=$(printf '%s' "$INFO" | jq -r '.result.process_info.shell_pid // empty')
FOREGROUND_PID=$(printf '%s' "$INFO" | jq -r '.result.process_info.foreground_processes[0].pid // empty')
FOREGROUND_CWD=$(printf '%s' "$INFO" | jq -r '.result.process_info.foreground_processes[0].cwd // empty')
[ "$INFO_PANE" = "$SHELL_PANE" ] || fail "process-info returned pane $INFO_PANE, expected $SHELL_PANE"
[ "$SHELL_PID" = "$FOREGROUND_PID" ] || fail "shell pid $SHELL_PID is not the foreground pid $FOREGROUND_PID"
if [ -n "$FOREGROUND_CWD" ] && [ "$FOREGROUND_CWD" != "$SCRATCH" ]; then
  fail "refusing to kill shell pid $SHELL_PID because cwd $FOREGROUND_CWD is not the lab scratch $SCRATCH"
fi
case "$SHELL_PID" in ''|*[!0-9]*) fail "refusing to kill non-numeric shell pid '$SHELL_PID'" ;; esac
kill -KILL "$SHELL_PID" || fail "could not kill lab pane shell pid $SHELL_PID"
wait_for_pane_state "$SHELL_PANE" dead \
  || fail "killing shell pid $SHELL_PID did not make pane $SHELL_PANE disappear"
assert_states "shell reap by killing own pane shell pid" "$SHELL_PANE" dead missing

# Recipe 3: a registered pane survives a session restart as a husk with no agent.
IFS=$'\t' read -r HUSK_TAB HUSK_PANE <<EOF
$(create_pane fm-lab-restart-husk)
EOF
[ -n "$HUSK_TAB" ] || fail "restart-husk setup did not produce a tab id"
record_done_line "$HUSK_PANE"
report_idle_agent "$HUSK_PANE" fm-lab-restart-husk-agent
"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not stop the isolated Herdr lab for the restart-husk recipe"
sleep 0.5
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not restart the isolated Herdr lab for the restart-husk recipe"
assert_states "session restart husk" "$HUSK_PANE" no-agent dead

pass "Herdr pane disappearance recipes use one classifier and map vanished panes to missing, husks to dead"
cleanup_all
