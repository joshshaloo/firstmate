# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
# Compatible means tasks-axi --version reports 0.1.1 or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs (introduced in tasks-axi 0.2.2).
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.
# The --version probe runs through fm-timeout-lib.sh's bounded runner, so a
# present-but-hung tasks-axi is reported as incompatible rather than stalling
# every caller. FM_TASKS_AXI_VERSION_TIMEOUT overrides the 5s bound; blank,
# non-numeric, and 0 values fall back to it, because a zero bound is not a
# bound. On a timeout, fm_tasks_axi_version_parts returns 1 and leaves the
# concrete reason in FM_TASKS_AXI_VERSION_TIMEOUT_DIAGNOSTIC for callers that
# report remediation; a probe that returns normally clears it.

# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_TASKS_AXI_VERSION_TIMEOUT_DEFAULT=5
FM_TASKS_AXI_VERSION_TIMEOUT_DIAGNOSTIC=${FM_TASKS_AXI_VERSION_TIMEOUT_DIAGNOSTIC:-}
FM_TASKS_AXI_VERSION_PARTS=${FM_TASKS_AXI_VERSION_PARTS:-}

fm_tasks_axi_version_timeout() {
  local timeout=${FM_TASKS_AXI_VERSION_TIMEOUT:-$FM_TASKS_AXI_VERSION_TIMEOUT_DEFAULT}
  case "$timeout" in
    ''|*[!0-9]*|0) timeout=$FM_TASKS_AXI_VERSION_TIMEOUT_DEFAULT ;;
  esac
  printf '%s\n' "$timeout"
}

fm_tasks_axi_version_parts() {
  local output timeout rc
  FM_TASKS_AXI_VERSION_TIMEOUT_DIAGNOSTIC=
  FM_TASKS_AXI_VERSION_PARTS=
  command -v tasks-axi >/dev/null 2>&1 || return 1
  timeout=$(fm_tasks_axi_version_timeout)
  output=$(fm_run_timed "$timeout" tasks-axi --version 2>/dev/null </dev/null)
  rc=$?
  if [ "$rc" -eq 124 ]; then
    FM_TASKS_AXI_VERSION_TIMEOUT_DIAGNOSTIC="tasks-axi --version hung for ${timeout}s"
    return 1
  fi
  [ "$rc" -eq 0 ] || return 1
  FM_TASKS_AXI_VERSION_PARTS=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  printf '%s\n' "$FM_TASKS_AXI_VERSION_PARTS"
}

fm_tasks_axi_compatible() {
  local parts major minor patch rest
  fm_tasks_axi_version_parts >/dev/null || return 1
  parts=$FM_TASKS_AXI_VERSION_PARTS
  [ -n "$parts" ] || return 1
  major=${parts%% *}
  rest=${parts#* }
  minor=${rest%% *}
  patch=${rest##* }

  if [ "$major" -gt 0 ] ||
    { [ "$major" -eq 0 ] && [ "$minor" -gt 1 ]; } ||
    { [ "$major" -eq 0 ] && [ "$minor" -eq 1 ] && [ "$patch" -ge 1 ]; }; then
    fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
    return $?
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}
