# shellcheck shell=bash
# Stop-event claim handshake between Claude's two Stop hooks.
#
# ONE owner of how the synchronous turn-end guard (bin/fm-turnend-guard.sh
# --claude) learns what the asynchronous Stop auto-arm
# (bin/fm-claude-stop-autoarm.sh) decided for the SAME Stop event, and of which
# process counts as a live auto-arm owner.
#
# Claude Code launches every hook of one Stop event in parallel and feeds each
# the same payload bytes (docs/verification/supervision.md records the live
# check). Both hooks derive the same event key from those bytes. The auto-arm
# publishes its progress for that key, and the guard waits for that verdict
# instead of inferring absence from a fixed timer: a slow auto-arm on a loaded
# host is waited for rather than reported missing, while an auto-arm that
# declines, dies undecided, or never starts is reported with that concrete
# reason. Hook order inside the Stop group is irrelevant to this contract.
#
# Record: state/.claude-autoarm-claims/<key>, one line
#   phase=<phase> pid=<auto-arm pid> reason=<slug> at=<epoch seconds>
# Phases:
#   started   the auto-arm is running for this event and has not decided yet
#   claimed   this firing holds the single-flight owner lock and owns recovery
#   deferred  a verified live owner from an earlier firing already owns recovery
#   declined  this firing will not arm; reason names why
# Records older than an hour are pruned whenever a new event starts.
# Two stops can share a key only when their payloads are byte-identical (the
# same prompt, loop-guard flag, and final message), which happens only inside
# one forced-continuation chain; a reused record then reflects the same home
# state the new firing would report, so the collision is benign.
#
# Owner liveness is verified, never inferred from a bare pid: the pid must be
# alive AND running this home's auto-arm script, so a recycled pid can never
# impersonate an owner and wedge the single-flight lock. A verified owner that
# has held its claim past the grace window while no healthy watcher exists is
# wedged: it is not proof of recovery, and the next firing retires it.
# Sourced by scripts; no side effects on source beyond resolving paths.

FM_CLAUDE_AUTOARM_SCRIPT=${FM_CLAUDE_AUTOARM_SCRIPT:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-claude-stop-autoarm.sh"}

fm_claude_autoarm_owner_lock() {  # <state-dir>
  printf '%s/.claude-autoarm.lock\n' "$1"
}

fm_claude_autoarm_epoch_file() {  # <state-dir>
  printf '%s/.claude-autoarm-epoch\n' "$1"
}

fm_claude_autoarm_claims_dir() {  # <state-dir>
  printf '%s/.claude-autoarm-claims\n' "$1"
}

# Event key: CRC and byte length of the raw Stop payload. Both hooks receive the
# identical bytes; cksum is POSIX, so no platform hash tool is required.
fm_claude_stop_event_key() {  # <payload>
  printf '%s' "$1" | cksum | awk '{printf "%s-%s\n", $1, $2}'
}

# True when <pid> is alive and one of its argv entries is this home's auto-arm
# script (same file, however the path was spelled).
fm_claude_autoarm_pid_is_owner() {  # <pid>
  local pid=$1 arg args
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    while IFS= read -r -d '' arg; do
      case "$arg" in
        *fm-claude-stop-autoarm.sh) [ "$arg" -ef "$FM_CLAUDE_AUTOARM_SCRIPT" ] && return 0 ;;
      esac
    done < "/proc/$pid/cmdline"
    return 1
  fi
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  for arg in $args; do
    case "$arg" in
      *fm-claude-stop-autoarm.sh) [ "$arg" -ef "$FM_CLAUDE_AUTOARM_SCRIPT" ] && return 0 ;;
    esac
  done
  return 1
}

# Classify the current single-flight owner. Sets FM_AUTOARM_OWNER_STATE to
# none (no verified live owner), live, or wedged, and FM_AUTOARM_OWNER_PID to
# the verified owner pid. Call it directly, never in a command substitution.
# Requires bin/fm-wake-lib.sh (fm_path_age, fm_watcher_healthy).
fm_claude_autoarm_owner_status() {  # <state-dir> <watch-path> <grace> <home>
  local state=$1 watch=$2 grace=$3 home=$4 lock pid age
  FM_AUTOARM_OWNER_STATE=none
  FM_AUTOARM_OWNER_PID=
  lock=$(fm_claude_autoarm_owner_lock "$state")
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  fm_claude_autoarm_pid_is_owner "$pid" || return 0
  # shellcheck disable=SC2034 # Read by callers after this returns.
  FM_AUTOARM_OWNER_PID=$pid
  FM_AUTOARM_OWNER_STATE=live
  age=$(fm_path_age "$lock/pid")
  if [ "$age" -ge "$grace" ] && ! fm_watcher_healthy "$state" "$watch" "$grace" "$home"; then
    # shellcheck disable=SC2034 # Read by callers after this returns.
    FM_AUTOARM_OWNER_STATE=wedged
  fi
  return 0
}

