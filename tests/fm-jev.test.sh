#!/usr/bin/env bash
# Behavioral coverage for bin/fm-jev.sh: the fail-closed contract (absent or
# non-private credential file, transport failure, non-2xx status, malformed
# response, and a response missing a question that was asked), the answered
# path that those refusals are measured against, and the secret-handling and
# retry guarantees. No network: curl is a PATH stub.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_set_base_path BASE_PATH jq
fm_test_tmproot TMP_ROOT fm-jev
JEV="$ROOT/bin/fm-jev.sh"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CURL_LOG="$TMP_ROOT/curl.log"
MODE_LOG="$TMP_ROOT/curl.modes"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Stand-in for curl's -o/-D/-w contract: record the invocation and the on-disk
# mode of every @file it was handed, write the configured body and headers, then
# print the configured status code.
[ -z "${FM_FAKE_CURL_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_CURL_LOG"
out=; hdr=; prev=
for a in "$@"; do
  case "$prev" in
    -o) out=$a ;;
    -D) hdr=$a ;;
  esac
  case "$a" in
    @*)
      f=${a#@}
      if [ -n "${FM_FAKE_CURL_MODE_LOG:-}" ] && [ -e "$f" ]; then
        mode=$(stat -c %a "$f" 2>/dev/null) || mode=$(stat -f %Lp "$f" 2>/dev/null)
        printf '%s %s\n' "$mode" "$f" >> "$FM_FAKE_CURL_MODE_LOG"
      fi
      ;;
  esac
  prev=$a
done
[ -z "$hdr" ] || printf 'HTTP/1.1 %s\r\n%s\r\n\r\n' "${FM_FAKE_CURL_CODE:-200}" "${FM_FAKE_CURL_HEADER:-}" > "$hdr"
[ -z "$out" ] || printf '%s' "${FM_FAKE_CURL_BODY:-}" > "$out"
[ -z "${FM_FAKE_CURL_FAIL:-}" ] || exit "$FM_FAKE_CURL_FAIL"
printf '%s' "${FM_FAKE_CURL_CODE:-200}"
SH
chmod +x "$FAKEBIN/curl"

ENV_FILE="$TMP_ROOT/openrouter.env"
printf 'OPENROUTER_API_KEY=sk-or-test-secret\nTYPESAFE_BASE_URL=https://openrouter.example.invalid/api\n' > "$ENV_FILE"
chmod 600 "$ENV_FILE"

STATE="$TMP_ROOT/state.json"
QUESTIONS="$TMP_ROOT/questions.json"
printf '%s\n' '{"summary":"the registry returned 500 for the pinned digest"}' > "$STATE"
printf '%s\n' '{"upstream":{"type":"noul","instructions":"Is this an external service failure?"},"urgency":{"type":"score","instructions":"How urgent?","criteria":["low","high"]}}' > "$QUESTIONS"

ANSWERED='{"model":"typesafe/jev-1.13-20260917","answers":{"upstream":{"type":"noul","noul":0.91},"urgency":{"type":"score","score":1.47}},"usage":{"cost":0.000027}}'

# run_jev <expected-exit> <label> [extra args...]
# Captures stdout and stderr separately so "printed no answer" is a real
# assertion about stdout rather than about combined output.
OUT=
ERR=
RC=0
run_jev() {
  local expected=$1 label=$2
  shift 2
  local outfile="$TMP_ROOT/stdout" errfile="$TMP_ROOT/stderr"
  RC=0
  PATH="$FAKEBIN:$BASE_PATH" \
  HOME="$TMP_ROOT/home" \
  FM_JEV_ENV_FILE="${FM_JEV_ENV_FILE_OVERRIDE-$ENV_FILE}" \
  FM_FAKE_CURL_LOG="$CURL_LOG" \
  FM_FAKE_CURL_MODE_LOG="$MODE_LOG" \
  FM_FAKE_CURL_CODE="${CODE-200}" \
  FM_FAKE_CURL_BODY="${BODY-$ANSWERED}" \
  FM_FAKE_CURL_HEADER="${HEADER-}" \
  FM_FAKE_CURL_FAIL="${FAIL-}" \
    "$JEV" --state "$STATE" --questions "$QUESTIONS" "$@" \
    > "$outfile" 2> "$errfile" || RC=$?
  OUT=$(cat "$outfile")
  ERR=$(cat "$errfile")
  expect_code "$expected" "$RC" "$label"
}

# assert_refused <label>: a fail-closed refusal names its requirement on stderr
# and puts nothing at all on stdout, so no caller can read an absent answer as
# a judgment.
assert_refused() {
  local label=$1
  [ -z "$OUT" ] || fail "$label: refused but still printed on stdout: $OUT"
  [ -n "$ERR" ] || fail "$label: refused with no diagnostic on stderr"
  assert_contains "$ERR" 'fm-jev:' "$label: diagnostic is not a fm-jev line"
  case "$ERR" in
    *sk-or-test-secret*) fail "$label: diagnostic leaked the API key" ;;
  esac
}

