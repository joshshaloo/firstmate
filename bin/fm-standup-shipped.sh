#!/usr/bin/env bash
# fm-standup-shipped.sh - time-windowed shipped evidence for the /standup skill.
#
# WHY THIS EXISTS. Bearings reads CURRENT state and its landed list is a
# count-bounded baseline, not a time window: it answers "where do I resume".
# A standup asks a different question - "what actually reached users in the last
# N hours" - and the backlog alone cannot answer it, because Done retention is
# count-bounded (.tasks.toml done_keep) and older closures move to
# data/done-archive.md. This script is the ONLY time-windowed reader; the /standup
# skill takes current fleet state (in progress, next up, blockers) from
# bin/fm-bearings-snapshot.sh and never reimplements it here.
#
# HONESTY CONTRACT. THE VERDICT DEFAULTS CLOSED, AND ABSENCE OF EVIDENCE IS
# REPORTED AS ABSENCE - never resolved into a yes or a no. That governs this whole
# reader, not one code path: nothing is inferred from a name, a position, an
# ordering, or a recency, and a field this reader could not read can only ever
# withhold a verdict, never grant one.
#
# Merged is not shipped. Every merge row carries a separate
# deployed verdict that is `unknown` unless the evidence ledger for the project's
# own default-branch deploy train found all three things: a declared production
# deploy step for that repository, that step's successful outcome in a run, and a
# deploy log recording the production head. That head was read, and the merge
# commit was PROVEN to be contained in it by git ancestry.
# Containment is checked against EVERY such head gathered, never assumed from
# ordering, so a superseded or stopped train never carries credit for work only a
# later successful train shipped. Every path that cannot answer degrades to
# `unknown` plus an omitted[] disclosure - an unreadable source, an unfetched
# clone, a listing that nominated no run to examine, a run whose branch cannot
# be determined, no declared production deploy step for the repository,
# unreadable or unparsed steps, a deploy step that did not finish, a log that
# records no production head - so this reader can only ever under-claim, never
# report an unproved ship. `no` is a firm negative and is therefore also
# proof-bearing: it requires a declared production deploy step AND at least one
# candidate run examined against it, and a truncated run list, a step probe that
# did not reach every candidate, a spent deploy budget, or a head that is not in
# the local copy, downgrades to `unknown` rather than calling work undeployed. A run
# whose steps PARSED and did not contain the DECLARED production deploy step is a
# known fact rather than a gap, so it can support an honest `no`; a repository
# with no declaration stays unknown because the step was not recognized here.
#
# WHAT `deployed: yes` DOES NOT MEAN. It proves the deploy ran to a successful
# finish and that the commit is contained in what that deploy carried. It is NOT
# an independent read of what production is serving right now: the authoritative
# record of the currently served head lives in an artifact this host holds no
# credentials for. Production VERIFICATION is likewise not
# emitted at all: no durable structured field records it, so the skill reads the
# closed record's own words (--fields bodies) rather than being handed a guess.
#
# SOURCES, in the order they are trusted:
#   1. Each registered project's default-branch git history in the window. The
#      first-parent mainline is read whole and a commit counts when it is a real
#      merge OR its subject says "pull request #N" outright, the explicit form
#      both supported forges write, so a squash-merging project reads as busy
#      rather than as quiet. A bare trailing "(#N)" is equally an issue reference
#      and is counted as unseen, not as a ship; a revert is never a ship. The
#      read is bounded by FM_STANDUP_MERGE_SCAN and says when it hit that bound.
#      Merge commits are durable project truth and need no network. The clone is
#      read as it stands - this NEVER fetches, because firstmate does not write to
#      a project - so each project row carries its last-fetch time and a stale
#      clone is disclosed instead of silently under-reporting.
#   2. data/backlog.md Done plus data/done-archive.md, for this home and every
#      registered LOCAL secondmate home, filtered on the row's own close date.
#      bin/fm-backlog-parse-lib.sh owns that row syntax and its closed_on date.
#   3. --include-deploy (network): the project's deploy train. Bitbucket Cloud
#      repositories are read through `bkt`; a project on any other forge reports
#      no wired deploy source, which is `unknown`, never `deployed`. A pipeline
#      LISTING is not itself a deploy train - it carries build, test, and custom
#      runs alike - so `bkt pipeline list` only nominates candidates, and each
#      candidate's STEPS (`bkt pipeline view`) only narrow them. The one thing
#      that GRANTS a head is a deploy step log recording `production is now
#      recorded at <sha>`; that sha is the deployed head, and it still has to
#      prove containment. A step's position is never consulted at all. Which step
#      is the production deploy is decided in exactly one place,
#      `deploy_step_identity`, from the per-project declaration in
#      `config/standup-deploy-steps`; step names are never guessed from
#      conventions. Each deploy row records the evidence sought, found, and
#      unavailable in captain-facing nouns. A run is refused outright when its
#      declared deploy step did not complete successfully, which is how a failed
#      production deploy stays out of the shipped list. A repository whose runs
#      record no production head reports that instead of turning CI-green into a
#      shipped claim. Every deploy network call, the listing included, passes the
#      aggregate budget and is charged to it. The probe is bounded
#      per project by FM_STANDUP_DEPLOY_STEPS and across the whole invocation by
#      FM_STANDUP_DEPLOY_PROBES and FM_STANDUP_DEPLOY_BUDGET, each log read is
#      bounded by FM_STANDUP_DEPLOY_LOG_BYTES, and every one of those says when it
#      stopped short.
#   4. --include-forge (network): merged pull requests in the window, through gh
#      for GitHub remotes and bkt for Bitbucket ones. Local merge subjects already
#      carry the PR number on both forges, so this only adds titles and catches
#      merges a stale clone has not fetched. A Bitbucket pull request has no merge
#      timestamp, so its row is timed by LAST ACTIVITY and says so in its own
#      column; merges[] remains the merge-time source.
#
# Registered REMOTE secondmate homes are not read: this is a local, read-only
# gatherer and a remote home's records reach the parent through its own transport.
# They are disclosed, never silently dropped.
#
# Flags:
#   --window <spec>    <N>h | <N>d | <N>w (default 72h)
#   --project <name>   restrict to one registered project
#   --json             the same model as JSON (machine/debug; parity form)
#   --include-forge    ALSO fetch merged pull requests in the window (network)
#   --include-deploy   ALSO read each project's deploy train (network)
#   --fields <list>    opt in to dropped surfaces: bodies
#   --all-merges       include every merge in the window
#   --all-closed       include every closed record in the window
#   -h,--help          usage
#
# Output contract: `fm-standup-shipped.v1`, TOON by default. Read-only: no locks,
# no fetches, no mutation, no writes to any project or to state.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS_DIR="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REGISTRY="$DATA/projects.md"
SECONDMATES="$DATA/secondmates.md"
DEPLOY_STEP_CONFIG="$CONFIG/standup-deploy-steps"

# shellcheck source=bin/fm-backlog-parse-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backlog-parse-lib.sh"  # fm_backlog_json: the shared backlog/archive row parser
# shellcheck source=bin/fm-secondmate-registry-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"  # secondmate_registry_parse_line
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"  # fm_run_timed: the shared hard bound

FM_STANDUP_MERGES=${FM_STANDUP_MERGES:-40}
FM_STANDUP_MERGE_SCAN=${FM_STANDUP_MERGE_SCAN:-500}
FM_STANDUP_CLOSED=${FM_STANDUP_CLOSED:-40}
FM_STANDUP_DEPLOY_RUNS=${FM_STANDUP_DEPLOY_RUNS:-30}
FM_STANDUP_DEPLOY_STEPS=${FM_STANDUP_DEPLOY_STEPS:-10}
FM_STANDUP_DEPLOY_PROBES=${FM_STANDUP_DEPLOY_PROBES:-24}
FM_STANDUP_DEPLOY_BUDGET=${FM_STANDUP_DEPLOY_BUDGET:-90}
FM_STANDUP_DEPLOY_LOG_BYTES=${FM_STANDUP_DEPLOY_LOG_BYTES:-262144}
FM_STANDUP_FORGE_PRS=${FM_STANDUP_FORGE_PRS:-50}
FM_STANDUP_NET_TIMEOUT=${FM_STANDUP_NET_TIMEOUT:-20}
case "$FM_STANDUP_NET_TIMEOUT" in ''|*[!0-9]*|0) FM_STANDUP_NET_TIMEOUT=20 ;; esac
validate_bound() {  # <name> <value>
  case "$2" in ''|*[!0-9]*|0) echo "fm-standup-shipped: $1 must be a positive integer" >&2; exit 2 ;; esac
}
validate_bound FM_STANDUP_MERGES "$FM_STANDUP_MERGES"
validate_bound FM_STANDUP_MERGE_SCAN "$FM_STANDUP_MERGE_SCAN"
validate_bound FM_STANDUP_CLOSED "$FM_STANDUP_CLOSED"
validate_bound FM_STANDUP_DEPLOY_RUNS "$FM_STANDUP_DEPLOY_RUNS"
validate_bound FM_STANDUP_DEPLOY_STEPS "$FM_STANDUP_DEPLOY_STEPS"
validate_bound FM_STANDUP_DEPLOY_PROBES "$FM_STANDUP_DEPLOY_PROBES"
validate_bound FM_STANDUP_DEPLOY_BUDGET "$FM_STANDUP_DEPLOY_BUDGET"
validate_bound FM_STANDUP_DEPLOY_LOG_BYTES "$FM_STANDUP_DEPLOY_LOG_BYTES"
validate_bound FM_STANDUP_FORGE_PRS "$FM_STANDUP_FORGE_PRS"

