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

# ── N11: cold install proven positively, not only by an absence ──────────────
check "the fresh-identity line is detected" yes \
  '2026-08-12T20:00:00.000000Z  INFO unyt::runtime: identity: no prior data-root identity; using a fresh identity' smoke_match_fresh
check "a carried boot is not a fresh identity" no \
  '2026-08-12T20:00:00.000000Z  INFO unyt::runtime: identity: agent identity carried forward into the new version' smoke_match_fresh
check "a boot that never ran the identity check is not fresh" no \
  "$P Starting -> LairAwaitingPassword { is_initial_setup: true }" smoke_match_fresh

# ── N3/N4: the declared-vs-computed comparison ───────────────────────────────
# Both bugs were invisible to reading and are pinned here against the REAL
# function: a declared floor BELOW the computed one used to pass silently, and a
# correctly-declared libstdc++6 used to be reported missing because `c++` is an
# ERE quantifier.
dep_d="$(mktemp)"; dep_c="$(mktemp)"
printf 'libc6 (>= 2.17)\nlibstdc++6\nlibgtk-3-0\nlibsoup-3.0-0 (>= 3.0.3)\nlibpango-1.0-0 (>= 1.14.0)\n' >"$dep_d"
printf 'libc6 (>= 2.34)\nlibstdc++6 (>= 4.1.1)\nlibglib2.0-0 (>= 2.65.1)\nlibsoup-3.0-0 (>= 3.0.3)\nlibpango-1.0-0 (>= 1.10.0)\n' >"$dep_c"
gaps="$(smoke_depends_gaps "$dep_d" "$dep_c")"
expect_gap() {
  if printf '%s\n' "$gaps" | grep -qF -e "$1"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL  %-58s not reported\n' "$2" >&2
    printf '      gaps were:\n%s\n' "$gaps" >&2; fi
}
reject_gap() {
  if printf '%s\n' "$gaps" | grep -qF -e "$1"; then
    fail=$((fail + 1)); printf 'FAIL  %-58s wrongly reported\n' "$2" >&2
  else pass=$((pass + 1)); fi
}
expect_gap "TOOLOW libc6 (>= 2.34) declared (>= 2.17)" "a declared floor below the computed one"
expect_gap "UNCONSTRAINED libstdc++6 (>= 4.1.1)"       "a bare declaration where a floor is required"
expect_gap "MISSING libglib2.0-0 (>= 2.65.1)"          "a genuinely absent dependency"
reject_gap "MISSING libstdc++6"                        "libstdc++6 (the c++ ERE-quantifier bug)"
reject_gap "libsoup-3.0-0"                             "an exactly-matching dependency"
reject_gap "libpango-1.0-0"                            "a declared floor ABOVE the computed one"
# F1/F2/F3: a declaration can also provide no USABLE floor while looking like one.
# Each of these passed silently before; they are the same class as the too-low
# floor above, which is the one property this gate exists to enforce.
one_case() { # <declared> <expected-finding-prefix> <description>
  local df cf out
  df="$(mktemp)"; cf="$(mktemp)"
  printf '%s\n' "$1" >"$df"; printf 'libc6 (>= 2.34)\n' >"$cf"
  out="$(smoke_depends_gaps "$df" "$cf")"
  if [ -z "$2" ]; then
    # AN EMPTY EXPECTATION MEANS NO FINDING AT ALL, and it needs its own branch:
    # `case "$out" in "$2"*)` expands to `*)`, which matches ANY output. Every
    # "must not fire" case below therefore passed unconditionally — including if
    # the comparison started reporting TOOLOW or BADVERSION against a perfectly
    # valid declaration, which is the exact regression those cases exist to
    # catch. They are the fixtures added to stop an over-eager fix reporting
    # everything, and they could not have caught one.
    if [ -z "$out" ]; then pass=$((pass + 1)); else
      fail=$((fail + 1)); printf 'FAIL  %-58s expected NO finding, got: %s\n' "$3" "$out" >&2; fi
  else
    case "$out" in
      "$2"*) pass=$((pass + 1)) ;;
      *) fail=$((fail + 1)); printf 'FAIL  %-58s got: %s\n' "$3" "${out:-<no finding>}" >&2 ;;
    esac
  fi
  rm -f "$df" "$cf"
}
one_case 'libc6 (<= 2.40)'            NOFLOOR    "an upper bound accepted as a floor"
one_case 'libc6 (<< 2.40)'            NOFLOOR    "a strict upper bound accepted as a floor"
one_case 'libc6 (= 2.40)'             NOFLOOR    "an equality accepted as a floor"
one_case 'libc6 (>= v2.34)'           BADVERSION "a malformed version dpkg accepts against anything"
one_case 'libc6 (>=1.0)'              TOOLOW     "a no-space constraint whose floor is too low"
one_case 'libc6'                      UNCONSTRAINED "a bare declaration"
one_case 'libfoo (>= 1)'              MISSING    "a wholly different package"
# Must NOT fire: a correct declaration in each accepted shape.
one_case 'libc6 (>= 2.34)'            ""         "an exact floor (must not fire)"
one_case 'libc6 (>=2.34)'             ""         "a valid no-space floor (must not fire)"
one_case 'libc6 (>> 2.40)'            ""         "a strict lower bound above the floor (must not fire)"
one_case 'libc6:amd64 (>= 2.34)'      ""         "an arch-qualified name (must not fire)"

