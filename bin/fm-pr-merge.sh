#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= and
# landing_branch= through bin/fm-pr-check.sh, so teardown can verify landed work
# after squash merges and non-default target-branch merges.
# The full canonical GitHub or Bitbucket Cloud PR URL is parsed by
# bin/fm-pr-lib.sh and the derived owner/workspace, repository, and PR number are
# passed to the forge CLI as separate arguments.
#
# GitHub merge method defaults to --squash when the caller passes none of
# --squash, --merge, --rebase, or --method after the optional -- separator.
# Bitbucket Cloud merge strategy defaults to --strategy squash when the caller
# passes no --strategy after the optional -- separator. Extra args must not
# include repository selectors because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra forge merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still refuses GitLab until merge parity lands there.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" = gitlab ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

caller_has_bitbucket_strategy() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --strategy|--strategy=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|--workspace|--workspace=*|--project|--project=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
case "$PROVIDER" in
  github)
    if ! caller_has_merge_method "$@"; then
      merge_args=(--squash)
    fi
    gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
    ;;
  bitbucket)
    if ! command -v bkt >/dev/null 2>&1; then
      echo "error: merging a Bitbucket pull request requires bkt on PATH" >&2
      exit 1
    fi
    if ! fm_pr_bkt_auth_ready; then
      echo "error: merging a Bitbucket pull request requires $FM_PR_BKT_AUTH_MISSING in the environment or ~/.config/firstmate/bkt.env" >&2
      exit 1
    fi
    if ! caller_has_bitbucket_strategy "$@"; then
      merge_args=(--strategy squash)
    fi
    bkt pr merge "$PR_NUMBER" --workspace "$PR_OWNER" --repo "$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
    ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac
