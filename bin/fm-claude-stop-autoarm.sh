#!/usr/bin/env bash
# Claude Stop-owned watcher auto-arm (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true and an explicit multi-hour timeout. Claude Code fires it
# in the background on EVERY Stop of a Claude primary session, with no
# deduplication across firings. It owns routine tokenless watcher continuity
# for Claude primaries (main home and marked secondmate homes):
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session's harness ancestor holds state/.lock.
#     When an existing numeric owner fails the shared harness-liveness predicate,
#     the hook delegates guarded recovery to bin/fm-lock.sh and then re-verifies
#     ownership. A live owner, missing lock, malformed lock, or unresolved
#     ancestry remains inert, so a competing session never arms or rewakes.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while work is in flight (state/*.meta) or X mode has a
#     relay poll to run (state/x-watch.check.sh); an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so a home-scoped owner
#     lock (state/.claude-autoarm.lock) admits exactly one owner; every other
#     concurrent firing exits 0 without translating, which keeps one event
#     epoch on exactly one recovery turn.
#   - Tracked arm: the owner runs bin/fm-watch-arm.sh as a tracked background
#     child of this hook-owned process tree, never detached; it polls and waits
#     on that child and retires it at the lifetime bound. Claude owns the process
#     group, so its timeout/session teardown kills arm and watcher together.
#   - Translation: while supervision is still needed and AFK remains inactive,
#     an actionable arm close (signal:/stale:/check:/heartbeat) prints one
#     rewake banner to stderr and exits 2, which wakes Claude even while idle
#     ("Stop hook feedback"). A typed watcher: FAILED is also rewoken unless a
#     final identity-matched fresh-beacon check proves a watcher is already live
#     for this home. A clean close with no actionable reason and no remaining
#     need exits 0 silently.
#   - Continuity: a suppressed typed failure never ends the hook while a live
#     watcher has no translator. Every cycle close consults the health predicate,
#     and each proof re-arms so this hook attaches to the surviving watcher and
#     keeps translating its wakes; the close of THAT cycle is classified the same
#     way. REARM_MAX bounds how many re-arms one firing may take. An exhausted
#     bound, a close with no health proof, or a re-arm that cannot prove it
#     started or attached to a watcher all run the failure alarm path, which
#     reports the unresolved absorbed-wake chain rather than supervision being
#     down whenever the closing cycle did prove a live watcher.
#
#   - Lifetime: Claude kills an async hook at its configured timeout, and a
#     killed hook can neither rewake nor start a successor, so a quiet cycle
#     that outlived the timeout used to leave an idle session blind until the
#     next human message. The owner therefore retires its own cycle before the
#     timeout (read from this hook's tracked .claude/settings.json entry) and
#     exits 2 with a renewal banner; the handling turn's Stop starts a fresh
#     firing with a full lifetime.
#   - Handshake: every firing that passes the scope, AFK, and need gates
#     publishes its progress for this Stop event through
#     bin/fm-claude-autoarm-claim-lib.sh (started, then claimed, deferred, or
#     declined with a reason), so the synchronous guard waits for this hook's
#     own verdict instead of guessing from a timer.
#   - Self-healing owner lock: a recorded owner counts only while it is a live
#     process running this home's auto-arm script, so a recycled pid never
#     wedges the single-flight lock; a verified owner that has held its claim
#     for the grace window while the watcher beacon has also been missing or
#     stale that long is retired (signalled once) and replaced.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim and
# outcome so the synchronous Stop guard (bin/fm-turnend-guard.sh --claude) can
# allow a stop whose recovery this hook already owns, instead of forcing a
# duplicate continuation for the same event epoch.
#
# This hook never blocks the Stop decision itself and never prints to stdout:
# exit 0 is always silent, and exit 2 carries the rewake banner on stderr.
# On any uncertainty such as unresolvable ancestry, malformed lock state, or
# lock contention, it exits 0 and leaves continuity to the synchronous guard and
# the model.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
# The single owner of how many proven-healthy re-arms one firing may take before
# an absorbed-wake chain stops being credible and becomes the failure alarm.
# Deliberately not an environment knob: the bound is a contract, not a tuning.
REARM_MAX=3

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-claude-autoarm-claim-lib.sh
. "$SCRIPT_DIR/fm-claude-autoarm-claim-lib.sh"

