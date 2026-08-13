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

# ── every backend-ready state is detected (UiReady is asserted separately) ───
check "HcAuthRequired" yes \
  "$P LairAwaitingPassword { is_initial_setup: true } -> HcAuthRequired { agent_key: \"uhCAkAAA\", joining_service_url: \"https://joining.unyt.dev\" }" smoke_match_backend_ready
check "NetworkSetupRequired" yes \
  "$P LairReady -> NetworkSetupRequired { agent_key: \"uhCAkAAA\", has_existing_key: false }" smoke_match_backend_ready
check "JoiningRequired" yes \
  "$P LairReady -> JoiningRequired { agent_key: \"uhCAkAAA\" }" smoke_match_backend_ready
check "Ready" yes "$P Syncing -> Ready" smoke_match_backend_ready

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
check "a failure line is not healthy"  no "$P Ready -> ConductorCrashed" smoke_match_backend_ready
check "a healthy line is not a failure" no "$P LairReady -> Ready" smoke_match_failed

# ── bug 3: the merged log carries other subsystems' arrows ───────────────────
# These are the lines that made the oracle pass for a broken app.
check "kitsune2 line containing '-> Ready'" no \
  '2026-08-12T20:00:00.000000Z  INFO kitsune2_gossip: peer uhCAkXXX state Initiated -> Ready' smoke_match_backend_ready
check "holochain line containing '-> Ready'" no \
  '2026-08-12T20:00:00.000000Z  INFO holochain::conductor: cell transition Pending -> Ready' smoke_match_backend_ready
check "an unrelated line naming ConductorError" no \
  '2026-08-12T20:00:00.000000Z DEBUG unyt: matching on ConductorError("x") in a comment' smoke_match_failed
check "LairReady is not Ready" no "$P Starting -> LairReady" smoke_match_backend_ready
check "quiet boot log is neither" no \
  '2026-08-12T20:00:00.000000Z  INFO unyt: holochain_dir: Final path' smoke_match_backend_ready

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
got="$(printf '%s\n' "$P LairReady -> NetworkSetupRequired { agent_key: \"uhCAkAAA\", has_existing_key: false }" | smoke_first_backend_ready)"
case "$got" in
  *NetworkSetupRequired*uhCAkAAA*) pass=$((pass + 1)) ;;
  *) fail=$((fail + 1)); printf 'FAIL  %-58s got: %s\n' "first-healthy reports the matched state" "$got" >&2 ;;
esac

# ── H2: UiReady is its own REQUIRED assertion, not an alternative ────────────
# As an OR-set member it gated nothing: a build whose UI bundle never loads still
# reaches HcAuthRequired from Rust, so a black-window release passed.
check "a backend state alone is NOT a ui-ready signal" no \
  "$P LairReady -> NetworkSetupRequired { agent_key: \"uhCAkAAA\", has_existing_key: false }" smoke_match_ui_ready
check "the breadcrumb is a ui-ready signal" yes \
  '2026-08-12T20:00:00.000000Z  INFO unyt::runtime: UI ready: webview mounted the root element' smoke_match_ui_ready
check "the breadcrumb alone is not a backend state" no \
  '2026-08-12T20:00:00.000000Z  INFO unyt::runtime: UI ready: webview mounted the root element' smoke_match_backend_ready

# The breadcrumb probe reads the artifact, so old artifacts stay smokeable and a
# new one cannot quietly lose its only webview proof.
probe="$(mktemp)"; printf 'irrelevant bytes' >"$probe"
if smoke_supports_ui_ready "$probe"; then
  fail=$((fail + 1)); echo "FAIL  a binary without the breadcrumb must not claim support" >&2
else pass=$((pass + 1)); fi
printf 'padding %s padding' "$UNYT_RE_UI_READY" >"$probe"
if smoke_supports_ui_ready "$probe"; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  a binary containing the breadcrumb must claim support" >&2; fi
rm -f "$probe"

# ── cold-install proof ───────────────────────────────────────────────────────
# has_existing_key: true is CORRECT on an authenticated build's first install
# (hc-auth mints a key at boot and resolve_agent_key reuses it), so it must not
# be used as the freshness signal. Carried-forward identity is the real one.
check "a carried-forward identity is detected" yes \
  '2026-08-12T20:00:00.000000Z  INFO unyt::runtime: identity: agent identity carried forward into the new version' smoke_match_carried
check "a cold install shows no carry" no \
  "$P LairReady -> NetworkSetupRequired { agent_key: \"uhCAkAAA\", has_existing_key: true }" smoke_match_carried
check "has_existing_key: true is still a healthy backend state" yes \
  "$P LairReady -> NetworkSetupRequired { agent_key: \"uhCAkAAA\", has_existing_key: true }" smoke_match_backend_ready

# ── N1: the bundle scan must survive a file with no GLIBC_ symbols LAST ──────
# `[ -n "$v" ] && printf` as the last statement of a loop body makes the whole
# `while` exit non-zero when the final iteration's test fails; pipefail carries
# that through the `| sort`, and set -e then kills the script — skipping every
# check below it, including the ceiling comparison. Which file lands last is
# `find` order, so the gate was a coin flip per build. Drives the REAL script
# against a synthetic AppDir whose last .so is data-only.
if command -v objdump >/dev/null 2>&1 && [ -x "$(command -v ls || true)" ]; then
  appdir="$(mktemp -d)"
  mkdir -p "$appdir/usr/bin" "$appdir/usr/lib"
  # A real dynamically-linked ELF, so the scan has a genuine GLIBC_ version to
  # find; `command -v true` would resolve the shell builtin, not a file.
  real_elf="$(command -v ls || true)"
  cp "$real_elf" "$appdir/usr/bin/app"
  printf 'not an elf at all' >"$appdir/usr/lib/zzz-data.so.9"   # sorts last
  if out="$(bash "$here/check-appimage.sh" "$appdir" 2>&1)"; then :; fi
  if printf '%s' "$out" | grep -q 'glibc ceiling of the bundle'; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL  the bundle scan aborted before reporting (N1 regression)" >&2
    printf '      output was: %s\n' "${out:-<empty>}" >&2
  fi
  rm -rf "$appdir"
else
  echo "SKIP  N1 bundle-scan regression (no objdump)" >&2
fi

echo "oracle regression: $pass passed, $fail failed"
# A floor on the COUNT, not just on failures: truncate this file and it would
# otherwise report "3 passed, 0 failed" and exit 0 — the same shape as the
# container-never-ran bug one level up. Raise it when adding assertions.
if [ "$pass" -lt 33 ]; then
  echo "::error::only $pass assertions ran; expected at least 33 — the test file is truncated or a block was skipped" >&2
  exit 1
fi
[ "$fail" -eq 0 ]