# --- the answered path ------------------------------------------------------

: > "$CURL_LOG"
: > "$MODE_LOG"
run_jev 0 'a well-formed request is answered'
assert_contains "$OUT" '"model":"typesafe/jev-1.13-20260917"' 'answered output records the responding model version'
assert_contains "$OUT" '"upstream"' 'answered output carries the first answer'
assert_contains "$OUT" '"urgency"' 'answered output carries the second answer'
assert_contains "$OUT" '"usage"' 'answered output carries usage for cost tracing'
[ "$(printf '%s' "$OUT" | wc -l)" = 0 ] || fail 'answered output is not a single JSON line'
pass 'a well-formed request prints the typed answers with the responding model version'

# The key reaches curl only through a header file, never through argv, and the
# payload reaches it only through a file, so neither is visible to ps.
CURL_ARGS=$(cat "$CURL_LOG")
assert_not_contains "$CURL_ARGS" 'sk-or-test-secret' 'the API key appeared in a curl argument'
assert_contains "$CURL_ARGS" '--data-binary @' 'the payload was not posted from a file'
assert_contains "$CURL_ARGS" 'https://openrouter.example.invalid/api/v1/systemone' 'the base URL from the credential file was not used'
pass 'the key and the payload never appear in a command argument'

# The mode the key header actually reached on disk, not the mode intended for
# it: the caller's umask decides that unless the script takes it back.
[ -s "$MODE_LOG" ] || fail 'the curl stub recorded no @file modes'
SAW_AUTH=0
while read -r MODE MODE_PATH; do
  [ "$MODE" = 600 ] || fail "a file handed to curl is not mode 0600: $MODE $MODE_PATH"
  case "$MODE_PATH" in */auth) SAW_AUTH=1 ;; esac
done < "$MODE_LOG"
[ "$SAW_AUTH" = 1 ] || fail 'the Authorization header file was never handed to curl'
pass 'the key header and the payload reach mode 0600 on disk'

# A state larger than the argv ceiling proves the state is staged as a file
# rather than passed to jq as an argument, where it would fail with E2BIG.
BIGSTATE="$TMP_ROOT/big-state.json"
{ printf '{"blob":"'; head -c 300000 /dev/zero | tr '\0' 'x'; printf '"}\n'; } > "$BIGSTATE"
RC=0
PATH="$FAKEBIN:$BASE_PATH" FM_JEV_ENV_FILE="$ENV_FILE" \
  FM_FAKE_CURL_CODE=200 FM_FAKE_CURL_BODY="$ANSWERED" \
  "$JEV" --state "$BIGSTATE" --questions "$QUESTIONS" \
  > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr" || RC=$?
expect_code 0 "$RC" 'a state larger than the argv ceiling is answered'
pass 'a state too large for a command argument is still sent'

# --- fail closed: credentials ----------------------------------------------

FM_JEV_ENV_FILE_OVERRIDE="$TMP_ROOT/nope.env" run_jev 1 'an absent credential file refuses'
assert_refused 'absent credential file'
assert_contains "$ERR" 'credential file is absent' 'absent credential file is not named concretely'
pass 'an absent credential file refuses and prints no answer'

mkdir -p "$TMP_ROOT/home/.config/firstmate"
FM_JEV_ENV_FILE_OVERRIDE='' run_jev 1 'the default credential path is used when unset'
assert_refused 'absent default credential file'
assert_contains "$ERR" "$TMP_ROOT/home/.config/firstmate/openrouter.env" 'the documented default credential path was not used'
pass 'the credential file defaults to the documented path under HOME'

LOOSE="$TMP_ROOT/loose.env"
cp "$ENV_FILE" "$LOOSE"
chmod 644 "$LOOSE"
FM_JEV_ENV_FILE_OVERRIDE="$LOOSE" run_jev 1 'a world-readable credential file refuses'
assert_refused 'world-readable credential file'
assert_contains "$ERR" 'mode 0600' 'the private-file requirement is not named'
pass 'a credential file that is not private refuses and prints no answer'

