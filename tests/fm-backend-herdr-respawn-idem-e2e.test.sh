#!/usr/bin/env bash
# tests/fm-backend-herdr-respawn-idem-e2e.test.sh - isolated real-herdr
# regression test for firstmate-restart idempotency against herdr's
# restored-layout husks (docs/herdr-backend.md "Known gaps" / "ID stability
# across a server restart").
#
# herdr persists its whole session layout (workspaces/tabs/panes) and
# restores it after a server restart, including a reboot. A restored fm-<id>
# task tab comes back a husk - a dead pane, or a plain agent-less shell in the
# saved cwd - never the crewmate that used to be there.
#
# This test drives a REAL `herdr session stop` + fresh `herdr server` restart
# (the same "ID stability" mechanism docs/herdr-backend.md already documents:
# the pane survives alive, but agent_status resets and nothing is registered
# in it - exactly the restored-plain-shell husk shape), then proves
# fm_backend_herdr_create_task refuses the duplicate tab and leaves it intact
# for explicit reconciliation instead of closing and replacing it. Adapter-level
# (fm_backend_herdr_container_ensure/create_task), not
# through the full bin/fm-spawn.sh + treehouse pipeline - mirrors
# tests/fm-backend-herdr-prune-safety-e2e.test.sh's own style, and avoids any
# question of whether treehouse itself supports re-acquiring a worktree for
# an id that already has one checked out (a separate, out-of-scope concern).
#
# Safety (tests/herdr-test-safety.sh): cleanup uses ONLY
# herdr_safe_stop_and_delete, never a bare/inline-prefixed `herdr server
# stop` - the exact category of unscoped destructive call that caused the
# 2026-07-02 incident. Every herdr lifecycle call in this file targets this
# test's own isolated $SESSION explicitly via --session; the live `default`
# session is never touched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

