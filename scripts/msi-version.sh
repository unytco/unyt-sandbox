#!/usr/bin/env bash
# Echo the `bundle.windows.wix.version` a pre-release build needs, or nothing when tauri derives
# its own.
#
# tauri's msi bundler parses the WHOLE pre-release identifier as one number (`convert_version`), so
# `0.101.0-dev.0` bails and takes the entire Windows job — .exe included — with it.
# `bundle.windows.wix.version` is the documented override.
#
# NEVER COMMIT WHAT THIS PRINTS: a wix.version in tauri.conf.json outlives the release that set it
# and would version every later MSI. The caller writes the key at build time.
#
# Usage:  msi-version.sh 0.101.0-dev.3   ->  0.101.0.3
#         msi-version.sh 0.101.0         ->  (nothing)
#         msi-version.sh --self-test     ->  runs the cases below
set -euo pipefail

fail() { echo "msi-version: $*" >&2; exit 1; }
# Length first: `[ 18446744073709551616 -le 65535 ]` is a shell error, not a comparison, and would
# reject the version with the interpreter's words rather than ours.
bound() {
  { [ "${#2}" -le 5 ] && [ "$2" -le "$3" ]; } ||
    fail "the $1 field is $2, past the $3 the msi allows"
}

derive() {
  # `-dev.N` is the shape the release pipeline supports; the tag trigger is a glob and admits any
  # `-dev.*`, so this is where a tag it cannot carry has to be turned away. No leading zeros: the
  # msi would keep them in its product version.
  local n='(0|[1-9][0-9]*)'
  [[ "$1" =~ ^$n\.$n\.$n(-dev\.$n)?$ ]] ||
    fail "'$1' is not MAJOR.MINOR.PATCH with an optional -dev.N suffix"
  local major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
  local dev="${BASH_REMATCH[5]}"
  # Before the bounds: a stable version is tauri's to derive and to validate.
  [ -n "${BASH_REMATCH[4]}" ] || return 0

  # tauri's validate_wix_version bounds all four fields, and runs on this override as well as on
  # the version it derives itself.
  bound major "$major" 255
  bound minor "$minor" 255
  bound patch "$patch" 65535
  bound build "$dev" 65535

  echo "$major.$minor.$patch.$dev"
}

self_test() {
  local passed=0 failed=0
  ok() { # ok <version> <expected-stdout>
    local got
    got="$(derive "$1" 2>/dev/null)" || { echo "FAIL $1: exited non-zero, expected '$2'"; failed=$((failed + 1)); return; }
    if [ "$got" = "$2" ]; then passed=$((passed + 1)); else
      echo "FAIL $1: got '$got', expected '$2'"; failed=$((failed + 1)); fi
  }
  no() { # no <version> — must be rejected, AND print nothing. Checking only the exit status lets
         # the echo move above the bounds and still report fourteen green cases while stdout
         # carries a version the msi cannot take. Subshell: `fail` exits, and an unguarded call
         # would take the whole self-test with it instead of failing one case.
    local got rc=0
    got="$( derive "$1" 2>/dev/null )" || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "FAIL $1: accepted, expected a rejection"; failed=$((failed + 1))
    elif [ -n "$got" ]; then
      echo "FAIL $1: rejected but printed '$got'"; failed=$((failed + 1))
    else passed=$((passed + 1)); fi
  }
  cli() { # cli <args...> — through the entry point, which is what CI calls
    local want="$1" got rc=0; shift
    got="$(bash "$0" "$@" 2>/dev/null)" || rc=$?
    if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then passed=$((passed + 1)); else
      echo "FAIL cli $*: exit $rc, printed '$got', expected exit 0 and '$want'"; failed=$((failed + 1)); fi
  }

  ok 0.101.0        ""          # stable: tauri derives it, we must stay silent
  ok 256.0.0        ""          # and validates it — a stable version is not ours to bound
  ok 0.101.0-dev.0  0.101.0.0
  ok 0.101.0-dev.3  0.101.0.3
  ok 255.255.65535-dev.65535 255.255.65535.65535   # every field at tauri's ceiling
  no 0.101.0-dev
  no 0.101.0-dev.x
  no 0.101.0-dev.08           # a leading zero would reach the msi's product version verbatim
  no 0.101.0-dev.65536        # past the msi ceiling
  no 0.101.70000-dev.0        # tauri bounds the patch field too
  no 256.0.0-dev.0            # and the major
  no 0.256.0-dev.0            # and the minor
  no 1.2.3-alpha.4            # -dev is the only pre-release channel
  no 0.101.0+build.4          # build metadata is tauri's other bail path
  no 0.101
  no ""
  # `msi="$(bash scripts/msi-version.sh "$APP_VERSION")"` under `set -e` is the caller: a stable
  # version has to exit 0 with nothing on stdout, or every stable release fails at that line.
  cli "" 0.101.0
  cli 0.101.0.3 0.101.0-dev.3

  echo "msi-version self-test: $passed passed, $failed failed"
  [ "$failed" -eq 0 ] || return 1
  # A floor on the COUNT, as the smoke harnesses have. After the failure check, so a case that
  # FAILED is reported as a failure rather than as a deleted one.
  [ "$passed" -ge 18 ] || { echo "::error::only $passed cases ran; expected at least 18" >&2; return 1; }
}

case "${1-}" in
  --self-test) self_test ;;
  "") fail "usage: msi-version.sh <version> | --self-test" ;;
  *) derive "$1" ;;
esac
