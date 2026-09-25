#!/usr/bin/env bash
# Shadow-only wake triage, using the real fm-jev helper with a PATH curl stub.
# No credentials or network outside this fixture, no model judgment in tests.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
fm_test_set_base_path BASE_PATH jq
fm_test_tmproot TMP_ROOT fm-watch-jev
OBSERVER="$ROOT/bin/fm-watch-jev.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
out=; payload=; prev=
for arg in "$@"; do
  case "$prev" in -o) out=$arg ;; --data-binary) payload=${arg#@} ;; esac
  prev=$arg
done
printf 'call\n' >> "$CURL_LOG"
cp "$payload" "$CAPTURE"
[ "${DELAY:-0}" = 0 ] || sleep "$DELAY"
[ "${TRANSPORT:-0}" = 0 ] || exit 7
printf '%s\n' "$FM_FAKE_CURL_BODY" > "$out"
printf '%s' "${CODE:-200}"
SH
chmod +x "$FAKEBIN/curl"
export CURL_LOG="$TMP_ROOT/calls" CAPTURE="$TMP_ROOT/request"
export FM_JEV_ENV_FILE="$TMP_ROOT/credentials"
printf 'OPENROUTER_API_KEY=never-log-this-secret\n' > "$FM_JEV_ENV_FILE"
chmod 600 "$FM_JEV_ENV_FILE"
GOOD='{"model":"typesafe/jev-1.13-20260917","answers":{"external_wait":{"type":"noul","noul":0.99},"new_fact":{"type":"noul","noul":0.01},"stuck":{"type":"noul","noul":0.01},"action":{"type":"choice","choice":"no_action","probabilities":{"no_action":0.98,"supervisor_action":0.01,"captain_decision":0.01},"confidence":0.97}}}'
BODY="$GOOD"
SNAPSHOT='{"task":"a","deterministic":"SURFACE","origin":"pause-cadence","events":["paused: vendor reset","paused: vendor reset"],"declared_wait":"paused: vendor reset","paused_verb":"paused","age_seconds":3600,"metadata_ok":true,"open_event":false,"override":false,"check_state":"","pr_state":""}'

new_case() {
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE"
  : > "$CURL_LOG"
}
run_observer() {
  OUT=$(printf '%s\n' "$SNAPSHOT" | PATH="$FAKEBIN:$BASE_PATH" FM_FAKE_CURL_BODY="$BODY" "$OBSERVER" --state-dir "$CASE")
  [ "$OUT" = SURFACE ] || fail "observer changed actual verdict: $OUT"
}
last_entry() { tail -1 "$CASE/.jev-shadow.jsonl"; }
assert_entry() { last_entry | jq -e "$1" >/dev/null || fail "bad audit: $1: $(last_entry)"; }

new_case good
run_observer
assert_entry '.actual == "SURFACE" and .deterministic == "SURFACE" and .hypothetical == "ABSORB" and .miss == null and .confidence == 0.97 and .new_fact == 0.01 and .latency_ms >= 0 and .model == "typesafe/jev-1.13-20260917"'
jq -e '.questions | keys == ["action","external_wait","new_fact","stuck"]' "$CAPTURE" >/dev/null || fail 'not one decomposed request'
jq -e '.state.same_wait_surfaced == 0' "$CAPTURE" >/dev/null || fail 'wrong first surface count'
run_observer
assert_entry '.hypothetical == "ABSORB" and .simulated_streak == 2 and .same_wait_surfaced == 2'
run_observer
assert_entry '.hypothetical == "SURFACE" and .simulated_streak == 0 and .same_wait_surfaced == 3 and .policy_reason == "consecutive_bound"'
run_observer
assert_entry '.hypothetical == "ABSORB" and .simulated_streak == 1'
[ "$(wc -l < "$CURL_LOG")" = 4 ] || fail 'more than one request per consultation'
pass 'shadow always surfaces; default simulated absorb bound forces every third pass'

new_case configurable-bound
FM_JEV_SHADOW_MAX_ABSORBS=1 run_observer
FM_JEV_SHADOW_MAX_ABSORBS=1 run_observer
assert_entry '.hypothetical == "SURFACE" and .max_absorbs == 1'
SNAPSHOT=$(printf '%s' "$SNAPSHOT" | jq '.declared_wait = "paused: different vendor" | .events[-1] = .declared_wait')
run_observer
assert_entry '.same_wait_surfaced == 1 and .simulated_streak == 1'
pass 'configured bound and new-wait counter reset are independent of wake markers'

printf '{"streak":"broken"}\n' > "$CASE/.jev-shadow-a.json"
: > "$CURL_LOG"
run_observer
assert_entry '.miss == "invalid_counter" and .hypothetical == "SURFACE" and .simulated_streak == 0'
[ ! -s "$CURL_LOG" ] || fail 'corrupt counter consulted Jev'
run_observer
assert_entry '.miss == null and .hypothetical == "ABSORB" and .simulated_streak == 1'
pass 'a corrupt streak forces a surface before repairing simulated state'

new_case confidence
BODY=$(printf '%s' "$GOOD" | jq '.answers.action.confidence = 0.94') run_observer
assert_entry '.miss == "low_confidence" and .hypothetical == "SURFACE" and .simulated_streak == 0 and .confidence == 0.94'
BODY=$(printf '%s' "$GOOD" | jq '.answers.action.confidence = 0.95') run_observer
assert_entry '.miss == null and .hypothetical == "ABSORB"'
FM_JEV_SHADOW_CONFIDENCE=0.99 run_observer
assert_entry '.miss == "low_confidence" and .confidence_floor == 0.99'
pass 'Choice confidence below the configured floor is a recorded miss, equality is allowed'

for mutation in '.answers.external_wait.noul = 0.94' '.answers.new_fact.noul = 0.06' '.answers.stuck.noul = 0.06' \
  '.answers.action.choice = "captain_decision" | .answers.action.probabilities = {no_action:0.01,supervisor_action:0.01,captain_decision:0.98}' \
  '.answers.action.choice = "supervisor_action" | .answers.action.probabilities = {no_action:0.01,supervisor_action:0.98,captain_decision:0.01}'; do
  new_case composition
  BODY=$(printf '%s' "$GOOD" | jq "$mutation") run_observer
  assert_entry '.hypothetical == "SURFACE" and .miss == null'
done
pass 'each Noul and each action outcome participates in deterministic policy'

new_case miss
FM_JEV_ENV_FILE="$TMP_ROOT/absent" run_observer
assert_entry '.miss == "helper_error" and .hypothetical == "SURFACE" and .model == null'
[ ! -s "$CURL_LOG" ] || fail 'missing key reached transport'
TRANSPORT=1 run_observer
assert_entry '.miss == "helper_error"'
for code in 401 429 503; do
  : > "$CURL_LOG"
  CODE=$code run_observer
  assert_entry '.miss == "helper_error"'
  [ "$(wc -l < "$CURL_LOG")" = 1 ] || fail 'observer retried a failed request'
done
for mutation in 'del(.answers.stuck)' '.answers.new_fact = null' '.answers.external_wait.noul = "0.99"' \
  '.answers.stuck.noul = -1' '.answers.action.confidence = 2' \
  'del(.answers.action.probabilities.captain_decision)' \
  '.answers.action.probabilities.no_action = 0.1' \
  '.answers.action.choice = "ignore"' '.answers.action.type = "noul"' 'del(.model)' \
  '.answers.action.choice = "supervisor_action"'; do
  BODY=$(printf '%s' "$GOOD" | jq "$mutation") run_observer
  assert_entry '.miss != null and .hypothetical == "SURFACE" and .simulated_streak == 0 and .choice == null'
done
BODY='not JSON never-log-this-secret' run_observer
assert_entry '.miss != null and .hypothetical == "SURFACE"'
assert_not_contains "$(cat "$CASE/.jev-shadow.jsonl")" never-log-this-secret 'secret in audit'
pass 'absent key, transport, HTTP, malformed and missing answers all record misses without network'

new_case timeout
start=$(date +%s)
FM_JEV_SHADOW_TIMEOUT=1 DELAY=15 run_observer
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 6 ] || fail "outer timeout stalled: ${elapsed}s"
assert_entry '.miss == "timeout" and .hypothetical == "SURFACE"'
pass 'outer watcher-owned timeout bounds a slow helper, including its process tree'
new_case timeout-fallback
FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_JEV_SHADOW_TIMEOUT=1 DELAY=15 run_observer
assert_entry '.miss == "timeout" and .hypothetical == "SURFACE"'
pass 'dependency-free timeout fallback also records a miss and surfaces'