usage() {
  cat <<'EOF'
usage: fm-standup-shipped.sh [--window <spec>] [--project <name>] [--json]
                             [--include-forge] [--include-deploy]
                             [--fields bodies] [--all-merges] [--all-closed]

Time-windowed shipped evidence across every registered project. TOON by default.
Default is LOCAL-ONLY (no network); --include-forge and --include-deploy fetch.

--window accepts <N>h, <N>d, or <N>w and defaults to 72h.
--project restricts every section to one registered project.

Fields: schema, home, generated, window{spec,hours,since,since_date},
  forge, deploy,
  projects{id,mode,path,forge,slug,branch,available,reason,fetched,deploy_step,deploy_step_status},
  merges{project,when,commit,pr,deployed,title},
  closed{id,home,project,closed_on,artifact,title},
  deploys{project,source,run,result,branch,deploy_step,deploy_step_outcome,head,head_from,when,counted,evidence_sought,evidence_found,evidence_unavailable},
  forge_prs{project,pr,when,when_means,title} (only under --include-forge),
  bodies{id,body} (only under --fields bodies),
  omitted{surface,reveal}.

merges lists every merge commit on the default branch in the window plus every
commit whose subject says "pull request #N" outright, so a squash-merging project
is not reported as quiet; a bare trailing "(#N)" is equally an issue reference and
is disclosed as unseen rather than counted, and a revert is never counted.
merges.when is UTC. The verdict derives from the deploy evidence ledger and
defaults closed. merges.deployed is yes only when the ledger found a declared
production deploy step for the repository, that step's successful outcome, and a
deploy log recording a production head that contains the merge commit by git
ancestry. It is no only when the read was complete and none of the heads found
contain the commit; a truncated run list, a step probe that stopped short, a spent
deploy budget, an undeclared production step, a listing that nominated no run to
examine, or a head missing from the local copy leaves it unknown rather than
calling the work undeployed. A parsed run that
lacks the repository's declared production deploy step is a known absence and can
support a no. A repository with no declaration is different: its deploy step was
not recognized here, so the verdict remains unknown. Disclosures keep the reasons
apart: a refused run, an unreadable log, a truncated log, a log that simply
records nothing, an unparseable step payload, and a non-unique declared step are
distinct facts and none of them is a ship.

yes proves the deploy ran to a successful finish and carried the commit. It is NOT
a read of what production is serving right now - that record lives in an artifact
this host holds no credentials for - and production verification is never emitted:
read the closed record's own words with
--fields bodies. A project with no rows in the window is still listed under
projects, so "quiet" is distinguishable from "not looked at".

Deploy trains are wired for Bitbucket Cloud remotes. `bkt pipeline list` only
nominates candidate runs and `bkt pipeline view` only narrows them; the evidence
that grants a head is the deploy step log line `production is now recorded at
<sha>`. A step position is never consulted. Which step is the production deploy is
decided in one place from local `config/standup-deploy-steps`, whose format is
one line per project as `<project><TAB><exact step name>`. A step name is never
inferred from conventions. deploys[].evidence_sought, evidence_found, and
evidence_unavailable are the per-run ledger. A run is refused whole when the
repository's declared deploy step did not complete successfully. A project on
another forge reports no wired deploy source rather than a deployed claim.
forge_prs.when_means states what its time really is:
a Bitbucket pull request carries last activity, not a merge time.
Bounds: FM_STANDUP_MERGES, FM_STANDUP_MERGE_SCAN, FM_STANDUP_CLOSED,
FM_STANDUP_DEPLOY_RUNS, FM_STANDUP_DEPLOY_STEPS, FM_STANDUP_DEPLOY_PROBES,
FM_STANDUP_DEPLOY_BUDGET, FM_STANDUP_DEPLOY_LOG_BYTES, FM_STANDUP_FORGE_PRS,
FM_STANDUP_NET_TIMEOUT.
EOF
}

FORMAT=toon
WINDOW_SPEC=72h
ONLY_PROJECT=""
INCLUDE_FORGE=0
INCLUDE_DEPLOY=0
ALL_MERGES=0
ALL_CLOSED=0
FIELDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --window) shift; WINDOW_SPEC=${1:-} ;;
    --window=*) WINDOW_SPEC=${1#--window=} ;;
    --project) shift; ONLY_PROJECT=${1:-} ;;
    --project=*) ONLY_PROJECT=${1#--project=} ;;
    --json) FORMAT=json ;;
    --include-forge) INCLUDE_FORGE=1 ;;
    --include-deploy) INCLUDE_DEPLOY=1 ;;
    --all-merges) ALL_MERGES=1 ;;
    --all-closed) ALL_CLOSED=1 ;;
    --fields) shift; FIELDS=${1:-} ;;
    --fields=*) FIELDS=${1#--fields=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-standup-shipped: jq not found" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "fm-standup-shipped: git not found" >&2; exit 1; }

case "$ONLY_PROJECT" in
  *[!A-Za-z0-9._-]*) echo "fm-standup-shipped: invalid --project name" >&2; exit 2 ;;
esac

# --- window -----------------------------------------------------------------
# One spec form, one owner: <N><unit>. An unparseable spec is refused rather than
# silently defaulted, because a wrong window silently changes what "shipped" means.
window_hours() {  # <spec>
  local spec=$1 n unit
  n=${spec%[hdwHDW]}
  unit=${spec#"$n"}
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -gt 0 ] || return 1
  case "$unit" in
    h|H) printf '%s\n' "$n" ;;
    d|D) printf '%s\n' "$((n * 24))" ;;
    w|W) printf '%s\n' "$((n * 168))" ;;
    *) return 1 ;;
  esac
}
WINDOW_HOURS=$(window_hours "$WINDOW_SPEC") || {
  echo "fm-standup-shipped: invalid --window '$WINDOW_SPEC' (use <N>h, <N>d, or <N>w)" >&2
  exit 2
}
[ "$WINDOW_HOURS" -le 8760 ] || {
  echo "fm-standup-shipped: --window is capped at one year" >&2
  exit 2
}

NOW=${FM_STANDUP_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
epoch_of() {  # <iso8601>
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null \
    || return 1
}
NOW_EPOCH=$(epoch_of "$NOW") || NOW_EPOCH=$(date +%s)
SINCE_EPOCH=$((NOW_EPOCH - WINDOW_HOURS * 3600))
iso_of() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}
SINCE=$(iso_of "$SINCE_EPOCH") || { echo "fm-standup-shipped: cannot compute the window start" >&2; exit 1; }
# Portable file mtime in epoch seconds. GNU `date -r` takes a FILE, BSD `date -r`
# takes epoch SECONDS, so `date -r <path>` reads as two different commands and
# silently reports every local copy as stale on macOS. Select the stat syntax
# once, exactly as bin/fm-fleet-snapshot.sh and bin/fm-busy-event.sh do; do NOT
# collapse the pair, because GNU `stat -f` is a filesystem report that exits 0.
if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
  file_mtime_epoch() { stat -f '%m' "$1" 2>/dev/null; }
else
  file_mtime_epoch() { stat -c '%Y' "$1" 2>/dev/null; }
fi
SINCE_DATE=${SINCE%%T*}
TODAY=${NOW%%T*}

# The deterministic return-catch-up owner must clear before this or any other
# ordinary captain request proceeds, exactly as Bearings consults it.
"$SCRIPT_DIR/fm-afk-return.sh" guard || exit $?

# --- registered projects ----------------------------------------------------
forge_of() {  # <remote-url>
  case "$1" in
    *github.com[:/]*) printf 'github\n' ;;
    *bitbucket.org[:/]*) printf 'bitbucket\n' ;;
    '') printf 'none\n' ;;
    *) printf 'other\n' ;;
  esac
}