OWNER_LOCK=$(fm_claude_autoarm_owner_lock "$STATE")
EPOCH=$(fm_claude_autoarm_epoch_file "$STATE")

# Consume the Stop payload once; its bytes key this event's claim record.
PAYLOAD=$(cat 2>/dev/null || true)

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
# The guard knows this gate too, so an away home stays byte-for-byte inert.
[ -e "$STATE/.afk" ] && exit 0

# --- need: in-flight work or an X-mode relay poll ----------------------------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- handshake: this firing is running for this Stop event -------------------
EVENT_KEY=$(fm_claude_stop_event_key "$PAYLOAD")
claim() {  # <phase> [reason]
  fm_claude_claim_publish "$STATE" "$EVENT_KEY" "$@"
}
decline() {  # <reason>
  claim declined "$1"
  exit 0
}
claim started

write_epoch() {  # <outcome>
  local outcome=$1 seq tmp
  seq=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$EPOCH" 2>/dev/null || true)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  tmp="$EPOCH.tmp.$$"
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=%s\n' \
    "$seq" "${BASHPID:-$$}" "$outcome" "$(date +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$EPOCH" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

# --- identity: only the lock-owning session's hooks may arm ------------------
# A prior session may have died after leaving its numeric harness pid in .lock.
# Use the shared liveness predicate to recognize only that stale-owner case.
# Missing or malformed locks are uncertainty rather than stale-owner evidence
# and remain inert, but the guard hears exactly why.
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    '') decline session-lock-missing ;;
    *[!0-9]*) decline session-lock-malformed ;;
  esac
  fm_harness_pid_alive "$LOCK_PID" && decline session-lock-held-by-another-live-session
  # --- stale session-lock recovery -------------------------------------------
  # Delegate the claim to fm-lock.sh so its live-owner refusal and write
  # semantics remain the single acquisition owner, then re-verify
  # current-session identity before touching any auto-arm state.
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || decline session-lock-recovery-failed
  fm_session_lock_owned_by_self "$STATE" || decline session-lock-recovery-unverified
fi

# --- single-flight owner claim ------------------------------------------------
# Claude runs one background process per firing with no dedupe. Exactly one
# owner runs the arm and translates its close; every other firing defers to a
# verified live owner so one watcher cycle maps to at most one exit-2 rewake.
# A holder that is not a live auto-arm of this home is stale and stolen by the
# shared lock protocol; a verified holder that is wedged is retired first.
ARM_PID=
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
cleanup() {
  if [ -n "$ARM_PID" ] && fm_pid_alive "$ARM_PID"; then
    kill -TERM "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
  fi
  [ -z "${OUT:-}" ] || rm -f "$OUT" 2>/dev/null || true
  fm_lock_release "$OWNER_LOCK"
}

UNAVAILABLE="owner-lock-unavailable"
acquire_owner_lock() {
  local i=0 retired=
  while [ "$i" -lt 20 ]; do
    fm_lock_try_acquire "$OWNER_LOCK" fm_claude_autoarm_pid_is_owner && return 0
    fm_claude_autoarm_owner_status "$STATE" "$GRACE"
    case "$FM_AUTOARM_OWNER_STATE" in
      live) claim deferred; exit 0 ;;
      wedged)
        UNAVAILABLE="owner-wedged-and-unretirable"
        if [ "$FM_AUTOARM_OWNER_PID" != "$retired" ]; then
          retired=$FM_AUTOARM_OWNER_PID
          kill -TERM "$retired" 2>/dev/null || true
        fi
        ;;
    esac
    # No verified holder: a concurrent acquisition or a retiring owner. Retry
    # briefly rather than deferring to a holder nobody can vouch for.
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}
acquire_owner_lock || decline "$UNAVAILABLE"
trap cleanup EXIT
trap 'write_epoch killed; exit 143' TERM
trap 'write_epoch killed; exit 129' HUP
trap 'write_epoch killed; exit 130' INT
claim claimed

