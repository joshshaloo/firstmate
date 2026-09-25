#!/usr/bin/env bash
# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode and pi adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive. Grok delegates native
# blocking when its running Stop payload advertises that capability, with one
# bounded resume fallback for payloads from pre-native processes.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# secondmate home (treehouse-leased or git-cloned), and any crewmate/scout task
# worktree spawned to work on firstmate itself (the recursive "firstmate
# improving itself" case). A secondmate home runs its OWN primary firstmate
# session, so it must be guarded like the main primary; only child crew/scout
# worktrees are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked secondmate home - and
# stay a silent, fast no-op inside child task worktrees.
#
# Loop-guard, codex/Grok (default) mode: never block twice in the same turn.
# Codex uses stop_hook_active and Grok uses stopHookActive; typed camel-case
# takes precedence when both spellings are present. A true value means the
# current stop attempt already follows a block, so this guard always allows it.
# Passive harness adapters provide their own one-follow-up guard before calling
# this script.
# That bounds those harnesses to at most one forced continuation per turn -
# never a wedged, un-endable session - while still nagging again on a later turn
# if the problem persists.
#
# Loop-guard, --claude mode (Stop-owned auto-arm cooperation): Claude Code
# marks EVERY stop after ANY stop-hook-driven continuation stop_hook_active=true,
# including turns started by the asyncRewake auto-arm, so the one-shot allow
# would re-open the exact blind window this guard exists to close
# (docs/turnend-guard.md records the 2026-07-21 incident). In --claude mode this
# guard ignores stop_hook_active and instead cooperates with the Stop-owned
# auto-arm (bin/fm-claude-stop-autoarm.sh), which Claude runs in parallel on the
# same Stop event with the same payload bytes:
#   1. a live identity-matched watcher with a fresh beacon allows immediately;
#   2. otherwise it waits for the auto-arm's own verdict for THIS event through
#      the handshake owned by bin/fm-claude-autoarm-claim-lib.sh: a claim, a
#      verified live owner, or a fresh rewake/renewal outcome allows without
#      consuming a continuation, so one event epoch yields exactly one recovery
#      turn. A slow auto-arm on a loaded host is waited for, not reported
#      missing: the wait is bounded by FM_CLAUDE_AUTOARM_SYNC_WAIT_MS (default
#      10000) until the auto-arm first reports and FM_CLAUDE_AUTOARM_DECIDE_WAIT_MS
#      (default 30000) until it decides;
#   3. only a declined verdict, an auto-arm that died undecided, one that never
#      reported, one still undecided at the bound, or away mode re-blocks, with
#      that concrete reason, bounded to FM_CLAUDE_TURNEND_BLOCK_BUDGET (default 3)
#      consecutive blocks per session - safely below Claude Code's hard
#      8-consecutive-block override - then allows degraded with a visible
#      systemMessage so the session can always end.
# Any allow resets the consecutive-block budget. Separately, a durable streak
# (state/.claude-autoarm-streak) counts consecutive turn ends on which the
# auto-arm did not own recovery, across degraded allows and sessions, and resets
# only on proof that it did; from FM_CLAUDE_AUTOARM_STREAK_ESCALATE (default 3)
# the banner escalates the pattern as a supervision defect for the captain.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
CLAUDE_MODE=0
SYNC_WAIT_MS=${FM_CLAUDE_AUTOARM_SYNC_WAIT_MS:-10000}
DECIDE_WAIT_MS=${FM_CLAUDE_AUTOARM_DECIDE_WAIT_MS:-30000}
EPOCH_FRESH=${FM_CLAUDE_AUTOARM_EPOCH_FRESH:-15}
BLOCK_BUDGET=${FM_CLAUDE_TURNEND_BLOCK_BUDGET:-3}
STREAK_ESCALATE=${FM_CLAUDE_AUTOARM_STREAK_ESCALATE:-3}
case "$SYNC_WAIT_MS" in ''|*[!0-9]*) SYNC_WAIT_MS=10000 ;; esac
case "$DECIDE_WAIT_MS" in ''|*[!0-9]*) DECIDE_WAIT_MS=30000 ;; esac
case "$EPOCH_FRESH" in ''|*[!0-9]*|0) EPOCH_FRESH=15 ;; esac
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac
case "$STREAK_ESCALATE" in ''|*[!0-9]*|0) STREAK_ESCALATE=3 ;; esac

for arg in "$@"; do
  case "$arg" in
    --claude) CLAUDE_MODE=1 ;;
    *) echo "usage: $(basename "$0") [--claude]" >&2; exit 2 ;;
  esac
