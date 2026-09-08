#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Shared parser for data/secondmates.md record SYNTAX. The supported routing
# table contract is owned by .agents/skills/secondmate-provisioning/SKILL.md;
# this library only turns one parser-compatible row into fields and says whether
# the row is well formed. Reading a registry file, resolving a home, and
# validating a route are other owners' jobs.
#
# Summary text and scope text are natural language and may contain parentheses
# and semicolons, so field boundaries are anchored to the suffix markers rather
# than to the first incidental punctuation.

# The one wording every caller uses when a well formed row is refused because it
# places its secondmate on another host. A reader on this home cannot answer a
# remote row's local questions, and saying so is not the same as "malformed row"
# or "no row at all", so the distinction is named here rather than re-invented.
SECONDMATE_REGISTRY_REMOTE_REFUSAL='registered on another host: a remote secondmate row is not supported by this home'
# The companion wording for a row this parser cannot read at all. What a valid
# row looks like is this file's knowledge, so the message that names it belongs
# here too rather than in each caller that has to report the refusal.
SECONDMATE_REGISTRY_MALFORMED_REFUSAL='registered by a row this parser cannot read: expected (home: ...; scope: ...; projects: ...; added YYYY-MM-DD)'

SECONDMATE_REGISTRY_ID=
SECONDMATE_REGISTRY_SUMMARY=
SECONDMATE_REGISTRY_HOST=
SECONDMATE_REGISTRY_ROOT=
SECONDMATE_REGISTRY_HOME=
SECONDMATE_REGISTRY_SCOPE=
SECONDMATE_REGISTRY_PROJECTS=
SECONDMATE_REGISTRY_ADDED=
SECONDMATE_REGISTRY_REMOTE=0
SECONDMATE_REGISTRY_REMOTE_REFUSAL="remote secondmate rows are parser-only tolerance; local home resolution is unsupported"

secondmate_registry_remote_refusal() {
  printf '%s\n' "$SECONDMATE_REGISTRY_REMOTE_REFUSAL"
}

secondmate_registry_parse_line() {
  local line=$1
  local local_re='^- ([A-Za-z0-9._-]+) - (.+) \(home:[[:space:]]*([^;)]*);[[:space:]]*scope:[[:space:]]*(.*);[[:space:]]*projects:[[:space:]]*([^;)]*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'
  local remote_re='^- ([A-Za-z0-9._-]+) - (.+) \(host:[[:space:]]*([^;)]*);[[:space:]]*root:[[:space:]]*([^;)]*);[[:space:]]*home:[[:space:]]*([^;)]*);[[:space:]]*scope:[[:space:]]*(.*);[[:space:]]*projects:[[:space:]]*([^;)]*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'
  SECONDMATE_REGISTRY_ID=
  SECONDMATE_REGISTRY_SUMMARY=
  SECONDMATE_REGISTRY_HOST=
  SECONDMATE_REGISTRY_ROOT=
  SECONDMATE_REGISTRY_HOME=
  SECONDMATE_REGISTRY_SCOPE=
  SECONDMATE_REGISTRY_PROJECTS=
  SECONDMATE_REGISTRY_ADDED=
  SECONDMATE_REGISTRY_REMOTE=0
  # Parse the legacy local form first so summary prose that happens to mention
  # remote field names cannot change an existing route's placement semantics.
  if [[ "$line" =~ $local_re ]]; then
    SECONDMATE_REGISTRY_ID=${BASH_REMATCH[1]}
    SECONDMATE_REGISTRY_SUMMARY=${BASH_REMATCH[2]}
    SECONDMATE_REGISTRY_HOME=${BASH_REMATCH[3]}
    SECONDMATE_REGISTRY_SCOPE=${BASH_REMATCH[4]}
    SECONDMATE_REGISTRY_PROJECTS=${BASH_REMATCH[5]}
    SECONDMATE_REGISTRY_ADDED=${BASH_REMATCH[6]}
  elif [[ "$line" =~ $remote_re ]]; then
    SECONDMATE_REGISTRY_ID=${BASH_REMATCH[1]}
    SECONDMATE_REGISTRY_SUMMARY=${BASH_REMATCH[2]}
    SECONDMATE_REGISTRY_HOST=${BASH_REMATCH[3]}
    SECONDMATE_REGISTRY_ROOT=${BASH_REMATCH[4]}
    SECONDMATE_REGISTRY_HOME=${BASH_REMATCH[5]}
    SECONDMATE_REGISTRY_SCOPE=${BASH_REMATCH[6]}
    SECONDMATE_REGISTRY_PROJECTS=${BASH_REMATCH[7]}
    SECONDMATE_REGISTRY_ADDED=${BASH_REMATCH[8]}
    SECONDMATE_REGISTRY_REMOTE=1
  else
    return 1
  fi
  [ -n "$SECONDMATE_REGISTRY_HOME" ] || return 1
  [ -n "$SECONDMATE_REGISTRY_SCOPE" ] || return 1
  if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
    [ -n "$SECONDMATE_REGISTRY_HOST" ] || return 1
    [ -n "$SECONDMATE_REGISTRY_ROOT" ] || return 1
  fi
  return 0
}
