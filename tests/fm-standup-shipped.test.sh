#!/usr/bin/env bash
# Behavior tests for the time-windowed shipped-evidence reader behind /standup.
#
# The load-bearing guarantee is that a merge is never reported as a ship: every
# merge row stays `unknown` until a deploy LOG RECORDS the head it served, that
# head is read, AND git ancestry proves containment. Nothing is inferred from a
# step name, a step position, or run order. These cases drive that boundary from
# every side - a proven containment, a merge that landed after the recorded head,
# a run refused because one deploy step failed while another succeeded, a log that
# records nothing, a log that could not be read, a log cut short at its byte
# bound, steps that could not be read, a green run with no deploy step at all (a
# known fact, not a gap), a superseded train whose work a later train provably
# carried, and a truncated or budget-exhausted read that must not harden into a
# firm negative - plus the window arithmetic, the durable backlog/archive
# close-date sources, the local-only default, and the honest empty/unavailable
# states.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHIPPED="$ROOT/bin/fm-standup-shipped.sh"
TMP_ROOT=$(fm_test_tmproot fm-standup)
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"
mkdir -p "$FM_ROOT_OVERRIDE"
export FM_ROOT_OVERRIDE

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

NOW=2026-08-28T12:00:00Z
fm_git_identity

# A fakebin whose gh/bkt/curl RECORD every call to $NET_LOG, so a case can prove
# the default path reaches no network at all. bkt answers with Bitbucket-shaped
# payloads: $FAKE_BKT_RUNS for the pipeline listing, $FAKE_BKT_STEPS_<run> (or
# $FAKE_BKT_STEPS) for that run's step breakdown, and $FAKE_BKT_LOG_<run> (or
# $FAKE_BKT_LOG) for a deploy step's log, with $FAKE_BKT_LOG_STEP_<uuid> winning
# over both so one run's steps can answer differently. $FAKE_BKT_VIEW_FAIL and
# $FAKE_BKT_LOG_FAIL are comma-separated run ids whose read fails outright, which
# is how "the steps could not be read" is driven.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$NET_LOG"
printf '%s\n' "${FAKE_GH_PRS:-[]}"
SH
  cat > "$fb/bkt" <<'SH'
#!/usr/bin/env bash
echo "bkt $*" >> "$NET_LOG"
[ "${FAKE_BKT_FAIL:-0}" = 1 ] && exit 1
if [ "${1:-}" = pr ]; then
  printf '%s\n' "${FAKE_BKT_PRS:-{\"values\":[]\}}"
  exit 0
fi
run=${3:-}
case "${2:-}" in
  view)
    case ",${FAKE_BKT_VIEW_FAIL:-}," in *,"$run",*) exit 1 ;; esac
    v="FAKE_BKT_STEPS_$run"
    printf '%s\n' "${!v:-${FAKE_BKT_STEPS:-{\"steps\":[]\}}}"
    ;;
  logs)
    case ",${FAKE_BKT_LOG_FAIL:-}," in *,"$run",*) exit 1 ;; esac
    step=""
    while [ $# -gt 0 ]; do
      [ "$1" = --step ] && { step=${2:-}; break; }
      shift
    done
    step=$(printf '%s' "$step" | tr -cd 'A-Za-z0-9')
    v="FAKE_BKT_LOG_STEP_$step"
    if [ -n "${!v:-}" ]; then printf '%s\n' "${!v}"; exit 0; fi
    v="FAKE_BKT_LOG_$run"
    printf '%s\n' "${!v:-${FAKE_BKT_LOG:-}}"
    ;;
  *) printf '%s\n' "${FAKE_BKT_RUNS:-{\"values\":[]\}}" ;;
esac
SH
  cat > "$fb/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "$NET_LOG"
exit 1
SH
  chmod +x "$fb/gh" "$fb/bkt" "$fb/curl"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

# commit_at <repo> <iso8601> <file> <message> [--merge <branch>]
# Builds real merge commits at controlled dates, because the window arithmetic and
# the ancestry check both read real git, never a parsed stand-in.
commit_at() {  # <repo> <iso> <name>
  local repo=$1 when=$2 name=$3
  printf '%s\n' "$name" > "$repo/$name.txt"
  git -C "$repo" add -A
  GIT_AUTHOR_DATE=$when GIT_COMMITTER_DATE=$when \
    git -C "$repo" commit -qm "chore: $name"
}

merge_at() {  # <repo> <iso> <branch> <subject>
  local repo=$1 when=$2 branch=$3 subject=$4
  GIT_AUTHOR_DATE=$when GIT_COMMITTER_DATE=$when \
    git -C "$repo" merge -q --no-ff -m "$subject" "$branch"
}