done

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload")
  elif has("stopHookActive") then
    if ((.stopHookActive | type) == "boolean") then .stopHookActive else error("stopHookActive") end
  elif has("stop_hook_active") then
    if ((.stop_hook_active | type) == "boolean") then .stop_hook_active else error("stop_hook_active") end
  else false
  end
' 2>/dev/null) || exit 0
if [ "$CLAUDE_MODE" -eq 0 ] && [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# --- scope precisely to a PRIMARY checkout ----------------------------------
# A genuinely-marked secondmate home runs its OWN primary firstmate session, so
# force-INCLUDE it as a guarded primary whether treehouse leased it as a linked
# worktree (git-dir != git-common-dir) or it is a git-cloned plain checkout. This
# mirrors the cd-guard's intent that a secondmate's own session is a guarded
# primary. Only an UNMARKED checkout (or one with an invalid marker) falls
# through to the linked-worktree exemption: firstmate hands out crewmate/scout
# task worktrees as genuine linked `git worktree`s (bin/fm-spawn.sh aborts
# otherwise), whose git-dir lives under the parent repo's .git/worktrees/<name>
# and differs from the common (shared) git-dir, while a main, non-worktree
# checkout has the two equal. Child worktrees never carry the gitignored marker,
# so this exempts them while guarding every real secondmate home.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-claude-autoarm-claim-lib.sh
. "$SCRIPT_DIR/fm-claude-autoarm-claim-lib.sh"

BUDGET_FILE="$STATE/.turnend-claude-blocks"
STREAK_FILE="$STATE/.claude-autoarm-streak"
budget_reset() {
  [ "$CLAUDE_MODE" -eq 1 ] || return 0
  rm -f "$BUDGET_FILE" 2>/dev/null || true
}
# Proof that the auto-arm (or a healthy watcher) owns recovery ends any streak.
streak_reset() {
  [ "$CLAUDE_MODE" -eq 1 ] || return 0
  rm -f "$STREAK_FILE" 2>/dev/null || true
}

fm_supervision_status "$STATE" "$GRACE"
if [ "$CLAUDE_MODE" -eq 1 ]; then
  if [ "$FM_SUP_NEEDED" = false ]; then
    budget_reset
    exit 0
  fi
else
  if [ "$FM_SUP_IN_FLIGHT" -eq 0 ]; then
    budget_reset
    exit 0
  fi
fi
if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  budget_reset
  streak_reset
  exit 0
fi

AUTOARM_REASON=
STREAK_COUNT=0
STREAK_SINCE=
utc_time() {  # <epoch seconds>
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf 'epoch %s\n' "$1"
}
# Count this turn end as one more on which the auto-arm did not own recovery.
streak_record() {  # <reason slug>
  local count since
  count=$(sed -n 's/^count=\([0-9][0-9]*\)$/\1/p' "$STREAK_FILE" 2>/dev/null || true)
  since=$(sed -n 's/^since=\([0-9][0-9]*\)$/\1/p' "$STREAK_FILE" 2>/dev/null || true)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$since" in ''|*[!0-9]*) since=$(date +%s); count=0 ;; esac
  STREAK_COUNT=$((count + 1))
  STREAK_SINCE=$since
  printf 'since=%s\ncount=%s\nreason=%s\n' "$STREAK_SINCE" "$STREAK_COUNT" "$1" > "$STREAK_FILE" 2>/dev/null || true
}
streak_escalation() {
  [ "$STREAK_COUNT" -ge "$STREAK_ESCALATE" ] || return 1
  printf 'PERSISTENT FAILURE: the Stop auto-arm has not owned recovery on %s consecutive turn ends since %s. This is a supervision defect, not a routine lapse: after repairing supervision, report it to the captain as a blocker and quote this banner.' \
    "$STREAK_COUNT" "$(utc_time "$STREAK_SINCE")"
}

block_stop() {
  local afk x_mode reason rule escalation
  afk=0
  [ -e "$STATE/.afk" ] && afk=1
  x_mode=0
  [ -f "$CONFIG/x-mode.env" ] && x_mode=1
  reason=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
    || printf '%s\n' 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn')
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
    if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
      printf '●  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC"
    else
      printf '●  X-mode relay polling needs supervision, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_BEACON_DESC"
    fi
    if [ "$CLAUDE_MODE" -eq 1 ]; then
      printf '●  The Stop-owned auto-arm did not claim this home either, so recovery is NOT already under way.\n'
      [ -z "$AUTOARM_REASON" ] || printf '●  Why: %s.\n' "$(fm_claude_claim_reason_text "$AUTOARM_REASON")"
      if escalation=$(streak_escalation); then
        printf '●  %s\n' "$escalation"
      fi
    fi
    printf '●  %s\n' "$reason"
    printf '●%s\n' "$rule"
  } >&2
  exit 2
}