for config in timeout-zero timeout-text bound-zero floor-text; do
  new_case "$config"
  case "$config" in
    timeout-zero) FM_JEV_SHADOW_TIMEOUT=0 run_observer ;;
    timeout-text) FM_JEV_SHADOW_TIMEOUT=unbounded run_observer ;;
    bound-zero) FM_JEV_SHADOW_MAX_ABSORBS=0 run_observer ;;
    floor-text) FM_JEV_SHADOW_CONFIDENCE=never-log-this-secret run_observer ;;
  esac
  assert_entry '.miss == "invalid_config" and .hypothetical == "SURFACE"'
  [ ! -s "$CURL_LOG" ] || fail 'invalid config reached transport'
  assert_not_contains "$(cat "$CASE/.jev-shadow.jsonl")" never-log-this-secret 'config leaked into audit'
done
pass 'an invalid/unbounded configuration skips the call and records a miss'

BASE_SNAPSHOT=$SNAPSHOT
for mutation in '.metadata_ok = false' 'del(.metadata_ok)' '.open_event = true' '.override = true' \
  '.origin = "check"' '.origin = "signal"' '.origin = "wedge"' \
  '.origin = "queued-wakes"' '.origin = "watcher-liveness"' '.origin = "worktree-tangle"' \
  '.deterministic = "ABSORB"' '.events = []' '.check_state = "red: failed pipeline"' \
  '.pr_state = "merged"' '.pr_state = "declined"' '.declared_wait = ""' \
  '.events[-1] = "blocked: vendor reset" | .declared_wait = .events[-1]' \
  '.paused_verb = "blocked" | .events[-1] = "blocked: vendor reset" | .declared_wait = .events[-1]' \
  '.events[-1] = "needs-decision: approve" | .declared_wait = .events[-1]' \
  '.events[-1] = "done: all finished" | .declared_wait = .events[-1]' \
  '.events[-1] = "failed: pipeline" | .declared_wait = .events[-1]' \
  '.events[-1] = "working: still busy" | .declared_wait = .events[-1]' \
  '.events[-1] = "paused [key=open]: wait" | .declared_wait = .events[-1]'; do
  new_case excluded
  SNAPSHOT=$(printf '%s' "$BASE_SNAPSHOT" | jq "$mutation") run_observer
  [ ! -s "$CURL_LOG" ] || fail "excluded state consulted Jev: $mutation"
  [ ! -s "$CASE/.jev-shadow.jsonl" ] || fail 'excluded state logged as a consultation'
done
SNAPSHOT=$BASE_SNAPSHOT
pass 'all always-surface classes and missing context bypass inference entirely'

new_case custom-verb
SNAPSHOT=$(printf '%s' "$BASE_SNAPSHOT" | jq '.paused_verb="waiting" | .events=["waiting: vendor reset"] | .declared_wait=.events[-1]') run_observer
assert_entry '.miss == null'
new_case truncate
SNAPSHOT=$(printf '%s' "$BASE_SNAPSHOT" | jq '.events=["paused: " + ("x" * 10000)] | .declared_wait=.events[-1]') run_observer
jq -e '.state.events[0] | length == 512' "$CAPTURE" >/dev/null || fail 'status not truncated'
assert_not_contains "$(cat "$CASE/.jev-shadow.jsonl")" 'paused:' 'status text reached audit'
pass 'configured pause vocabulary works; request text is bounded and absent from audit'

new_case storage
printf 'untouched\n' > "$TMP_ROOT/foreign"
ln -s "$TMP_ROOT/foreign" "$CASE/.jev-shadow.jsonl"
run_observer
[ "$(cat "$TMP_ROOT/foreign")" = untouched ] || fail 'followed audit symlink'
[ ! -s "$CURL_LOG" ] || fail 'unsafe audit storage consulted Jev'
rm "$CASE/.jev-shadow.jsonl"
# Fill with complete records beyond the cap, then require complete JSON lines.
jq -nc 'range(0;18000) | {padding:("x" * 70)}' > "$CASE/.jev-shadow.jsonl"
run_observer
[ "$(wc -c < "$CASE/.jev-shadow.jsonl")" -le 1048576 ] || fail 'audit cap exceeded'
jq -e . "$CASE/.jev-shadow.jsonl" >/dev/null || fail 'audit rotation broke JSON lines'
if [ "$(uname)" = Darwin ]; then mode=$(stat -f %Lp "$CASE/.jev-shadow.jsonl"); else mode=$(stat -c %a "$CASE/.jev-shadow.jsonl"); fi
[ "$mode" = 600 ] || fail 'audit file is not private'
pass 'audit rejects symlinks, caps size at complete records and remains private'