# Provides resolution: a declared name the computed package PROVIDES must count
# as declared, because that is what apt does — the t64 rename means the declared
# list can only name one of the two, and the install is ground truth.
prov_d="$(mktemp)"; prov_c="$(mktemp)"; prov_p="$(mktemp)"
printf 'libgtk-3-0 (>= 3.21.5)\nlibglib2.0-0 (>= 2.66.0)\n' >"$prov_d"
printf 'libgtk-3-0t64 (>= 3.21.5)\nlibglib2.0-0t64 (>= 2.66.0)\nlibabsent (>= 1)\n' >"$prov_c"
printf 'libgtk-3-0t64 libgtk-3-0\nlibglib2.0-0t64 libglib2.0-0\n' >"$prov_p"
prov_out="$(smoke_depends_gaps "$prov_d" "$prov_c" "$prov_p")"
if printf '%s\n' "$prov_out" | grep -q 'libgtk-3-0t64'; then
  fail=$((fail + 1)); echo "FAIL  a provided name should count as declared (libgtk-3-0t64)" >&2
else pass=$((pass + 1)); fi
if printf '%s\n' "$prov_out" | grep -q 'libglib2.0-0t64'; then
  fail=$((fail + 1)); echo "FAIL  a provided name should count as declared (libglib2.0-0t64)" >&2
else pass=$((pass + 1)); fi
# MUST still fire: Provides resolution must not become a blanket amnesty.
if printf '%s\n' "$prov_out" | grep -q 'MISSING libabsent'; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  a genuinely absent dependency must still be MISSING" >&2; fi
# MUST still fire: a provided name does not excuse a too-low floor.
printf 'libgtk-3-0 (>= 1.0)\n' >"$prov_d"
printf 'libgtk-3-0t64 (>= 3.21.5)\n' >"$prov_c"
if smoke_depends_gaps "$prov_d" "$prov_c" "$prov_p" | grep -q '^TOOLOW '; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  a too-low floor must still fire through a provided name" >&2; fi
# Without the map, behaviour is unchanged (so nothing silently depends on it).
printf 'libgtk-3-0 (>= 3.21.5)\n' >"$prov_d"
if smoke_depends_gaps "$prov_d" "$prov_c" | grep -q '^MISSING libgtk-3-0t64'; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  without a provides map the t64 name should read as MISSING" >&2; fi
rm -f "$prov_d" "$prov_c" "$prov_p"

