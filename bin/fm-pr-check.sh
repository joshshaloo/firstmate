#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url>, the forge's
# exact pr_head=<sha> when available, and landing_branch=<branch> when the forge
# exposes the PR base branch, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL, a GitLab merge request URL, and a Bitbucket Cloud
# pull request URL are accepted, including a merge request on a self-hosted
# GitLab instance.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm forge watches whose standard CLI or authenticated context is
# absent. The poll is silent on ordinary forge read errors by design, so arming
# is the one point where a missing local requirement can be reported instead of
# watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi
if [ "$PROVIDER" = bitbucket ]; then
  if ! command -v bkt >/dev/null 2>&1; then
    echo "error: watching a Bitbucket pull request requires bkt on PATH" >&2
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: watching a Bitbucket pull request requires jq on PATH" >&2
    exit 1
  fi
  if ! fm_pr_bkt_auth_ready; then
    echo "error: watching a Bitbucket pull request requires $FM_PR_BKT_AUTH_MISSING in the environment or ~/.config/firstmate/bkt.env" >&2
    exit 1
  fi
fi

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head and landing_branch are recorded when the forge's CLI can supply them.
# gh exposes both the head commit and base branch as selectable fields; Bitbucket
# Cloud exposes an abbreviated PR source hash, so the full commit hash is read in
# a second authenticated request before arming. Plain glab exposes equivalent
# data only inside its JSON output, which would need a JSON processor firstmate
# did not require when GitLab watching was added, so a GitLab task records
# neither field. Consumers treat both as optional for GitHub and GitLab, while a
# Bitbucket task must record pr_head because its CI poll is keyed to that source
# commit.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
LANDING_BRANCH=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
  if REMOTE_BASE=$(cd "$WT" && gh pr view "$URL" --json baseRefName -q .baseRefName 2>/dev/null) \
    && fm_pr_branch_name_valid "$REMOTE_BASE"; then
    LANDING_BRANCH=$REMOTE_BASE
  fi
elif [ "$PROVIDER" = bitbucket ]; then
  WORKSPACE=${PROJECT_PATH%%/*}
  REPO=${PROJECT_PATH#*/}
  PR_JSON=$(bkt api "/repositories/$WORKSPACE/$REPO/pullrequests/$NUMBER" --json 2>/dev/null) || {
    echo "error: Bitbucket pull request details could not be read" >&2
    exit 1
  }
  REMOTE_SHORT_HEAD=$(printf '%s' "$PR_JSON" | jq -r '.source.commit.hash // empty' 2>/dev/null) || {
    echo "error: Bitbucket pull request details could not be parsed" >&2
    exit 1
  }
  REMOTE_BASE=$(printf '%s' "$PR_JSON" | jq -r '.destination.branch.name // empty' 2>/dev/null) || {
    echo "error: Bitbucket pull request details could not be parsed" >&2
    exit 1
  }
  [ -n "$REMOTE_SHORT_HEAD" ] && [ -n "$REMOTE_BASE" ] || {
    echo "error: Bitbucket pull request details did not include a head and target branch" >&2
    exit 1
  }
  COMMIT_JSON=$(bkt api "/repositories/$WORKSPACE/$REPO/commit/$REMOTE_SHORT_HEAD" --json 2>/dev/null) || {
    echo "error: Bitbucket pull request head commit could not be read" >&2
    exit 1
  }
  REMOTE_HEAD=$(printf '%s' "$COMMIT_JSON" | jq -r '.hash // empty' 2>/dev/null) || {
    echo "error: Bitbucket pull request head commit could not be parsed" >&2
    exit 1
  }
  fm_pr_head_valid "$REMOTE_HEAD" || {
    echo "error: Bitbucket pull request head commit was not a full hash" >&2
    exit 1
  }
  fm_pr_branch_name_valid "$REMOTE_BASE" || {
    echo "error: Bitbucket pull request target branch was not a valid branch name" >&2
    exit 1
  }
  PR_HEAD=$REMOTE_HEAD
  LANDING_BRANCH=$REMOTE_BASE
fi

META_TMP=
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*|landing_branch=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
[ -z "$LANDING_BRANCH" ] || printf 'landing_branch=%s\n' "$LANDING_BRANCH" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"