# A registered project clone with a default branch, three merges spread across and
# outside a 72h window, and an origin/HEAD symref so the reader resolves the same
# default branch a real clone exposes.
make_project() {  # <home> <name> <remote-url>
  local home=$1 name=$2 remote=$3
  local repo="$home/projects/$name"
  fm_git_init_commit "$repo"
  git -C "$repo" branch -M main
  git -C "$repo" remote add origin "$remote"
  local b when subject
  while IFS='|' read -r b when subject; do
    [ -n "$b" ] || continue
    git -C "$repo" checkout -q -b "$b" main
    commit_at "$repo" "$when" "$b"
    git -C "$repo" checkout -q main
    merge_at "$repo" "$when" "$b" "Merged in $subject"
  done <<'BRANCHES'
old|2026-08-20T09:00:00Z|feat/old (pull request #10)
shipped|2026-08-26T09:00:00Z|feat/shipped (pull request #11)
fresh|2026-08-28T09:00:00Z|feat/fresh (pull request #12)
BRANCHES
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/heads/main
  git -C "$repo" update-ref refs/remotes/origin/main main
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  # A fetch marker inside the window, so freshness is not the case under test.
  touch "$repo/.git/FETCH_HEAD"
  printf '%s\n' "$repo"
}

run() {  # <home> <fakebin> <args...>
  local home=$1 fakebin=$2; shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STANDUP_NOW="$NOW" \
    NET_LOG="$home/net.log" "$SHIPPED" "$@"
}

# --- usage and window parsing ------------------------------------------------

HOME_A=$(make_home home-a)
FB_A=$(make_fakebin "$HOME_A")
printf -- '- alpha [no-mistakes +yolo] - Fixture project (cloned 2026-08-01)\n' > "$HOME_A/data/projects.md"
REPO_A=$(make_project "$HOME_A" alpha "git@bitbucket.org:acme/alpha.git")

out=$(run "$HOME_A" "$FB_A" --help)
assert_contains "$out" "usage: fm-standup-shipped.sh" "--help prints usage"
assert_contains "$out" "merges.deployed is yes only when" "--help owns the deployed-verdict contract"

rc=0
run "$HOME_A" "$FB_A" --window 3x >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" "an unparseable window is refused instead of silently defaulted"

rc=0
run "$HOME_A" "$FB_A" --project nosuch >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" "an unregistered project scope is refused"

pass "usage, window parsing, and project scoping refuse bad input"

# --- window arithmetic and the local-only default ---------------------------

json=$(run "$HOME_A" "$FB_A" --window 72h --json)
ids=$(printf '%s' "$json" | jq -r '.merges[].title')
assert_contains "$ids" "pull request #11" "a merge inside the window is reported"
assert_contains "$ids" "pull request #12" "a merge inside the window is reported"
assert_not_contains "$ids" "pull request #10" "a merge older than the window is excluded"

deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | join(",")')
[ "$deployed" = unknown ] || fail "merges must default to unknown, got: $deployed"

pr=$(printf '%s' "$json" | jq -r '.merges[] | select(.title | test("#12")) | .pr')
[ "$pr" = "https://bitbucket.org/acme/alpha/pull-requests/12" ] \
  || fail "the merge subject's PR number must render a full Bitbucket URL, got: $pr"

[ ! -s "$HOME_A/net.log" ] || fail "the default path must make no network call: $(cat "$HOME_A/net.log")"

win=$(printf '%s' "$json" | jq -r '"\(.window.spec) \(.window.hours) \(.window.since_date)"')
[ "$win" = "72h 72 2026-08-25" ] || fail "unexpected window projection: $win"

wk=$(run "$HOME_A" "$FB_A" --window 1w --json | jq -r '.window.hours')
[ "$wk" = 168 ] || fail "1w must resolve to 168 hours, got: $wk"

pass "the window bounds merges, the default path is local-only, and merged is never deployed"

# --- TOON/JSON parity --------------------------------------------------------

toon=$(run "$HOME_A" "$FB_A" --window 72h)
assert_contains "$toon" "schema: fm-standup-shipped.v1" "TOON carries the schema"
assert_contains "$toon" "merges[2]{project,when,commit,pr,deployed,title}:" "TOON renders the tabular merge array"
assert_contains "$toon" "window: spec=72h hours=72" "TOON renders the window object inline"
n_toon=$(printf '%s\n' "$toon" | sed -n 's/^merges\[\([0-9]*\)\].*/\1/p')
n_json=$(printf '%s' "$json" | jq '.merges | length')
[ "$n_toon" = "$n_json" ] || fail "TOON and JSON disagree on merge count: $n_toon vs $n_json"

pass "TOON and JSON are parity representations of one model"

# --- containment: the merged-vs-deployed boundary ---------------------------
#
# A pipeline LISTING only nominates candidates and the STEPS only narrow them.
# The one thing that grants a deployed head is the deploy log recording the
# production head. Here that head is the SECOND merge, so the merge that landed
# after it is provably not contained, and a newer STOPPED run must not carry
# credit - the "superseded train" case in the header.

head_shipped=$(git -C "$REPO_A" rev-parse main~1)
head_fresh=$(git -C "$REPO_A" rev-parse main)

# A Bitbucket step breakdown: uuid, name, and a nested state/result.
steps_json() {  # <state> <result> [name]
  jq -nc --arg st "$1" --arg res "$2" --arg name "${3:-Deploy to production}" \
    '{steps:[{uuid:"{step-build}", name:"Build and test",
              state:{name:"COMPLETED", result:{name:"SUCCESSFUL"}}},
             {uuid:"{step-deploy}", name:$name,
              state:{name:$st, result:{name:$res}}}]}'
}
recorded_log() {  # <sha>
  printf 'pushing bundle\nproduction is now recorded at %s\ndone\n' "$1"
}