rm -f "$dep_d" "$dep_c"

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
  # check-appimage.sh resolves the app binary from the .desktop Exec rather than
  # guessing at find order, so the fixture has to carry one as a real AppImage
  # does. Without it the script correctly refuses, and this regression test then
  # measures the refusal instead of the bundle scan it exists to pin.
  printf '[Desktop Entry]\nExec=app\n' >"$appdir/app.desktop"
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

  # ── the ceiling must cover EVERY bundled ELF, not just the app's own ────────
  # A helper in usr/bin that is NOT the .desktop Exec target is exactly where a
  # too-new-glibc dependency arrives, and it was invisible: the scan fed itself
  # one binary plus *.so* files, so a helper requiring GLIBC_9.99 left the gate
  # green. The bundle's ceiling is a property of the WHOLE bundle — the Exec
  # binary names the app, it does not bound the bundle.
  #
  # The fixture patches a real ELF's version string in place (same length, so
  # every offset survives) rather than trying to build one that genuinely needs
  # a nonexistent glibc.
  appdir2="$(mktemp -d)"
  mkdir -p "$appdir2/usr/bin"
  printf '[Desktop Entry]\nExec=app\n' >"$appdir2/app.desktop"
  cp "$real_elf" "$appdir2/usr/bin/app"
  cp "$real_elf" "$appdir2/usr/bin/helper"
  LC_ALL=C sed -i 's/GLIBC_2\.34/GLIBC_9.99/' "$appdir2/usr/bin/helper" 2>/dev/null || true
  if objdump -T "$appdir2/usr/bin/helper" 2>/dev/null | grep -q 'GLIBC_9\.99'; then
    if out2="$(bash "$here/check-appimage.sh" "$appdir2" 2>&1)"; then
      fail=$((fail + 1))
      echo "FAIL  a non-Exec helper requiring GLIBC_9.99 left the ceiling GREEN" >&2
    else
      pass=$((pass + 1))
    fi
    if printf '%s' "$out2" | grep -q 'helper'; then pass=$((pass + 1)); else
      fail=$((fail + 1))
      echo "FAIL  the too-new helper was not named as the worst offender" >&2
      printf '      output was: %s\n' "$out2" >&2
    fi
  else
    # The patch is the whole fixture; if it did not take, the case proves nothing
    # and must say so rather than counting as covered.
    echo "SKIP  bundle-wide ceiling regression (could not patch a GLIBC version)" >&2
  fi
  rm -rf "$appdir2"
else
  echo "SKIP  N1 bundle-scan regression (no objdump)" >&2
fi

# ── the check runner: one check per invocation ───────────────────────────────
# The Linux drivers are now run one check at a time (release-smoke.yaml gives
# each its own CI step), and the machinery for that lives in common.sh so this
# file can drive it — same reason the matchers do. What it has to get right is
# entirely about what happens BETWEEN invocations, and every way of getting it
# wrong looks like a pass:
#   - a check that runs out of order, after tooling has been installed, cannot
#     find the under-declared dependency it exists to find;
#   - a check whose predecessor never ran must not report on an install that is
#     not there;
#   - a stale state file must not let a later check believe in an install the
#     current run never made.
#
# DRIVEN AS A CHILD PROCESS, through a fake driver built here, because
# smoke_dispatch ends in `exit` and because the real thing is a fresh process per
# check. Calling the functions in-process would test a shape production never
# uses — the trap the Windows harness fell into (see its header).
runner_dir="$(mktemp -d)"
cat >"$runner_dir/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
. "$SMOKE_HERE/common.sh"
UNYT_SMOKE_CHECKS=(
  "one|check one|c_one"
  "two|check two|c_two"
  "three|check three|c_three"
)
UNYT_SMOKE_GATE=one
UNYT_SMOKE_STATE_VARS=(GATE_OK MARK)
c_one() {
  [ "${FAKE_BREAK:-}" = one ] && return 1
  smoke_state_set MARK hello && smoke_state_set GATE_OK 1
}
c_two() {
  [ "${FAKE_BREAK:-}" = two ] && return 1
  [ "${MARK:-}" = hello ] || { echo "::error::MARK did not survive the invocation" >&2; return 1; }
  return 0
}
c_three() { [ "${FAKE_BREAK:-}" = three ] && return 1; return 0; }
MODE=all; ONLY=""
case "${1:-}" in
  --print-checks) MODE=print ;;
  --only) MODE=only; ONLY="${2:-}" ;;