SESSION="fm-lab-respawn-idem-e2e-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-respawn-idem.XXXXXX")
cleanup_all() {
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$SCRATCH"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

fm_backend_herdr_version_check || fail "version_check failed against the real installed herdr"

# --- 1. spawn two real task tabs (crewmate-shaped and secondmate-shaped) ----
# fm_backend_herdr_create_task is the ONE function both bin/fm-spawn.sh's
# ordinary crewmate/scout path and its --secondmate path call, so exercising
# it directly here covers both paths identically - already proven distinct
# only in FM_HOME-shadowing (tests/fm-backend-herdr-workspace-per-home-e2e.test.sh),
# never in this duplicate-guard logic, which has no home-specific branching.

PROJ_CWD="$SCRATCH/proj"
mkdir -p "$PROJ_CWD"

RAW=$(fm_backend_herdr_container_ensure "$PROJ_CWD") || fail "container_ensure failed"
CONTAINER=${RAW%%$'\t'*}
SEEDED_TAB_ID=${RAW#*$'\t'}
WSID=${CONTAINER#*:}

CREW_LABEL="fm-respawn-crew1"
CREW_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "$CREW_LABEL" "$PROJ_CWD" "$SEEDED_TAB_ID") \
  || fail "initial crewmate-shaped task creation failed"
read -r CREW_TAB_ID CREW_PANE_ID <<EOF
$CREW_IDS
EOF
if [ -z "$CREW_TAB_ID" ] || [ -z "$CREW_PANE_ID" ]; then
  fail "initial crewmate-shaped task did not return tab/pane ids"
fi

SM_LABEL="fm-respawn-sm1"
SM_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "$SM_LABEL" "$PROJ_CWD") \
  || fail "initial secondmate-shaped task creation failed"
read -r SM_TAB_ID SM_PANE_ID <<EOF
$SM_IDS
EOF
if [ -z "$SM_TAB_ID" ] || [ -z "$SM_PANE_ID" ]; then
  fail "initial secondmate-shaped task did not return tab/pane ids"
fi

pass "repro setup: two real fm-<id> task tabs exist (crewmate-shaped and secondmate-shaped), neither with a registered agent"

# --- 2. a REAL herdr session restart - the actual root cause -----------------
# `session stop` + fresh `herdr server` for the SAME named session: verified
# in docs/herdr-backend.md "ID stability across a server restart" to preserve
# every workspace/tab/pane id and label, while resetting each pane's
# underlying process (a fresh shell) and its agent_status to unknown - the
# exact husk shape a restored task tab comes back in.

fm_herdr_lab_stop "$SESSION" >/dev/null 2>&1 \
  || fail "could not stop the isolated session for the restart"
sleep 0.5
fm_backend_herdr_server_ensure "$SESSION" || fail "the isolated session's server did not come back up after the restart"

if ! herdr pane get "$CREW_PANE_ID" --session "$SESSION" >/dev/null 2>&1; then
  fail "repro setup is wrong: the crewmate-shaped pane should survive a session restart alive (docs/herdr-backend.md 'ID stability'), but it is gone"
fi
if herdr agent get "$CREW_PANE_ID" --session "$SESSION" >/dev/null 2>&1; then
  fail "repro setup is wrong: the restored pane should have NO registered agent (agent_not_found expected)"
fi
pass "repro confirmed: after a real session restart, both task panes survive alive but with no registered agent - the restored-layout husk"

# --- 3. duplicate husks refuse and remain for explicit reconciliation -------

if fm_backend_herdr_create_task "$CONTAINER" "$CREW_LABEL" "$PROJ_CWD" >/dev/null 2>&1; then
  fail "REGRESSION: create_task should refuse the crewmate-shaped restored husk"
fi
if ! herdr pane get "$CREW_PANE_ID" --session "$SESSION" >/dev/null 2>&1; then
  fail "REGRESSION: the refused crewmate-shaped husk pane should have survived untouched"
fi
pass "fixed: create_task refuses the crewmate-shaped restored husk and leaves it for explicit reconciliation"

if fm_backend_herdr_create_task "$CONTAINER" "$SM_LABEL" "$PROJ_CWD" >/dev/null 2>&1; then
  fail "REGRESSION: create_task should refuse the secondmate-shaped restored husk"
fi
if ! herdr pane get "$SM_PANE_ID" --session "$SESSION" >/dev/null 2>&1; then
  fail "REGRESSION: the refused secondmate-shaped husk pane should have survived untouched"
fi
pass "fixed: create_task refuses the secondmate-shaped restored husk and leaves it for explicit reconciliation"

WS_TABS=$(herdr tab list --workspace "$WSID" --session "$SESSION" 2>&1)
WS_COUNT=$(printf '%s' "$WS_TABS" | jq -r '.result.tabs? // [] | length')
[ "$WS_COUNT" = 2 ] || fail "expected exactly 2 original husk tabs, got $WS_COUNT: $WS_TABS"
pass "fixed: the workspace still holds exactly the original husk tabs after refused respawns"

# --- 4. a GENUINELY live duplicate still refuses, unchanged -----------------
# Register a real agent on one husk and confirm another same-labeled spawn
# attempt still refuses without touching it.

herdr pane report-agent "$CREW_PANE_ID" --source fm-respawn-e2e --agent fm-respawn-live-agent --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a live agent on the crewmate-shaped pane"

if fm_backend_herdr_create_task "$CONTAINER" "$CREW_LABEL" "$PROJ_CWD" >/dev/null 2>&1; then
  fail "REGRESSION: create_task should refuse a same-labeled tab whose pane hosts a genuinely live registered agent"
fi
if ! herdr pane get "$CREW_PANE_ID" --session "$SESSION" >/dev/null 2>&1; then
  fail "REGRESSION: the live-agent pane should have survived the refused create_task call untouched"
fi
pass "fixed: a genuinely live duplicate still refuses and remains untouched"

fm_backend_herdr_kill "$SESSION:$CREW_PANE_ID"
fm_backend_herdr_kill "$SESSION:$SM_PANE_ID"

cleanup_all
trap - EXIT