runs=$(jq -nc --arg ok "$head_shipped" --arg bad "$head_fresh" '
  {values:[
    {build_number:1042, state:{result:{name:"FAILED"}},
     target:{ref_name:"main", commit:{hash:$bad}}, created_on:"2026-08-28T10:00:00Z"},
    {build_number:1041, state:{result:{name:"SUCCESSFUL"}},
     target:{ref_name:"main", commit:{hash:$ok}}, created_on:"2026-08-26T10:00:00Z"}]}')

json=$(FAKE_BKT_RUNS="$runs" FAKE_BKT_STEPS="$(steps_json COMPLETED SUCCESSFUL)" \
  FAKE_BKT_LOG="$(recorded_log "$head_shipped")" \
  run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
v11=$(printf '%s' "$json" | jq -r '.merges[] | select(.title | test("#11")) | .deployed')
v12=$(printf '%s' "$json" | jq -r '.merges[] | select(.title | test("#12")) | .deployed')
[ "$v11" = yes ] || fail "a merge contained in the recorded production head must be yes, got: $v11"
[ "$v12" = no ] || fail "a merge that landed after the recorded head must be no, got: $v12"

assert_grep "bkt pipeline list" "$HOME_A/net.log" "--include-deploy is a network path"
assert_grep "bkt pipeline view 1041" "$HOME_A/net.log" "the deploy evidence is read from the run's steps"
grep -q "bkt pipeline view 1042" "$HOME_A/net.log" \
  && fail "a run that did not succeed must never be probed for steps"

# The failed run is still disclosed as evidence, but never grants a deployed verdict.
res=$(printf '%s' "$json" | jq -r '[.deploys[] | "\(.run)=\(.result)"] | sort | join(" ")')
assert_contains "$res" "1042=FAILED" "a stopped run stays visible as evidence"
assert_contains "$res" "1041=SUCCESSFUL" "the successful run is the one that grants containment"
row=$(printf '%s' "$json" | jq -r '.deploys[] | select(.run == "1041") | "\(.deploy_step) \(.head) \(.head_from)"')
assert_contains "$row" "COMPLETED/SUCCESSFUL" "the deploy step's own state is reported"
assert_contains "$row" "$head_shipped" "the recorded head is the one reported"
assert_contains "$row" "recorded in the deploy log" "the row says where its head came from"

pass "the recorded production head plus ancestry proves a ship, and a stopped train grants nothing"

# --- only the recorded production line grants a verdict ---------------------
#
# A step NAME is not evidence of what a step touched, and a step POSITION is not
# evidence of which environment it reached. Without the recorded line there is no
# head, whatever the run targeted.

json=$(FAKE_BKT_RUNS="$runs" FAKE_BKT_STEPS="$(steps_json COMPLETED SUCCESSFUL)" \
  FAKE_BKT_LOG="starting deploy
finished, no head recorded here" \
  run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | join(",")')
[ "$deployed" = unknown ] \
  || fail "a successful deploy step that recorded no head must grant nothing, got: $deployed"
assert_contains "$(printf '%s' "$json" | jq -r '.deploys[].counted')" "records no production head" \
  "a silent deploy log says exactly that"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "could not be read" \
  "a deploy that proved nothing is disclosed as unproved, not as a failure"

# An unreadable log is a different fact from a silent one, and both withhold.
json=$(FAKE_BKT_RUNS="$runs" FAKE_BKT_STEPS="$(steps_json COMPLETED SUCCESSFUL)" \
  FAKE_BKT_LOG_FAIL=1041 run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | join(",")')
[ "$deployed" = unknown ] || fail "an unreadable deploy log must grant nothing, got: $deployed"
assert_contains "$(printf '%s' "$json" | jq -r '.deploys[].counted')" "could not be read" \
  "an unreadable deploy log carries its own reason"

pass "a step name and a step position grant nothing; only the recorded head does"

# --- a run with a failed deploy step is refused whole -----------------------
#
# Steps [build ✓, deploy staging COMPLETED/SUCCESSFUL, deploy production
# COMPLETED/FAILED]. The staging step succeeded and its log even records a head,
# but the production deploy in the same run failed, so the run ships nothing.

mixed=$(jq -nc '{steps:[
  {uuid:"{step-build}", name:"Build and test",
   state:{name:"COMPLETED", result:{name:"SUCCESSFUL"}}},
  {uuid:"{step-staging}", name:"Deploy to staging",
   state:{name:"COMPLETED", result:{name:"SUCCESSFUL"}}},
  {uuid:"{step-prod}", name:"Deploy to production",
   state:{name:"COMPLETED", result:{name:"FAILED"}}}]}')
json=$(FAKE_BKT_RUNS="$runs" FAKE_BKT_STEPS="$mixed" \
  FAKE_BKT_LOG_STEP_stepstaging="$(recorded_log "$head_shipped")" \
  run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | join(",")')
[ "$deployed" = unknown ] \
  || fail "a successful staging deploy beside a failed production one is not a ship, got: $deployed"
assert_contains "$(printf '%s' "$json" | jq -r '.deploys[].counted')" "did not complete successfully" \
  "the refused run says why it was refused"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "runs refused because a deploy step" \
  "a refused run is disclosed as its own fact"
grep -q "step-staging" "$HOME_A/net.log" \
  && fail "a refused run must not have its steps' logs read at all"

while IFS='|' read -r st res; do
  [ -n "$st" ] || continue
  json=$(FAKE_BKT_RUNS="$runs" FAKE_BKT_STEPS="$(steps_json "$st" "$res")" \
    FAKE_BKT_LOG="$(recorded_log "$head_shipped")" \
    run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
  deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | join(",")')
  [ "$deployed" = unknown ] \
    || fail "a deploy step at $st/$res must leave every merge unknown, got: $deployed"
done <<'STEPSTATES'
IN_PROGRESS|-
COMPLETED|FAILED
COMPLETED|STOPPED
STEPSTATES

pass "a run is refused whole when any deploy step in it did not complete successfully"

# --- steps that could not be read differ from a run with no deploy step -----
#
# Both grant nothing, but only one is a GAP. A build-only run alongside a real
# deploy run must not make "merged, not yet deployed" unreachable.

json=$(FAKE_BKT_RUNS="$runs" FAKE_BKT_VIEW_FAIL=1041 \
  run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | join(",")')
[ "$deployed" = unknown ] || fail "unreadable steps must leave merges unknown, got: $deployed"
assert_contains "$(printf '%s' "$json" | jq -r '.deploys[].counted')" "steps could not be read" \
  "a run whose steps could not be read says so"

nodeploy=$(jq -nc '{steps:[{uuid:"{s1}", name:"Build and test",
                            state:{name:"COMPLETED", result:{name:"SUCCESSFUL"}}}]}')
json=$(FAKE_BKT_RUNS="$runs" FAKE_BKT_STEPS="$nodeploy" \
  run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | join(",")')
[ "$deployed" = unknown ] \
  || fail "a green run that deployed nothing must never grant deployed, got: $deployed"
assert_contains "$(printf '%s' "$json" | jq -r '.deploys[].counted')" "no deploy step in this run" \
  "a run with no deploy step says so"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "no run recorded a production head" \
  "a repository with no deploy evidence is disclosed, not read as a deploy train"

# A build-only run beside a real deploy run: the build run is a known fact, not a
# gap, so the merge the deploy genuinely did not carry still reads as `no`.
runs_mixed=$(jq -nc --arg ok "$head_shipped" '
  {values:[{build_number:1402, state:{result:{name:"SUCCESSFUL"}},
            target:{ref_name:"main", commit:{hash:$ok}}, created_on:"2026-08-28T10:00:00Z"},
           {build_number:1401, state:{result:{name:"SUCCESSFUL"}},
            target:{ref_name:"main", commit:{hash:$ok}}, created_on:"2026-08-26T10:00:00Z"}]}')
json=$(FAKE_BKT_RUNS="$runs_mixed" \
  FAKE_BKT_STEPS_1402="$nodeploy" \
  FAKE_BKT_STEPS_1401="$(steps_json COMPLETED SUCCESSFUL)" \
  FAKE_BKT_LOG="$(recorded_log "$head_shipped")" \
  run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
v11=$(printf '%s' "$json" | jq -r '.merges[] | select(.title | test("#11")) | .deployed')
v12=$(printf '%s' "$json" | jq -r '.merges[] | select(.title | test("#12")) | .deployed')
[ "$v11" = yes ] || fail "the deploy run still proves its own containment, got: $v11"
[ "$v12" = no ] \
  || fail "a build-only run is a known fact, not a gap, so a firm negative stays reachable, got: $v12"
assert_not_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "deploy read was partial" \
  "a build-only run must not manufacture a partial-read disclosure"

pass "a run with no deploy step is a known fact; only an unreadable one is a gap"

# --- the deploy probe has an aggregate budget, and its log read is bounded ---

json=$(FM_STANDUP_DEPLOY_PROBES=1 FAKE_BKT_RUNS="$runs_mixed" \
  FAKE_BKT_STEPS="$(steps_json COMPLETED SUCCESSFUL)" \
  FAKE_BKT_LOG="$(recorded_log "$head_shipped")" \
  run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "deploy budget was spent" \
  "a spent deploy budget is disclosed rather than resolved"
deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | join(",")')
[ "$deployed" = unknown ] \
  || fail "work the budget stopped us testing must stay unknown, got: $deployed"

# A log longer than the byte bound is read only up to that bound; the recorded
# line beyond it is missing evidence, disclosed rather than guessed at.
long_log="$(recorded_log "$head_shipped")"
json=$(FM_STANDUP_DEPLOY_LOG_BYTES=8 FAKE_BKT_RUNS="$runs" \
  FAKE_BKT_STEPS="$(steps_json COMPLETED SUCCESSFUL)" \
  FAKE_BKT_LOG="$long_log" \
  run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | join(",")')
[ "$deployed" = unknown ] || fail "a truncated log must grant nothing, got: $deployed"
assert_contains "$(printf '%s' "$json" | jq -r '.deploys[].counted')" "truncated" \
  "a log cut short at the byte bound says so"

pass "the deploy probe is bounded in aggregate and its log read is bounded in bytes"

# --- a superseded train still counts through a LATER successful deploy -------
#
# The first deploy recorded only the older merge and was then superseded. The
# later deploy recorded the newer one. Containment is tested against EVERY
# accepted head, so recency never decides it and the older merge keeps its
# proven verdict.

runs_two=$(jq -nc --arg new "$head_fresh" '
  {values:[
    {build_number:1302, state:{result:{name:"SUCCESSFUL"}},
     target:{ref_name:"main", commit:{hash:$new}}, created_on:"2026-08-28T10:00:00Z"},
    {build_number:1301, state:{result:{name:"STOPPED"}},
     target:{ref_name:"main", commit:{hash:$new}}, created_on:"2026-08-27T10:00:00Z"},
    {build_number:1300, state:{result:{name:"SUCCESSFUL"}},
     target:{ref_name:"main", commit:{hash:$new}}, created_on:"2026-08-26T10:00:00Z"}]}')
json=$(FAKE_BKT_RUNS="$runs_two" FAKE_BKT_STEPS="$(steps_json COMPLETED SUCCESSFUL)" \
  FAKE_BKT_LOG_1302="$(recorded_log "$head_fresh")" \
  FAKE_BKT_LOG_1300="$(recorded_log "$head_shipped")" \
  run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | join(",")')
[ "$deployed" = yes ] \
  || fail "work carried by a later successful train must be yes, got: $deployed"
assert_contains "$(printf '%s' "$json" | jq -r '[.deploys[] | select(.run == "1301") | .counted] | join("")')" \
  "not a successful run" "the superseded train is disclosed, and grants nothing itself"

pass "a superseded train is superseded by proof, never by run order"

# --- an unreadable deploy train withholds the verdict rather than guessing ----

: > "$HOME_A/net.log"
json=$(FAKE_BKT_FAIL=1 run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | join(",")')
[ "$deployed" = unknown ] || fail "an unreadable deploy train must leave merges unknown, got: $deployed"
assert_contains "$(printf '%s' "$json" | jq -r '.deploys[].result')" "unavailable" \
  "an unreadable deploy train is reported, not omitted"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "no usable deployed head" \
  "the missing deploy evidence is disclosed"

# A recorded head that is not in the local copy cannot be tested at all.
json=$(FAKE_BKT_RUNS="$runs" FAKE_BKT_STEPS="$(steps_json COMPLETED SUCCESSFUL)" \
  FAKE_BKT_LOG="$(recorded_log 0000000000000000000000000000000000000000)" \
  run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | join(",")')
[ "$deployed" = unknown ] || fail "a head absent from the local copy must grant nothing, got: $deployed"
assert_contains "$(printf '%s' "$json" | jq -r '.deploys[].counted')" "head not in the local copy" \
  "the untestable head is named"

pass "every unreadable deploy path withholds the verdict instead of guessing"

# --- a missed field withholds a verdict, it never grants one -----------------
#
# A vendor payload may not say which branch a run targeted. That run is excluded
# and counted; it may never promote a merge to deployed.

runs_nobranch=$(jq -nc --arg ok "$head_fresh" '
  {values:[{build_number:2001, state:{result:{name:"SUCCESSFUL"}},
            target:{commit:{hash:$ok}}, created_on:"2026-08-28T10:00:00Z"}]}')
json=$(FAKE_BKT_RUNS="$runs_nobranch" FAKE_BKT_STEPS="$(steps_json COMPLETED SUCCESSFUL)" \
  FAKE_BKT_LOG="$(recorded_log "$head_fresh")" \
  run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | join(",")')
[ "$deployed" = unknown ] \
  || fail "a run whose branch cannot be determined must never grant deployed, got: $deployed"
assert_contains "$(printf '%s' "$json" | jq -r '.deploys[].counted')" "branch undetermined" \
  "the excluded run says why it was excluded"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "branch could not be determined" \
  "runs excluded for an undetermined branch are disclosed"

pass "a run whose branch cannot be determined never grants a verdict"

# --- a partial deploy read reports uncertainty, never a firm negative --------
#
# `no` is a claim too. This recorded head forked BEFORE the second merge, as a
# rewritten mainline leaves behind, so neither in-window merge is contained in
# it; whether that means "not deployed" or "we could not tell" depends entirely
# on whether the run list was read in full.

git -C "$REPO_A" checkout -q -b rewritten main~2
commit_at "$REPO_A" 2026-08-27T00:00:00Z rewritten-tip
head_rewritten=$(git -C "$REPO_A" rev-parse rewritten)
git -C "$REPO_A" checkout -q main

runs=$(jq -nc --arg h "$head_rewritten" '
  {values:[{build_number:3001, state:{result:{name:"SUCCESSFUL"}},
            target:{ref_name:"main", commit:{hash:$h}}, created_on:"2026-08-27T01:00:00Z"}]}')

# Read in full: the heads actually read genuinely fail to contain either merge.
json=$(FM_STANDUP_DEPLOY_RUNS=5 FAKE_BKT_RUNS="$runs" \
  FAKE_BKT_STEPS="$(steps_json COMPLETED SUCCESSFUL)" \
  FAKE_BKT_LOG="$(recorded_log "$head_rewritten")" \
  run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | sort | join(",")')
[ "$deployed" = no ] || fail "a complete deploy read may still say no, got: $deployed"

# Truncated at the bound: a merge older than the oldest run read may have been
# deployed by a run that was never fetched, so it degrades to unknown.
json=$(FM_STANDUP_DEPLOY_RUNS=1 FAKE_BKT_RUNS="$runs" \
  FAKE_BKT_STEPS="$(steps_json COMPLETED SUCCESSFUL)" \
  FAKE_BKT_LOG="$(recorded_log "$head_rewritten")" \
  run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
v11=$(printf '%s' "$json" | jq -r '.merges[] | select(.title | test("#11")) | .deployed')
v12=$(printf '%s' "$json" | jq -r '.merges[] | select(.title | test("#12")) | .deployed')
[ "$v11" = unknown ] || fail "a merge older than the oldest run read must be unknown, got: $v11"
[ "$v12" = no ] || fail "a merge newer than every run read is genuinely undeployed, got: $v12"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "deploy read was partial" \
  "a truncated deploy read is disclosed rather than presented as a firm negative"

# The step probe is bounded too, and stopping short is the same partial read.
runs_many=$(jq -nc --arg h "$head_rewritten" --arg ok "$head_shipped" '
  {values:[{build_number:3202, state:{result:{name:"SUCCESSFUL"}},
            target:{ref_name:"main", commit:{hash:$h}}, created_on:"2026-08-27T02:00:00Z"},
           {build_number:3201, state:{result:{name:"SUCCESSFUL"}},
            target:{ref_name:"main", commit:{hash:$ok}}, created_on:"2026-08-26T02:00:00Z"}]}')
json=$(FM_STANDUP_DEPLOY_STEPS=1 FAKE_BKT_RUNS="$runs_many" \
  FAKE_BKT_STEPS="$(steps_json COMPLETED SUCCESSFUL)" \
  FAKE_BKT_LOG_3202="$(recorded_log "$head_rewritten")" \
  FAKE_BKT_LOG_3201="$(recorded_log "$head_shipped")" \
  run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
assert_contains "$(printf '%s' "$json" | jq -r '.deploys[].counted')" "not probed within the step bound" \
  "a candidate run left unprobed says so"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "deploy read was partial" \
  "a step probe that stopped short is a partial read"
v11=$(printf '%s' "$json" | jq -r '.merges[] | select(.title | test("#11")) | .deployed')
[ "$v11" = unknown ] \
  || fail "the run that would have proven this merge was never probed, so unknown, got: $v11"

pass "a truncated or partial deploy read degrades to unknown instead of denying the ship"

# --- merged pull requests are an opt-in network surface ---------------------

: > "$HOME_A/net.log"
json=$(run "$HOME_A" "$FB_A" --window 72h --json)
[ "$(printf '%s' "$json" | jq 'has("forge_prs")')" = false ] \
  || fail "forge_prs must be absent until --include-forge is passed"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "merged pull requests from the forge" \
  "the unfetched forge surface is disclosed"

prs=$(jq -nc '{values:[{id:11, title:"Landed inside the window", updated_on:"2026-08-26T09:05:00Z"},
                       {id:10, title:"Landed before the window", updated_on:"2026-08-20T09:05:00Z"}]}')
json=$(FAKE_BKT_PRS="$prs" run "$HOME_A" "$FB_A" --window 72h --include-forge --json)
got=$(printf '%s' "$json" | jq -r '[.forge_prs[].pr] | sort | join(",")')
[ "$got" = "https://bitbucket.org/acme/alpha/pull-requests/11" ] \
  || fail "only pull requests merged inside the window may appear, got: $got"
assert_grep "bkt pr list" "$HOME_A/net.log" "--include-forge is a network path"

: > "$HOME_A/net.log"
json=$(FAKE_BKT_FAIL=1 run "$HOME_A" "$FB_A" --window 72h --include-forge --json)
[ "$(printf '%s' "$json" | jq '.forge_prs | length')" = 0 ] || fail "a failed forge read must add nothing"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "could not be read" \
  "a forge that could not be read is disclosed, not treated as nothing merged"

pass "merged pull requests are opt-in, window-filtered, and disclosed when unreadable"

# --- a project on a forge with no wired deploy train -------------------------

HOME_B=$(make_home home-b)
FB_B=$(make_fakebin "$HOME_B")
printf -- '- gamma [no-mistakes +yolo] - GitHub fixture (cloned 2026-08-01)\n' > "$HOME_B/data/projects.md"
make_project "$HOME_B" gamma "git@github.com:acme/gamma.git" >/dev/null

json=$(run "$HOME_B" "$FB_B" --window 72h --include-deploy --json)
assert_contains "$(printf '%s' "$json" | jq -r '.deploys[].result')" "no wired deploy train" \
  "a project without a wired deploy train says so"
deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | join(",")')
[ "$deployed" = unknown ] || fail "no wired train must still mean unknown, got: $deployed"
pr=$(printf '%s' "$json" | jq -r '.merges[] | select(.title | test("#12")) | .pr')
[ "$pr" = "https://github.com/acme/gamma/pull/12" ] || fail "unexpected GitHub PR URL: $pr"

pass "a project with no wired deploy train reports that, never a deployed claim"

# --- closed records: backlog Done plus the archive, by close date ------------

cat > "$HOME_A/data/backlog.md" <<'EOF'
## In flight
- [ ] alpha-live - Still building (repo: alpha) (kind: ship) (since 2026-08-27)

## Done
- [x] alpha-recent - Landed inside the window https://bitbucket.org/acme/alpha/pull-requests/11 (repo: alpha) (kind: ship) (done 2026-08-26)
  Production check ran after deploy train 1041; all services answered.
- [x] alpha-old - Landed before the window (repo: alpha) (kind: ship) (done 2026-08-01)
- [x] alpha-undated - Closed with no date at all (repo: alpha) (kind: ship)
- [x] alpha-prose - Verify the fix is LIVE (merged to main at 1c9e99d5 via PR #259) (repo: alpha) (kind: ship)
EOF

cat > "$HOME_A/data/done-archive.md" <<'EOF'

## Archived 2026-08-27
- [x] alpha-archived - Retention moved this out of the live queue (repo: alpha) (kind: ship)

## Archived 2026-08-27
- [x] alpha-archived-dated - Archived late but closed early (repo: alpha) (kind: ship) (done 2026-08-02)

## Archived 2026-08-02
- [x] alpha-archived-old - Archived before the window (repo: alpha) (kind: ship)
EOF

json=$(run "$HOME_A" "$FB_A" --window 72h --json)
closed=$(printf '%s' "$json" | jq -r '[.closed[].id] | sort | join(",")')
[ "$closed" = "alpha-archived,alpha-recent" ] \
  || fail "unexpected closed set (expected the dated in-window rows only): $closed"

art=$(printf '%s' "$json" | jq -r '.closed[] | select(.id == "alpha-recent") | .artifact')
[ "$art" = "https://bitbucket.org/acme/alpha/pull-requests/11" ] \
  || fail "a Bitbucket pull-request URL must survive as the closed artifact, got: $art"

assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "no close date" \
  "a Done row with no close date is disclosed rather than dropped silently"

bodies=$(run "$HOME_A" "$FB_A" --window 72h --fields bodies --json \
  | jq -r '.bodies[] | select(.id == "alpha-recent") | .body')
assert_contains "$bodies" "Production check ran" \
  "--fields bodies surfaces the words a production check was recorded in"

pass "closed work comes from the live queue and the archive, filtered on its own close date"

# --- global scope: a quiet project is reported, never omitted ----------------

printf -- '- beta [local-only] - A project with nothing in the window (cloned 2026-08-01)\n' \
  >> "$HOME_A/data/projects.md"
BETA="$HOME_A/projects/beta"
fm_git_init_commit "$BETA"
git -C "$BETA" branch -M main
git -C "$BETA" symbolic-ref refs/remotes/origin/HEAD refs/heads/main
touch "$BETA/.git/FETCH_HEAD"

json=$(run "$HOME_A" "$FB_A" --window 72h --json)
listed=$(printf '%s' "$json" | jq -r '[.projects[].id] | sort | join(",")')
[ "$listed" = "alpha,beta" ] || fail "every registered project must be listed, got: $listed"
beta_merges=$(printf '%s' "$json" | jq '[.merges[] | select(.project == "beta")] | length')
[ "$beta_merges" = 0 ] || fail "the quiet project must contribute no merges, got: $beta_merges"
mode=$(printf '%s' "$json" | jq -r '.projects[] | select(.id == "beta") | .mode')
assert_contains "$mode" "local-only" "the registered delivery posture is carried through"

# A project with no local copy at all is reported unavailable with its reason.
printf -- '- delta [no-mistakes] - Never cloned here (cloned 2026-08-01)\n' >> "$HOME_A/data/projects.md"
json=$(run "$HOME_A" "$FB_A" --window 72h --json)
row=$(printf '%s' "$json" | jq -r '.projects[] | select(.id == "delta") | "\(.available) \(.reason)"')
assert_contains "$row" "no" "a project with no local copy is unavailable"
assert_contains "$row" "no local copy" "the unavailable project states why"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "local copies unreadable" \
  "an unreadable local copy is disclosed"

pass "every registered project is accounted for, quiet or unreadable alike"

# --- a stale local copy is disclosed, never silently under-reported ----------

HOME_C=$(make_home home-c)
FB_C=$(make_fakebin "$HOME_C")
printf -- '- alpha [no-mistakes] - Fixture project (cloned 2026-08-01)\n' > "$HOME_C/data/projects.md"
STALE=$(make_project "$HOME_C" alpha "git@bitbucket.org:acme/alpha.git")
touch -d 2026-08-20T00:00:00Z "$STALE/.git/FETCH_HEAD" 2>/dev/null \
  || touch -t 202608200000 "$STALE/.git/FETCH_HEAD"

json=$(run "$HOME_C" "$FB_C" --window 72h --json)
assert_contains "$(printf '%s' "$json" | jq -r '.projects[0].reason')" "before the window opened" \
  "a local copy older than the window states so"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "older than the window" \
  "a stale local copy is disclosed with what it costs"

pass "a stale local copy is disclosed instead of silently under-reporting"

# --- second mate homes: local records merged, remote ones disclosed ---------

MATE="$TMP_ROOT/mate-home"
mkdir -p "$MATE/data"
cat > "$MATE/data/backlog.md" <<'EOF'
## Done
- [x] mate-landed - A mate managed this merge https://github.com/acme/alpha/pull/50 (repo: alpha) (kind: ship) (done 2026-08-27)
EOF
{
  printf -- '- mate - fixture domain (home: %s; scope: fixture work; projects: alpha; added 2026-08-01)\n' "$MATE"
  printf -- '- faraway - remote domain (host: elsewhere; root: /srv/fm; home: /srv/fm/home; scope: remote work; projects: alpha; added 2026-08-01)\n'
} > "$HOME_A/data/secondmates.md"

json=$(run "$HOME_A" "$FB_A" --window 72h --json)
assert_contains "$(printf '%s' "$json" | jq -r '[.closed[].id] | join(",")')" "mate-landed" \
  "a local second mate home's closed work is included"
owner=$(printf '%s' "$json" | jq -r '.closed[] | select(.id == "mate-landed") | .home')
[ "$owner" = mate ] || fail "closed work must name the home that owns it, got: $owner"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "another host" \
  "a second mate home on another host is disclosed, not silently skipped"

rm -f "$HOME_A/data/secondmates.md"
json=$(run "$HOME_A" "$FB_A" --window 72h --json)
assert_not_contains "$(printf '%s' "$json" | jq -r '[.closed[].id] | join(",")')" "mate-landed" \
  "no registry means no registered second mates"

pass "local second mate records are merged in and remote homes are disclosed"

# --- bounds are capped with counted opt-in expansion ------------------------

json=$(FM_STANDUP_MERGES=1 run "$HOME_A" "$FB_A" --window 72h --json)
[ "$(printf '%s' "$json" | jq '.merges | length')" = 1 ] || fail "the merge bound must apply"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "merges showing 1 of 2" \
  "a capped merge list discloses the true total"
[ "$(FM_STANDUP_MERGES=1 run "$HOME_A" "$FB_A" --window 72h --all-merges --json | jq '.merges | length')" = 2 ] \
  || fail "--all-merges must reveal the full set"

rc=0
FM_STANDUP_MERGES=0 run "$HOME_A" "$FB_A" --window 72h >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" "an invalid bound is refused"

pass "fleet-sized sections are capped with counted opt-in expansion"

# --- a squash-merging project reads as busy, never as quiet ------------------
#
# `--merges` alone would contribute zero rows for a project that squash-merges,
# and it would say so as an empty Shipped section rather than as "could not see
# it" - the one failure the disclosure contract exists to prevent. What counts is
# a subject that SAYS "pull request #N": a bare trailing "(#N)" is equally an
# issue reference, and a revert is not a ship at all.

HOME_E=$(make_home home-e)
FB_E=$(make_fakebin "$HOME_E")
printf -- '- epsilon [no-mistakes] - Squash-merging fixture (cloned 2026-08-01)\n' > "$HOME_E/data/projects.md"
SQUASH="$HOME_E/projects/epsilon"
fm_git_init_commit "$SQUASH"
git -C "$SQUASH" branch -M main
git -C "$SQUASH" remote add origin "git@github.com:acme/epsilon.git"
squash_commit() {  # <iso> <name> <subject>
  printf '%s\n' "$2" > "$SQUASH/$2.txt"
  git -C "$SQUASH" add -A
  GIT_AUTHOR_DATE=$1 GIT_COMMITTER_DATE=$1 git -C "$SQUASH" commit -qm "$3"
}
squash_commit 2026-08-27T09:00:00Z squashed \
  "feat: land the whole change in one commit (pull request #77)"
squash_commit 2026-08-27T10:00:00Z direct "chore: a direct push with no pull request"
squash_commit 2026-08-27T11:00:00Z issueref "chore: bump deps (#88)"
squash_commit 2026-08-27T12:00:00Z reverted \
  'Revert "feat: land the whole change (pull request #77)"'
git -C "$SQUASH" update-ref refs/remotes/origin/main main
git -C "$SQUASH" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
touch "$SQUASH/.git/FETCH_HEAD"

json=$(run "$HOME_E" "$FB_E" --window 72h --json)
titles=$(printf '%s' "$json" | jq -r '[.merges[].title] | join("|")')
assert_contains "$titles" "pull request #77" "a squash merge that says so is counted"
assert_not_contains "$titles" "direct push" "a direct push carries no pull request and is not a merge"
assert_not_contains "$titles" "bump deps" "a bare trailing number is an issue reference, not a merge"
assert_not_contains "$titles" "Revert" "a revert is never presented as a ship"
pr=$(printf '%s' "$json" | jq -r '.merges[] | select(.title | test("#77")) | .pr')
[ "$pr" = "https://github.com/acme/epsilon/pull/77" ] \
  || fail "a squash subject must still render its full pull request URL, got: $pr"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "bare pull-request-shaped number" \
  "a commit the reader could not confirm as a merge is disclosed as unseen, not dropped"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "does not say" \
  "what the mainline read still cannot see is disclosed"

pass "a squash-merging project contributes rows, and a revert or issue reference never does"

# --- a deployed verdict never claims production was inspected ---------------

assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "what production is serving right now" \
  "the reader states plainly that it did not read production itself"

pass "the deployed verdict says what it proves and what it does not"

# --- merge times are absolute, so ranking and truncation are chronological ---

when=$(printf '%s' "$json" | jq -r '.merges[0].when')
case "$when" in
  *T*Z) ;;
  *) fail "merge times must be emitted in UTC so ordering is unambiguous, got: $when" ;;
esac
[ "$(printf '%s' "$json" | jq '.merges[0] | has("ct")')" = false ] \
  || fail "the internal sort key must not leak into the output model"

json=$(run "$HOME_A" "$FB_A" --window 72h --json)
ordered=$(printf '%s' "$json" | jq -r '[.merges[].when] | . == (sort | reverse)')
[ "$ordered" = true ] || fail "merges must be ranked newest first on absolute time"

pass "merges are ranked on an unambiguous absolute time"

# --- a second mate registry that cannot be followed is disclosed -------------

ln -s "$MATE/data/backlog.md" "$HOME_A/data/secondmates.md"
json=$(run "$HOME_A" "$FB_A" --window 72h --json)
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "is a symlink and was not followed" \
  "a symlinked second mate registry is disclosed rather than silently dropped"
rm -f "$HOME_A/data/secondmates.md"

pass "a second mate registry that is not followed says so"

# --- a forge time says what it actually is ----------------------------------

prs=$(jq -nc '{values:[{id:11, title:"Merged long ago, commented on today",
                        updated_on:"2026-08-26T09:05:00Z"}]}')
json=$(FAKE_BKT_PRS="$prs" run "$HOME_A" "$FB_A" --window 72h --include-forge --json)
means=$(printf '%s' "$json" | jq -r '.forge_prs[0].when_means')
assert_contains "$means" "not a merge time" \
  "a Bitbucket pull request time is labelled as last activity, never as a merge"
[ "$(printf '%s' "$json" | jq '.forge_prs[0] | has("merged_at")')" = false ] \
  || fail "the column must not still promise a merge time"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "timed by last activity" \
  "what the forge time really is gets disclosed too"

pass "a forge time is labelled for what it is instead of over-claiming a merge"

# --- honest empty state with no registry at all -----------------------------

HOME_D=$(make_home home-d)
FB_D=$(make_fakebin "$HOME_D")
json=$(run "$HOME_D" "$FB_D" --window 72h --json)
[ "$(printf '%s' "$json" | jq '.projects | length')" = 0 ] || fail "no registry means no projects"
[ "$(printf '%s' "$json" | jq '.merges | length')" = 0 ] || fail "no registry means no merges"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "no project registry" \
  "a missing registry is stated, never rendered as an empty fleet"

pass "an empty home reports honest empty sections and says why"