esac
smoke_dispatch "$MODE" "$ONLY"
DRIVER

RUNNER_OUT=""; RUNNER_ERR=""; RUNNER_RC=0
drive() { # <state-dir> [args...]
  local state="$1"; shift
  RUNNER_ERR="$runner_dir/stderr.log"
  RUNNER_OUT="$(SMOKE_HERE="$here" UNYT_SMOKE_STATE="$state" \
    bash "$runner_dir/driver.sh" "$@" 2>"$RUNNER_ERR")"
  RUNNER_RC=$?
}
expect_rows() { # <expected stdout> <description>
  if [ "$RUNNER_OUT" = "$1" ]; then pass=$((pass + 1)); return; fi
  fail=$((fail + 1))
  printf 'FAIL  %-58s rows were:\n%s\n' "$2" "${RUNNER_OUT:-<none>}" >&2
}
expect_runner_rc() { # <rc> <description>
  if [ "$RUNNER_RC" = "$1" ]; then pass=$((pass + 1)); return; fi
  fail=$((fail + 1))
  printf 'FAIL  %-58s exit was %s, expected %s\n' "$2" "$RUNNER_RC" "$1" >&2
}
expect_runner_err() { # <substring> <description>
  if grep -qF -e "$1" "$RUNNER_ERR"; then pass=$((pass + 1)); return; fi
  fail=$((fail + 1))
  printf 'FAIL  %-58s no "%s" in the diagnosis\n' "$2" "$1" >&2
}

# The list every other piece reads: the workflow's step ids, and the guard's
# expectation of what should have reported.
drive "$runner_dir/s0" --print-checks
expect_rows "$(printf 'one\tcheck one\ntwo\tcheck two\nthree\tcheck three')" \
  "--print-checks is <id><TAB><name> in run order"
expect_runner_rc 0 "--print-checks exits 0"

# The whole run, unchanged: every check, in order, one row each.
drive "$runner_dir/s1"
expect_rows "$(printf 'check one|pass\ncheck two|pass\ncheck three|pass')" "the whole run reports every check"
expect_runner_rc 0 "a clean whole run exits 0"

# A FAILING CHECK MUST NOT SILENCE THE NEXT ONE. Both are independent, and CI
# needs both rows — the whole point of a step per check.
FAKE_BREAK=two drive "$runner_dir/s2"
expect_rows "$(printf 'check one|pass\ncheck two|FAIL\ncheck three|pass')" \
  "a failed check still lets the next one report"
expect_runner_rc 1 "a whole run with a failure exits 1"

# One check per invocation, sharing a state directory — the CI shape. `check two`
# reads MARK, which only exists if the state file carried it across processes.
drive "$runner_dir/s3" --only one
expect_rows "check one|pass" "--only prints exactly one row"
expect_runner_rc 0 "a passing --only exits 0"
drive "$runner_dir/s3" --only two
expect_rows "check two|pass" "state crosses the process boundary"
expect_runner_rc 0 "the second --only exits 0"

# THE ORDER GUARD. Running a later check first is how the split could quietly
# stop honouring the sequence that makes the closure check mean anything.
drive "$runner_dir/s4" --only two
expect_rows "check two|FAIL" "a check whose predecessor never ran FAILS"
expect_runner_rc 1 "and exits non-zero"
expect_runner_err "has to run after: check one" "the diagnosis names the missing predecessor"

drive "$runner_dir/s5" --only one
drive "$runner_dir/s5" --only three
expect_rows "check three|FAIL" "one skipped predecessor is still refused"
expect_runner_err "has to run after: check two" "and the skipped one is named"

# THE GATE. With the first check failed there is no install to look at, and the
# rest must say so rather than reporting on nothing.
FAKE_BREAK=one drive "$runner_dir/s6" --only one
expect_rows "check one|FAIL" "a failing gate check reports FAIL"
drive "$runner_dir/s6" --only two
expect_rows "check two|FAIL" "the gate having failed refuses the next check"
expect_runner_err "'check one' check did not pass" "and says which check it is waiting on"