write_epoch arming

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- lifetime bound -----------------------------------------------------------
# Renew before Claude's timeout for this hook can kill the cycle. The tracked
# settings entry owns the timeout; FM_CLAUDE_AUTOARM_RENEW_AFTER (seconds) is a
# test and diagnostic override. An unreadable timeout falls back to an hourly
# renewal, which costs one quiet turn per idle hour but never goes blind.
hook_timeout() {
  command -v jq >/dev/null 2>&1 || return 1
  jq -er '[.hooks.Stop[]?.hooks[]? | select((.command // "") | contains("fm-claude-stop-autoarm.sh")) | .timeout | numbers][0]' \
    "$FM_ROOT/.claude/settings.json" 2>/dev/null
}
RENEW_AFTER=${FM_CLAUDE_AUTOARM_RENEW_AFTER:-}
case "$RENEW_AFTER" in
  ''|*[!0-9]*)
    TIMEOUT=$(hook_timeout) || TIMEOUT=
    case "$TIMEOUT" in
      ''|*[!0-9]*|0) RENEW_AFTER=3600 ;;
      *)
        MARGIN=$((TIMEOUT / 8))
        [ "$MARGIN" -le 900 ] || MARGIN=900
        RENEW_AFTER=$((TIMEOUT - MARGIN))
        ;;
    esac
    ;;
esac
RENEW_AT=$(( $(date +%s) + RENEW_AFTER ))
RENEWED=0
RETIRE_GRACE=15

# --- run the real arm wrapper -------------------------------------------------
# The arm stays a tracked child of this hook-owned process tree (never detached),
# forks the watcher as its own tracked child exactly as it does for the
# model-driven background-task path, and propagates the wake reason on close.
# This hook waits on it and retires it at the lifetime bound; the arm's own
# TERM handling stops the watcher it started and records the interruption.
OUT=
RC=0
run_arm() {
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  OUT=$(mktemp "$STATE/.claude-autoarm-output.XXXXXX") || OUT=/dev/null
  "$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1 &
  ARM_PID=$!
  # Poll finely while a close is likely (startup, attach, a fast wake), then
  # once a second for the long quiet stretch of a parked cycle.
  # Retirement signals the arm exactly once so its TERM handler can stop its
  # watcher and record the cycle; a second TERM would land after that handler
  # reset its trap and cut the bookkeeping short. Only an arm that ignores the
  # TERM for RETIRE_GRACE seconds is killed outright.
  local polls=0 retire_by=
  while fm_pid_alive "$ARM_PID"; do
    if [ "$RENEWED" -eq 0 ] && [ "$(date +%s)" -ge "$RENEW_AT" ]; then
      RENEWED=1
      retire_by=$(( $(date +%s) + RETIRE_GRACE ))
      kill -TERM "$ARM_PID" 2>/dev/null || true
    elif [ -n "$retire_by" ] && [ "$(date +%s)" -ge "$retire_by" ]; then
      kill -KILL "$ARM_PID" 2>/dev/null || true
    fi
    if [ "$polls" -lt 50 ]; then
      sleep 0.1
      polls=$((polls + 1))
    else
      sleep 1
    fi
  done
  wait "$ARM_PID"
  RC=$?
  ARM_PID=
  [ "$OUT" != /dev/null ] || OUT=
  return 0
}

ACTIONABLE=0
FAILED=0
TYPED_FAILED=0
ATTACHED=0
classify_arm_close() {
  ACTIONABLE=0
  FAILED=0
  TYPED_FAILED=0
  ATTACHED=0
  if [ -n "$OUT" ]; then
    grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" 2>/dev/null && ACTIONABLE=1
    grep -q '^watcher: FAILED' "$OUT" 2>/dev/null && TYPED_FAILED=1
    grep -Eq '^watcher: (started|attached) pid=' "$OUT" 2>/dev/null && ATTACHED=1
  fi
  [ "$TYPED_FAILED" -eq 0 ] || FAILED=1
  [ "$RC" -ne 0 ] && FAILED=1
  return 0
}

