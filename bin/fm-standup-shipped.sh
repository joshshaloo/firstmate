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
# HONESTY CONTRACT. Merged is not shipped. Every merge row carries a separate
# deployed verdict that is `unknown` unless a successful deploy run's head was
# read AND the merge commit was PROVEN to be contained in it by git ancestry.
# Containment is checked against EVERY successful deploy head gathered, never
# assumed from ordering, so a superseded or stopped train never carries credit for
# work only a later successful train shipped. Every path that cannot answer
# degrades to `unknown` plus an omitted[] disclosure - an unreadable source, an
# unfetched clone, a vendor payload without a commit - so this reader can only ever
# under-claim, never report an unproved ship. Production VERIFICATION is not
# emitted at all: no durable structured field records it, so the skill reads the
# closed record's own words (--fields bodies) rather than being handed a guess.
#
# SOURCES, in the order they are trusted:
#   1. Each registered project's default-branch git history in the window. Merge
#      commits are durable project truth and need no network. The clone is read as
#      it stands - this NEVER fetches, because firstmate does not write to a
#      project - so each project row carries its last-fetch time and a stale clone
#      is disclosed instead of silently under-reporting.
#   2. data/backlog.md Done plus data/done-archive.md, for this home and every
#      registered LOCAL secondmate home, filtered on the row's own close date.
#      bin/fm-backlog-parse-lib.sh owns that row syntax and its closed_on date.
#   3. --include-deploy (network): the project's deploy train. Bitbucket Cloud
#      repositories are read through `bkt pipeline list`; a project on any other
#      forge reports no wired deploy source, which is `unknown`, never `deployed`.
#   4. --include-forge (network): merged pull requests in the window, through gh
#      for GitHub remotes and bkt for Bitbucket ones. Local merge subjects already
#      carry the PR number on both forges, so this only adds titles and catches
#      merges a stale clone has not fetched.
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
PROJECTS_DIR="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REGISTRY="$DATA/projects.md"
SECONDMATES="$DATA/secondmates.md"

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
FM_STANDUP_CLOSED=${FM_STANDUP_CLOSED:-40}
FM_STANDUP_DEPLOY_RUNS=${FM_STANDUP_DEPLOY_RUNS:-30}
FM_STANDUP_FORGE_PRS=${FM_STANDUP_FORGE_PRS:-50}
FM_STANDUP_NET_TIMEOUT=${FM_STANDUP_NET_TIMEOUT:-20}
case "$FM_STANDUP_NET_TIMEOUT" in ''|*[!0-9]*|0) FM_STANDUP_NET_TIMEOUT=20 ;; esac
validate_bound() {  # <name> <value>
  case "$2" in ''|*[!0-9]*|0) echo "fm-standup-shipped: $1 must be a positive integer" >&2; exit 2 ;; esac
}
validate_bound FM_STANDUP_MERGES "$FM_STANDUP_MERGES"
validate_bound FM_STANDUP_CLOSED "$FM_STANDUP_CLOSED"
validate_bound FM_STANDUP_DEPLOY_RUNS "$FM_STANDUP_DEPLOY_RUNS"
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
  projects{id,mode,path,forge,slug,branch,available,reason,fetched},
  merges{project,when,commit,pr,deployed,title},
  closed{id,home,project,closed_on,artifact,title},
  deploys{project,source,run,result,head,when,contains},
  forge_prs{project,pr,merged_at,title} (only under --include-forge),
  bodies{id,body} (only under --fields bodies),
  omitted{surface,reveal}.

merges.deployed is yes only when a successful deploy run's head was read and the
merge commit is a proven git ancestor of it; no when successful heads were read
and none contain it; unknown in every other case, always with a disclosure.
Production verification is never emitted: read the closed record's own words with
--fields bodies. A project with no rows in the window is still listed under
projects, so "quiet" is distinguishable from "not looked at".

Deploy trains are wired for Bitbucket Cloud remotes (bkt pipeline list). A project
on another forge reports no wired deploy source rather than a deployed claim.
Bounds: FM_STANDUP_MERGES, FM_STANDUP_CLOSED, FM_STANDUP_DEPLOY_RUNS,
FM_STANDUP_FORGE_PRS, FM_STANDUP_NET_TIMEOUT.
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
  ''|[A-Za-z0-9._-]*) : ;;
esac
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

slug_of() {  # <remote-url>
  printf '%s' "$1" \
    | sed -n 's#.*\(github\.com\|bitbucket\.org\)[:/]\([^/]*/[^/]*\)#\2#p' \
    | sed 's#\.git$##; s#/$##'
}

pr_url_for() {  # <forge> <slug> <number>
  case "$1" in
    github) printf 'https://github.com/%s/pull/%s\n' "$2" "$3" ;;
    bitbucket) printf 'https://bitbucket.org/%s/pull-requests/%s\n' "$2" "$3" ;;
    *) printf '\n' ;;
  esac
}