# Exercise the production watcher surface function, not just the observer.
# The real wake() exits and real fm_wake_append writes the queue; no test stub
# can accidentally hide an observed change to its verdict or marker behavior.
watch_case() {
  new_case "$1"
  printf 'window=sess:fm-a\nharness=pi\nkind=ship\n' > "$CASE/a.meta"
  printf 'paused: vendor reset\npaused: vendor reset\n' > "$CASE/a.status"
  touch -t 202001010000 "$CASE/a.status"
}
watch_recheck() {
  PATH="$FAKEBIN:$BASE_PATH" FM_FAKE_CURL_BODY="$BODY" \
    FM_STATE_OVERRIDE="$CASE" FM_HOME="$CASE" FM_PAUSE_RESURFACE_SECS=1 \
    bash -c '. "$1/bin/fm-watch.sh"; handle_paused_stale sess:fm-a a unchanged-hash' _ "$ROOT" > "$CASE/out"
  grep -Eq '^stale: sess:fm-a .*confirm the wait still holds' "$CASE/out" || fail 'wake reason changed'
  assert_grep $'\tstale\tsess:fm-a\tstale:' "$CASE/.wake-queue" 'surface queue missing'
  [ "$(cat "$CASE/.stale-sess_fm-a")" = unchanged-hash ] || fail 'deterministic stale marker changed'
  [ -s "$CASE/.paused-resurfaced-sess_fm-a" ] || fail 'cadence marker not recorded'
}
watch_case watcher-good
watch_recheck
assert_entry '.hypothetical == "ABSORB" and .actual == "SURFACE"'
watch_case watcher-miss
FM_JEV_ENV_FILE="$TMP_ROOT/missing" watch_recheck
assert_entry '.miss == "helper_error" and .actual == "SURFACE"'
watch_case watcher-bound
FM_JEV_SHADOW_MAX_ABSORBS=1 watch_recheck
rm "$CASE/.paused-resurfaced-sess_fm-a"
FM_JEV_SHADOW_MAX_ABSORBS=1 watch_recheck
assert_entry '.hypothetical == "SURFACE" and .actual == "SURFACE"'
pass 'real watcher queue, reason, cadence and stale markers are unchanged for shadow absorb, miss and forced surface'

for excluded in open old-open malformed-meta duplicate-meta missing-status fifo-status override check afk terminal captain-held; do
  watch_case "watcher-$excluded"
  case "$excluded" in
    open) printf 'needs-decision [key=security]: approve\npaused: vendor reset\n' > "$CASE/a.status" ;;
    old-open) printf 'blocked [key=old]: help\nworking: one\nworking: two\npaused: vendor reset\n' > "$CASE/a.status" ;;
    malformed-meta) printf 'window=sess:fm-a\nnot metadata\n' > "$CASE/a.meta" ;;
    duplicate-meta) printf 'window=other\n' >> "$CASE/a.meta" ;;
    missing-status) rm "$CASE/a.status" ;;
    fifo-status) rm "$CASE/a.status"; mkfifo "$CASE/a.status" ;;
    override) printf 'state: failed | paused: vendor reset' > "$CASE/.paused-runstep-surfaced-sess_fm-a" ;;
    check) printf 'registration|merged' > "$CASE/.check-surfaced-a" ;;
    afk) touch "$CASE/.afk" ;;
    terminal) printf 'done: shipped\n' > "$CASE/a.status" ;;
    captain-held) printf 'captain-held: wait on captain\n' > "$CASE/a.status" ;;
  esac
  # Direct observation avoids redefining the existing deterministic classifier:
  # it is deliberately unchanged, including its legacy captain-held cadence.
  PATH="$FAKEBIN:$BASE_PATH" FM_FAKE_CURL_BODY="$BODY" FM_STATE_OVERRIDE="$CASE" FM_HOME="$CASE" bash -c \
    '. "$1/bin/fm-watch.sh"; observe_paused_stale a sess_fm-a 3600' _ "$ROOT"
  [ ! -s "$CURL_LOG" ] || fail "watcher consulted Jev for $excluded"
done
pass 'watcher snapshot excludes full-history open events, malformed metadata, absent status, transitions, checks and away-mode'

# Metadata-only compatibility matrix: no adapter commands or endpoint lifecycle
# are needed to observe the shared pause-cadence surface.
for harness in claude codex opencode pi pi-signed grok kimi; do
  for backend in tmux herdr zellij orca cmux; do
    watch_case "matrix-$harness-$backend"
    printf 'window=sess:fm-a\nharness=%s\nbackend=%s\nkind=ship\n' "$harness" "$backend" > "$CASE/a.meta"
    watch_recheck
    assert_entry '.actual == "SURFACE" and .hypothetical == "ABSORB"'
  done
done
pass 'shared observation path preserves surfaces across all harness/backend metadata combinations'

help=$($OBSERVER --help)
assert_contains "$help" 'separate code change and explicit captain' 'missing approval boundary in help'
pass 'help makes future suppression a separately approved change'