fm_claude_claim_publish() {  # <state-dir> <key> <phase> [reason]
  local state=$1 key=$2 phase=$3 reason=${4:-none} dir tmp
  dir=$(fm_claude_autoarm_claims_dir "$state")
  mkdir -p "$dir" 2>/dev/null || return 0
  if [ "$phase" = started ]; then
    find "$dir" -type f -mmin +60 -exec rm -f {} + 2>/dev/null || true
  fi
  tmp="$dir/.$key.tmp.${BASHPID:-$$}"
  printf 'phase=%s pid=%s reason=%s at=%s\n' "$phase" "${BASHPID:-$$}" "$reason" "$(date +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$dir/$key" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# Reads the record for <key>. Sets FM_CLAIM_PHASE, FM_CLAIM_PID, FM_CLAIM_REASON;
# returns 1 when no well-formed record exists.
fm_claude_claim_read() {  # <state-dir> <key>
  local line
  FM_CLAIM_PHASE=
  FM_CLAIM_PID=
  FM_CLAIM_REASON=
  line=$(cat "$(fm_claude_autoarm_claims_dir "$1")/$2" 2>/dev/null) || return 1
  FM_CLAIM_PHASE=$(printf '%s\n' "$line" | sed -n 's/^phase=\([a-z]*\) .*/\1/p')
  # shellcheck disable=SC2034 # Read by callers after this returns.
  FM_CLAIM_PID=$(printf '%s\n' "$line" | sed -n 's/.* pid=\([0-9]*\) .*/\1/p')
  # shellcheck disable=SC2034 # Read by callers after this returns.
  FM_CLAIM_REASON=$(printf '%s\n' "$line" | sed -n 's/.* reason=\([A-Za-z0-9._-]*\) .*/\1/p')
  case "$FM_CLAIM_PHASE" in
    started|claimed|deferred|declined) return 0 ;;
  esac
  return 1
}

# Human-readable text for a declined reason or a guard-observed failure. The
# auto-arm publishes the slugs; the guard observes the last four itself.
fm_claude_claim_reason_text() {  # <slug>
  case "$1" in
    session-lock-missing) echo 'the auto-arm declined: this home has no session lock (state/.lock), so no session is proven to own it' ;;
    session-lock-malformed) echo 'the auto-arm declined: the session lock (state/.lock) does not hold a harness pid' ;;
    session-lock-held-by-another-live-session) echo 'the auto-arm declined: another live harness session holds this home'"'"'s session lock, so this session does not own supervision; check bin/fm-lock.sh status and settle which session owns this home before arming anything' ;;
    session-lock-recovery-failed) echo 'the auto-arm declined: it could not reclaim the dead session owner'"'"'s lock through bin/fm-lock.sh' ;;
    session-lock-recovery-unverified) echo 'the auto-arm declined: after reclaiming the session lock it could not verify this session owns it' ;;
    owner-lock-unavailable) echo 'the auto-arm declined: its single-flight lock stayed held with no verifiable owner' ;;
    owner-wedged-and-unretirable) echo 'the auto-arm declined: a wedged earlier auto-arm holds the claim and did not retire' ;;
    away-mode) echo 'away mode is active, so the away daemon, not the Stop auto-arm, owns this home'"'"'s watcher' ;;
    never-started) echo 'the Stop auto-arm never reported for this turn end, so the harness did not run it or it died before its first step' ;;
    exited-undecided) echo 'the Stop auto-arm started for this turn end but exited before claiming or declining' ;;
    still-deciding) echo 'the Stop auto-arm is still running for this turn end but has not claimed recovery within the wait bound' ;;
    *) printf 'the auto-arm reported %s\n' "$1" ;;
  esac
}