drive "$runner_dir/s7" --only one
FAKE_BREAK=one drive "$runner_dir/s7" --only one
expect_rows "check one|FAIL" "re-running the gate check can still fail"
drive "$runner_dir/s7" --only two
expect_rows "check two|FAIL" "a previous run's GATE_OK does not survive into this one"
expect_runner_err "'check one' check did not pass" "and the gate is what refuses it"

# A STALE STATE FILE MUST NOT OUTLIVE ITS RUN, and this is the case that says so:
# the WHOLE-RUN path, where every check shares one shell. Loading state is
# sourcing, and sourcing cannot REMOVE a variable that is no longer in the file —
# so a GATE_OK left in the directory by an earlier run stays in scope for the
# whole run that follows, and every check after a FAILED install reports on the
# install before it. The unset-on-load is what stops that, and only a single
# process can show it: with a step per check there is no scope to leak into.
mkdir -p "$runner_dir/s11"
printf 'GATE_OK=1\nMARK=hello\n' >"$runner_dir/s11/state.env"
FAKE_BREAK=one drive "$runner_dir/s11"
expect_rows "$(printf 'check one|FAIL\ncheck two|FAIL\ncheck three|FAIL')" \
  "a stale state file does not carry a previous run's install into this one"
expect_runner_err "'check one' check did not pass" "the gate refuses them, not a stale GATE_OK"

# THE STATE FILE IS THE ONLY SOURCE OF STATE, and that includes whatever the
# caller happens to have in its environment. A RAN_* or a GATE_OK inherited from
# the shell would otherwise satisfy the order guard for checks that never ran —
# the same leak as a stale file, arriving by the other door.
RUNNER_ERR="$runner_dir/stderr.log"
RUNNER_OUT="$(SMOKE_HERE="$here" UNYT_SMOKE_STATE="$runner_dir/s12" \
  RAN_ONE=1 RAN_TWO=1 GATE_OK=1 bash "$runner_dir/driver.sh" --only three 2>"$RUNNER_ERR")"
RUNNER_RC=$?
expect_rows "check three|FAIL" "an inherited RAN_/GATE_OK does not count as having run"
expect_runner_rc 1 "and the check goes red rather than reporting on nothing"
expect_runner_err "has to run after: check one, check two" "both predecessors are still named"

# An id nobody declared is an INVOCATION error (2), not a failing artifact (1).
drive "$runner_dir/s8" --only nosuch
expect_runner_rc 2 "an unknown check id exits 2, not 1"
expect_runner_err "no such check: nosuch" "and names the id"