# `\|` alternation is a GNU sed extension, not POSIX BRE, so one pattern per
# forge - exactly as bin/fm-bearings-snapshot.sh's repo_slug does for GitHub.
slug_of() {  # <remote-url>
  local s
  s=$(printf '%s' "$1" | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)#\1#p')
  [ -n "$s" ] || s=$(printf '%s' "$1" | sed -n 's#.*bitbucket\.org[:/]\([^/]*/[^/]*\)#\1#p')
  printf '%s' "$s" | sed 's#\.git$##; s#/$##'
}

PROJECT_IDS=""
REGISTRY_PRESENT=false
if [ -f "$REGISTRY" ]; then
  REGISTRY_PRESENT=true
  PROJECT_IDS=$(awk '$1 == "-" && $2 ~ /^[A-Za-z0-9._-]+$/ { print $2 }' "$REGISTRY")
fi
if [ -n "$ONLY_PROJECT" ]; then
  case $'\n'"$PROJECT_IDS"$'\n' in
    *$'\n'"$ONLY_PROJECT"$'\n'*) PROJECT_IDS=$ONLY_PROJECT ;;
    *) echo "fm-standup-shipped: '$ONLY_PROJECT' is not a registered project" >&2; exit 2 ;;
  esac
fi

PROJECT_ROWS='[]'
MERGE_ROWS='[]'
DEPLOY_ROWS='[]'
FORGE_ROWS='[]'
STALE_CLONES=0
UNREADABLE_CLONES=0
MERGE_SCAN_CAPPED=0
MERGE_UNSEEN=0
DEPLOY_UNAVAILABLE=0
DEPLOY_NO_DEPLOYMENT=0
DEPLOY_LOG_UNREAD=0
DEPLOY_REFUSED=0
DEPLOY_UNPARSED=0
DEPLOY_AMBIGUOUS=0
DEPLOY_PROBE_CALLS=0
DEPLOY_BUDGET_EXHAUSTED=0
DEPLOY_PROBE_START=""
DEPLOY_IDENTITY_UNCONFIGURED=0
DEPLOY_IDENTITY_DUPLICATE=0
DEPLOY_NO_CANDIDATES=0

