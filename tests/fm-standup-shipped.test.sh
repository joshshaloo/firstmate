#!/usr/bin/env bash
# Behavior tests for the time-windowed shipped-evidence reader behind /standup.
#
# The load-bearing guarantee is that a merge is never reported as a ship: every
# merge row stays `unknown` until a successful deploy run's head is read AND git
# ancestry proves containment. These cases drive that boundary from both sides -
# a proven containment, a merge that landed after the deployed head, a stopped
# train that must not carry credit - plus the window arithmetic, the durable
# backlog/archive close-date sources, the local-only default, and the honest
# empty/unavailable states.
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
# the default path reaches no network at all. bkt answers with a Bitbucket-shaped
# pipeline payload driven by $FAKE_BKT_RUNS.
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
case "${1:-}" in
  pr) printf '%s\n' "${FAKE_BKT_PRS:-{\"values\":[]\}}" ;;
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
# The deployed head is the SECOND merge, so the merge that landed after it is
# provably not contained. A newer STOPPED run for the newest merge must not carry
# credit, which is the "superseded train" case stated in the script header.

head_shipped=$(git -C "$REPO_A" rev-parse main~1)
head_fresh=$(git -C "$REPO_A" rev-parse main)

runs=$(jq -nc --arg ok "$head_shipped" --arg bad "$head_fresh" '
  {values:[
    {build_number:1042, state:{result:{name:"FAILED"}},
     target:{ref_name:"main", commit:{hash:$bad}}, created_on:"2026-08-28T10:00:00Z"},
    {build_number:1041, state:{result:{name:"SUCCESSFUL"}},
     target:{ref_name:"main", commit:{hash:$ok}}, created_on:"2026-08-26T10:00:00Z"}]}')

json=$(FAKE_BKT_RUNS="$runs" run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
v11=$(printf '%s' "$json" | jq -r '.merges[] | select(.title | test("#11")) | .deployed')
v12=$(printf '%s' "$json" | jq -r '.merges[] | select(.title | test("#12")) | .deployed')
[ "$v11" = yes ] || fail "a merge contained in a successful deployed head must be yes, got: $v11"
[ "$v12" = no ] || fail "a merge that landed after the successful head must be no, got: $v12"

assert_grep "bkt pipeline list" "$HOME_A/net.log" "--include-deploy is a network path"

# The failed run is still disclosed as evidence, but never grants a deployed verdict.
res=$(printf '%s' "$json" | jq -r '[.deploys[] | "\(.run)=\(.result)"] | sort | join(" ")')
assert_contains "$res" "1042=FAILED" "a stopped run stays visible as evidence"
assert_contains "$res" "1041=SUCCESSFUL" "the successful run is the one that grants containment"

pass "deployed is proven by ancestry against a successful head, and a stopped train grants nothing"

# --- an unreadable deploy train withholds the verdict rather than guessing ----

: > "$HOME_A/net.log"
json=$(FAKE_BKT_FAIL=1 run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | join(",")')
[ "$deployed" = unknown ] || fail "an unreadable deploy train must leave merges unknown, got: $deployed"
assert_contains "$(printf '%s' "$json" | jq -r '.deploys[].result')" "unavailable" \
  "an unreadable deploy train is reported, not omitted"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "no usable deployed head" \
  "the missing deploy evidence is disclosed"

# A vendor payload with no commit hash is the same class: no head, no verdict.
runs=$(jq -nc '{values:[{build_number:9, state:{result:{name:"SUCCESSFUL"}}, target:{ref_name:"main"}}]}')
json=$(FAKE_BKT_RUNS="$runs" run "$HOME_A" "$FB_A" --window 72h --include-deploy --json)
deployed=$(printf '%s' "$json" | jq -r '[.merges[].deployed] | unique | join(",")')
[ "$deployed" = unknown ] || fail "a deploy run with no head must leave merges unknown, got: $deployed"

pass "every unreadable deploy path withholds the verdict instead of guessing"

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

# --- honest empty state with no registry at all -----------------------------

HOME_D=$(make_home home-d)
FB_D=$(make_fakebin "$HOME_D")
json=$(run "$HOME_D" "$FB_D" --window 72h --json)
[ "$(printf '%s' "$json" | jq '.projects | length')" = 0 ] || fail "no registry means no projects"
[ "$(printf '%s' "$json" | jq '.merges | length')" = 0 ] || fail "no registry means no merges"
assert_contains "$(printf '%s' "$json" | jq -r '.omitted[].surface')" "no project registry" \
  "a missing registry is stated, never rendered as an empty fleet"

pass "an empty home reports honest empty sections and says why"