# A symlinked credential file exists, so "absent" would name the wrong
# requirement to a user who keeps this file in a dotfiles repo.
LINKED="$TMP_ROOT/linked.env"
ln -sf "$ENV_FILE" "$LINKED"
FM_JEV_ENV_FILE_OVERRIDE="$LINKED" run_jev 1 'a symlinked credential file refuses'
assert_refused 'symlinked credential file'
assert_contains "$ERR" 'symlink' 'the regular-file requirement is not named'
assert_not_contains "$ERR" 'absent' 'a symlinked credential file was reported as absent'
pass 'a symlinked credential file refuses by naming the regular-file requirement'

KEYLESS="$TMP_ROOT/keyless.env"
printf 'TYPESAFE_BASE_URL=https://openrouter.example.invalid/api\n' > "$KEYLESS"
chmod 600 "$KEYLESS"
FM_JEV_ENV_FILE_OVERRIDE="$KEYLESS" run_jev 1 'a credential file with no key refuses'
assert_refused 'credential file with no key'
assert_contains "$ERR" 'OPENROUTER_API_KEY' 'the missing key is not named'
pass 'a credential file carrying no key refuses and prints no answer'

# --- fail closed: transport and status --------------------------------------

FAIL=7 run_jev 1 'a failed call refuses'
assert_refused 'failed call'
assert_contains "$ERR" 'failed' 'the transport failure is not reported'
pass 'a failed call refuses and prints no answer'

CODE=401 run_jev 1 'an HTTP error refuses'
assert_refused 'HTTP error'
assert_contains "$ERR" 'HTTP 401' 'the HTTP status is not reported'
pass 'an HTTP error refuses and prints no answer'

: > "$CURL_LOG"
CODE=503 HEADER='Retry-After: 0' run_jev 1 'a 5xx refuses after its one retry'
assert_refused 'persistent 5xx'
assert_contains "$ERR" 'HTTP 503' 'the retried HTTP status is not reported'
[ "$(wc -l < "$CURL_LOG")" = 2 ] || fail "a 5xx must be retried exactly once (attempts: $(wc -l < "$CURL_LOG"))"
pass 'a 5xx is retried exactly once, then refuses and prints no answer'

: > "$CURL_LOG"
CODE=429 HEADER='Retry-After: 0' run_jev 1 'a 429 refuses after its one retry'
assert_refused 'persistent 429'
[ "$(wc -l < "$CURL_LOG")" = 2 ] || fail "a 429 must be retried exactly once (attempts: $(wc -l < "$CURL_LOG"))"
pass 'a 429 is retried exactly once, then refuses and prints no answer'

# Bounded shadow observers need exactly one transport attempt, while ordinary
# callers retain the existing retry contract.
for STATUS in 429 503; do
  : > "$CURL_LOG"
  CODE=$STATUS HEADER='Retry-After: 0' run_jev 1 "--no-retry refuses HTTP $STATUS without retry" --no-retry
  assert_refused 'single-attempt refusal'
  [ "$(wc -l < "$CURL_LOG")" = 1 ] || fail '--no-retry made more than one transport attempt'
done
pass '--no-retry preserves failure diagnostics but performs only one transport attempt'

# --- fail closed: malformed and incomplete responses ------------------------

BODY='<html>gateway timeout</html>' run_jev 1 'a non-JSON response refuses'
assert_refused 'non-JSON response'
assert_contains "$ERR" 'malformed' 'the malformed response is not reported'
pass 'a non-JSON response refuses and prints no answer'

BODY='{"answers":{"upstream":{"type":"noul","noul":0.9},"urgency":{"type":"score","score":1.0}}}' \
  run_jev 1 'a response with no model field refuses'
assert_refused 'response with no model field'
assert_contains "$ERR" 'model field' 'the untraceable response is not reported'
pass 'a response that cannot be traced to a model version refuses and prints no answer'

BODY='{"model":"typesafe/jev-1.13-20260917","answers":{"upstream":{"type":"noul","noul":0.91}}}' \
  run_jev 1 'a response missing a requested question refuses'
assert_refused 'response missing a requested question'
assert_contains "$ERR" 'urgency' 'the unanswered question is not named'
pass 'a response missing a question that was asked refuses and prints no answer'

BODY='{"model":"typesafe/jev-1.13-20260917"}' run_jev 1 'a response with no answers object refuses'
assert_refused 'response with no answers object'
pass 'a response carrying no answers object refuses and prints no answer'

# An explicitly null answer is an absent answer, not a judgment: key presence
# alone would let it through and a caller would read the null as a verdict.
BODY='{"model":"typesafe/jev-1.13-20260917","answers":{"upstream":{"type":"noul","noul":0.91},"urgency":null}}' \
  run_jev 1 'a null answer refuses'
