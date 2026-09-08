#!/usr/bin/env bash
# fm-ci-budget-guard.sh - fail a CI timing artifact when a test lane exceeds
# the documented fraction of its GitHub Actions timeout budget.
#
# Usage: fm-ci-budget-guard.sh <timing-json> <timeout-minutes>
#
# The fraction is owned by bin/fm-test-run.sh and read through
# `bin/fm-test-run.sh --ci-budget-fraction`, so workflow jobs do not carry a
# second copy. The timing JSON is the artifact emitted by bin/fm-test-run.sh.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

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

[ "$#" -eq 2 ] || { usage; exit 2; }
TIMING_JSON=$1
TIMEOUT_MINUTES=$2
[ -f "$TIMING_JSON" ] || die "timing JSON not found: $TIMING_JSON"
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