if [ "$CLAUDE_MODE" -eq 0 ]; then
  block_stop
fi

# --- --claude cooperative path -----------------------------------------------
# The Stop-owned auto-arm runs in parallel on the same Stop event. Wait for its
# own verdict for this event (never for a fixed guess of how long it takes)
# before consuming one of Claude's bounded continuations.
now_ms() {
  local t
  t=$(date +%s%3N 2>/dev/null)
  case "$t" in ''|*[!0-9]*) t=$(( $(date +%s) * 1000 )) ;; esac
  printf '%s\n' "$t"
}

autoarm_owns_recovery() {
  local outcome age
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && return 0
  fm_claude_autoarm_owner_status "$STATE" "$WATCH" "$GRACE" "$FM_HOME"
  [ "$FM_AUTOARM_OWNER_STATE" = live ] && return 0
  outcome=$(sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$(fm_claude_autoarm_epoch_file "$STATE")" 2>/dev/null || true)
  case "$outcome" in
    rewake|renewal)
      age=$(fm_path_age "$(fm_claude_autoarm_epoch_file "$STATE")")
      [ "$age" -lt "$EPOCH_FRESH" ] && return 0
      ;;
  esac
  return 1
}

allow_owned() {
  budget_reset
  streak_reset
  exit 0
}

if [ -e "$STATE/.afk" ]; then
  # The auto-arm is inert under away mode by contract; nothing to wait for.
  AUTOARM_REASON=away-mode
else
  EVENT_KEY=$(fm_claude_stop_event_key "$PAYLOAD")
  START=$(now_ms)
  while :; do
    autoarm_owns_recovery && allow_owned
    NOW=$(now_ms)
    if fm_claude_claim_read "$STATE" "$EVENT_KEY"; then
      case "$FM_CLAIM_PHASE" in
        claimed|deferred) allow_owned ;;
        declined) AUTOARM_REASON=${FM_CLAIM_REASON:-unknown}; break ;;
        started)
          if ! fm_claude_autoarm_pid_is_owner "$FM_CLAIM_PID"; then
            # Re-read once: it may have decided between the two reads.
            fm_claude_claim_read "$STATE" "$EVENT_KEY" && [ "$FM_CLAIM_PHASE" != started ] && continue
            AUTOARM_REASON=exited-undecided
            break
          fi
          [ $((NOW - START)) -lt "$DECIDE_WAIT_MS" ] || { AUTOARM_REASON=still-deciding; break; }
          ;;
      esac
    elif [ $((NOW - START)) -ge "$SYNC_WAIT_MS" ]; then
      AUTOARM_REASON=never-started
      break
    fi
    sleep 0.1
  done
  streak_record "$AUTOARM_REASON"
fi

# The auto-arm genuinely failed to establish recovery: re-block, but never past
# the budget so the session can always end and Claude's 8-block override is
# never approached.
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null || printf 'unknown')
COUNT=0
if [ -f "$BUDGET_FILE" ]; then
  old_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
  old_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
  case "$old_count" in
    ''|*[!0-9]*) old_count=0 ;;
  esac
  [ "$old_session" = "$SESSION_ID" ] && COUNT=$old_count
fi
COUNT=$((COUNT + 1))
if [ "$COUNT" -gt "$BLOCK_BUDGET" ]; then
  budget_reset
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
    NEED_DESC="$FM_SUP_IN_FLIGHT task(s) in flight"
  else
    NEED_DESC="X-mode relay polling active"
  fi
  DETAIL=$(fm_claude_claim_reason_text "$AUTOARM_REASON")
  if escalation=$(streak_escalation); then
    DETAIL="$DETAIL. $escalation"
  fi
  jq -cn --arg need "$NEED_DESC" --arg detail "$DETAIL" \
    '{systemMessage: ("firstmate turn-end guard: " + $need + " with no live watcher and no Stop auto-arm claim; block budget exhausted, allowing this stop. Why: " + $detail + ". Repair supervision (bin/fm-watch-arm.sh as a Claude Code background task) or investigate why bin/fm-claude-stop-autoarm.sh is not claiming this home.")}'
  exit 0
fi
printf 'session=%s\ncount=%s\n' "$SESSION_ID" "$COUNT" > "$BUDGET_FILE" 2>/dev/null || true
block_stop
