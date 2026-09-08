#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-axi-lib.sh - the shared quota-axi
# compatibility floor for the bootstrap diagnostic.
#
# The bounded form `fm_quota_axi_compatible <seconds>` used to re-derive its own
# timeout/gtimeout/perl selection. bin/fm-timeout-lib.sh now owns bounded
# execution, so this suite pins that the bound is actually delegated there and
# that the floor verdict is unchanged by the move:
#
#   - a hung `quota-axi --version` is bounded and reported incompatible rather
#     than wedging the caller, and it is bounded through the SHARED owner: the
#     probe runs on a PATH carrying no timeout, gtimeout, or perl, where the
#     retired inline selection had no mechanism left and returned without ever
#     calling quota-axi. Only the shared library's dependency-free bash
#     mechanism can bound a real call there;
#   - the floor comparison itself is unchanged under the bound - the same
#     versions pass and fail as with no bound at all;
#   - a bound of zero or a non-numeric bound is still refused before any call,
#     because `timeout 0` and `alarm 0` both mean "no deadline".
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_test_tmproot TMP_ROOT fm-quota-axi-lib-tests
LIB="$ROOT/bin/fm-quota-axi-lib.sh"

# A fake quota-axi that prints a chosen version, or hangs, and logs each call.
make_fakebin() {  # <dir>
  local dir=$1 fakebin
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_QUOTA_LOG"
if [ "${FM_FAKE_QUOTA_HANG:-0}" = 1 ]; then
  sleep 30
fi
printf 'quota-axi %s\n' "${FM_FAKE_QUOTA_VERSION:-0.1.16}"
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

# A PATH with no bounded-execution dependency at all: no timeout, no gtimeout,
# no perl. bin/fm-timeout-lib.sh's bash mechanism is the only thing that can
# bound a command here, so honoring this PATH is proof the bound is delegated.
MINIMAL_TOOLS="bash sh env sleep mktemp cat rm sed head awk date"
make_minimal_bin() {  # <dir>
  local dir=$1 bin tool path
  bin="$dir/minimal-bin"
  mkdir -p "$bin"
  for tool in $MINIMAL_TOOLS; do
    path=$(PATH="$BASE_PATH" command -v "$tool" 2>/dev/null) || continue
    ln -sf "$path" "$bin/$tool"
  done
  for tool in timeout gtimeout perl; do
    [ -e "$bin/$tool" ] && fail "minimal PATH must not carry $tool"
  done
  printf '%s\n' "$bin"
}

# check <case> <version> <hang> <mechanism-override> [bound]
# Sets CHECK_RC, CHECK_ELAPSED, CHECK_CALLS in the caller's shell.
CHECK_RC=0
CHECK_ELAPSED=0
CHECK_CALLS=0
check() {
  local case_name=$1 version=$2 hang=$3 mechanism=$4 bound=${5:-}
  local dir fakebin log started path
  dir="$TMP_ROOT/$case_name"
  fakebin=$(make_fakebin "$dir")
  log="$dir/quota.log"
  : > "$log"
  # CHECK_PATH_MODE=minimal drops every external bounding dependency.
  if [ "${CHECK_PATH_MODE:-full}" = minimal ]; then
    path=$(make_minimal_bin "$dir")
  else
    path=$BASE_PATH
  fi
  started=$SECONDS
  CHECK_RC=0
  # shellcheck disable=SC2016 # The child shell expands its own positional parameters.
  env "PATH=$fakebin:$path" \
    FM_FAKE_QUOTA_LOG="$log" \
    FM_FAKE_QUOTA_VERSION="$version" \
    FM_FAKE_QUOTA_HANG="$hang" \
    FM_TIMEOUT_MECHANISM_OVERRIDE="$mechanism" \
    bash -c '. "$1"; shift; fm_quota_axi_compatible "$@"' _ "$LIB" ${bound:+"$bound"} \
    >/dev/null 2>&1 || CHECK_RC=$?
  CHECK_ELAPSED=$((SECONDS - started))
  CHECK_CALLS=$(awk 'END { print NR + 0 }' "$log" 2>/dev/null || echo 0)
}

# A hung `quota-axi --version` must not wedge the bootstrap diagnostic. Forcing
# the shared library's `bash` mechanism proves the bound comes from
# bin/fm-timeout-lib.sh: no private copy in this library ever had that mechanism.
test_hung_version_is_bounded_through_the_shared_owner() {
  CHECK_PATH_MODE=minimal check hang-shared 0.1.16 1 bash 2
  [ "$CHECK_RC" -ne 0 ] || fail "a hung quota-axi was reported compatible"
  [ "$CHECK_ELAPSED" -lt 20 ] \
    || fail "the shared bound did not stop a hung quota-axi (${CHECK_ELAPSED}s)"
  # The retired inline selection had no mechanism on this PATH and bailed out
  # before running anything, so the call itself is the delegation evidence.
  [ "$CHECK_CALLS" -eq 1 ] \
    || fail "the check never reached quota-axi on a PATH without timeout/perl ($CHECK_CALLS calls)"
  pass "a hung quota-axi --version is bounded through the shared timeout owner"
}

# The bound must not change the floor verdict: the same versions pass and fail
# whether the call is bounded (shared owner) or unbounded.
test_floor_verdict_is_identical_bounded_and_unbounded() {
  local version expected bounded unbounded
  while read -r version expected; do
    [ -n "$version" ] || continue
    CHECK_PATH_MODE=minimal check "bounded-$version" "$version" 0 bash 5
    bounded=$CHECK_RC
    check "unbounded-$version" "$version" 0 bash
    unbounded=$CHECK_RC
    [ "$bounded" -eq "$unbounded" ] \
      || fail "$version: bounded verdict ($bounded) disagrees with unbounded ($unbounded)"
    case "$expected" in
      compatible)   [ "$bounded" -eq 0 ] || fail "$version should clear the 0.1.16 floor" ;;
      incompatible) [ "$bounded" -ne 0 ] || fail "$version should fail the 0.1.16 floor" ;;
    esac
  done <<'VERSIONS'
0.1.15 incompatible
0.1.16 compatible
0.1.17 compatible
0.2.0 compatible
1.0.0 compatible
0.0.99 incompatible
VERSIONS
  pass "the compatibility floor is unchanged by the shared bound"
}

# Zero and garbage are not bounds, so they are refused before quota-axi runs.
test_non_positive_bound_is_refused_without_calling() {
  local bound
  for bound in 0 abc 1.5; do
    check "bad-bound-${bound//./_}" 0.1.16 0 bash "$bound"
    [ "$CHECK_RC" -ne 0 ] || fail "bound '$bound' was accepted as a deadline"
    [ "$CHECK_CALLS" -eq 0 ] || fail "bound '$bound' still invoked quota-axi"
  done
  pass "a zero or non-numeric bound is refused before quota-axi is called"
}

test_hung_version_is_bounded_through_the_shared_owner
test_floor_verdict_is_identical_bounded_and_unbounded
test_non_positive_bound_is_refused_without_calling
printf 'all fm-quota-axi-lib tests passed\n'