# The merge subject is the durable local PR pointer on both supported forges:
# Bitbucket writes "(pull request #N)", GitHub writes "Merge pull request #N" or a
# trailing "(#N)" on a squash. Anything else has no PR number, which is a real
# answer (a direct push), not a failure.
pr_number_in() {  # <subject>
  printf '%s' "$1" \
    | sed -n -e 's/.*pull request #\([0-9][0-9]*\).*/\1/p' \
             -e 's/.*(#\([0-9][0-9]*\))[[:space:]]*$/\1/p' \
    | head -1
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
DEPLOY_UNAVAILABLE=0
FORGE_UNAVAILABLE=0

for id in $PROJECT_IDS; do
  path="$PROJECTS_DIR/$id"
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
      if [ -f "$path/.git/FETCH_HEAD" ]; then
        fetched=$(date -u -r "$path/.git/FETCH_HEAD" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "-")
      fi
      if [ "$fetched" = "-" ]; then
        reason="last refresh unknown; a stale local copy under-reports"
        STALE_CLONES=$((STALE_CLONES + 1))
      else
        fetched_epoch=$(epoch_of "$fetched" 2>/dev/null || printf '0')
        if [ "$fetched_epoch" -lt "$SINCE_EPOCH" ]; then
          reason="local copy last refreshed before the window opened"
          STALE_CLONES=$((STALE_CLONES + 1))
        fi
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
    '. + [{id:$id,mode:$mode,path:$path,forge:$forge,slug:$slug,branch:$branch,
           available:$available,reason:$reason,fetched:$fetched}]')

  [ "$available" = yes ] || continue

  # --- merges on the default branch inside the window -----------------------
  merges_tsv=$(git -C "$path" log "$branch" --merges --first-parent \
    --since="$SINCE" --until="$NOW" --date=iso-strict \
    --format='%H%x09%cI%x09%s' 2>/dev/null) || merges_tsv=""
  while IFS=$'\t' read -r commit when subject; do
    [ -n "$commit" ] || continue
    num=$(pr_number_in "$subject")
    pr="-"
    if [ -n "$num" ] && [ -n "$slug" ]; then
      pr=$(pr_url_for "$forge" "$slug" "$num")
      [ -n "$pr" ] || pr="-"
    fi
    MERGE_ROWS=$(printf '%s' "$MERGE_ROWS" | jq -c \
      --arg project "$id" --arg when "$when" --arg commit "$commit" \
      --arg pr "$pr" --arg title "$subject" \
      'def trunc($n): tostring | gsub("\\s+"; " ") | if length > $n then .[:$n] + "…" else . end;
       . + [{project:$project,when:$when,commit:$commit,pr:$pr,
             deployed:"unknown",title:($title | trunc(90))}]')
  done <<EOF
$merges_tsv
EOF

  # --- deploy train (opt-in, network) ---------------------------------------
  [ "$INCLUDE_DEPLOY" = 1 ] || continue
  if [ "$forge" != bitbucket ] || [ -z "$slug" ]; then
    DEPLOY_ROWS=$(printf '%s' "$DEPLOY_ROWS" | jq -c --arg project "$id" \
      '. + [{project:$project,source:"none",run:"-",result:"no wired deploy train",
             head:"-",when:"-",contains:"-"}]')
    DEPLOY_UNAVAILABLE=$((DEPLOY_UNAVAILABLE + 1))
    continue
  fi
  if ! command -v bkt >/dev/null 2>&1; then
    DEPLOY_ROWS=$(printf '%s' "$DEPLOY_ROWS" | jq -c --arg project "$id" \
      '. + [{project:$project,source:"bkt",run:"-",result:"unavailable (bkt not found)",
             head:"-",when:"-",contains:"-"}]')
    DEPLOY_UNAVAILABLE=$((DEPLOY_UNAVAILABLE + 1))
    continue
  fi
  workspace=${slug%%/*}
  repo=${slug#*/}
  if ! runs=$(fm_run_timed "$FM_STANDUP_NET_TIMEOUT" bkt pipeline list --json \
      --workspace "$workspace" --repo "$repo" --limit "$FM_STANDUP_DEPLOY_RUNS" 2>/dev/null); then
    DEPLOY_ROWS=$(printf '%s' "$DEPLOY_ROWS" | jq -c --arg project "$id" \
      '. + [{project:$project,source:"bkt",run:"-",result:"unavailable (deploy train read failed)",
             head:"-",when:"-",contains:"-"}]')
    DEPLOY_UNAVAILABLE=$((DEPLOY_UNAVAILABLE + 1))
    continue
  fi
  # The vendor payload's shape is not a contract we control, so read the few
  # plausible commit/result/branch paths and treat a miss as an unknown head. A
  # missing head can only withhold a deployed verdict, never grant one.
  ok_runs=$(printf '%s' "$runs" | jq -c '
      def arr: if type == "array" then . elif type == "object" and (.values? | type) == "array" then .values else [] end;
      def head_of: (.target.commit.hash? // .commit.hash? // .target.commit? // .commit? // null)
                   | if type == "string" then . else null end;
      def result_of: (.state.result.name? // .result? // .state.name? // "") | ascii_upcase;
      def branch_of: (.target.ref_name? // .target.branch? // .branch? // "");
      [ arr[]
        | {run:((.build_number? // .uuid? // "-") | tostring),
           result:result_of, branch:branch_of,
           head:(head_of // "-"),
           when:((.completed_on? // .created_on? // "-") | tostring)} ]' 2>/dev/null) || ok_runs='[]'
  succeeded=$(printf '%s' "$ok_runs" | jq -r --arg b "${branch#origin/}" \
    '[ .[] | select(.result == "SUCCESSFUL") | select(.branch == "" or .branch == $b) ] | .[] | .head' 2>/dev/null)
  heads=""
  while IFS= read -r h; do
    [ -n "$h" ] && [ "$h" != "-" ] || continue
    git -C "$path" rev-parse --verify -q "$h^{commit}" >/dev/null 2>&1 || continue
    heads="$heads $h"
  done <<EOF
$succeeded
EOF
  DEPLOY_ROWS=$(printf '%s\n%s' "$DEPLOY_ROWS" "$ok_runs" | jq -sc \
    --arg project "$id" --arg heads "$heads" \
    '($heads | split(" ")) as $readable
     | .[0] + [ .[1][]
                | . as $run
                | {project:$project,source:"bkt",run:$run.run,result:$run.result,
                   head:$run.head,when:$run.when,
                   contains:(if ($readable | index($run.head)) then "readable"
                             else "head not in the local copy" end)} ]')
  if [ -z "${heads// /}" ]; then
    DEPLOY_UNAVAILABLE=$((DEPLOY_UNAVAILABLE + 1))
    continue
  fi
  # Containment is proven against EVERY successful head, never inferred from run
  # order, so a stopped or superseded train never carries credit for work only a
  # later successful train shipped.
  contained='[]'
  for c in $(printf '%s' "$MERGE_ROWS" | jq -r --arg p "$id" '.[] | select(.project == $p) | .commit'); do
    for h in $heads; do
      if git -C "$path" merge-base --is-ancestor "$c" "$h" 2>/dev/null; then
        contained=$(printf '%s' "$contained" | jq -c --arg c "$c" '. + [$c]')
        break
      fi
    done
  done
  MERGE_ROWS=$(printf '%s' "$MERGE_ROWS" | jq -c --arg project "$id" --argjson contained "$contained" \
    'map(. as $row
         | if $row.project == $project
           then .deployed = (if ($contained | index($row.commit)) then "yes" else "no" end)
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

if [ -f "$SECONDMATES" ] && [ ! -L "$SECONDMATES" ]; then
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
               | {pr:.url, merged_at:.mergedAt, title:(.title[:90])} ]') || rows=""
        fi
        ;;
      bitbucket)
        if command -v bkt >/dev/null 2>&1; then
          rows=$(fm_run_timed "$FM_STANDUP_NET_TIMEOUT" \
            bkt pr list --json --state MERGED --limit "$FM_STANDUP_FORGE_PRS" \
            --workspace "${slug%%/*}" --repo "${slug#*/}" 2>/dev/null \
            | jq -c --arg since "$SINCE" --arg slug "$slug" '
              def arr: if type == "array" then . elif type == "object" and (.values? | type) == "array" then .values else [] end;
              [ arr[]
                | {pr:((.links.html.href? // ("https://bitbucket.org/" + $slug + "/pull-requests/" + ((.id // "") | tostring)))),
                   merged_at:((.updated_on? // .closed_on? // "") | tostring),
                   title:(((.title // "-") | tostring)[:90])}
                | select(.merged_at >= $since) ]') || rows=""
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
  --arg only "$ONLY_PROJECT" '
  ($merges | sort_by(.when) | reverse) as $merges_sorted
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
        (if $undated > 0 then {surface:("closed records carrying no close date, so they cannot be placed in any window: \($undated)"), reveal:"add a close date to those backlog rows"} else empty end),
        (if $include_deploy == 1 and $deploy_gaps > 0 then {surface:("projects with no usable deployed head: \($deploy_gaps); their merges stay unconfirmed, never deployed"), reveal:"see deploys[].result"} else empty end),
        (if $include_forge == 1 and $forge_gaps > 0 then {surface:("projects whose merged pull requests could not be read: \($forge_gaps)"), reveal:"check the forge credentials"} else empty end),
        (if $include_deploy == 1 then empty else {surface:"deploy evidence; every merge stays unconfirmed", reveal:"--include-deploy"} end),
        (if $include_forge == 1 then empty else {surface:"merged pull requests from the forge", reveal:"--include-forge"} end),
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