# One owner for the per-project declaration of which pipeline step is the
# production deploy. The file is local and gitignored because project deploy
# naming is captain-private operating configuration, not repo-wide behavior.
# Format: one non-comment line per project, `<project><TAB><step name>`.
# Step names may contain spaces, but not tabs. Missing, duplicate, or blank
# declarations are evidence gaps and can never produce a deployed verdict.
deploy_step_config_record() {  # <project-id> -> status<TAB>value
  local project=$1
  if [ ! -f "$DEPLOY_STEP_CONFIG" ]; then
    printf '%s\t%s\n' missing -
    return 0
  fi
  awk -F '\t' -v p="$project" '
    /^[[:space:]]*($|#)/ { next }
    $1 == p {
      count++
      if (count == 1) value = $2
    }
    END {
      if (count == 0) print "absent\t-"
      else if (count > 1) print "duplicate\t-"
      else if (value == "") print "blank\t-"
      else print "configured\t" value
    }
  ' "$DEPLOY_STEP_CONFIG" 2>/dev/null || printf '%s\t%s\n' unreadable -
}

# One aggregate budget for the whole invocation, not just a bound per call: a
# two-minute report must not spend half an hour waiting on a forge. The clock
# starts on the FIRST probe rather than at startup, and every deploy network
# call - the pipeline listing included - passes this gate and is charged to it,
# so the budget bounds exactly the work it measures. When it is spent, probing
# stops and the shortfall travels the existing partial/unknown path with its own
# disclosure - never a guess in either direction.
deploy_budget_left() {
  [ "$DEPLOY_BUDGET_EXHAUSTED" = 0 ] || return 1
  if [ -z "$DEPLOY_PROBE_START" ]; then
    DEPLOY_PROBE_START=$(date +%s)
    return 0
  fi
  if [ "$DEPLOY_PROBE_CALLS" -ge "$FM_STANDUP_DEPLOY_PROBES" ] \
     || [ "$(( $(date +%s) - DEPLOY_PROBE_START ))" -ge "$FM_STANDUP_DEPLOY_BUDGET" ]; then
    DEPLOY_BUDGET_EXHAUSTED=1
    return 1
  fi
  return 0
}

# THE SINGLE OWNER of "which step in this run is the production deploy, and what
# does that identification rest on". Every caller - which steps are examined,
# which runs are refused, which logs are read - consumes this one answer; nothing
# else in this script may re-derive the identification from a step payload.
#
# The production deploy step is a per-project declaration from
# config/standup-deploy-steps. A parsed run with no step matching that declaration
# is a known absence for that run. A missing declaration is different: the run's
# deploy step was not recognized here, so the verdict stays unknown.
deploy_step_identity() {  # <steps-payload-json> <declared-step-name>
  printf '%s' "$1" | jq -c --arg declared "$2" '
      def arr: if type == "array" then . elif type == "object" then (.steps? // .values? // .pipeline?.steps? // []) else [] end
               | if type == "array" then . else [] end;
      def state_of: (.state.name? // .state? // "") | tostring | ascii_upcase;
      def result_of: (.state.result.name? // .result? // "") | tostring | ascii_upcase;
      [ arr[]
        | {uuid:((.uuid? // "-") | tostring), name:((.name? // "-") | tostring),
           state:state_of, result:result_of} ] as $all
      | ($all | map(select(.name == $declared))) as $steps
      | {parsed: ($all | length),
         steps: (if ($all | length) == 0 then [] else $steps end),
         evidence: "declared configuration",
         identification: (if ($all | length) == 0 then "unparsed"
                          elif ($steps | length) == 0 then "absent"
                          elif ($steps | length) > 1 then "ambiguous"
                          else "configured" end),
         unfinished: (if ($all | length) == 0 then 0
                      else ($steps | map(select(.state != "COMPLETED" or .result != "SUCCESSFUL")) | length) end),
         state: (if ($all | length) == 0 or ($steps | length) == 0 then "-"
                 else ($steps | map("\(.state)/\(.result)") | unique | join(" ")) end)}' 2>/dev/null \
    || printf '%s' '{"parsed":0,"steps":[],"evidence":"declared configuration","identification":"unparsed","unfinished":0,"state":"-"}'
}
DEPLOY_BRANCHLESS=0
DEPLOY_PARTIAL=0

# The evidence this reader goes looking for on every deploy read, named once so
# the ledger asks the same question of every project and every run.
DEPLOY_EVIDENCE_SOUGHT="declared production deploy step; deploy step outcome; recorded production head"

# THE SINGLE OWNER of a ledger row that belongs to the whole project rather than
# to one run: a deploy source that is not wired, a reader that is not installed,
# a spent budget, a listing that could not be read or nominated nothing, and a
# repository with no usable declared production deploy step all land here. Every
# such row carries the same columns as a per-run row so the ledger reads as one
# table, and every one of them is an evidence gap, never a verdict.
deploy_project_row() {  # <project> <source> <step> <result> <counted> <sought> <found> <unavailable>
  DEPLOY_ROWS=$(printf '%s' "$DEPLOY_ROWS" | jq -c \
    --arg project "$1" --arg source "$2" --arg step "$3" --arg result "$4" \
    --arg counted "$5" --arg sought "$6" --arg found "$7" --arg unavailable "$8" \
    '. + [{project:$project,source:$source,run:"-",result:$result,branch:"-",
           deploy_step:$step,deploy_step_outcome:"-",head:"-",head_from:"-",when:"-",
           counted:$counted,evidence_sought:$sought,evidence_found:$found,
           evidence_unavailable:$unavailable}]')
}
FORGE_UNAVAILABLE=0
FORGE_ACTIVITY_TIMED=0

for id in $PROJECT_IDS; do
  path="$PROJECTS_DIR/$id"
  deploy_step_record=$(deploy_step_config_record "$id")
  deploy_step_status=${deploy_step_record%%$'\t'*}
  deploy_step_name=${deploy_step_record#*$'\t'}
  [ "$deploy_step_name" != "$deploy_step_record" ] || deploy_step_name=-
  mode=$("$SCRIPT_DIR/fm-project-mode.sh" --raw "$id" 2>/dev/null) || mode="unknown"
  remote=""
  forge=none
  slug=""
  branch=""
  available=no
  reason=""
  fetched="-"
  if [ ! -d "$path/.git" ]; then
    reason="no local copy at $path"
    UNREADABLE_CLONES=$((UNREADABLE_CLONES + 1))
  elif ! remote=$(git -C "$path" remote get-url origin 2>/dev/null); then
    remote=""
    reason="no origin remote"
    UNREADABLE_CLONES=$((UNREADABLE_CLONES + 1))
  fi
  if [ -n "$remote" ] || [ -d "$path/.git" ]; then
    forge=$(forge_of "$remote")
    slug=$(slug_of "$remote")
  fi
  if [ -d "$path/.git" ]; then
    # origin/HEAD is the registered default branch; fall back to the checked-out
    # branch so a clone without a remote HEAD symref still reports something real.
    if branch=$(git -C "$path" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); then
      :
    elif branch=$(git -C "$path" symbolic-ref -q --short HEAD 2>/dev/null); then
      :
    else
      branch=""
    fi
    if [ -n "$branch" ] && git -C "$path" rev-parse --verify -q "$branch^{commit}" >/dev/null 2>&1; then
      available=yes
      fetched_epoch=""
      if [ -f "$path/.git/FETCH_HEAD" ]; then
        fetched_epoch=$(file_mtime_epoch "$path/.git/FETCH_HEAD")
        case "$fetched_epoch" in
          ''|*[!0-9]*) fetched_epoch="" ;;
          *) fetched=$(iso_of "$fetched_epoch" || printf '%s' "-") ;;
        esac
      fi
      if [ -z "$fetched_epoch" ]; then
        reason="last refresh unknown; a stale local copy under-reports"
        STALE_CLONES=$((STALE_CLONES + 1))
      elif [ "$fetched_epoch" -lt "$SINCE_EPOCH" ]; then
        reason="local copy last refreshed before the window opened"
        STALE_CLONES=$((STALE_CLONES + 1))
      fi
    elif [ -z "$reason" ]; then
      reason="no readable default branch"
      UNREADABLE_CLONES=$((UNREADABLE_CLONES + 1))
    fi
  fi
  PROJECT_ROWS=$(printf '%s' "$PROJECT_ROWS" | jq -c \
    --arg id "$id" --arg mode "$mode" --arg path "$path" --arg forge "$forge" \
    --arg slug "${slug:--}" --arg branch "${branch:--}" --arg available "$available" \
    --arg reason "${reason:--}" --arg fetched "$fetched" \
    --arg deploy_step "$deploy_step_name" --arg deploy_step_status "$deploy_step_status" \
    '. + [{id:$id,mode:$mode,path:$path,forge:$forge,slug:$slug,branch:$branch,
           available:$available,reason:$reason,fetched:$fetched,
           deploy_step:$deploy_step,deploy_step_status:$deploy_step_status}]')

  [ "$available" = yes ] || continue

  # --- merges on the default branch inside the window -----------------------
  # `--merges` alone would make a squash-merging project read as quiet rather
  # than as unseen, so the first-parent mainline is read whole and a row
  # qualifies when it is a real merge commit OR its subject says "pull request
  # #N", the explicit form both supported forges write. A bare trailing "(#N)" on
  # a single-parent commit is NOT that evidence - it is equally an issue
  # reference - so those are counted as unseen and disclosed rather than
  # presented as ships. A revert is not a ship either. The read itself is
  # bounded, not just the output: a one-year window is otherwise unbounded.
  merges_tsv=$(git -C "$path" log "$branch" --first-parent \
    --max-count="$FM_STANDUP_MERGE_SCAN" \
    --since="$SINCE" --until="$NOW" \
    --format='%H%x09%ct%x09%P%x09%s' 2>/dev/null) || merges_tsv=""
  scanned=$(printf '%s' "$merges_tsv" | grep -c . || true)
  if [ "${scanned:-0}" -ge "$FM_STANDUP_MERGE_SCAN" ]; then
    MERGE_SCAN_CAPPED=$((MERGE_SCAN_CAPPED + 1))
  fi
  # One pass over the whole TSV, and the single owner of the local pull request
  # pointer. The trailing "(#N)" form still supplies the LINK once a commit is
  # already known to be a merge; it never qualifies one on its own.
  merges_read=$(printf '%s' "$merges_tsv" | jq -R -s -c \
    --arg project "$id" --arg forge "$forge" --arg slug "$slug" '
    def trunc($n): tostring | gsub("\\s+"; " ") | if length > $n then .[:$n] + "…" else . end;
    def prnum:
      if test("pull request #[0-9]+") then (capture("pull request #(?<n>[0-9]+)") | .n)
      elif test("\\(#[0-9]+\\)[[:space:]]*$") then (capture("\\(#(?<n>[0-9]+)\\)[[:space:]]*$") | .n)
      else null end;
    def prurl($n):
      if $n == null or $slug == "" then "-"
      elif $forge == "github" then "https://github.com/\($slug)/pull/\($n)"
      elif $forge == "bitbucket" then "https://bitbucket.org/\($slug)/pull-requests/\($n)"
      else "-" end;
    [ split("\n")[]
      | select(length > 0)
      | split("\t")
      | select(length >= 4)
      | {commit:.[0], ct:(.[1] | tonumber? // 0),
         parents:(.[2] | split(" ") | map(select(length > 0)) | length),
         subject:(.[3:] | join("\t"))}
      | . + {num:(.subject | prnum),
             revert:(.subject | test("^[[:space:]]*Revert\\b")),
             explicit:(.subject | test("pull request #[0-9]+"))} ]
    | {rows: [ .[]
               | select(.parents > 1 or (.explicit and (.revert | not)))
               | {project:$project, when:(.ct | todate), ct:.ct, commit:.commit,
                  pr:prurl(.num), deployed:"unknown", title:(.subject | trunc(90))} ],
       unseen: ([ .[]
                  | select(.parents == 1 and (.explicit | not) and (.revert | not))
                  | select(.num != null) ] | length)}') \
    || merges_read='{"rows":[],"unseen":0}'
  MERGE_UNSEEN=$((MERGE_UNSEEN + $(printf '%s' "$merges_read" | jq '.unseen')))
  MERGE_ROWS=$(printf '%s\n%s' "$MERGE_ROWS" "$merges_read" | jq -sc '.[0] + .[1].rows')

  # --- deploy train (opt-in, network) ---------------------------------------
  [ "$INCLUDE_DEPLOY" = 1 ] || continue
  if [ "$forge" != bitbucket ] || [ -z "$slug" ]; then
    deploy_project_row "$id" none "$deploy_step_name" "no wired deploy train" "-" \
      "deploy train for this project" "-" "no wired deploy train for this forge"
    DEPLOY_UNAVAILABLE=$((DEPLOY_UNAVAILABLE + 1))
    continue
  fi
  if ! command -v bkt >/dev/null 2>&1; then
    deploy_project_row "$id" bkt "$deploy_step_name" "unavailable (bkt not found)" "-" \
      "deploy train for this project" "-" "the deploy reader is not installed"
    DEPLOY_UNAVAILABLE=$((DEPLOY_UNAVAILABLE + 1))
    continue
  fi
  workspace=${slug%%/*}
  repo=${slug#*/}
  if ! deploy_budget_left; then
    deploy_project_row "$id" bkt "$deploy_step_name" \
      "unavailable (deploy budget spent before this train was read)" "-" \
      "deploy train for this project" "-" \
      "the deploy read ran out of time before this project was checked"
    DEPLOY_UNAVAILABLE=$((DEPLOY_UNAVAILABLE + 1))
    continue
  fi
  DEPLOY_PROBE_CALLS=$((DEPLOY_PROBE_CALLS + 1))
  if ! runs=$(fm_run_timed "$FM_STANDUP_NET_TIMEOUT" bkt pipeline list --json \
      --workspace "$workspace" --repo "$repo" --limit "$FM_STANDUP_DEPLOY_RUNS" 2>/dev/null); then
    deploy_project_row "$id" bkt "$deploy_step_name" "unavailable (deploy train read failed)" "-" \
      "deploy train for this project" "-" "the deploy train could not be read"
    DEPLOY_UNAVAILABLE=$((DEPLOY_UNAVAILABLE + 1))
    continue
  fi
  # The vendor payload's shape is not a contract we control, so read the few
  # plausible commit/result/branch paths and treat every miss as a withheld
  # verdict. A missed field can only withhold a deployed verdict, never grant
  # one: a run whose branch cannot be determined is excluded, not admitted.
  ok_runs=$(printf '%s' "$runs" | jq -c '
      def arr: if type == "array" then . elif type == "object" and (.values? | type) == "array" then .values else [] end;
      def str($v): $v | if type == "string" and . != "" then . else null end;
      def result_of: (.state.result.name? // .result? // .state.name? // "") | ascii_upcase;
      def branch_of: str(.target.ref_name? // .target.branch? // .branch? // null);
      [ arr[]
        | {run:((.build_number? // .uuid? // "-") | tostring),
           result:result_of,
           branch:(branch_of // "-"),
           when:((.completed_on? // .created_on? // "-") | tostring)} ]' 2>/dev/null) || ok_runs='[]'
  # jq consumes no input and emits nothing when the listing is empty, so it exits
  # 0 and the fallback above never fires. An unset listing is still a listing
  # that nominated nothing, and it has to reach the ledger as that rather than as
  # an empty string every later reader would trip over.
  case "$ok_runs" in ''|null) ok_runs='[]' ;; esac
  runs_read=$(printf '%s' "$ok_runs" | jq 'length')
  branchless=$(printf '%s' "$ok_runs" | jq \
    '[ .[] | select(.result == "SUCCESSFUL" and .branch == "-") ] | length')
  DEPLOY_BRANCHLESS=$((DEPLOY_BRANCHLESS + branchless))

  # A pipeline LISTING is not a deploy train - it carries build, test, and custom
  # runs alike - so deploy evidence comes from the run's STEPS, and even those
  # only nominate. The ONE thing that GRANTS a deployed head is the deploy step's
  # own log recording `production is now recorded at <sha>`. Which step that log
  # is read from, which runs are refused, and whether a run definitively deployed
  # nothing are all one question, and deploy_step_identity is its only owner;
  # nothing below re-derives it. Absence of the declared step in parsed steps is
  # a known no-deploy fact; missing identity configuration and unreadable
  # evidence remain unknown.
  candidate_runs=$(printf '%s' "$ok_runs" | jq -r --arg b "${branch#origin/}" \
    '.[] | select(.result == "SUCCESSFUL" and .branch == $b) | .run' 2>/dev/null)
  candidate_n=$(printf '%s' "$candidate_runs" | grep -c . || true)
  heads=""
  head_gaps=0
  probed=0
  STEP_ROWS='[]'
  # Why a candidate run went unexamined is decided wherever the reason is actually
  # known, never re-derived after the loop from whatever flag happens to be set:
  # a run the step bound or the budget cut off and a run there was never anything
  # to examine against are different facts, and each row has to say its own.
  unexamined=""
  unexamined_why=""
  # Two facts belong to the REPOSITORY rather than to any one run, and both are
  # settled here, before a single run is examined, so that neither can be decided
  # by a loop that never ran. Which step is the production deploy is a per-project
  # declaration: without a usable one there is nothing to examine a run against.
  # And a listing that nominated no candidate run examined no evidence at all -
  # whether it came back empty, did not parse, or carried only other branches -
  # so it cannot support a firm negative either. Each records its own gap, and a
  # gap can only ever withhold the verdict.
  if [ "$deploy_step_status" != configured ]; then
    gap_counted="no declared production deploy step for this project"
    gap_unavailable="no declared production deploy step for this project in config/standup-deploy-steps"
    case "$deploy_step_status" in
      duplicate)
        DEPLOY_IDENTITY_DUPLICATE=$((DEPLOY_IDENTITY_DUPLICATE + 1))
        gap_counted="more than one production deploy step is declared for this project"
        gap_unavailable="more than one production deploy step is declared for this project"
        ;;
      blank)
        gap_counted="the declared production deploy step is blank"
        gap_unavailable="the declared production deploy step is blank"
        ;;
      unreadable)
        gap_counted="the production deploy step configuration could not be read"
        gap_unavailable="config/standup-deploy-steps could not be read"
        ;;
    esac
    deploy_project_row "$id" bkt "$deploy_step_name" \
      "unavailable (no usable declared production deploy step)" "$gap_counted" \
      "$DEPLOY_EVIDENCE_SOUGHT" "-" "$gap_unavailable"
    DEPLOY_IDENTITY_UNCONFIGURED=$((DEPLOY_IDENTITY_UNCONFIGURED + 1))
    head_gaps=$((head_gaps + 1))
    candidate_runs=""
    unexamined="not examined: $gap_counted"
    unexamined_why="$gap_unavailable"
  elif [ "$candidate_n" -eq 0 ]; then
    deploy_project_row "$id" bkt "$deploy_step_name" \
      "unavailable (no candidate deploy run to examine)" \
      "no run on the default branch was examined" \
      "$DEPLOY_EVIDENCE_SOUGHT" "declared production deploy step '$deploy_step_name'" \
      "the deploy train listing nominated no successful run on the default branch, so no run was examined"
    DEPLOY_NO_CANDIDATES=$((DEPLOY_NO_CANDIDATES + 1))
    head_gaps=$((head_gaps + 1))
  fi
  while IFS= read -r run_id; do
    [ -n "$run_id" ] && [ "$run_id" != "-" ] || continue
    [ "$probed" -lt "$FM_STANDUP_DEPLOY_STEPS" ] || break
    head=-; head_from=-; counted=""; step_state=-
    evidence_sought="$DEPLOY_EVIDENCE_SOUGHT"
    evidence_found="-"
    evidence_unavailable="-"

    deploy_budget_left || break
    probed=$((probed + 1))
    DEPLOY_PROBE_CALLS=$((DEPLOY_PROBE_CALLS + 1))
    if ! steps=$(fm_run_timed "$FM_STANDUP_NET_TIMEOUT" bkt pipeline view "$run_id" --json \
        --workspace "$workspace" --repo "$repo" 2>/dev/null); then
      steps=""
    fi
    evidence_found="declared production deploy step '$deploy_step_name'"
    if [ -z "$steps" ]; then
      counted="steps could not be read"
      evidence_unavailable="the run's steps could not be read, so the deploy step outcome and production head were not available"
      head_gaps=$((head_gaps + 1))
    else
      identity=$(deploy_step_identity "$steps" "$deploy_step_name")
      identification=$(printf '%s' "$identity" | jq -r '.identification')
      step_state=$(printf '%s' "$identity" | jq -r '.state')
      [ "$identification" = ambiguous ] && DEPLOY_AMBIGUOUS=$((DEPLOY_AMBIGUOUS + 1))
      if [ "$identification" = unparsed ]; then
        counted="the run's steps did not parse, so the declared deploy step could not be checked"
        evidence_unavailable="the run's steps did not parse, so the declared deploy step could not be checked"
        DEPLOY_UNPARSED=$((DEPLOY_UNPARSED + 1))
        head_gaps=$((head_gaps + 1))
      elif [ "$identification" = absent ]; then
        counted="the declared deploy step is not in this run"
        evidence_found="declared production deploy step '$deploy_step_name'; the run's steps were read"
        evidence_unavailable="that declared step was not present in this run"
      elif [ "$identification" = ambiguous ]; then
        counted="the declared deploy step appears more than once in this run"
        evidence_unavailable="the declared deploy step appeared more than once, so the production step was not unique"
        head_gaps=$((head_gaps + 1))
      elif [ "$(printf '%s' "$identity" | jq '.unfinished')" -gt 0 ]; then
        counted="a deploy step in this run did not complete successfully"
        evidence_found="declared production deploy step '$deploy_step_name'; deploy step outcome $step_state"
        evidence_unavailable="the deploy step did not complete successfully, so no production head was accepted"
        DEPLOY_REFUSED=$((DEPLOY_REFUSED + 1))
        head_gaps=$((head_gaps + 1))
      else
        counted="the deploy log records no production head"
        evidence_found="declared production deploy step '$deploy_step_name'; deploy step outcome $step_state"
        evidence_unavailable="the deploy log records no production head"
        while IFS= read -r step_uuid; do
          [ -n "$step_uuid" ] && [ "$step_uuid" != "-" ] || continue
          if ! deploy_budget_left; then
            counted="the deploy log was not read within the deploy budget"
            evidence_unavailable="the deploy log was not read within the deploy budget"
            break
          fi
          DEPLOY_PROBE_CALLS=$((DEPLOY_PROBE_CALLS + 1))
          # Only as much of the log as the recorded line can hide in, streamed
          # through head rather than slurped: a deploy log runs to megabytes. The
          # sentinel carries the pipeline's own status out past the trailing
          # newlines command substitution would otherwise strip.
          log_head=$( { set -o pipefail
            fm_run_timed "$FM_STANDUP_NET_TIMEOUT" bkt pipeline logs "$run_id" \
              --step "$step_uuid" --workspace "$workspace" --repo "$repo" 2>/dev/null \
            | head -c "$FM_STANDUP_DEPLOY_LOG_BYTES"; } ; printf '\037%s' "$?" )
          log_rc=${log_head##*$'\037'}
          log_head=${log_head%$'\037'*}
          # head -c cuts BYTES, so the truncation test must count bytes too: a
          # multibyte log yields fewer characters than bytes and would otherwise
          # be misreported as unreadable.
          log_bytes=$(printf '%s' "$log_head" | LC_ALL=C wc -c | tr -cd '0-9')
          log_truncated=0
          if [ "${log_bytes:-0}" -ge "$FM_STANDUP_DEPLOY_LOG_BYTES" ]; then
            log_truncated=1
          fi
          recorded=$(printf '%s' "$log_head" \
            | sed -n 's/.*production is now recorded at \([0-9a-f][0-9a-f]*\).*/\1/p' | tail -1)
          if [ -n "$recorded" ]; then
            head=$recorded
            head_from="recorded in the deploy log"
            counted="deploy head recorded in the log"
            evidence_found="declared production deploy step '$deploy_step_name'; deploy step outcome $step_state; recorded production head $recorded"
            evidence_unavailable="-"
            break
          fi
          if [ "$log_truncated" = 1 ]; then
            counted="the deploy log was truncated before any recorded production head"
            evidence_unavailable="the deploy log was truncated before any recorded production head"
          elif [ "$log_rc" != 0 ]; then
            counted="the deploy log could not be read"
            evidence_unavailable="the deploy log could not be read"
          fi
        done <<STEPS
$(printf '%s' "$identity" | jq -r '.steps[] | .uuid')
STEPS
        if [ "$head" = "-" ]; then
          DEPLOY_LOG_UNREAD=$((DEPLOY_LOG_UNREAD + 1))
          head_gaps=$((head_gaps + 1))
        elif ! git -C "$path" rev-parse --verify -q "$head^{commit}" >/dev/null 2>&1; then
          counted="head not in the local copy"
          evidence_unavailable="the recorded production head is not in the local copy"
          head_gaps=$((head_gaps + 1))
        else
          heads="$heads $head"
        fi
      fi
    fi
    STEP_ROWS=$(printf '%s' "$STEP_ROWS" | jq -c \
      --arg run "$run_id" --arg step "$deploy_step_name" --arg outcome "$step_state" \
      --arg head "$head" --arg head_from "$head_from" --arg counted "$counted" \
      --arg sought "$evidence_sought" --arg found "$evidence_found" \
      --arg unavailable "$evidence_unavailable" \
      '. + [{run:$run,deploy_step:$step,deploy_step_outcome:$outcome,head:$head,
             head_from:$head_from,counted:$counted,
             evidence_sought:$sought,evidence_found:$found,
             evidence_unavailable:$unavailable}]')
  done <<EOF
$candidate_runs
EOF
  if [ "$candidate_n" -gt 0 ] && [ -z "${heads// /}" ] && [ "$head_gaps" -eq 0 ]; then
    DEPLOY_NO_DEPLOYMENT=$((DEPLOY_NO_DEPLOYMENT + 1))
  fi
  if [ -z "$unexamined" ]; then
    if [ "$DEPLOY_BUDGET_EXHAUSTED" = 1 ]; then
      unexamined="not probed within the deploy budget"
    else
      unexamined="not probed within the step bound"
    fi
    unexamined_why="$unexamined"
  fi
  DEPLOY_ROWS=$(printf '%s\n%s\n%s' "$DEPLOY_ROWS" "$ok_runs" "$STEP_ROWS" | jq -sc \
    --arg project "$id" --arg b "${branch#origin/}" --arg unprobed "$unexamined" \
    --arg unprobed_why "$unexamined_why" \
    --arg step "$deploy_step_name" --arg sought "$DEPLOY_EVIDENCE_SOUGHT" \
    '(.[2] | map({key:.run, value:.}) | from_entries) as $probe
     | .[0] + [ .[1][]
                | . as $run
                | ($probe[$run.run] // null) as $p
                | {project:$project,source:"bkt",run:$run.run,result:$run.result,
                   branch:$run.branch,
                   deploy_step:($p.deploy_step // $step),
                   deploy_step_outcome:($p.deploy_step_outcome // "-"),
                   head:($p.head // "-"),
                   head_from:($p.head_from // "-"),
                   when:$run.when,
                   counted:(if $p != null then $p.counted
                            elif $run.result != "SUCCESSFUL" then "not a successful run"
                            elif $run.branch == "-" then "branch undetermined"
                            elif $run.branch != $b then "another branch"
                            elif $run.run == "-" then "not examined: the run carries no identifier to probe"
                            else $unprobed end),
                   evidence_sought:($p.evidence_sought // $sought),
                   evidence_found:($p.evidence_found // "-"),
                   evidence_unavailable:($p.evidence_unavailable //
                     (if $run.result != "SUCCESSFUL" then "the run did not succeed"
                      elif $run.branch == "-" then "the run branch could not be determined"
                      elif $run.branch != $b then "the run belongs to another branch"
                      elif $run.run == "-" then "the run carries no identifier to probe, so its steps could not be read"
                      else $unprobed_why end))} ]')
  [ -n "${heads// /}" ] || [ "$head_gaps" -eq 0 ] || DEPLOY_UNAVAILABLE=$((DEPLOY_UNAVAILABLE + 1))
  # A truncated or partial read must never produce a firm negative. The run list
  # is capped, the step probe is capped, and an accepted run whose head is not in
  # the local copy cannot be tested at all, so `no` survives only where the heads
  # actually read genuinely fail to contain the commit.
  partial=0
  [ "$runs_read" -ge "$FM_STANDUP_DEPLOY_RUNS" ] && partial=1
  [ "$candidate_n" -gt "$probed" ] && partial=1
  [ "$head_gaps" -gt 0 ] && partial=1
  [ "$branchless" -gt 0 ] && partial=1
  if [ "$head_gaps" -gt 0 ] || [ -z "${heads// /}" ]; then
    floor_ct=9999999999
  else
    # shellcheck disable=SC2086
    floor_ct=$(git -C "$path" show -s --format=%ct $heads 2>/dev/null | sort -n | head -1)
    case "$floor_ct" in ''|*[!0-9]*) floor_ct=9999999999 ;; esac
  fi
  [ "$partial" = 1 ] && DEPLOY_PARTIAL=$((DEPLOY_PARTIAL + 1))
  # Containment is proven against EVERY successful deploy head in one traversal,
  # never inferred from run order, so a stopped or superseded train never carries
  # credit for work only a later successful train shipped. The walk is bounded by
  # the oldest candidate's parents: every candidate sits at or after it on the
  # first-parent mainline, so nothing provable is excluded.
  candidates=$(printf '%s' "$MERGE_ROWS" | jq -r --arg p "$id" '.[] | select(.project == $p) | .commit')
  contained='[]'
  if [ -n "$candidates" ] && [ -n "${heads// /}" ]; then
    oldest=$(printf '%s\n' "$candidates" | tail -1)
    # shellcheck disable=SC2086
    reached=$(git -C "$path" rev-list $heads --not "$oldest^@" 2>/dev/null) \
      || reached=$(git -C "$path" rev-list $heads 2>/dev/null) || reached=""
    contained=$(printf '%s\n' "$reached" \
      | grep -Fxf <(printf '%s\n' "$candidates") \
      | jq -Rsc 'split("\n") | map(select(length > 0))') || contained='[]'
  fi
  MERGE_ROWS=$(printf '%s' "$MERGE_ROWS" | jq -c --arg project "$id" \
    --argjson contained "$contained" --argjson partial "$partial" --argjson floor "$floor_ct" \
    'map(. as $row
         | if $row.project == $project
           then .deployed = (if ($contained | index($row.commit)) then "yes"
                             elif $partial == 1 and $row.ct < $floor then "unknown"
                             else "no" end)
           else . end)')
done

# --- closed records in the window, this home plus local secondmate homes ------
CLOSED_ROWS='[]'
BODY_ROWS='[]'
REMOTE_MATES=0
UNREADABLE_MATES=0

# A Done row carrying no close date at all cannot be placed in a window. It is
# counted and disclosed rather than dropped, so an undated record never quietly
# shrinks the shipped list.
UNDATED_CLOSED=0

collect_closed() {  # <home-label> <backlog-path> <archive-path>
  local label=$1 backlog=$2 archive=$3 f parsed rows
  for f in "$backlog" "$archive"; do
    [ -f "$f" ] || continue
    parsed=$(fm_backlog_json "$f" "$TODAY") || continue
    UNDATED_CLOSED=$((UNDATED_CLOSED + $(printf '%s' "$parsed" | jq '
      [ .records[] | select(.structured == true and .state == "done" and .closed_on == null) ] | length')))
    rows=$(printf '%s' "$parsed" | jq -c \
      --arg home "$label" --arg since "$SINCE_DATE" --arg only "$ONLY_PROJECT" '
      def trunc($n): tostring | gsub("\\s+"; " ") | if length > $n then .[:$n] + "…" else . end;
      [ .records[]
        | select(.structured == true and .state == "done")
        | select(.closed_on != null and .closed_on >= $since)
        | select($only == "" or (.repo // "") == $only)
        | {id, home:$home, project:((.repo // "-")),
           closed_on:.closed_on,
           artifact:((.pr_url // .body_pr_url // .report_path // .local_note // "-")),
           title:((.title // .id) | trunc(90)),
           body:((.body_excerpt // "-") | trunc(240))} ]') || continue
    CLOSED_ROWS=$(printf '%s\n%s' "$CLOSED_ROWS" "$rows" | jq -sc \
      '.[0] + [ .[1][] | del(.body) ]')
    BODY_ROWS=$(printf '%s\n%s' "$BODY_ROWS" "$rows" | jq -sc \
      '.[0] + [ .[1][] | {id, body} ]')
  done
}

collect_closed "(main)" "$DATA/backlog.md" "$DATA/done-archive.md"

SECONDMATE_REGISTRY_UNFOLLOWED=0
if [ -f "$SECONDMATES" ] && [ -L "$SECONDMATES" ]; then
  # Not followed, but never silently: dropping every mate's closed work without a
  # disclosure is the exact failure this reader exists to prevent.
  SECONDMATE_REGISTRY_UNFOLLOWED=1
elif [ -f "$SECONDMATES" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- "*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      REMOTE_MATES=$((REMOTE_MATES + 1))
      continue
    fi
    if [ ! -d "$SECONDMATE_REGISTRY_HOME/data" ]; then
      UNREADABLE_MATES=$((UNREADABLE_MATES + 1))
      continue
    fi
    collect_closed "$SECONDMATE_REGISTRY_ID" \
      "$SECONDMATE_REGISTRY_HOME/data/backlog.md" \
      "$SECONDMATE_REGISTRY_HOME/data/done-archive.md"
  done < "$SECONDMATES"
fi

# --- merged pull requests in the window (opt-in, network) --------------------
FORGE_STATUS='not_requested (pass --include-forge)'
DEPLOY_STATUS='not_requested (pass --include-deploy)'
[ "$INCLUDE_DEPLOY" = 1 ] && DEPLOY_STATUS='requested'
if [ "$INCLUDE_FORGE" = 1 ]; then
  FORGE_STATUS='requested'
  while IFS=$'\t' read -r id forge slug; do
    [ -n "$id" ] || continue
    rows=""
    case "$forge" in
      github)
        if command -v gh >/dev/null 2>&1; then
          rows=$(fm_run_timed "$FM_STANDUP_NET_TIMEOUT" \
            env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
            gh pr list --repo "$slug" --state merged --limit "$FM_STANDUP_FORGE_PRS" \
            --json number,title,url,mergedAt 2>/dev/null | jq -c --arg since "$SINCE" \
            '[ .[] | select(.mergedAt != null and .mergedAt >= $since)
               | {pr:.url, when:.mergedAt, when_means:"merged", title:(.title[:90])} ]') || rows=""
        fi
        ;;
      bitbucket)
        if command -v bkt >/dev/null 2>&1; then
          # A Bitbucket pull request carries no merge timestamp: `updated_on` is
          # LAST ACTIVITY and advances on any later comment, so a request merged
          # months ago can fall inside the window. The column says what the time
          # actually is rather than presenting it as a merge time, and the row is
          # disclosed, because over-claiming in the shipped direction is the one
          # direction this reader may never take.
          rows=$(fm_run_timed "$FM_STANDUP_NET_TIMEOUT" \
            bkt pr list --json --state MERGED --limit "$FM_STANDUP_FORGE_PRS" \
            --workspace "${slug%%/*}" --repo "${slug#*/}" 2>/dev/null \
            | jq -c --arg since "$SINCE" --arg slug "$slug" '
              def arr: if type == "array" then . elif type == "object" and (.values? | type) == "array" then .values else [] end;
              [ arr[]
                | {pr:((.links.html.href? // ("https://bitbucket.org/" + $slug + "/pull-requests/" + ((.id // "") | tostring)))),
                   when:((.updated_on? // "") | tostring),
                   when_means:"last activity, not a merge time",
                   title:(((.title // "-") | tostring)[:90])}
                | select(.when >= $since) ]') || rows=""
          case "$rows" in ''|'[]') ;; *) FORGE_ACTIVITY_TIMED=$((FORGE_ACTIVITY_TIMED + 1)) ;; esac
        fi
        ;;
    esac
    if [ -z "$rows" ]; then
      FORGE_UNAVAILABLE=$((FORGE_UNAVAILABLE + 1))
      continue
    fi
    FORGE_ROWS=$(printf '%s\n%s' "$FORGE_ROWS" "$rows" | jq -sc --arg project "$id" \
      '.[0] + [ .[1][] | {project:$project} + . ]')
  done <<EOF
$(printf '%s' "$PROJECT_ROWS" | jq -r '.[] | select(.forge == "github" or .forge == "bitbucket") | [.id, .forge, .slug] | @tsv')
EOF
fi

# --- model ------------------------------------------------------------------
case ",$FIELDS," in *,bodies,*) F_BODIES=true ;; *) F_BODIES=false ;; esac

MODEL=$(jq -n \
  --arg schema "fm-standup-shipped.v1" \
  --arg home "$(printf '%s' "$FM_HOME" | awk -F/ '{ if (NF > 1) printf "%s/%s", $(NF-1), $NF; else print $0 }')" \
  --arg generated "$NOW" \
  --arg spec "$WINDOW_SPEC" --argjson hours "$WINDOW_HOURS" \
  --arg since "$SINCE" --arg since_date "$SINCE_DATE" \
  --arg forge_status "$FORGE_STATUS" --arg deploy_status "$DEPLOY_STATUS" \
  --argjson projects "$PROJECT_ROWS" \
  --argjson merges "$MERGE_ROWS" \
  --argjson closed "$CLOSED_ROWS" \
  --argjson deploys "$DEPLOY_ROWS" \
  --argjson forge_prs "$FORGE_ROWS" \
  --argjson bodies "$BODY_ROWS" \
  --argjson merges_n "$FM_STANDUP_MERGES" --argjson closed_n "$FM_STANDUP_CLOSED" \
  --argjson all_merges "$ALL_MERGES" --argjson all_closed "$ALL_CLOSED" \
  --argjson include_forge "$INCLUDE_FORGE" --argjson include_deploy "$INCLUDE_DEPLOY" \
  --argjson f_bodies "$F_BODIES" \
  --argjson registry_present "$REGISTRY_PRESENT" \
  --argjson stale "$STALE_CLONES" --argjson unreadable "$UNREADABLE_CLONES" \
  --argjson deploy_gaps "$DEPLOY_UNAVAILABLE" --argjson forge_gaps "$FORGE_UNAVAILABLE" \
  --argjson remote_mates "$REMOTE_MATES" --argjson unreadable_mates "$UNREADABLE_MATES" \
  --argjson undated "$UNDATED_CLOSED" \
  --argjson scan_capped "$MERGE_SCAN_CAPPED" --argjson scan_bound "$FM_STANDUP_MERGE_SCAN" \
  --argjson merge_unseen "$MERGE_UNSEEN" \
  --argjson no_deployment "$DEPLOY_NO_DEPLOYMENT" --argjson branchless "$DEPLOY_BRANCHLESS" \
  --argjson deploy_partial "$DEPLOY_PARTIAL" \
  --argjson log_unread "$DEPLOY_LOG_UNREAD" --argjson refused "$DEPLOY_REFUSED" \
  --argjson budget_spent "$DEPLOY_BUDGET_EXHAUSTED" \
  --argjson unparsed_steps "$DEPLOY_UNPARSED" \
  --argjson identity_unconfigured "$DEPLOY_IDENTITY_UNCONFIGURED" \
  --argjson identity_duplicate "$DEPLOY_IDENTITY_DUPLICATE" \
  --argjson no_candidates "$DEPLOY_NO_CANDIDATES" \
  --argjson ambiguous "$DEPLOY_AMBIGUOUS" \
  --argjson activity_timed "$FORGE_ACTIVITY_TIMED" \
  --argjson mate_registry_unfollowed "$SECONDMATE_REGISTRY_UNFOLLOWED" \
  --arg only "$ONLY_PROJECT" '
  ($merges | sort_by(.ct) | reverse | map(del(.ct))) as $merges_sorted
  | ($closed | sort_by(.closed_on) | reverse) as $closed_sorted
  | {
      schema: $schema,
      home: $home,
      generated: $generated,
      window: {spec:$spec, hours:$hours, since:$since, since_date:$since_date},
      forge: $forge_status,
      deploy: $deploy_status,
      scope: (if $only == "" then "all registered projects" else $only end),
      projects: $projects,
      merges: (if $all_merges == 1 then $merges_sorted else $merges_sorted[:$merges_n] end),
      closed: (if $all_closed == 1 then $closed_sorted else $closed_sorted[:$closed_n] end),
      deploys: $deploys
    }
  | . + (if $include_forge == 1 then {forge_prs:$forge_prs} else {} end)
  | . + (if $f_bodies then {bodies:$bodies} else {} end)
  | . + {omitted: (
      [ (if $registry_present then empty else {surface:"no project registry; nothing could be scoped", reveal:"rebuild data/projects.md from the local copies"} end),
        (if $f_bodies then empty else {surface:"closed-record bodies (where a production check is recorded)", reveal:"--fields bodies"} end),
        (if $all_merges == 0 and ($merges_sorted | length) > $merges_n then {surface:("merges showing \($merges_n) of \($merges_sorted | length)"), reveal:"--all-merges"} else empty end),
        (if $all_closed == 0 and ($closed_sorted | length) > $closed_n then {surface:("closed showing \($closed_n) of \($closed_sorted | length)"), reveal:"--all-closed"} else empty end),
        (if $unreadable > 0 then {surface:("project local copies unreadable: \($unreadable)"), reveal:"see projects[].reason"} else empty end),
        (if $stale > 0 then {surface:("project local copies older than the window: \($stale); merges since the last refresh are not counted"), reveal:"refresh the local copies, or --include-forge"} else empty end),
        (if $remote_mates > 0 then {surface:("second mate homes on another host, not read here: \($remote_mates)"), reveal:"ask that mate for its own closed work"} else empty end),
        (if $unreadable_mates > 0 then {surface:("second mate homes with no readable records: \($unreadable_mates)"), reveal:"inspect the registered home paths"} else empty end),
        (if $mate_registry_unfollowed == 1 then {surface:"the second mate registry is a symlink and was not followed, so no second mate closed work is counted", reveal:"replace data/secondmates.md with the file itself"} else empty end),
        (if $merge_unseen > 0 then {surface:("mainline commits carrying only a bare pull-request-shaped number, which is equally an issue reference and is not counted as a merge: \($merge_unseen)"), reveal:"--include-forge, which reads the merged list the forge itself keeps"} else empty end),
        (if $scan_capped > 0 then {surface:("projects whose mainline read hit its bound of \($scan_bound) commits: \($scan_capped); older merges in the window were not read"), reveal:"raise FM_STANDUP_MERGE_SCAN, or narrow --window"} else empty end),
        (if $undated > 0 then {surface:("closed records carrying no close date, so they cannot be placed in any window: \($undated)"), reveal:"add a close date to those backlog rows"} else empty end),
        (if $include_deploy == 1 and $deploy_gaps > 0 then {surface:("projects with no usable deployed head: \($deploy_gaps); their merges stay unconfirmed, never deployed"), reveal:"see deploys[].result"} else empty end),
        (if $include_deploy == 1 and $no_deployment > 0 then {surface:("projects where no run recorded a production head: \($no_deployment); a pipeline listing carries build, test, and custom runs, and neither CI-green nor a step named deploy is a deploy"), reveal:"see deploys[].counted and deploys[].deploy_step_outcome"} else empty end),
        (if $include_deploy == 1 and $refused > 0 then {surface:("runs refused because a deploy step in them did not complete successfully: \($refused); a successful staging deploy beside a failed production one is not a ship"), reveal:"see deploys[].counted"} else empty end),
        (if $include_deploy == 1 and $identity_unconfigured > 0 then {surface:("projects with no usable declared production deploy step: \($identity_unconfigured); their deploy step was not recognized here, so the verdict stays unknown"), reveal:"set config/standup-deploy-steps for that project"} else empty end),
        (if $include_deploy == 1 and $identity_duplicate > 0 then {surface:("projects declaring more than one production deploy step: \($identity_duplicate); the production step is not unique"), reveal:"keep one line for the project in config/standup-deploy-steps"} else empty end),
        (if $include_deploy == 1 and $no_candidates > 0 then {surface:("projects whose deploy train listing nominated no run to examine: \($no_candidates); no deploy evidence was examined at all, so their merges stay unconfirmed rather than being called undeployed"), reveal:"see deploys[].evidence_unavailable"} else empty end),
        (if $include_deploy == 1 and $ambiguous > 0 then {surface:("runs where the declared production deploy step appears more than once, so the production step is not unique: \($ambiguous)"), reveal:"see deploys[].evidence_unavailable; only a recorded production head from a unique declared step settles it"} else empty end),
        (if $include_deploy == 1 and $unparsed_steps > 0 then {surface:("runs whose step payload parsed to nothing, so a deploy step could neither be found nor ruled out: \($unparsed_steps)"), reveal:"see deploys[].counted"} else empty end),
        (if $include_deploy == 1 and $log_unread > 0 then {surface:("successful deploys whose recorded production head could not be read: \($log_unread); the deploy ran, what it served is unproved, and neither is a ship"), reveal:"see deploys[].counted for whether the log was unreadable, truncated, or simply silent"} else empty end),
        (if $include_deploy == 1 and $budget_spent == 1 then {surface:"the deploy budget was spent before every candidate run was read, so some merges could not be tested at all", reveal:"raise FM_STANDUP_DEPLOY_BUDGET or FM_STANDUP_DEPLOY_PROBES"} else empty end),
        (if $include_deploy == 1 and $branchless > 0 then {surface:("successful runs excluded because their branch could not be determined: \($branchless); they can never grant a deployed verdict"), reveal:"see deploys[].counted"} else empty end),
        (if $include_deploy == 1 and $deploy_partial > 0 then {surface:("projects whose deploy read was partial: \($deploy_partial); merges older than the oldest deploy head read stay unconfirmed rather than being called undeployed"), reveal:"raise FM_STANDUP_DEPLOY_RUNS, FM_STANDUP_DEPLOY_STEPS, or FM_STANDUP_DEPLOY_BUDGET, or refresh the local copy"} else empty end),
        (if $include_forge == 1 and $forge_gaps > 0 then {surface:("projects whose merged pull requests could not be read: \($forge_gaps)"), reveal:"check the forge credentials"} else empty end),
        (if $include_forge == 1 and $activity_timed > 0 then {surface:("projects whose pull requests are timed by last activity, not by merge time: \($activity_timed); a Bitbucket pull request merged before the window can appear in it"), reveal:"see forge_prs[].when_means, and trust merges[] for the merge time"} else empty end),
        (if $include_deploy == 1 then empty else {surface:"deploy evidence; every merge stays unconfirmed", reveal:"--include-deploy"} end),
        (if $include_forge == 1 then empty else {surface:"merged pull requests from the forge", reveal:"--include-forge"} end),
        {surface:"work landed by a rebase or squash whose subject does not say \"pull request #N\"; the mainline read counts merge commits and subjects that say it outright, and a revert is never counted as a ship", reveal:"--include-forge, which reads the merged list the forge itself keeps"},
        {surface:"what production is serving right now; a deployed verdict proves the deploy ran and carried the commit, it is not a read of production itself", reveal:"the served head lives in an artifact this host holds no credentials for"},
        {surface:"production verification; no durable field records it", reveal:"read the closed record body with --fields bodies"} ]) }
') || { echo "fm-standup-shipped: projection failed" >&2; exit 1; }

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$MODEL"
  exit 0
fi

# --- TOON renderer (output boundary; parity with the JSON model) -------------
TOON=$(printf '%s\n' "$MODEL" | jq -r '
  def q:
    tostring
    | if (. == "")
        or test("^\\s|\\s$")
        or (. == "true" or . == "false" or . == "null")
        or test("^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")
        or test("[:\"\\\\\\[\\]{},]")
        or test("[[:cntrl:]]")
        or test("^-")
      then "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n") | gsub("\r"; "\\r") | gsub("\t"; "\\t")) + "\""
      else . end;
  def scal:
    if . == null then "null"
    elif type == "boolean" then (if . then "true" else "false" end)
    elif type == "number" then tostring
    else q end;
  def emit($k; $v):
    if ($v | type) == "array" then
      if ($v | length) == 0 then "\($k): []"
      else
        ($v[0] | keys_unsorted) as $ks
        | ( "\($k)[\($v | length)]{\($ks | map(q) | join(","))}:",
            ($v[] as $row | "  " + ([ $ks[] as $kk | ($row[$kk] | scal) ] | join(","))) )
      end
    elif ($v | type) == "object" then
      "\($k): " + ([ $v | to_entries[] | "\(.key)=\(.value | scal)" ] | join(" "))
    else "\($k): " + ($v | scal)
    end;
  [ to_entries[] | emit(.key; .value) ] | join("\n")
') || { echo "fm-standup-shipped: TOON rendering failed" >&2; exit 1; }
printf '%s\n' "$TOON"
