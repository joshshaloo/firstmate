#!/usr/bin/env bash
# Regression test for fm-spawn.sh's metadata-verified worktree occupancy check
# (bin/fm-spawn.sh, worktree_meta_claim plus the bounded re-acquire loop around
# `treehouse get`).
#
# Treehouse decides a pooled worktree is free from live processes cwd'd inside
# it. That detection goes stale whenever a working crewmate's shell sits outside
# its own worktree, and a reboot clears it entirely while every recorded
# worktree= under state/ survives. Treehouse then hands a live task's checkout to
# a second crewmate, whose first branch switch hijacks the first worker's
# checkout and pipeline anchoring; teardown later refuses to clean up because the
# slot holds another task's unpushed commits.
#
# These cases cover the observed incident shapes: a slot claimed by a live task
# is refused, a retry lands on the next clean slot, a claim whose task is no
# longer running is named but never discarded by spawn, an unclaimed slot still
# spawns exactly as before, and a task's own record never blocks its respawn.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-claim)

# make_claim_fakebin <dir> builds a fake tmux that models the treehouse pool as
# an ordered list of slots (FM_FAKE_SLOTS_FILE, one absolute path per line).
# It models treehouse's process-based occupancy the way fm-spawn's guards make
# it observable: a slot listed in a live state/<id>.wtguard marker is held by a
# guard process and is skipped, and selecting a claimed slot that no guard was
# holding is recorded as a protection violation.
# With no unclaimed slot, the pane remains in FM_FAKE_PROJECT_DIR.
#
# The occupant's liveness comes from the same fake: FM_FAKE_WINDOWS lists the
# window names `list-windows` reports (an absent window is an authoritatively
# missing endpoint), and FM_FAKE_COMMAND is the foreground command
# `#{pane_current_command}` reports for a listed one.
make_claim_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
countfile="${FM_FAKE_GET_COUNTFILE:?FM_FAKE_GET_COUNTFILE unset}"
selected_file="${FM_FAKE_SELECTED_FILE:?FM_FAKE_SELECTED_FILE unset}"
slot_claimed() {
  local slot=$1 meta recorded
  for meta in "${FM_STATE_OVERRIDE:?}"/*.meta; do
    [ -f "$meta" ] || continue
    recorded=$(grep '^worktree=' "$meta" 2>/dev/null | cut -d= -f2-)
    [ "$recorded" = "$slot" ] && return 0
  done
  return 1
}
slot_guarded() {
  local slot=$1 marker real
  real=$(cd "$slot" 2>/dev/null && pwd -P) || return 1
  for marker in "${FM_STATE_OVERRIDE:?}"/*.wtguard; do
    [ -f "$marker" ] || continue
    grep -Fqx -- "$real" "$marker" && return 0
  done
  return 1
}
case "$*" in
  *"send-keys"*" exit Enter"*)
    # Leaving the treehouse subshell puts the pane back in the project checkout,
    # which is exactly what spawn polls for before asking for another slot.
    printf 'exit\n' >> "${FM_FAKE_EXIT_SENDS:?}"
    printf '%s\n' "${FM_FAKE_PROJECT_DIR:?}" > "$selected_file"
    exit 0
    ;;
  *"send-keys"*"cd "*)
    while IFS= read -r slot; do
      [ -n "$slot" ] || continue
      case "$*" in
        *"$slot"*) printf '%s\n' "$slot" > "$selected_file"; break ;;
      esac
    done < "${FM_FAKE_SLOTS_FILE:?}"
    exit 0
    ;;
  *"send-keys"*"treehouse get"*)
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    selected=""
    # FM_FAKE_IGNORE_GUARDS models a treehouse that allocates from its own free
    # list instead of process cwd, so live guards do not stop it handing out a
    # recorded slot. That is not a protection violation - it is the case the
    # metadata occupancy check and the retry ladder exist to catch.
    if [ -n "${FM_FAKE_IGNORE_GUARDS:-}" ]; then
      selected=$(sed -n "${n}p" "${FM_FAKE_SLOTS_FILE:?}")
    else
      while IFS= read -r slot; do
        [ -n "$slot" ] || continue
        if slot_guarded "$slot"; then
          continue
        fi
        selected=$slot
        break
      done < "${FM_FAKE_SLOTS_FILE:?}"
      if [ -n "$selected" ] && slot_claimed "$selected"; then
        printf '%s\n' "$selected" >> "${FM_FAKE_CLAIM_VIOLATIONS:?}"
      fi
    fi
    if [ -n "$selected" ]; then
      printf '%s\n' "$selected" > "$selected_file"
    else
      printf '%s\n' "${FM_FAKE_PROJECT_DIR:?}" > "$selected_file"
    fi
    exit 0
    ;;
  *"#{pane_current_path}"*)
    if [ -f "$selected_file" ]; then
      cat "$selected_file"
    else
      printf '%s\n' "${FM_FAKE_PROJECT_DIR:?}"
    fi
    exit 0
    ;;
  *"#{pane_current_command}"*)
    printf '%s\n' "${FM_FAKE_COMMAND:-zsh}"
    exit 0
    ;;
  *"#{window_id}"*)
    printf '@7\n'
    exit 0
    ;;
esac
case "${1:-}" in
  list-windows)
    case "$*" in
      *" -a "*) exit 0 ;;
    esac
    printf '%s' "${FM_FAKE_WINDOWS:-}"
    exit 0
    ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_claim_case <name> <id> builds a home, a primary project, and two pooled
# worktrees of it (slot A and slot B). The caller decides which slots treehouse
# offers and which of them another task's record already claims.
make_claim_case() {
  local name=$1 id=$2 case_dir
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  SLOT_A="$CASE_DIR/slot-a"
  SLOT_B="$CASE_DIR/slot-b"
  SLOTS_FILE="$CASE_DIR/slots"
  COUNTFILE="$CASE_DIR/get-count"
  SELECTED_FILE="$CASE_DIR/selected-path"
  VIOLATION_FILE="$CASE_DIR/claimed-get-violations"
  EXIT_SENDS_FILE="$CASE_DIR/exit-sends"
  case_dir=$CASE_DIR
  FAKEBIN_DIR=$(make_claim_fakebin "$case_dir/fake")
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  fm_git_worktree "$PROJ_DIR" "$SLOT_A" "slot-a-$name"
  git -C "$PROJ_DIR" worktree add --quiet -b "slot-b-$name" "$SLOT_B"
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  touch "$HOME_DIR/state/.last-watcher-beat"
}

# offer_slots <path>...: the ordered slots treehouse hands out, one per
# `treehouse get`.
offer_slots() {
  : > "$SLOTS_FILE"
  printf '%s\n' "$@" >> "$SLOTS_FILE"
}

# claim_slot <task-id> <worktree> [backend]: record <worktree> as <task-id>'s
# worktree, exactly as a live spawn would have. An explicit backend covers the
# records whose runtime has no recovery-grade liveness classifier.
claim_slot() {
  local extra=()
  [ -z "${3:-}" ] || extra=("backend=$3")
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
    "effort=default" \
    ${extra+"${extra[@]}"}
}

run_claim_spawn() {  # <id> [windows] [command]
  local id=$1 windows=${2:-} command=${3:-zsh}
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_SPAWN_WORKTREE_POLLS=3 FM_SPAWN_WORKTREE_POLL_INTERVAL=0.05 \
    FM_FAKE_SLOTS_FILE="$SLOTS_FILE" FM_FAKE_GET_COUNTFILE="$COUNTFILE" \
    FM_FAKE_SELECTED_FILE="$SELECTED_FILE" \
    FM_FAKE_CLAIM_VIOLATIONS="$VIOLATION_FILE" FM_FAKE_PROJECT_DIR="$PROJ_DIR" \
    FM_FAKE_EXIT_SENDS="$EXIT_SENDS_FILE" \
    FM_FAKE_WINDOWS="$windows" FM_FAKE_COMMAND="$command" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

make_herdr_relaunch_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_FAKE_HERDR_RELAUNCH_LOG:?}"
STATE="${FM_FAKE_HERDR_RELAUNCH_STATE:?}"
ID="${FM_FAKE_HERDR_RELAUNCH_ID:?}"
WT="${FM_FAKE_HERDR_RELAUNCH_WT:?}"
PROJ="${FM_FAKE_PROJECT_DIR:?}"
MODE="${FM_FAKE_HERDR_RELAUNCH_MODE:?}"
OLD_PANE=w1:p-old
OLD_TAB=w1:t-old
NEW_PANE=w1:p-new
NEW_TAB=w1:t-new
SPLIT_PANE=w1:p-old-split
CAPTAIN_TAB=w1:t-captain
NEIGHBOR_TAB=w1:t-neighbor
mkdir -p "$STATE"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
json_not_found() { printf '{"error":{"code":"%s"}}\n' "$1"; }
arg_after() {
  local want=$1 prev= arg
  shift
  for arg in "$@"; do
    if [ "$prev" = "$want" ]; then printf '%s' "$arg"; return 0; fi
    prev=$arg
  done
  return 1
}
# The captain sits on its own tab; the husk tab is a sibling. MODE=activetab
# instead parks the captain on the husk tab itself, which is exactly the shape
# no exact-tab restore can survive.
FOCUS_FILE="$STATE/focused-tab"
if [ ! -f "$FOCUS_FILE" ]; then
  if [ "$MODE" = activetab ]; then printf '%s' "$OLD_TAB" > "$FOCUS_FILE"
  else printf '%s' "$CAPTAIN_TAB" > "$FOCUS_FILE"; fi
fi
focused_tab() { cat "$FOCUS_FILE"; }
tab_rows() {  # "<tab_id> <label>"
  printf '%s captain\n' "$CAPTAIN_TAB"
  printf '%s neighbor\n' "$NEIGHBOR_TAB"
  [ -e "$STATE/old-closed" ] || printf '%s fm-%s\n' "$OLD_TAB" "$ID"
  [ ! -e "$STATE/new-created" ] || printf '%s fm-%s\n' "$NEW_TAB" "$ID"
  return 0
}
pane_rows() {  # "<pane_id> <tab_id>"
  printf 'w1:p-captain %s\n' "$CAPTAIN_TAB"
  printf 'w1:p-neighbor %s\n' "$NEIGHBOR_TAB"
  if [ ! -e "$STATE/old-closed" ]; then
    printf '%s %s\n' "$OLD_PANE" "$OLD_TAB"
    [ "$MODE" != split ] || printf '%s %s\n' "$SPLIT_PANE" "$OLD_TAB"
  fi
  [ ! -e "$STATE/new-created" ] || printf '%s %s\n' "$NEW_PANE" "$NEW_TAB"
  return 0
}
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "session list")
    printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s/herdr.sock"}]}\n' "$STATE"
    ;;
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"%s"}]}}\n' \
      "$(focused_tab)"
    ;;
  "tab list")
    focus=$(focused_tab)
    sep=
    printf '{"result":{"tabs":['
    while read -r tid label; do
      [ -n "$tid" ] || continue
      if [ "$tid" = "$focus" ]; then flag=true; else flag=false; fi
      printf '%s{"tab_id":"%s","label":"%s","workspace_id":"w1","focused":%s}' "$sep" "$tid" "$label" "$flag"
      sep=,
    done < <(tab_rows)
    printf ']}}\n'
    ;;
  "pane list")
    sep=
    printf '{"result":{"panes":['
    while read -r pid tid; do
      [ -n "$pid" ] || continue
      printf '%s{"pane_id":"%s","tab_id":"%s","workspace_id":"w1"}' "$sep" "$pid" "$tid"
      sep=,
    done < <(pane_rows)
    printf ']}}\n'
    ;;
  "tab get")
    tid=${3:-}
    if tab_rows | cut -d' ' -f1 | grep -Fqx -- "$tid"; then
      printf '{"result":{"tab":{"tab_id":"%s","workspace_id":"w1"}}}\n' "$tid"
    else
      json_not_found tab_not_found
    fi
    ;;
  "tab focus")
    printf '%s' "${3:-}" > "$FOCUS_FILE"
    ;;
  "tab create")
    : > "$STATE/new-created"
    printf '%s\n' "$PROJ" > "$STATE/current-path"
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$NEW_TAB" "$NEW_PANE"
    ;;
  "pane get")
    pane=${3:-}
    if [ "$pane" = "$OLD_PANE" ]; then
      if [ -e "$STATE/old-closed" ]; then json_not_found pane_not_found; else printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"w1"}}}\n' "$OLD_PANE" "$OLD_TAB"; fi
    elif [ "$pane" = "$NEW_PANE" ] && [ -e "$STATE/new-created" ]; then
      path=$(cat "$STATE/current-path" 2>/dev/null || printf '%s' "$PROJ")
      printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"w1","foreground_cwd":"%s"}}}\n' "$NEW_PANE" "$NEW_TAB" "$path"
    else
      json_not_found pane_not_found
    fi
    ;;
  "agent get")
    pane=${3:-}
    if [ "$pane" = "$OLD_PANE" ] && [ "$MODE" = alive ]; then
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      json_not_found agent_not_found
    fi
    ;;
  "pane process-info")
    pane=$(arg_after --pane "$@" || true)
    [ "$pane" = "$OLD_PANE" ] || { json_not_found pane_not_found; exit 0; }
    if [ "$MODE" = fgjob ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":67,"foreground_process_group_id":99,"foreground_processes":[{"pid":99,"name":"sleep","argv":["/bin/sleep","100"]}]}}}\n' "$OLD_PANE"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":67,"foreground_process_group_id":67,"foreground_processes":[{"pid":67,"name":"bash","argv":["/bin/bash"]}]}}}\n' "$OLD_PANE"
    fi
    ;;
  "pane close")
    # Herdr 0.7.4's last-pane close focuses an unrelated neighbor; the caller
    # is only correct if it restores the exact pre-close tab afterwards.
    if [ "${3:-}" = "$OLD_PANE" ]; then
      : > "$STATE/old-closed"
      printf '%s' "$NEIGHBOR_TAB" > "$FOCUS_FILE"
      # MODE=closeraces: the husk vanished between the close-boundary recheck
      # and the close itself, so herdr answers the close with a not-found
      # error even though the pane is genuinely gone.
      [ "$MODE" != closeraces ] || { json_not_found pane_not_found >&2; exit 1; }
    fi
    ;;
  "pane run")
    command=${4:-}
    case "$command" in cd\ *) printf '%s\n' "$WT" > "$STATE/current-path" ;; esac
    ;;
  *) : ;;
esac
SH
  chmod +x "$fakebin/herdr"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  '-axo pid=,ppid=') printf '67 1\n' ;;
  '-p 67 -o stat=') printf 'S\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

claim_herdr_slot() {  # <task-id> <worktree> [backend]
  local id=$1 worktree=$2 backend=${3:-herdr}
  if [ "$backend" = herdr ]; then
    fm_write_meta "$HOME_DIR/state/$id.meta" \
      "window=default:w1:p-old" \
      "endpoint_task_id=$id" \
      "worktree=$worktree" \
      "project=$PROJ_DIR" \
      "harness=codex" \
      "kind=ship" \
      "mode=no-mistakes" \
      "yolo=off" \
      "tasktmp=/tmp/fm-$id" \
      "model=default" \
      "effort=default" \
      "backend=herdr" \
      "herdr_session=default" \
      "herdr_workspace_id=w1" \
      "herdr_tab_id=w1:t-old" \
      "herdr_pane_id=w1:p-old"
  else
    claim_slot "$id" "$worktree" "$backend"
  fi
}

herdr_relaunch_focused_tab() {
  cat "$CASE_DIR/herdr-fake/herdr-state/focused-tab" 2>/dev/null
}

# The named-session presentation lock this case's fake session resolves to. The
# per-case socket path keeps every case on its own lock even though the
# namespace itself is machine-shared, exactly as in production.
herdr_relaunch_lock_path() {
  local fake_dir="$CASE_DIR/herdr-fake" herdr_fakebin_dir
  herdr_fakebin_dir=$(make_herdr_relaunch_fakebin "$fake_dir")
  mkdir -p "$fake_dir/herdr-state"
  FM_FAKE_HERDR_RELAUNCH_LOG=/dev/null \
    FM_FAKE_HERDR_RELAUNCH_STATE="$fake_dir/herdr-state" \
    FM_FAKE_HERDR_RELAUNCH_ID=lockpath FM_FAKE_HERDR_RELAUNCH_WT="$SLOT_A" \
    FM_FAKE_PROJECT_DIR="$PROJ_DIR" FM_FAKE_HERDR_RELAUNCH_MODE=dead \
    HERDR_SESSION=default PATH="$herdr_fakebin_dir:$PATH" \
    bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path default' \
      _ "$ROOT"
}

run_herdr_relaunch_spawn() {  # <id> <mode> [target-backend]
  local id=$1 mode=$2 target_backend=${3:-herdr} fake_dir herdr_fakebin_dir
  fake_dir="$CASE_DIR/herdr-fake"
  herdr_fakebin_dir=$(make_herdr_relaunch_fakebin "$fake_dir")
  : > "$fake_dir/herdr.log"
  mkdir -p "$fake_dir/herdr-state"
  printf '%s\n' "$target_backend" > "$HOME_DIR/config/backend"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_SPAWN_WORKTREE_POLLS=3 \
    HERDR_ENV='' HERDR_PANE_ID='' HERDR_SOCKET_PATH='' HERDR_TAB_ID='' HERDR_WORKSPACE_ID='' \
    FM_SPAWN_WORKTREE_POLL_INTERVAL=0.05 FM_HERDR_PS_BIN=ps \
    FM_FAKE_PROJECT_DIR="$PROJ_DIR" \
    FM_FAKE_HERDR_RELAUNCH_LOG="$fake_dir/herdr.log" \
    FM_FAKE_HERDR_RELAUNCH_STATE="$fake_dir/herdr-state" \
    FM_FAKE_HERDR_RELAUNCH_ID="$id" \
    FM_FAKE_HERDR_RELAUNCH_WT="$SLOT_A" \
    FM_FAKE_HERDR_RELAUNCH_MODE="$mode" \
    PATH="$herdr_fakebin_dir:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness 'echo launched' 2>&1
}

# Incident shape 1: the pool offers a slot a live task already records as its
# worktree. Metadata outranks treehouse's process detection, so the slot is
# refused; with nothing else to offer, the spawn fails naming the claimant
# instead of retargeting into the live worker's checkout.
test_live_claim_is_refused() {
  local id out status
  id=claim-live-z1
  make_claim_case claim-live "$id"
  offer_slots "$SLOT_A"
  claim_slot occupant-live "$SLOT_A"

  out=$(run_claim_spawn "$id" "fm-occupant-live" claude)
  status=$?
  expect_code 1 "$status" "spawn should refuse a worktree a live task already claims"
  assert_contains "$out" "refusing to launch $id" "refusal did not name the spawn it stopped"
  assert_contains "$out" "claimed by occupant-live" "refusal did not name the claiming task"
  assert_contains "$out" "live worker" "refusal did not report the claimant as live"
  assert_contains "$out" "$SLOT_A" "refusal did not name the claimed worktree"
  assert_absent "$VIOLATION_FILE" "treehouse get was allowed to select the claimed slot before protection"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not record metadata"
  pass "a slot recorded by a live task is protected before get and refused, naming the claimant"
}

# Incident shape 2: one pooled slot is claimed, the next one is clean. The live
# guards keep treehouse off the claimed slot entirely, so the spawn lands on the
# clean one on its first get, leaving the claimant's record untouched.
test_retry_lands_on_clean_slot() {
  local id out status
  id=claim-retry-z2
  make_claim_case claim-retry "$id"
  offer_slots "$SLOT_A" "$SLOT_B"
  claim_slot occupant-retry "$SLOT_A"

  out=$(run_claim_spawn "$id" "fm-occupant-retry" claude)
  status=$?
  expect_code 0 "$status" "spawn should succeed once a clean slot is offered"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_not_contains "$out" "already recorded as another task's worktree" \
    "a pre-protected claimed slot should not be entered and refused after allocation"
  assert_absent "$VIOLATION_FILE" "treehouse get was allowed to select the claimed slot before protection"
  assert_grep "worktree=$SLOT_B" "$HOME_DIR/state/$id.meta" \
    "meta did not record the clean slot"
  assert_no_grep "worktree=$SLOT_A" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the claimed slot"
  assert_grep "worktree=$SLOT_A" "$HOME_DIR/state/occupant-retry.meta" \
    "the claimant's own record was modified"
  pass "a claimed slot is never offered while guarded and the spawn takes the clean one"
}

# Incident shape 3: the claiming task is genuinely gone (its endpoint is
# authoritatively absent), which is exactly the reboot-cleared ghost that
# treehouse recycles. Spawn still refuses the slot and names the record as
# unreconciled - releasing it is firstmate's job, because that record is what
# protects the unlanded work sitting in the slot.
test_ghost_claim_is_named_not_discarded() {
  local id out status before
  id=claim-ghost-z3
  make_claim_case claim-ghost "$id"
  offer_slots "$SLOT_A"
  claim_slot occupant-ghost "$SLOT_A"
  before=$(cat "$HOME_DIR/state/occupant-ghost.meta")
  printf 'unlanded work\n' > "$SLOT_A/unlanded.txt"

  out=$(run_claim_spawn "$id" "" zsh)
  status=$?
  expect_code 1 "$status" "spawn should refuse a slot claimed by an unreconciled record"
  assert_contains "$out" "claimed by occupant-ghost" "refusal did not name the ghost record"
  assert_absent "$VIOLATION_FILE" "treehouse get was allowed to select the ghost-claimed slot before protection"
  assert_contains "$out" "no live worker (missing)" \
    "refusal did not report the ghost record as having no live worker"
  assert_contains "$out" "unreconciled record" \
    "refusal did not mark the ghost record as needing reconciliation"
  assert_present "$HOME_DIR/state/occupant-ghost.meta" \
    "spawn discarded a ghost record it may only name"
  [ "$(cat "$HOME_DIR/state/occupant-ghost.meta")" = "$before" ] \
    || fail "spawn modified the ghost record it may only name"
  assert_present "$SLOT_A/unlanded.txt" "spawn touched the unlanded work in the claimed slot"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not record metadata"
  pass "a ghost claim is named as unreconciled and left intact for firstmate"
}

# The clean path is unchanged: an unclaimed slot spawns on the first attempt,
# with no refusal, even while other tasks hold unrelated worktrees.
test_unclaimed_slot_spawns_unchanged() {
  local id out status
  id=claim-clean-z4
  make_claim_case claim-clean "$id"
  offer_slots "$SLOT_B"
  claim_slot occupant-elsewhere "$SLOT_A"

  out=$(run_claim_spawn "$id" "fm-occupant-elsewhere" claude)
  status=$?
  expect_code 0 "$status" "spawn should succeed on an unclaimed slot"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_not_contains "$out" "already recorded as another task's worktree" \
    "an unclaimed slot must not report a refusal"
  assert_absent "$VIOLATION_FILE" "treehouse get was allowed to select a claimed slot before the clean slot"
  assert_grep "worktree=$SLOT_B" "$HOME_DIR/state/$id.meta" \
    "meta did not record the unclaimed slot"
  [ "$(cat "$COUNTFILE")" = 1 ] || fail "an unclaimed slot took more than one treehouse get"
  pass "an unclaimed slot spawns on the first attempt, unchanged"
}

# A respawn of the SAME task re-claims the worktree its own record names: the
# check must refuse other tasks' records, never the task's own, or recovery
# could never put a crewmate back in its own checkout.
test_own_record_is_not_a_collision() {
  local id out status before after
  id=claim-self-z5
  make_claim_case claim-self "$id"
  offer_slots "$SLOT_A"
  claim_slot "$id" "$SLOT_A"
  before=$(cat "$HOME_DIR/state/$id.meta")

  out=$(run_claim_spawn "$id" "" zsh)
  status=$?
  expect_code 0 "$status" "a same-id relaunch should reuse the worktree its own record names"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$SLOT_A" "$HOME_DIR/state/$id.meta" \
    "meta did not record the task's own worktree"
  [ ! -f "$COUNTFILE" ] || [ "$(cat "$COUNTFILE")" = 0 ] \
    || fail "same-id relaunch called treehouse get instead of reusing the recorded worktree"
  after=$(cat "$HOME_DIR/state/$id.meta")
  [ "$after" = "$before" ] \
    || fail "same-id relaunch rewrote metadata unexpectedly"$'\n'"before:"$'\n'"$before"$'\n'"after:"$'\n'"$after"
  pass "a same-id relaunch reuses its recorded worktree without treehouse get or metadata churn"
}

test_same_id_relaunch_refuses_missing_recorded_worktree_without_get() {
  local id out status missing
  id=claim-self-missing-z6
  make_claim_case claim-self-missing "$id"
  offer_slots "$SLOT_B"
  missing="$CASE_DIR/missing-slot"
  claim_slot "$id" "$missing"

  out=$(run_claim_spawn "$id" "" zsh)
  status=$?
  expect_code 1 "$status" "same-id relaunch should refuse a missing recorded worktree"
  assert_contains "$out" "records missing worktree=$missing" \
    "refusal did not name the missing recorded worktree"
  [ ! -f "$COUNTFILE" ] || [ "$(cat "$COUNTFILE")" = 0 ] \
    || fail "same-id relaunch with a missing recorded worktree called treehouse get"
  assert_absent "$HOME_DIR/state/$id.meta.tmp" "refused relaunch left temporary metadata"
  pass "a same-id relaunch refuses a missing recorded worktree without treehouse get"
}

# If two records name the same worktree, the same-id relaunch must stop for
# supervisor reconciliation rather than allocating a third copy.
test_same_id_relaunch_refuses_conflicting_record_claim_without_get() {
  local id out status
  id=claim-self-conflict-z7
  make_claim_case claim-self-conflict "$id"
  offer_slots "$SLOT_B"
  claim_slot "$id" "$SLOT_A"
  claim_slot occupant-conflict "$SLOT_A"

  out=$(run_claim_spawn "$id" "" zsh)
  status=$?
  expect_code 1 "$status" "same-id relaunch should refuse a worktree claimed by another record"
  assert_contains "$out" "another task record claims that same path" \
    "refusal did not explain the conflicting worktree claim"
  assert_contains "$out" "claimed by occupant-conflict" \
    "refusal did not name the conflicting record"
  [ ! -f "$COUNTFILE" ] || [ "$(cat "$COUNTFILE")" = 0 ] \
    || fail "same-id relaunch with a conflicting record called treehouse get"
  pass "a same-id relaunch refuses a conflicting recorded worktree without treehouse get"
}

# The guards are the only thing standing between `treehouse get` and an
# irreversible reset of a recorded worktree, so a guard that cannot prove it
# reached its worktree must stop the spawn BEFORE any get - the reset it would
# otherwise allow cannot be undone by a later refusal. Squatting the marker path
# with a directory is the cheapest way to make every guard fail to report in.
test_unproven_guards_refuse_before_get() {
  local id out status
  id=claim-guardless-z9
  make_claim_case claim-guardless "$id"
  offer_slots "$SLOT_A" "$SLOT_B"
  claim_slot occupant-guardless "$SLOT_A"
  mkdir -p "$HOME_DIR/state/$id.wtguard"

  out=$(FM_SPAWN_WORKTREE_GUARD_POLLS=3 FM_SPAWN_WORKTREE_GUARD_POLL_INTERVAL=0.05 \
    run_claim_spawn "$id" "fm-occupant-guardless" claude)
  status=$?
  expect_code 1 "$status" "spawn should refuse when the recorded-worktree guards cannot be proven live"
  assert_contains "$out" "could not be proven live" \
    "refusal did not explain that the guards were never proven"
  assert_contains "$out" "$SLOT_A" "refusal did not name the unguarded recorded worktree"
  [ ! -f "$COUNTFILE" ] || [ "$(cat "$COUNTFILE")" = 0 ] \
    || fail "spawn ran treehouse get without proven recorded-worktree guards"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not record metadata"
  pass "unproven recorded-worktree guards refuse the spawn before any treehouse get"
}

# Guards are protection, not proof. A treehouse that allocates from its own free
# list can still hand out a recorded slot, so the metadata occupancy check stays
# the backstop: refuse the slot, leave the refused subshell, and re-ask.
test_guard_ignoring_treehouse_is_refused_and_retried() {
  local id out status
  id=claim-ignored-za
  make_claim_case claim-ignored "$id"
  offer_slots "$SLOT_A" "$SLOT_B"
  claim_slot occupant-ignored "$SLOT_A"

  out=$(FM_FAKE_IGNORE_GUARDS=1 run_claim_spawn "$id" "fm-occupant-ignored" claude)
  status=$?
  expect_code 0 "$status" "spawn should re-acquire when treehouse hands out a claimed slot anyway"
  assert_contains "$out" "already recorded as another task's worktree" \
    "the refused first slot was not reported"
  assert_grep "worktree=$SLOT_B" "$HOME_DIR/state/$id.meta" \
    "meta did not record the clean slot the retry landed on"
  assert_grep "worktree=$SLOT_A" "$HOME_DIR/state/occupant-ignored.meta" \
    "the claimant's own record was modified"
  [ "$(cat "$COUNTFILE")" = 2 ] || fail "the refused slot was not re-requested exactly once"
  [ -f "$EXIT_SENDS_FILE" ] && [ "$(grep -c . "$EXIT_SENDS_FILE")" = 1 ] \
    || fail "the refused treehouse subshell was not exited before the retry"
  assert_contains "$out" "asking for a different slot (attempt 1 of 3)" \
    "the retry only ran after the pane settled back in the project checkout"
  pass "a claimed slot handed out despite the guards is refused, exited, and re-asked"
}

# A record whose runtime has no recovery-grade liveness classifier cannot prove
# the claim is stale, so the slot is still refused. Occupancy comes from the
# record, never from a liveness read that came back inconclusive.
test_unclassifiable_claim_is_still_refused() {
  local id out status
  id=claim-unverified-z8
  make_claim_case claim-unverified "$id"
  offer_slots "$SLOT_A"
  claim_slot occupant-unverified "$SLOT_A" zellij

  out=$(run_claim_spawn "$id" "" zsh)
  status=$?
  expect_code 1 "$status" "spawn should refuse a claim whose liveness cannot be classified"
  assert_contains "$out" "claimed by occupant-unverified" "refusal did not name the claiming task"
  assert_contains "$out" "treated as claimed" "refusal did not report the inconclusive state as claimed"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not record metadata"
  pass "a claim with no classifiable liveness is refused, not assumed free"
}

test_same_id_herdr_dead_pane_reconciles_and_reuses_worktree() {
  local id out status log lock
  id=claim-herdr-dead-zb
  make_claim_case claim-herdr-dead "$id"
  claim_herdr_slot "$id" "$SLOT_A"

  out=$(run_herdr_relaunch_spawn "$id" dead)
  status=$?
  expect_code 0 "$status" "same-id relaunch should reconcile a dead Herdr pane and reuse its worktree"
  assert_contains "$out" "spawned $id" "Herdr relaunch did not report success"
  assert_grep "worktree=$SLOT_A" "$HOME_DIR/state/$id.meta" \
    "Herdr relaunch did not preserve the recorded worktree"
  assert_grep "window=default:w1:p-new" "$HOME_DIR/state/$id.meta" \
    "Herdr relaunch did not record the replacement pane"
  [ ! -f "$COUNTFILE" ] || [ "$(cat "$COUNTFILE")" = 0 ] \
    || fail "Herdr same-id relaunch called treehouse get instead of reusing the recorded worktree"
  log=$(cat "$CASE_DIR/herdr-fake/herdr.log")
  assert_contains "$log" $'pane\x1fprocess-info\x1f--pane\x1fw1:p-old' \
    "Herdr relaunch did not prove the old pane process state"
  assert_contains "$log" $'pane\x1fclose\x1fw1:p-old' \
    "Herdr relaunch did not close the exact old pane"
  assert_contains "$log" $'tab\x1fcreate\x1f--workspace\x1fw1' \
    "Herdr relaunch did not create a replacement endpoint after reconciliation"
  assert_contains "$log" $'tab\x1ffocus\x1fw1:t-captain' \
    "Herdr relaunch did not restore the captain's exact pre-close tab"
  [ "$(herdr_relaunch_focused_tab)" = w1:t-captain ] \
    || fail "Herdr relaunch left the captain focused somewhere other than its pre-close tab"
  lock=$(herdr_relaunch_lock_path) || fail "could not resolve the session presentation lock"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] \
    || fail "Herdr relaunch did not release the session presentation lock after reconciling"
  pass "a same-id Herdr relaunch closes a proven dead pane and reuses the recorded worktree"
}

# The focus-preserving close owner is only safe when one operation at a time
# snapshots, closes, and restores. A concurrent teardown or session cleanup
# holding the named-session presentation lock must make the relaunch refuse
# outright rather than snapshot a neighbor's transient focus.
test_same_id_herdr_reconcile_refuses_while_presentation_lock_is_held() {
  local id out status log lock ready release owner_pid
  id=claim-herdr-lock-zi
  make_claim_case claim-herdr-lock "$id"
  claim_herdr_slot "$id" "$SLOT_A"

  lock=$(herdr_relaunch_lock_path) || fail "could not resolve the session presentation lock"
  ready="$CASE_DIR/lock-ready"
  release="$CASE_DIR/lock-release"
  ROOT="$ROOT" READY="$ready" RELEASE="$release" LOCK="$lock" bash -c '
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ]; do sleep 0.05; done
    fm_lock_release "$LOCK"
  ' &
  owner_pid=$!
  while [ ! -e "$ready" ] && kill -0 "$owner_pid" 2>/dev/null; do sleep 0.01; done
  [ -e "$ready" ] || fail "could not hold the session presentation lock"

  out=$(run_herdr_relaunch_spawn "$id" dead)
  status=$?
  : > "$release"
  wait "$owner_pid" || fail "the presentation lock owner failed"

  expect_code 1 "$status" "a contended presentation lock should refuse the same-id relaunch"
  assert_contains "$out" "presentation focus lock unavailable" \
    "the lock-contention refusal did not name the focus lock"
  log=$(cat "$CASE_DIR/herdr-fake/herdr.log")
  assert_not_contains "$log" $'pane\x1fclose\x1fw1:p-old' \
    "a contended presentation lock still closed the recorded pane"
  assert_not_contains "$log" $'tab\x1fcreate\x1f--workspace\x1fw1' \
    "a contended presentation lock still created a duplicate endpoint"
  pass "a same-id Herdr relaunch refuses a concurrent focus-unsafe close under lock contention"
}

# The husk is the captain's own active tab, so no exact-tab restore can survive
# its close. The one focus-preserving close owner refuses instead of moving the
# captain, and the relaunch refuses with it.
test_same_id_herdr_active_tab_husk_refuses() {
  local id out status log
  id=claim-herdr-activetab-zf
  make_claim_case claim-herdr-activetab "$id"
  claim_herdr_slot "$id" "$SLOT_A"

  out=$(run_herdr_relaunch_spawn "$id" activetab)
  status=$?
  expect_code 1 "$status" "same-id relaunch should refuse to close the captain's active tab"
  assert_contains "$out" "active tab" \
    "the active-tab refusal did not name the focus boundary"
  assert_contains "$out" "was left untouched" \
    "the active-tab refusal did not say the endpoint survived"
  log=$(cat "$CASE_DIR/herdr-fake/herdr.log")
  assert_not_contains "$log" $'pane\x1fclose\x1fw1:p-old' \
    "the active-tab husk was closed anyway"
  assert_not_contains "$log" $'tab\x1fcreate\x1f--workspace\x1fw1' \
    "the active-tab refusal created a duplicate endpoint"
  [ "$(herdr_relaunch_focused_tab)" = w1:t-old ] \
    || fail "the refused relaunch still moved the captain's focus"
  pass "a same-id Herdr relaunch refuses an active-tab husk instead of stealing focus"
}

# A human split the husk pane in the Herdr UI. Closing the recorded pane would
# leave the fm-<id> tab alive, and the create path refuses any surviving
# same-labeled tab - so the proof must cover the tab, not just the pane.
test_same_id_herdr_split_tab_refuses_without_closing() {
  local id out status log
  id=claim-herdr-split-zg
  make_claim_case claim-herdr-split "$id"
  claim_herdr_slot "$id" "$SLOT_A"

  out=$(run_herdr_relaunch_spawn "$id" split)
  status=$?
  expect_code 1 "$status" "same-id relaunch should refuse a husk whose tab holds another pane"
  assert_contains "$out" "w1:t-old still holds another pane (w1:p-old-split)" \
    "the split-tab refusal did not name the tab and the extra pane"
  log=$(cat "$CASE_DIR/herdr-fake/herdr.log")
  assert_not_contains "$log" $'pane\x1fclose\x1fw1:p-old' \
    "the split-tab refusal destroyed the recorded pane anyway"
  assert_not_contains "$log" $'tab\x1fcreate\x1f--workspace\x1fw1' \
    "the split-tab refusal created a duplicate endpoint"
  pass "a same-id Herdr relaunch refuses a husk that would leave its task tab behind"
}

# Reconciliation is symmetric with tmux adoption: it only runs when the recorded
# AND the target backend are both herdr. A relaunch onto a different backend
# still refuses and asks for explicit reconciliation instead of mutating Herdr.
# A close that herdr answers with a not-found error still destroyed the pane.
# The reconcile's verdict comes from the post-close state read, so the relaunch
# proceeds instead of reporting an endpoint it just closed as left untouched.
test_same_id_herdr_close_race_is_reported_as_gone_not_untouched() {
  local id out status log
  id=claim-herdr-closerace-zj
  make_claim_case claim-herdr-closerace "$id"
  claim_herdr_slot "$id" "$SLOT_A"

  out=$(run_herdr_relaunch_spawn "$id" closeraces)
  status=$?
  expect_code 0 "$status" "a close the husk lost a race to should still let the relaunch proceed"
  assert_not_contains "$out" "was left untouched" \
    "a destroyed endpoint was reported as left untouched"
  assert_grep "window=default:w1:p-new" "$HOME_DIR/state/$id.meta" \
    "the relaunch did not record the replacement pane after the close race"
  log=$(cat "$CASE_DIR/herdr-fake/herdr.log")
  assert_contains "$log" $'tab\x1fcreate\x1f--workspace\x1fw1' \
    "the relaunch did not create a replacement endpoint after the close race"
  pass "a failed close whose pane is gone reconciles instead of refusing as untouched"
}

test_same_id_herdr_cross_backend_relaunch_refuses_without_closing() {
  local id out status log
  id=claim-herdr-cross-zh
  make_claim_case claim-herdr-cross "$id"
  claim_herdr_slot "$id" "$SLOT_A"

  out=$(run_herdr_relaunch_spawn "$id" dead zellij)
  status=$?
  expect_code 1 "$status" "a cross-backend same-id relaunch should refuse instead of reconciling Herdr"
  assert_contains "$out" "until that endpoint is reconciled" \
    "the cross-backend refusal did not ask for explicit reconciliation"
  log=$(cat "$CASE_DIR/herdr-fake/herdr.log")
  assert_not_contains "$log" $'pane\x1fclose\x1fw1:p-old' \
    "a cross-backend relaunch closed the recorded Herdr pane"
  [ ! -f "$COUNTFILE" ] || [ "$(cat "$COUNTFILE")" = 0 ] \
    || fail "a refused cross-backend relaunch called treehouse get"
  pass "a same-id relaunch onto another backend refuses without mutating Herdr"
}

test_same_id_herdr_alive_refuses_without_closing() {
  local id out status log
  id=claim-herdr-live-zc
  make_claim_case claim-herdr-live "$id"
  claim_herdr_slot "$id" "$SLOT_A"

  out=$(run_herdr_relaunch_spawn "$id" alive)
  status=$?
  expect_code 1 "$status" "same-id relaunch should refuse a live Herdr endpoint"
  assert_contains "$out" "still has a live agent" \
    "Herdr live refusal did not name the live-agent risk"
  log=$(cat "$CASE_DIR/herdr-fake/herdr.log")
  assert_not_contains "$log" $'pane\x1fclose\x1fw1:p-old' \
    "Herdr live refusal closed the old pane"
  assert_not_contains "$log" $'tab\x1fcreate\x1f--workspace\x1fw1' \
    "Herdr live refusal created a duplicate endpoint"
  pass "a same-id Herdr relaunch refuses a live endpoint without closing it"
}

test_same_id_unverified_endpoint_refuses_without_get() {
  local id out status
  id=claim-unverified-self-zd
  make_claim_case claim-unverified-self "$id"
  offer_slots "$SLOT_A"
  claim_herdr_slot "$id" "$SLOT_A" zellij

  out=$(run_herdr_relaunch_spawn "$id" dead)
  status=$?
  expect_code 1 "$status" "same-id relaunch should refuse an unverified old backend"
  assert_contains "$out" "is unverified" \
    "unverified endpoint refusal did not name the unverified state"
  [ ! -f "$COUNTFILE" ] || [ "$(cat "$COUNTFILE")" = 0 ] \
    || fail "unverified same-id relaunch called treehouse get"
  pass "a same-id relaunch refuses an unverified old endpoint without treehouse get"
}

test_same_id_herdr_foreground_job_refuses_without_closing() {
  local id out status log
  id=claim-herdr-fgjob-ze
  make_claim_case claim-herdr-fgjob "$id"
  claim_herdr_slot "$id" "$SLOT_A"

  out=$(run_herdr_relaunch_spawn "$id" fgjob)
  status=$?
  expect_code 1 "$status" "same-id relaunch should refuse when Herdr process proof fails"
  assert_contains "$out" "herdr pane w1:p-old is not a provably idle childless shell" \
    "Herdr process-proof refusal did not name the exact pane and the safety reason"
  log=$(cat "$CASE_DIR/herdr-fake/herdr.log")
  assert_contains "$log" $'pane\x1fprocess-info\x1f--pane\x1fw1:p-old' \
    "Herdr process-proof case did not inspect process info"
  assert_not_contains "$log" $'pane\x1fclose\x1fw1:p-old' \
    "Herdr process-proof failure still closed the old pane"
  assert_not_contains "$log" $'tab\x1fcreate\x1f--workspace\x1fw1' \
    "Herdr process-proof failure created a duplicate endpoint"
  pass "a same-id Herdr relaunch refuses a pane with a foreground job instead of closing it"
}

test_live_claim_is_refused
test_retry_lands_on_clean_slot
test_ghost_claim_is_named_not_discarded
test_unclaimed_slot_spawns_unchanged
test_own_record_is_not_a_collision
test_same_id_relaunch_refuses_missing_recorded_worktree_without_get
test_same_id_relaunch_refuses_conflicting_record_claim_without_get
test_unproven_guards_refuse_before_get
test_guard_ignoring_treehouse_is_refused_and_retried
test_unclassifiable_claim_is_still_refused
test_same_id_herdr_dead_pane_reconciles_and_reuses_worktree
test_same_id_herdr_alive_refuses_without_closing
test_same_id_unverified_endpoint_refuses_without_get
test_same_id_herdr_foreground_job_refuses_without_closing
test_same_id_herdr_reconcile_refuses_while_presentation_lock_is_held
test_same_id_herdr_active_tab_husk_refuses
test_same_id_herdr_split_tab_refuses_without_closing
test_same_id_herdr_close_race_is_reported_as_gone_not_untouched
test_same_id_herdr_cross_backend_relaunch_refuses_without_closing

echo "# all fm-spawn-worktree-claim tests passed"
