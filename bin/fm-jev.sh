#!/usr/bin/env bash
# Ask Jev one System One request of typed questions and print the typed answers.
# Usage: fm-jev.sh --state <file|-> --questions <file|-> [--model <id>] [--timeout <seconds>]
#
# Jev is a System One decision model: it answers typed questions (Choice, Noul,
# Score) over a state and returns calibrated probabilities. It does not generate
# text, use tools, or reason in steps. When a bounded, closed-outcome decision
# should go here instead of to a reasoning model is owned by
# .agents/skills/jev-routing/SKILL.md, not by this script.
#
# This helper is deliberately a single request in, one JSON line out. It holds no
# policy: it never compares a probability to a threshold and never decides
# anything. The caller owns its own thresholds in its own code.
#
# Fail-closed contract. Every refusal exits non-zero with one diagnostic on
# stderr and writes NOTHING to stdout, so an absent answer can never be mistaken
# for a judgment. Absence has exactly one meaning: no answer available, use the
# reasoning path. Refusals are the credential file being absent, not private, or
# carrying no key; a failed or non-2xx request; a malformed response; and a
# response missing any question that was asked.
#
# Secrets and payloads never reach a command argument: the key is written to a
# mode-0600 header file that curl reads with -H @file, and the request body is
# posted from a private temp file with --data-binary @file.
#
# The credential file is $HOME/.config/firstmate/openrouter.env (mode 0600),
# alongside the same directory's bkt.env. It is parsed, never sourced, so a
# corrupted credential file cannot execute. FM_JEV_ENV_FILE overrides the path
# for tests. There is deliberately no way to pass a key as an argument or an
# environment variable.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

DEFAULT_MODEL=jev-1.13
DEFAULT_BASE_URL=https://openrouter.ai/api
DEFAULT_TIMEOUT=20
MAX_RETRY_DELAY=30

usage() {
  cat <<'EOF'
Usage: fm-jev.sh --state <file|-> --questions <file|-> [--model <id>] [--timeout <seconds>]

Ask Jev one request of typed questions over one state and print the typed
answers as a single JSON line on stdout.

Inputs are files, or "-" for stdin (at most one input may be "-"), so no state,
question, or credential ever appears in a command argument.

  --state <file|->      a JSON value: the state every question is asked over.
                        Plain text is just a JSON string, e.g. jq -Rs . < notes.txt
  --questions <file|->  a non-empty JSON object of question id -> question.
                        Question ids are for the caller's code and are never sent
                        to the model, so put the full meaning in the question.
  --model <id>          default jev-1.13. Pin a version when thresholds have been
                        calibrated against it; an alias can move under you.
  --timeout <seconds>   per-attempt timeout, 1-300, default 20.

Output, on success only, one compact JSON line:

  {"model":"<versioned model that answered>","answers":{...},"usage":{...}}

The model field is the version that actually answered, recorded so a decision can
be traced to a model version and so a version change can retrigger calibration.

Contract:

  - Fail closed and loud. An absent key file, a failed call, a non-2xx status, a
    malformed response, or a response missing any question that was asked exits
    non-zero with one diagnostic on stderr and prints no answer. A caller must
    never be able to mistake an absent answer for a judgment: absence means no
    answer available, use the reasoning path, and say so.
  - No policy here. This prints probabilities. Thresholds, weights, and the
    resulting decision stay in the caller's own code, where they can be read,
    changed, and tested without re-running inference.
  - One bounded attempt plus one retry on 429 or 5xx, honoring Retry-After.
  - The key is read only from $HOME/.config/firstmate/openrouter.env, which must
    be mode 0600. It is never accepted as an argument and never printed.

The request and answer shapes, the question types, and the Score-criteria-is-an-
array trap are owned by the typesafe-jev skill. When a decision belongs to Jev at
all is owned by .agents/skills/jev-routing/SKILL.md.

Exit status: 0 answered, 2 bad usage, 1 every fail-closed refusal.
EOF
}

