# shellcheck shell=bash
# Shared quota-axi compatibility floor for the bootstrap diagnostic.
# Usage: . bin/fm-quota-axi-lib.sh
#
# 0.1.16 is the floor because it is the first build that reports each provider's
# credential sources independently and exposes Grok `state.authStatus`. Without
# those fields a dispatch candidate cannot be checked against the authentication
# surface it actually uses, which is how one harness's expired CLI token used to
# produce a captain-facing sign-out claim for a candidate that never read it.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns a failing check into the operator-facing MISSING diagnostic, which is
# what keeps an older build from reaching a dispatch intake at all.

FM_QUOTA_AXI_MIN=0.1.16
# The bound every caller of the version probe uses, owned here beside the floor
# it guards: a wedged `quota-axi --version` must surface as the MISSING
# diagnostic rather than stalling the startup check that reports it.
# FM_QUOTA_AXI_VERSION_TIMEOUT overrides the default for a slow host, matching
# FM_CREW_STATE_NM_TIMEOUT and FM_BEARINGS_PR_TIMEOUT. A non-positive or
# non-numeric value falls back to the default rather than failing the probe: a
# bad override must not report a healthy install as MISSING.
# shellcheck disable=SC2034 # Read by sourcing callers, not by this file.
FM_QUOTA_AXI_VERSION_TIMEOUT=${FM_QUOTA_AXI_VERSION_TIMEOUT:-10}
case "$FM_QUOTA_AXI_VERSION_TIMEOUT" in ''|*[!0-9]*|0) FM_QUOTA_AXI_VERSION_TIMEOUT=10 ;; esac
FM_QUOTA_AXI_LIB_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_QUOTA_AXI_LIB_DIR/fm-timeout-lib.sh"

fm_quota_axi_compatible() {
  local timeout=${1:-} output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -n "$timeout" ]; then
    case "$timeout" in
      ''|*[!0-9]*|0) return 1 ;;
    esac
    output=$(fm_run_timed "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
  else
    output=$(quota-axi --version 2>/dev/null </dev/null) || return 1
  fi
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}
