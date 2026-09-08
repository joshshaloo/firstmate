#!/usr/bin/env bash
# fm-ci-budget-guard.sh - fail a CI timing artifact when a test lane exceeds
# the documented fraction of its GitHub Actions timeout budget.
#
# Usage: fm-ci-budget-guard.sh <timing-json> [timeout-minutes]
#
# The fraction is owned by bin/fm-test-run.sh and read through
# `bin/fm-test-run.sh --ci-budget-fraction`, so workflow jobs do not carry a
# second copy. The per-job budget is owned by the workflow's own
# `timeout-minutes`: when the argument is omitted the guard resolves it from
# the running job ($GITHUB_JOB) in the workflow file ($GITHUB_WORKFLOW_REF), so
# a workflow job never spells its timeout twice. The explicit argument exists
# for local runs outside GitHub Actions. The timing JSON is the artifact
# emitted by bin/fm-test-run.sh.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-ci-budget-guard: %s\n' "$*" >&2
  exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage; exit 2; }

# Resolve the caller-supplied timing path before cd, so relative paths stay
# relative to the caller's directory rather than the repo root.
TIMING_JSON=$1
case "$TIMING_JSON" in
  /*) ;;
  *) TIMING_JSON="$PWD/$TIMING_JSON" ;;
esac
TIMEOUT_MINUTES=${2:-}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

[ -f "$TIMING_JSON" ] || die "timing JSON not found: $TIMING_JSON"

workflow_file() {
  local ref=${GITHUB_WORKFLOW_REF:-} path
  [ -n "$ref" ] || return 1
  path=${ref%%@*}
  case "$path" in
    */.github/*) path=".github/${path#*/.github/}" ;;
    *) return 1 ;;
  esac
  [ -f "$path" ] || return 1
  printf '%s\n' "$path"
}

job_timeout_minutes() {
  local workflow=$1 job=$2
  awk -v job="$job" '
    $0 ~ "^  " job ":[[:space:]]*$" { in_job = 1; next }
    in_job && /^  [^ ]/ { in_job = 0 }
    in_job && /^    timeout-minutes:[[:space:]]*[0-9]+[[:space:]]*$/ {
      value = $0
      sub(/^[^:]*:[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      print value
      exit
    }
  ' "$workflow"
}

if [ -z "$TIMEOUT_MINUTES" ]; then
  JOB=${GITHUB_JOB:-}
  [ -n "$JOB" ] \
    || die "timeout-minutes omitted and GITHUB_JOB is unset; pass it explicitly outside GitHub Actions"
  WORKFLOW=$(workflow_file) \
    || die "timeout-minutes omitted and the workflow file could not be resolved from GITHUB_WORKFLOW_REF"
  TIMEOUT_MINUTES=$(job_timeout_minutes "$WORKFLOW" "$JOB")
  [ -n "$TIMEOUT_MINUTES" ] \
    || die "job '$JOB' has no timeout-minutes in $WORKFLOW; every guarded job must declare one"
fi

case "$TIMEOUT_MINUTES" in
  ''|*[!0-9]*) die "timeout-minutes must be an integer" ;;
esac
[ "$TIMEOUT_MINUTES" -gt 0 ] || die "timeout-minutes must be > 0"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

FRACTION=$(bin/fm-test-run.sh --ci-budget-fraction)
python3 - "$TIMING_JSON" "$TIMEOUT_MINUTES" "$FRACTION" <<'PY'
import json, math, sys
from fractions import Fraction
from pathlib import Path

path = Path(sys.argv[1])
timeout_minutes = int(sys.argv[2])
fraction = Fraction(sys.argv[3])
if fraction <= 0 or fraction > 1:
    raise SystemExit(f"fm-ci-budget-guard: invalid budget fraction: {fraction}")

doc = json.loads(path.read_text(encoding="utf-8"))
summary = doc.get("summary") or {}
duration_ms = int(summary.get("duration_ms") or 0)
threshold_ms = math.floor(timeout_minutes * 60_000 * fraction.numerator / fraction.denominator)
selection = doc.get("selection") or path.name
if duration_ms > threshold_ms:
    print(
        f"::error::CI timing guard failed for {selection}: "
        f"duration_ms={duration_ms} exceeds {fraction} of {timeout_minutes}m budget "
        f"(threshold_ms={threshold_ms})"
    )
    raise SystemExit(1)
print(
    f"FM_CI_BUDGET ok selection={selection} duration_ms={duration_ms} "
    f"threshold_ms={threshold_ms} fraction={fraction} timeout_minutes={timeout_minutes}"
)
PY