# --- classify and translate ---------------------------------------------------
# An absorbed-wake race can print the typed empty-cycle failure while this home
# still holds an identity-matched watcher with a fresh beacon: that cycle
# started, beat, and had its wake absorbed, so it is healthy, never FAILED. The
# same race can repeat one cycle deeper, so the health predicate is consulted on
# EVERY typed-failed close, never skipped because a re-arm already happened. A
# healthy verdict must not leave that watcher without a wake translator, so each
# proof re-arms (the arm reports attached and blocks following the surviving
# watcher) and the close of that cycle is classified the same way, up to
# REARM_MAX re-arms per firing.
REARMS=0
HEALTHY_AT_CLOSE=0
while :; do
  run_arm

  # AFK may have appeared mid-cycle: the daemon owns triage now, so suppress the
  # rewake even for an actionable close.
  if [ -e "$STATE/.afk" ]; then
    write_epoch afk
    exit 0
  fi

  classify_arm_close
  [ "$RENEWED" -eq 0 ] || break
  HEALTHY_AT_CLOSE=0

  [ "$ACTIONABLE" -eq 0 ] || break
  [ "$TYPED_FAILED" -eq 1 ] || break
  fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME" || break
  HEALTHY_AT_CLOSE=1
  [ "$REARMS" -lt "$REARM_MAX" ] || break
  REARMS=$((REARMS + 1))
  write_epoch arming
done

# Default closed: the suppression only holds when the re-arm proved it owns a
# watcher, by reporting the one it started or attached to, or by returning an
# actionable wake it translated. An unproven re-attach takes the alarm path.
if [ "$REARMS" -gt 0 ] && [ "$ACTIONABLE" -eq 0 ] && [ "$ATTACHED" -eq 0 ]; then
  FAILED=1
fi

# The need may have vanished mid-cycle (fleet torn down, X opted out): nothing
# left to supervise, so close quietly instead of waking the model.
if ! need_supervision; then
  write_epoch clean
  exit 0
fi

# Lifetime renewal: this firing retired its own quiet cycle before Claude's
# hook timeout could kill it silently. An actionable reason that raced the
# retirement still wins and takes the ordinary wake path below.
if [ "$RENEWED" -eq 1 ] && [ "$ACTIONABLE" -eq 0 ]; then
  write_epoch renewal
  {
    printf 'firstmate watcher renewal - this Stop hook reached its lifetime bound with no wake, so it retired its quiet watcher cycle before Claude could kill it.\n'
    printf 'Run bin/fm-wake-drain.sh first and handle anything it returns, then end the turn normally: the next turn end re-arms automatically - do NOT run bin/fm-watch-arm.sh.\n'
  } >&2
  exit 2
fi

if [ "$ACTIONABLE" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
  write_epoch clean
  exit 0
fi

write_epoch rewake
# The banner never asserts a supervision state this firing did not measure: the
# "supervision is down" wording is reserved for a close where no live watcher was
# proven, and a close that did prove one names the unresolved absorbed-wake chain
# instead. Both carry the same close evidence and repair.
print_failure_detail() {
  [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
  printf 'Run bin/fm-wake-drain.sh first. Then repair supervision with bin/fm-watch-arm.sh as its own Claude Code background task (never shell &). If the failure repeats, treat it as a blocker and report it instead of ending blind.\n'
}

if [ "$FAILED" -eq 1 ]; then
  {
    if [ "$HEALTHY_AT_CLOSE" -eq 1 ]; then
      printf 'firstmate watcher absorbed-wake chain unresolved after %s re-arms - a live watcher still holds this home, but this Stop hook stopped translating its wakes.\n' "$REARMS"
    else
      printf 'firstmate watcher cycle FAILED - supervision is down while this home still needs it.\n'
    fi
    print_failure_detail
  } >&2
else
  {
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    [ -n "$OUT" ] && grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    printf 'Run bin/fm-wake-drain.sh first and handle the wake. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  } >&2
fi
exit 2
