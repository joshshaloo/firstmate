#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one terminal or actionable line for a supported PR or MR and
# stays silent on ordinary forge read errors, so a failed lookup can never be
# read as a merge or passing check. Local missing Bitbucket requirements are
# reported as one-line actionable output because Bitbucket authentication is
# environment-backed and otherwise looks like a permanent silent skip.
# The provider-tagged identity is data in the sidecar and is never interpolated
# into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI: gh for GitHub, glab for
# GitLab, and bkt for Bitbucket Cloud.
set -u
LC_ALL=C
export LC_ALL

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

bitbucket_segment_valid() {
  local segment=${1-}
  [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 100 ] || return 1
  case "$segment" in
    .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

bkt_env_load() {
  local env_file
  [ -n "${BKT_HOST:-}" ] && [ -n "${BKT_USERNAME:-}" ] \
    && [ -n "${BKT_TOKEN:-}" ] && [ -n "${BKT_AUTH_METHOD:-}" ] && return 0
  [ -n "${HOME:-}" ] || return 0
  env_file=$HOME/.config/firstmate/bkt.env
  [ -f "$env_file" ] && [ ! -L "$env_file" ] || return 0
  [ "$(file_mode "$env_file")" = 600 ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
}

bkt_auth_ready() {
  local missing='' var
  bkt_env_load || return 1
  for var in BKT_USERNAME BKT_TOKEN; do
    if [ -z "${!var:-}" ]; then
      missing="$missing${missing:+, }$var"
    fi
  done
  if [ "${BKT_HOST:-}" != https://bitbucket.org ]; then
    missing="$missing${missing:+, }BKT_HOST=https://bitbucket.org"
  fi
  if [ "${BKT_AUTH_METHOD:-}" != basic ]; then
    missing="$missing${missing:+, }BKT_AUTH_METHOD=basic"
  fi
  [ -z "$missing" ] && return 0
  printf 'bitbucket-auth-missing: %s\n' "$missing"
  return 1
}

single_line() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | cut -c 1-200
}

state_failed() {
  case "$1" in
    FAILED|ERROR|STOPPED|EXPIRED|CANCELLED|CANCELED) return 0 ;;
    *) return 1 ;;
  esac
}

state_successful() {
  case "$1" in
    SUCCESSFUL|SUCCESS|PASSED) return 0 ;;
    *) return 1 ;;
  esac
}

poll_bitbucket_checks() {
  local workspace=$1 repo=$2 number=$3 head=$4 short_head=$5 source_branch=$6 checks_json statuses
  local seen=0 pending=0 state key name label
  checks_json=$(bkt pr checks "$number" --json --workspace "$workspace" --repo "$repo" 2>/dev/null) || return 0
  statuses=$(printf '%s' "$checks_json" \
    | jq -r '.statuses[]? | [(.state // ""), (.key // ""), (.name // "")] | @tsv' 2>/dev/null) || return 0
  while IFS=$'\t' read -r state key name; do
    [ -n "$state$key$name" ] || continue
    seen=1
    state=$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')
    label=$(single_line "${name:-${key:-build}}")
    if state_failed "$state"; then
      printf 'red: %s %s\n' "$label" "$state"
      return 0
    fi
    if ! state_successful "$state"; then
      pending=1
    fi
  done <<EOF
$statuses
EOF
  if [ "$seen" -eq 1 ] && [ "$pending" -eq 0 ]; then
    printf '%s\n' green
    return 0
  fi
  poll_bitbucket_pipeline "$workspace" "$repo" "$source_branch"
}

poll_bitbucket_pipeline() {
  local workspace=$1 repo=$2 source_branch=$3 pipelines_json row
  local build result stage name label
  [ -n "$source_branch" ] || return 0
  pipelines_json=$(bkt pipeline list --json --workspace "$workspace" --repo "$repo" --limit 20 2>/dev/null) || return 0
  row=$(printf '%s' "$pipelines_json" | jq -r --arg branch "$source_branch" '
    (.pipelines // .values // [])[]?
    | select(((.target.ref.name? // .target.ref_name? // "") == $branch))
    | [(.build_number // .uuid // ""),
       (.state.result.name // ""),
       (.state.stage.name // ""),
       (.state.name // "")]
    | @tsv
  ' 2>/dev/null | head -1) || return 0
  [ -n "$row" ] || return 0
  IFS=$'\t' read -r build result stage name <<EOF
$row
EOF
  result=$(printf '%s' "$result" | tr '[:lower:]' '[:upper:]')
  stage=$(printf '%s' "$stage" | tr '[:lower:]' '[:upper:]')
  name=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
  label=$(single_line "pipeline ${build:-for $source_branch}")
  if state_failed "$result" || state_failed "$stage" || state_failed "$name"; then
    printf 'red: %s %s\n' "$label" "${result:-${stage:-$name}}"
  elif state_successful "$result"; then
    printf '%s\n' green
  fi
}

poll_bitbucket() {
  local workspace=$1 repo=$2 number=$3 pr_json state short_head source_branch commit_json head
  command -v bkt >/dev/null 2>&1 || { printf '%s\n' 'bitbucket-missing: bkt on PATH'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '%s\n' 'bitbucket-missing: jq on PATH'; return 0; }
  bkt_auth_ready || return 0
  pr_json=$(bkt api "/repositories/$workspace/$repo/pullrequests/$number" --json 2>/dev/null) || return 0
  state=$(printf '%s' "$pr_json" | jq -r '.state // empty' 2>/dev/null) || return 0
  case "$state" in
    MERGED) printf '%s\n' merged; return 0 ;;
    OPEN) ;;
    *) return 0 ;;
  esac
  short_head=$(printf '%s' "$pr_json" | jq -r '.source.commit.hash // empty' 2>/dev/null) || return 0
  source_branch=$(printf '%s' "$pr_json" | jq -r '.source.branch.name // empty' 2>/dev/null) || return 0
  [ -n "$short_head" ] || return 0
  commit_json=$(bkt api "/repositories/$workspace/$repo/commit/$short_head" --json 2>/dev/null) || return 0
  head=$(printf '%s' "$commit_json" | jq -r '.hash // empty' 2>/dev/null) || return 0
  [[ "$head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] || return 0
  case "$head" in
    "$short_head"*) ;;
    *) return 0 ;;
  esac
  poll_bitbucket_checks "$workspace" "$repo" "$number" "$head" "$short_head" "$source_branch"
}

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
    [ "$state" = MERGED ] && printf '%s\n' merged
    ;;
  bitbucket)
    [ "$host" = bitbucket.org ] || exit 0
    workspace=${path%%/*}
    repo=${path#*/}
    [ "$workspace" != "$path" ] || exit 0
    bitbucket_segment_valid "$workspace" || exit 0
    bitbucket_segment_valid "$repo" || exit 0
    [ "$url" = "https://bitbucket.org/$workspace/$repo/pull-requests/$number" ] || exit 0
    poll_bitbucket "$workspace" "$repo" "$number"
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