die() {
  local code=$1
  shift
  printf 'fm-jev: %s\n' "$*" >&2
  exit "$code"
}

STATE_PATH=
QUESTIONS_PATH=
MODEL=$DEFAULT_MODEL
TIMEOUT=$DEFAULT_TIMEOUT

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --state) [ "$#" -ge 2 ] || die 2 "--state needs a file or -"; STATE_PATH=$2; shift 2 ;;
    --questions) [ "$#" -ge 2 ] || die 2 "--questions needs a file or -"; QUESTIONS_PATH=$2; shift 2 ;;
    --model) [ "$#" -ge 2 ] || die 2 "--model needs a model id"; MODEL=$2; shift 2 ;;
    --timeout) [ "$#" -ge 2 ] || die 2 "--timeout needs seconds"; TIMEOUT=$2; shift 2 ;;
    *) die 2 "unknown argument '$1' (see --help)" ;;
  esac
done

[ -n "$STATE_PATH" ] || die 2 "--state is required (see --help)"
[ -n "$QUESTIONS_PATH" ] || die 2 "--questions is required (see --help)"
[ "$STATE_PATH" != - ] || [ "$QUESTIONS_PATH" != - ] \
  || die 2 "only one of --state and --questions may read stdin"
case "$MODEL" in
  ''|*[!A-Za-z0-9._/~-]*) die 2 "--model must be a plain model id" ;;
esac
case "$TIMEOUT" in
  ''|*[!0-9]*) die 2 "--timeout must be a whole number of seconds" ;;
esac
[ "$TIMEOUT" -ge 1 ] && [ "$TIMEOUT" -le 300 ] || die 2 "--timeout must be 1-300 seconds"

command -v curl >/dev/null 2>&1 || die 1 "curl is not installed"
command -v jq >/dev/null 2>&1 || die 1 "jq is not installed"

read_input() {
  local path=$1
  if [ "$path" = - ]; then
    cat
    return 0
  fi
  [ -f "$path" ] && [ -r "$path" ] || return 1
  cat -- "$path"
}

STATE=$(read_input "$STATE_PATH") || die 1 "state file is unreadable: $STATE_PATH"
QUESTIONS=$(read_input "$QUESTIONS_PATH") || die 1 "questions file is unreadable: $QUESTIONS_PATH"

printf '%s' "$STATE" | jq empty >/dev/null 2>&1 \
  || die 1 "state is not valid JSON (a plain-text state is a JSON string: jq -Rs .)"
printf '%s' "$QUESTIONS" | jq -e 'type == "object" and length > 0' >/dev/null 2>&1 \
  || die 1 "questions must be a non-empty JSON object of question id -> question"

# --- credentials ------------------------------------------------------------
#
# Parsed rather than sourced, and stricter than the lenient X-mode reader in
# fm-x-lib.sh: there, an absent file or key means "X mode is off" and succeeds;
# here every one of those is a refusal, because a caller that cannot reach Jev
# must fall back to the reasoning path rather than proceed without an answer.
env_value() {
  local key=$1 file=$2 line val
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}
  val=${val%"${val##*[![:space:]]}"}
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

[ -n "${HOME:-}" ] || die 1 "HOME is not set, so the credential file cannot be located"
ENV_FILE=${FM_JEV_ENV_FILE:-$HOME/.config/firstmate/openrouter.env}
[ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] \
  || die 1 "credential file is absent: $ENV_FILE"
[ "$(fm_pr_file_mode "$ENV_FILE")" = 600 ] \
  || die 1 "credential file must be mode 0600: $ENV_FILE"
API_KEY=$(env_value OPENROUTER_API_KEY "$ENV_FILE")
[ -n "$API_KEY" ] || die 1 "OPENROUTER_API_KEY is absent from $ENV_FILE"
BASE_URL=$(env_value TYPESAFE_BASE_URL "$ENV_FILE")
[ -n "$BASE_URL" ] || BASE_URL=$DEFAULT_BASE_URL
BASE_URL=${BASE_URL%/}
case "$BASE_URL" in
  https://*) ;;
  *) die 1 "TYPESAFE_BASE_URL in $ENV_FILE must be an https URL" ;;
