#!/usr/bin/env bash
# Regression test for the health oracle. No Docker, no app — just fixture log
# lines through the REAL matchers in common.sh.
#
#   scripts/smoke/test-oracle.sh
#
# WHY THIS EXISTS. Three separate defects in this oracle each made an assertion
# incapable of failing, and every one was in the INVOCATION rather than the
# pattern, so reading the patterns would not have caught any of them:
#
#   1. `-> (A|B|C)\(` required a `(` after every variant, but Rust prints unit
#      variants bare — 4 of 7 failure states never matched.
#   2. `grep -cE "$RE"` with a pattern starting with `-` parsed the pattern as
#      OPTIONS. The disconnect count was always 0, so "it stays up" asserted
#      nothing at all.
#   3. Unanchored alternations matched unrelated subsystem lines in the merged
#      log, so anything containing `-> Ready` declared the app healthy.
#
# That is why the test drives `smoke_match_*` / `smoke_count_*` — the same
# functions launch-and-assert.sh calls — instead of re-deriving the greps here.
# A copy would have passed while the real call site stayed broken.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$here/common.sh"

pass=0
fail=0
check() { # <description> <expected: yes|no> <log line(s)> <matcher>
  local desc="$1" expected="$2" log="$3" matcher="$4" got
  if printf '%s\n' "$log" | "$matcher"; then got=yes; else got=no; fi
  if [ "$got" = "$expected" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  %-58s expected %s, got %s\n' "$desc" "$expected" "$got" >&2
    printf '      log: %s\n' "$log" >&2
  fi
}
check_count() { # <description> <expected-count> <log>
  local desc="$1" expected="$2" log="$3" got
  got="$(printf '%s\n' "$log" | smoke_count_disconnects)"
  if [ "$got" = "$expected" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  %-58s expected %s disconnects, got %s\n' "$desc" "$expected" "$got" >&2
  fi
}

P='2026-08-12T20:00:00.000000Z  INFO unyt::runtime: Status update:'

# ── every healthy state is detected ───────────────────────────────────────────
check "UiReady breadcrumb" yes \
  '2026-08-12T20:00:00.000000Z  INFO unyt::runtime: UI ready: webview mounted the root element' smoke_match_healthy
check "HcAuthRequired" yes \
  "$P LairAwaitingPassword { is_initial_setup: true } -> HcAuthRequired { agent_key: \"uhCAkAAA\", joining_service_url: \"https://joining.unyt.dev\" }" smoke_match_healthy
check "NetworkSetupRequired" yes \
  "$P LairReady -> NetworkSetupRequired { agent_key: \"uhCAkAAA\", has_existing_key: false }" smoke_match_healthy
check "JoiningRequired" yes \
  "$P LairReady -> JoiningRequired { agent_key: \"uhCAkAAA\" }" smoke_match_healthy
check "Ready" yes "$P Syncing -> Ready" smoke_match_healthy

# ── every failure state is detected (bug 1: unit vs tuple vs struct shapes) ───
check "ConductorError (tuple variant)" yes "$P Starting -> ConductorError(\"boom\")" smoke_match_failed
check "AppInstallationError (tuple)"   yes "$P Starting -> AppInstallationError(\"boom\")" smoke_match_failed
check "Error (tuple)"                  yes "$P Starting -> Error(\"boom\")" smoke_match_failed
check "ConductorCrashed (unit)"        yes "$P Ready -> ConductorCrashed" smoke_match_failed
check "LairInvalidPassword (unit)"     yes "$P Starting -> LairInvalidPassword" smoke_match_failed
check "NetworkUnreachable (unit)"      yes "$P Starting -> NetworkUnreachable" smoke_match_failed
check "HcAuthFailed (struct variant)"  yes "$P Starting -> HcAuthFailed { error: \"nope\" }" smoke_match_failed
check "a Rust panic"                   yes \
  'thread '"'"'main'"'"' panicked at src/runtime/boot/lair.rs:79:5' smoke_match_failed

# ── healthy must NOT swallow a failure, and vice versa ────────────────────────
check "a failure line is not healthy"  no "$P Ready -> ConductorCrashed" smoke_match_healthy
check "a healthy line is not a failure" no "$P LairReady -> Ready" smoke_match_failed

# ── bug 3: the merged log carries other subsystems' arrows ───────────────────
# These are the lines that made the oracle pass for a broken app.
check "kitsune2 line containing '-> Ready'" no \
  '2026-08-12T20:00:00.000000Z  INFO kitsune2_gossip: peer uhCAkXXX state Initiated -> Ready' smoke_match_healthy
check "holochain line containing '-> Ready'" no \
  '2026-08-12T20:00:00.000000Z  INFO holochain::conductor: cell transition Pending -> Ready' smoke_match_healthy
check "an unrelated line naming ConductorError" no \
  '2026-08-12T20:00:00.000000Z DEBUG unyt: matching on ConductorError("x") in a comment' smoke_match_failed
check "LairReady is not Ready" no "$P Starting -> LairReady" smoke_match_healthy
check "quiet boot log is neither" no \
  '2026-08-12T20:00:00.000000Z  INFO unyt: holochain_dir: Final path' smoke_match_healthy

# ── bug 2: the pattern starts with '-', so an unguarded grep ate it as options ─
# Before the fix these all returned "" (grep: invalid option) and the caller's
# arithmetic silently produced 0, so a permanently flapping conductor passed.
D="$P Ready -> ConductorDisconnected"
check_count "no disconnects"  0 "$P LairReady -> Ready"
check_count "one disconnect"  1 "$D"
check_count "five disconnects" 5 "$D
$D
$D
$D
$D"
check "a disconnect is not a terminal failure" no "$D" smoke_match_failed

# ── the reported line is the real one, not a truncation ──────────────────────
got="$(printf '%s\n' "$P LairReady -> NetworkSetupRequired { agent_key: \"uhCAkAAA\", has_existing_key: false }" | smoke_first_healthy)"
case "$got" in
  *NetworkSetupRequired*uhCAkAAA*) pass=$((pass + 1)) ;;
  *) fail=$((fail + 1)); printf 'FAIL  %-58s got: %s\n' "first-healthy reports the matched state" "$got" >&2 ;;
esac

echo "oracle regression: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