# UNYT_SMOKE_RESULTS accumulates across invocations: that file is what the
# summary reads, and on Linux it is read back out of a container that may since
# have died.
res="$runner_dir/results"
: >"$res"
UNYT_SMOKE_RESULTS="$res" drive "$runner_dir/s9" --only one
UNYT_SMOKE_RESULTS="$res" drive "$runner_dir/s9" --only two
if [ "$(cat "$res")" = "$(printf 'check one|pass\ncheck two|pass')" ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL  %-58s results file held:\n%s\n' "UNYT_SMOKE_RESULTS collects a row per invocation" "$(cat "$res")" >&2
fi

# A state value nobody declared would never be cleared on load, which is the
# stale-state bug wearing its other hat.
UNYT_SMOKE_CHECKS=("one|check one|c_one") UNYT_SMOKE_GATE=one
UNYT_SMOKE_STATE_VARS=(GATE_OK)
if UNYT_SMOKE_STATE="$runner_dir/s10" smoke_state_set SNEAKY 1 2>/dev/null; then
  fail=$((fail + 1)); echo "FAIL  an undeclared state variable was accepted" >&2
else pass=$((pass + 1)); fi

rm -rf "$runner_dir"

# ── the did-it-run guard ─────────────────────────────────────────────────────
# summarise-checks.sh is what turns "one step per check" from a reporting change
# into a safe one: with the checks spread across steps, a check can stop
# happening, and a shorter table is exactly as green as a clean one.
sum_dir="$(mktemp -d)"
sum_case() { # <rows> <expected-rc> <description> [expected-substring] [line-ending]
  local rows="$1" want="$2" desc="$3" want_text="${4:-}" eol="${5:-}" out rc list
  list='printf "a\tone\nb\ttwo\nc\tthree\n"'
  if [ "$eol" = crlf ]; then
    rows="${rows//$'\n'/$'\r\n'}"
    list='printf "a\tone\r\nb\ttwo\r\nc\tthree\r\n"'
  fi
  printf '%s' "$rows" >"$sum_dir/results"
  out="$(bash "$here/summarise-checks.sh" --label L --results "$sum_dir/results" \
    -- bash -c "$list" 2>&1)"
  rc=$?
  if [ "$rc" = "$want" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL  %-58s exit %s, expected %s\n' "$desc" "$rc" "$want" >&2; fi
  [ -n "$want_text" ] || return 0
  if printf '%s' "$out" | grep -qF -e "$want_text"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL  %-58s no "%s" in:\n%s\n' "$desc" "$want_text" "$out" >&2; fi
}
sum_case 'one|pass
two|pass
three|pass
' 0 "every check reported and passed"
# The one that matters: a check that never reported is not a pass, and the table
# says so in the column people actually read.
sum_case 'one|pass
three|pass
' 1 "a check that never reported" "DID NOT RUN"
sum_case 'one|pass
two|pass
two|pass
three|pass
' 1 "a check wired up twice" "REPORTED 2x"
sum_case '' 1 "nothing reported at all" "DID NOT RUN"
sum_case 'one|pass
two|FAIL
three|pass
' 1 "a failed check"
# `warn` is the Windows signing lane's declared state: visible, and green.
sum_case 'one|pass
two|warn
three|pass
' 0 "a declared warn does not fail the job" "warn"
# FAILS CLOSED when it cannot read what to expect — with no list, nothing can be
# found missing and every table reads clean.
bash "$here/summarise-checks.sh" --label L --results "$sum_dir/results" -- false >/dev/null 2>&1
if [ $? -eq 2 ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  an unreadable check list must be an invocation error" >&2; fi
bash "$here/summarise-checks.sh" --label L --results "$sum_dir/results" -- true >/dev/null 2>&1
if [ $? -eq 2 ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  an empty check list must be an invocation error" >&2; fi
# BOTH SIDES OF THE BOUNDARY BETWEEN pwsh AND bash EMIT CRLF, and the Windows
# summary compares one against the other from git-bash. Left unstripped, every
# declared name carries a trailing `\r`, nothing matches, and a flawless run
# reports twelve checks as DID NOT RUN. Invisible to every other test here
# because Linux pwsh — which is the only pwsh this repo can run — emits LF.
sum_case 'one|pass
two|warn
three|pass
' 0 "CRLF from PowerShell still matches its rows" "warn" crlf
rm -rf "$sum_dir"

# ── the workflow wires up exactly the checks the scripts declare ─────────────
# The did-it-run guard catches a missing step at the next release, as a red run.
wf="$here/../../.github/workflows/release-smoke.yaml"
if [ -f "$wf" ]; then
  # Every id the workflow asks for, by either name: the Linux lane goes through
  # run-smoke.sh (`--exec`), the macOS lane calls its script directly (`--only`).
  wired="$(grep -oE -- '(--only|--exec) [a-z][a-z-]*' "$wf" | awk '{print $2}' | sort -u)"
  for spec in container-checks.sh container-checks-appimage.sh check-macos.sh; do
    missing=""
    while read -r id; do
      printf '%s\n' "$wired" | grep -qx -- "$id" || missing="${missing:+$missing }$id"
    done < <(bash "$here/$spec" --print-checks | cut -f1)
    if [ -z "$missing" ]; then pass=$((pass + 1)); else
      fail=$((fail + 1))
      printf 'FAIL  %-58s no CI step runs: %s\n' "$spec declares a check nobody wired up" "$missing" >&2
    fi
  done
  # THE SUFFIXES MUST MATCH THE DOWNLOADERS. Each lane skips when the inventory
  # says its artifact is absent, so a suffix that drifts from what the lane
  # downloads does not fail — it skips that lane forever, silently.
  for suffix in $(grep -oE '^[A-Z]+_SUFFIX="[^"]+"' scripts/smoke/release-inventory.sh | cut -d'"' -f2) \
                $(grep -oE '"[a-z0-9_]+_darwin\.dmg"' scripts/smoke/release-inventory.sh | tr -d '"' | sort -u); do
    if grep -qF -- "$suffix" "$wf"; then pass=$((pass + 1)); else
      fail=$((fail + 1))
      printf 'FAIL  %-58s %s\n' "inventory suffix no lane downloads" "$suffix" >&2
    fi
  done

  # The other direction — an id in the workflow that no script owns — is left to
  # runtime: it exits 2 there as an invocation error, which is a red step naming
  # the typo. Asserting it here would need the Windows registry too, and that
  # needs pwsh.

  # EVERY JOB IS NON-BLOCKING, OR THE RELEASE GOES RED AGAIN. `non-blocking`
  # keeps a failed check out of the calling release run's conclusion, but it does
  # that one job at a time: a lane added later without the key silently restores
  # the behaviour the input exists to remove, and nothing would say so until the
  # next release run came back red for a report. A prose "every job below carries
  # it" cannot catch that; counting can.
  #
  # PAIRED PER JOB, NOT COUNTED. Two totals can agree while being wrong about
  # every job in the file — miss one job key and forget the flag on another, and
  # 4 == 4 reports clean. Walking the blocks costs the same and can also NAME the
  # job, which a count cannot.
  #
  # Read only below `jobs:`, and over the full set of characters a job id may
  # use. Two-space keys exist above it too — `workflow_dispatch:` and
  # `workflow_call:` — so a whole-file scan is scanning the wrong thing: under
  # the pattern below it reads both as jobs, finds no flag under either, and
  # fails today. The only thing that would rescue a whole-file scan is narrowing
  # the name to `[a-z-]` so those two are skipped for containing an underscore,
  # and that cuts the other, worse way: a job called `linux_images` would go
  # unexamined, and an unexamined job is exactly the unflagged job this exists
  # to find. So: slice first, match broadly. A TRAILING COMMENT on the
  # key is admitted for the same reason — `windows:  # the windows lane` is legal
  # YAML, and a key regex that rejects it does not report that job as unflagged,
  # it stops seeing the job at all and attributes the next flag it meets to the
  # job before. The flag is anchored at four spaces, so the comment that quotes
  # it is never mistaken for the key.
  unflagged="$(printf '%s\n' "$(sed -n '/^jobs:/,$p' "$wf")" | awk '
    /^  [A-Za-z_][A-Za-z0-9_-]*:[ \t]*(#.*)?$/ {
      if (job != "" && !seen) print job
      job = $0; sub(/^  /, "", job); sub(/:.*$/, "", job); seen = 0; n++; next
    }
    /^    continue-on-error: \$\{\{ inputs\.non-blocking == true \}\}[ \t]*$/ { seen = 1 }
    END { if (job != "" && !seen) print job; if (n == 0) print "<no jobs found>" }')"
  if [ -z "$unflagged" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "release-smoke.yaml job without non-blocking" \
      "$(printf '%s' "$unflagged" | tr '\n' ' ')" >&2
  fi

  # AND THE INPUT STAYS OFF `workflow_dispatch`. The flag above is only safe
  # because the person who runs this smoke by hand cannot be handed a green run
  # for a red smoke — that is the whole reason `non-blocking` is declared under
  # `workflow_call` alone. Nothing else asserts it, and adding it to the dispatch
  # inputs would look like a convenience.
  if sed -n '/^  workflow_dispatch:/,/^  workflow_call:/p' "$wf" |
      grep -q 'non-blocking'; then
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "non-blocking offered on workflow_dispatch" \
      "a hand-dispatched smoke must be able to conclude failure" >&2
  else pass=$((pass + 1)); fi
else
  echo "SKIP  workflow/registry correspondence (no release-smoke.yaml)" >&2
fi

# ── the inventory decides which lanes run, so it must not be able to lie ─────
# A lane skips when its artifact is absent — right for a build that failed, wrong
# for an inventory that reports nothing by accident, which would leave a run that
# passed having examined nothing.
inv() { UNYT_SMOKE_ASSETS="$1" bash "$here/release-inventory.sh" 000 2>/dev/null; }
inv_rc() { UNYT_SMOKE_ASSETS="$1" bash "$here/release-inventory.sh" 000 >/dev/null 2>&1; }

full='x_linux.deb
x_linux.AppImage
x_aarch64_darwin.dmg
x_x64_darwin.dmg
x_x64_windows.exe
x_x64_windows.msi'

got="$(inv "$full")"
for want in 'deb=true' 'appimage=true' 'exe=true' 'msi=true'; do
  if printf '%s\n' "$got" | grep -qx -- "$want"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL  %-58s %s\n' "full release should report $want" "$got" >&2; fi
done
if [ "$(printf '%s\n' "$got" | grep -o '"arch"' | grep -c .)" = 2 ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL  %s\n' "full release should yield both macOS matrix rows" >&2; fi

# Each artifact absent is reported absent, and its neighbours stay present.
while IFS='|' read -r drop key; do
  [ -n "$drop" ] || continue
  got="$(inv "$(printf '%s\n' "$full" | grep -v -- "$drop")")"
  if printf '%s\n' "$got" | grep -qx -- "$key=false" &&
     [ "$(printf '%s\n' "$got" | grep -c '=true')" = 3 ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s dropped %s\n' "only $key should read absent" "$drop" >&2
  fi
done <<'DROPS'
linux.deb|deb
linux.AppImage|appimage
x64_windows.exe|exe
x64_windows.msi|msi
DROPS

# One macOS build failing costs one matrix row, not the lane.
got="$(inv "$(printf '%s\n' "$full" | grep -v aarch64_darwin)")"
if printf '%s\n' "$got" | grep -q 'dmgs=\[{"runner":"macos-15-intel"' &&
   ! printf '%s\n' "$got" | grep -q 'aarch64'; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL  %s\n' "a missing arm64 DMG should drop only its row" >&2; fi

# THE CASE THIS BLOCK EXISTS FOR: the shape of run 31800038674, where every build
# failed. Skipping all four lanes would be a green run that smoked nothing.
if inv_rc 'unyt.happ
unyt.webhapp
alliance.dna'; then
  fail=$((fail + 1))
  printf 'FAIL  %s\n' "a release with no installers must not report a clean inventory" >&2
else pass=$((pass + 1)); fi
if inv_rc ''; then
  fail=$((fail + 1))
  printf 'FAIL  %s\n' "an empty asset list must not report a clean inventory" >&2
else pass=$((pass + 1)); fi

# The real drivers declare real checks. Cheap, and it is what the workflow's
# `--only <id>` arguments are written against.
for drv in container-checks.sh container-checks-appimage.sh; do
  n="$(bash "$here/$drv" --print-checks | grep -c $'\t' || true)"
  if [ "$n" -ge 3 ]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL  %s --print-checks listed %s check(s)\n' "$drv" "$n" >&2; fi
done

echo "oracle regression: $pass passed, $fail failed"

# ANNOTATE, don't only exit non-zero. Every FAIL above goes to stderr, which is
# a line inside a collapsed step log — readable when a red run sent you looking,
# invisible when it did not. The job that runs this file is `continue-on-error`
# on a release, so the run stays green and nothing sends you looking; the
# annotation is then the only thing that surfaces on its own.
if [ "$fail" -ne 0 ]; then
  echo "::error title=Smoke oracle regressed::$fail assertion(s) failed — the checks' own guarantees are not holding; see this step's log for which"
fi

# A floor on the COUNT, not just on failures: truncate this file and it would
# otherwise report "3 passed, 0 failed" and exit 0 — the same shape as the
# container-never-ran bug one level up. Raise it when adding assertions.
if [ "$pass" -lt 125 ]; then
  echo "::error::only $pass assertions ran; expected at least 125 — the test file is truncated or a block was skipped"
  exit 1
fi
[ "$fail" -eq 0 ]