assert_refused 'null answer'
assert_contains "$ERR" 'urgency' 'the null-valued question is not named'
pass 'an explicitly null answer refuses and prints no answer'

# --- usage refusals ---------------------------------------------------------

RC=0
PATH="$FAKEBIN:$BASE_PATH" "$JEV" --state "$STATE" > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr" || RC=$?
expect_code 2 "$RC" 'a request with no questions is a usage error'
[ ! -s "$TMP_ROOT/stdout" ] || fail 'a usage error still printed on stdout'
pass 'a request with no questions is refused as a usage error'

RC=0
PATH="$FAKEBIN:$BASE_PATH" "$JEV" --state - --questions - > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr" < /dev/null || RC=$?
expect_code 2 "$RC" 'two stdin inputs are a usage error'
assert_contains "$(cat "$TMP_ROOT/stderr")" 'stdin' 'the two-stdin refusal is not explained'
pass 'only one input may read stdin'

RC=0
PATH="$FAKEBIN:$BASE_PATH" "$JEV" --help > "$TMP_ROOT/stdout" 2>&1 || RC=$?
expect_code 0 "$RC" '--help exits zero'
assert_grep 'Fail closed' "$TMP_ROOT/stdout" 'help does not state the fail-closed contract'
assert_grep 'jev-routing' "$TMP_ROOT/stdout" 'help does not point at the routing owner'
pass 'help states the contract and points at the routing owner'

# --- the accepted model id shape --------------------------------------------
#
# An anchored allowlist: an OpenRouter variant id carries a colon, and nothing
# outside the allowed set gets through on the strength of that widening.
for GOOD in 'vendor/model:beta' 'openrouter/jev-1.13:free' 'typesafe/jev-1.13-20260917' 'jev_1.13~a'; do
  run_jev 0 "--model accepts '$GOOD'" --model "$GOOD"
  assert_contains "$OUT" '"model":' "--model '$GOOD' was accepted but produced no answer"
done
run_jev 0 '--model accepts an id of exactly 200 characters' \
  --model "$(printf 'a%.0s' $(seq 1 200))"
pass '--model accepts a variant id carrying a colon'

DOLLAR='$'
for BAD in ':beta' 'vendor/model:' 'vendor/model::beta' 'vendor/model beta' "vendor/model${DOLLAR}(id)" 'vendor/model;id' ''; do
  run_jev 2 "--model rejects '$BAD'" --model "$BAD"
  assert_refused "--model '$BAD'"
  assert_contains "$ERR" '--model must be' "--model '$BAD' was refused without naming the requirement"
done
run_jev 2 '--model rejects an id of 201 characters' \
  --model "$(printf 'a%.0s' $(seq 1 201))"
assert_contains "$ERR" '200 characters' 'the model id length limit is not named'
pass '--model rejects an id outside the allowlist, a stray colon, or an overlong id'

# --- malformed inputs -------------------------------------------------------

BADSTATE="$TMP_ROOT/bad-state"
printf 'not json at all\n' > "$BADSTATE"
RC=0
PATH="$FAKEBIN:$BASE_PATH" FM_JEV_ENV_FILE="$ENV_FILE" \
  "$JEV" --state "$BADSTATE" --questions "$QUESTIONS" > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr" || RC=$?
expect_code 1 "$RC" 'a non-JSON state refuses'
[ ! -s "$TMP_ROOT/stdout" ] || fail 'a non-JSON state still printed on stdout'
pass 'a state that is not valid JSON refuses and prints no answer'

EMPTYQ="$TMP_ROOT/empty-questions.json"
printf '{}\n' > "$EMPTYQ"
RC=0
PATH="$FAKEBIN:$BASE_PATH" FM_JEV_ENV_FILE="$ENV_FILE" \
  "$JEV" --state "$STATE" --questions "$EMPTYQ" > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr" || RC=$?
expect_code 1 "$RC" 'an empty question set refuses'
[ ! -s "$TMP_ROOT/stdout" ] || fail 'an empty question set still printed on stdout'
pass 'an empty question set refuses and prints no answer'

# --- stdin inputs -----------------------------------------------------------

RC=0
PATH="$FAKEBIN:$BASE_PATH" FM_JEV_ENV_FILE="$ENV_FILE" \
  FM_FAKE_CURL_CODE=200 FM_FAKE_CURL_BODY="$ANSWERED" \
  "$JEV" --state - --questions "$QUESTIONS" < "$STATE" \
  > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr" || RC=$?
expect_code 0 "$RC" 'a state read from stdin is answered'
assert_grep '"model":"typesafe/jev-1.13-20260917"' "$TMP_ROOT/stdout" 'the stdin state was not answered'
pass 'either input can be read from stdin'