esac
case "$BASE_URL$API_KEY" in
  *[[:space:]]*) die 1 "credential file holds a malformed key or base URL: $ENV_FILE" ;;
esac
ENDPOINT="$BASE_URL/v1/systemone"

# --- request ----------------------------------------------------------------

TMPD=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-jev.XXXXXX") || die 1 "cannot create a private temp directory"
trap 'rm -rf -- "$TMPD"' EXIT HUP INT TERM

AUTH="$TMPD/auth"
PAYLOAD="$TMPD/payload.json"
BODY="$TMPD/body.json"
HEADERS="$TMPD/headers"

printf 'Authorization: Bearer %s\n' "$API_KEY" > "$AUTH" || die 1 "cannot stage the request credentials"
API_KEY=

jq -cn --arg model "$MODEL" \
  --argjson state "$STATE" \
  --argjson questions "$QUESTIONS" \
  '{model: $model, state: $state, questions: $questions}' > "$PAYLOAD" \
  || die 1 "cannot build the request payload"

# Retry-After may be seconds or an HTTP date; only the seconds form is honored,
# and anything else falls back to the one-second default rather than parsing a
# date format this helper cannot verify.
retry_delay() {
  local raw
  raw=$(grep -i '^[[:space:]]*retry-after:' "$HEADERS" 2>/dev/null | tail -n1 | cut -d: -f2-)
  raw=${raw//[[:space:]]/}
  case "$raw" in
    ''|*[!0-9]*) printf '1\n'; return 0 ;;
  esac
  [ "$raw" -le "$MAX_RETRY_DELAY" ] 2>/dev/null || raw=$MAX_RETRY_DELAY
  printf '%s\n' "$raw"
}

attempt() {
  : > "$BODY"
  : > "$HEADERS"
  curl -sS -m "$TIMEOUT" -o "$BODY" -D "$HEADERS" -w '%{http_code}' \
    -X POST \
    -H "@$AUTH" \
    -H 'Content-Type: application/json' \
    --data-binary "@$PAYLOAD" \
    "$ENDPOINT" 2>/dev/null
}

CODE=$(attempt); CURL_RC=$?
if [ "$CURL_RC" = 0 ]; then
  case "$CODE" in
    429|5[0-9][0-9])
      sleep "$(retry_delay)"
      CODE=$(attempt); CURL_RC=$?
      ;;
  esac
fi

[ "$CURL_RC" = 0 ] || die 1 "request to $ENDPOINT failed (curl exit $CURL_RC)"
case "$CODE" in
  2[0-9][0-9]) ;;
  *) die 1 "Jev refused the request with HTTP ${CODE:-000}" ;;
esac

# --- response ---------------------------------------------------------------

jq -e 'type == "object"' "$BODY" >/dev/null 2>&1 \
  || die 1 "Jev returned a malformed response that is not a JSON object"
jq -e '(.model | type) == "string" and ((.model | length) > 0)' "$BODY" >/dev/null 2>&1 \
  || die 1 "Jev response carries no model field, so an answer could not be traced to a version"
jq -e '.answers | type == "object"' "$BODY" >/dev/null 2>&1 \
  || die 1 "Jev response carries no answers object"

MISSING=$(printf '%s' "$QUESTIONS" | jq -r --slurpfile response "$BODY" \
  '($response[0].answers // {}) as $answers
   | [keys_unsorted[] as $id | select($answers | has($id) | not) | $id] | join(", ")') \
  || die 1 "cannot check the Jev response against the questions asked"
[ -z "$MISSING" ] \
  || die 1 "Jev response is missing an answer for: $MISSING"

jq -c '{model: .model, answers: .answers, usage: (.usage // null)}' "$BODY" \
  || die 1 "cannot render the Jev answers"
