#!/usr/bin/env bash
# Regression test for the health oracle: fixture log lines through the REAL
# `smoke_match_*` / `smoke_count_*` in common.sh, never a copy — all three
# defects this exists for were in the INVOCATION, not the pattern, so a copy
# would have passed while the call site stayed broken.
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
# Before the fix these returned "" (grep: invalid option) and the caller's
# arithmetic produced 0, so a permanently flapping conductor passed.
D="$P Ready -> ConductorDisconnected"
check_count "no disconnects"  0 "$P LairReady -> Ready"
check_count "one disconnect"  1 "$D"
check_count "five disconnects" 5 "$D
$D
$D
$D
$D"
check "a disconnect is not a terminal failure" no "$D" smoke_match_failed

got="$(printf '%s\n' "$P LairReady -> NetworkSetupRequired { agent_key: \"uhCAkAAA\", has_existing_key: false }" | smoke_first_backend_ready)"
case "$got" in
  *NetworkSetupRequired*uhCAkAAA*) pass=$((pass + 1)) ;;
  *) fail=$((fail + 1)); printf 'FAIL  %-58s got: %s\n' "first-healthy reports the matched state" "$got" >&2 ;;
esac

# has_existing_key: true is CORRECT on an authenticated build's first install
# (hc-auth mints a key at boot and resolve_agent_key reuses it), so it cannot be
# the freshness signal.
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
# A declared floor BELOW the computed one used to pass silently, and libstdc++6
# was reported missing because `c++` is an ERE quantifier.
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
one_case() { # <declared> <expected-finding-prefix> <description>
  local df cf out
  df="$(mktemp)"; cf="$(mktemp)"
  printf '%s\n' "$1" >"$df"; printf 'libc6 (>= 2.34)\n' >"$cf"
  out="$(smoke_depends_gaps "$df" "$cf")"
  if [ -z "$2" ]; then
    # An empty expectation needs its own branch: `case "$out" in "$2"*)` becomes
    # `*)`, which matches ANY output.
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
one_case 'libc6 (>= 2.34)'            ""         "an exact floor (must not fire)"
one_case 'libc6 (>=2.34)'             ""         "a valid no-space floor (must not fire)"
one_case 'libc6 (>> 2.40)'            ""         "a strict lower bound above the floor (must not fire)"
one_case 'libc6:amd64 (>= 2.34)'      ""         "an arch-qualified name (must not fire)"

# A declared name the computed package PROVIDES counts as declared, because that
# is what apt does — the t64 rename means the declared list can only name one of
# the two.
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
if printf '%s\n' "$prov_out" | grep -q 'MISSING libabsent'; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  a genuinely absent dependency must still be MISSING" >&2; fi
printf 'libgtk-3-0 (>= 1.0)\n' >"$prov_d"
printf 'libgtk-3-0t64 (>= 3.21.5)\n' >"$prov_c"
if smoke_depends_gaps "$prov_d" "$prov_c" "$prov_p" | grep -q '^TOOLOW '; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  a too-low floor must still fire through a provided name" >&2; fi
printf 'libgtk-3-0 (>= 3.21.5)\n' >"$prov_d"
if smoke_depends_gaps "$prov_d" "$prov_c" | grep -q '^MISSING libgtk-3-0t64'; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  without a provides map the t64 name should read as MISSING" >&2; fi
rm -f "$prov_d" "$prov_c" "$prov_p"

rm -f "$dep_d" "$dep_c"

# ── B: a duplicate declared entry must not read as a missing floor ───────────
# tauri-bundler appends bare `libwebkit2gtk-4.1-0` and `libgtk-3-0` on top of the
# floored list it copied from tauri.conf.json, and `sort -u` puts the bare entry
# FIRST (a prefix sorts before its extension).
#
# Debian `Depends` is a comma-separated AND list, so a duplicate ADDS a
# requirement rather than replacing one. Verified empirically rather than from
# the policy text: on ubuntu:22.04 and debian:13, apt and dpkg both refuse
# `libgtk-3-0 (>= 99.0), libgtk-3-0` — in either order — against libgtk-3-0 3.24.
dup_case() { # <description> <computed> <expected-finding-or-empty> <declared...>
  local desc="$1" computed="$2" want="$3"; shift 3
  local df cf out
  df="$(mktemp)"; cf="$(mktemp)"
  printf '%s\n' "$@" >"$df"
  printf '%s\n' "$computed" >"$cf"
  out="$(smoke_depends_gaps "$df" "$cf")"
  if [ "$out" = "$want" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s expected [%s], got [%s]\n' "$desc" "${want:-<no finding>}" "${out:-<no finding>}" >&2
    printf '      declared was: %s\n' "$*" >&2
  fi
  rm -f "$df" "$cf"
}
GTK='libgtk-3-0 (>= 3.21.5)'
# Order must not change the verdict — the whole defect was that it did.
dup_case "floored THEN bare"                  "$GTK" "" 'libgtk-3-0 (>= 3.21.5)' 'libgtk-3-0'
dup_case "bare THEN floored"                  "$GTK" "" 'libgtk-3-0' 'libgtk-3-0 (>= 3.21.5)'
dup_case "two floors, adequate one first"     "$GTK" "" 'libgtk-3-0 (>= 3.21.5)' 'libgtk-3-0 (>= 1.0)'
dup_case "two floors, adequate one last"      "$GTK" "" 'libgtk-3-0 (>= 1.0)' 'libgtk-3-0 (>= 3.21.5)'
dup_case "an adequate floor behind two duds"  "$GTK" "" 'libgtk-3-0' 'libgtk-3-0 (<= 9)' 'libgtk-3-0 (>= 3.21.5)'
dup_case "bare only is still unconstrained"   "$GTK" 'UNCONSTRAINED libgtk-3-0 (>= 3.21.5)' 'libgtk-3-0'
# Both too low: still TOOLOW, and it names the HIGHEST declared floor, which is
# the one actually in force once the entries are ANDed.
dup_case "two floors, both too low"           "$GTK" 'TOOLOW libgtk-3-0 (>= 3.21.5) declared (>= 3.0)' \
  'libgtk-3-0 (>= 1.0)' 'libgtk-3-0 (>= 3.0)'
dup_case "two floors, both too low, reversed" "$GTK" 'TOOLOW libgtk-3-0 (>= 3.21.5) declared (>= 3.0)' \
  'libgtk-3-0 (>= 3.0)' 'libgtk-3-0 (>= 1.0)'
dup_case "a too-low floor outranks a bare dup" "$GTK" 'TOOLOW libgtk-3-0 (>= 3.21.5) declared (>= 1.0)' \
  'libgtk-3-0' 'libgtk-3-0 (>= 1.0)'
dup_case "a non-floor outranks a bare dup"    "$GTK" 'NOFLOOR libgtk-3-0 (>= 3.21.5) declared (<= 9) — not a lower bound' \
  'libgtk-3-0' 'libgtk-3-0 (<= 9)'
dup_case "duplicates of the wrong package"    "$GTK" 'MISSING libgtk-3-0 (>= 3.21.5)' 'libfoo' 'libfoo (>= 1)'
# Ties are broken WITHOUT reference to input order, in byte order rather than the
# caller's collation: en_US.UTF-8 and C disagree on where `<` sorts against `=`.
NOFL='NOFLOOR libgtk-3-0 (>= 3.21.5) declared (<= 9) — not a lower bound'
dup_case "two non-floors tie, first order"    "$GTK" "$NOFL" 'libgtk-3-0 (<= 9)' 'libgtk-3-0 (= 4)'
dup_case "two non-floors tie, reversed"       "$GTK" "$NOFL" 'libgtk-3-0 (= 4)' 'libgtk-3-0 (<= 9)'
EQFL='TOOLOW libgtk-3-0 (>= 3.21.5) declared (>= 1.0)'
dup_case "equal too-low floors, first order"  "$GTK" "$EQFL" 'libgtk-3-0 (>= 1.0)' 'libgtk-3-0 (>> 1.0)'
dup_case "equal too-low floors, reversed"     "$GTK" "$EQFL" 'libgtk-3-0 (>> 1.0)' 'libgtk-3-0 (>= 1.0)'
# en_US.UTF-8 is the leg that bites: its collation ignores punctuation at the
# primary level, so `<= 9` and `= 4` compare by their digits and swap round.
tie_under_locale() { # <locale>
  LC_ALL="$1" LANG="$1" bash -c '
    . "'"$here"'/common.sh"
    d=$(mktemp); c=$(mktemp)
    printf "libgtk-3-0 (= 4)\nlibgtk-3-0 (<= 9)\n" >"$d"
    printf "libgtk-3-0 (>= 3.21.5)\n" >"$c"
    smoke_depends_gaps "$d" "$c"; rm -f "$d" "$c"'
}
for loc in C en_US.UTF-8; do
  # A locale the machine does not have silently falls back to C, which would make
  # this pass without testing anything. `locale -a` spells them without the dash
  # and in lower case (`en_US.utf8`), hence the normalising on both sides.
  loc_key="${loc//-/}"
  if ! locale -a 2>/dev/null | tr -d '-' | grep -qixF "$loc_key"; then
    echo "SKIP  tie-break under LC_ALL=$loc (locale not generated)" >&2
    continue
  fi
  tie_out="$(tie_under_locale "$loc")"
  if [ "$tie_out" = "$NOFL" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s got: %s\n' "the tie-break is the same under LC_ALL=$loc" "$tie_out" >&2
  fi
done

# ── a declared ALTERNATION guarantees only what its weakest branch does ──────
# `a | b` lets apt satisfy the dependency through EITHER package, so every branch
# has to carry the floor for the line to count. The parser reads "the first (…)
# on the line" and credits it to the line's first name, so an alternation used to
# hand one package's floor to another.
WK='libwebkit2gtk-4.1-0 (>= 2.41.90)'
UNWK='UNCONSTRAINED libwebkit2gtk-4.1-0 (>= 2.41.90)'
dup_case "an alternation's floor is not the other branch's" "$WK" "$UNWK" \
  'libwebkit2gtk-4.1-0' 'libwebkit2gtk-4.1-0 | libwebkit2gtk-4.0-37 (>= 2.41.90)'
dup_case "an alternation alone is not a floor"              "$WK" "$UNWK" \
  'libwebkit2gtk-4.1-0 | libwebkit2gtk-4.0-37 (>= 2.41.90)'
dup_case "a floor on only the first branch"                 "$WK" "$UNWK" \
  'libwebkit2gtk-4.1-0 (>= 2.41.90) | libwebkit2gtk-4.0-37'
dup_case "a matching branch behind a non-matching one"      "$GTK" 'UNCONSTRAINED libgtk-3-0 (>= 3.21.5)' \
  'libfoo | libgtk-3-0 (>= 3.21.5)'
# The WEAKEST branch decides, not the first and not the last. Both orders, because
# reading either end alone happens to give the right answer for the cases above.
dup_case "a bare branch after a floored one"                "$GTK" 'UNCONSTRAINED libgtk-3-0 (>= 3.21.5)' \
  'libgtk-3-0 (>= 1.0) | libgtk-3-0'
dup_case "a bare branch before a floored one"               "$GTK" 'UNCONSTRAINED libgtk-3-0 (>= 3.21.5)' \
  'libgtk-3-0 | libgtk-3-0 (>= 1.0)'
dup_case "every branch floored"                             "$GTK" "" \
  'libgtk-3-0 (>= 3.21.5) | libgtk-3-0 (>= 3.21.5)'
# A too-low branch is reported against the WHOLE line: quoting one branch's
# constraint would point at a floor that is not the one in doubt.
dup_case "an alternation with one too-low branch"           "$GTK" \
  'TOOLOW libgtk-3-0 (>= 3.21.5) declared (libgtk-3-0 (>= 3.21.5) | libgtk-3-0 (>= 1.0))' \
  'libgtk-3-0 (>= 3.21.5) | libgtk-3-0 (>= 1.0)'

# ── a computed entry with NO floor needs only to be present ──────────────────
# `libjavascriptcoregtk-4.1-0` is exactly this shape and is in all four expected
# files, so this is the production path, not a corner.
JSC='libjavascriptcoregtk-4.1-0'
dup_case "an unconstrained computed dep, declared once"  "$JSC" "" "$JSC"
dup_case "an unconstrained computed dep, declared twice" "$JSC" "" "$JSC" "$JSC"
dup_case "an unconstrained computed dep, absent"         "$JSC" "MISSING $JSC" 'libfoo'

# ── a computed constraint with no version is unreadable, not absent ──────────
# `dpkg --compare-versions X ge ''` is true for every X, so treating an empty
# requirement as "nothing to prove" would mark every declaration adequate.
dup_case "a computed entry whose constraint has no version" 'libgtk-3-0 (>=)' \
  'UNPARSEABLE libgtk-3-0 (>=) (no version in its constraint)' 'libgtk-3-0 (>= 0.1)'

# ── duplicates through the t64 PROVIDES alias — the path on 3 of the 4 images ─
# debian:13, ubuntu:24.04 and ubuntu:26.04 all compute `libgtk-3-0t64`, which
# resolves to `libgtk-3-0` and then matches BOTH declarations.
prov_case() { # <description> <computed> <expected> <provides-line> <declared...>
  local desc="$1" computed="$2" want="$3" provides="$4"; shift 4
  local df cf pf out
  df="$(mktemp)"; cf="$(mktemp)"; pf="$(mktemp)"
  printf '%s\n' "$@" >"$df"; printf '%s\n' "$computed" >"$cf"; printf '%s\n' "$provides" >"$pf"
  out="$(smoke_depends_gaps "$df" "$cf" "$pf")"
  if [ "$out" = "$want" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s expected [%s], got [%s]\n' "$desc" "${want:-<no finding>}" "${out:-<no finding>}" >&2
  fi
  rm -f "$df" "$cf" "$pf"
}
T64='libgtk-3-0t64 (>= 3.21.5)'
PMAP='libgtk-3-0t64 libgtk-3-0'
prov_case "t64: bare dup before the floored alias"  "$T64" "" "$PMAP" 'libgtk-3-0' 'libgtk-3-0 (>= 3.21.5)'
prov_case "t64: bare dup after the floored alias"   "$T64" "" "$PMAP" 'libgtk-3-0 (>= 3.21.5)' 'libgtk-3-0'
prov_case "t64: the bare dup uses the t64 name"     "$T64" "" "$PMAP" 'libgtk-3-0t64' 'libgtk-3-0 (>= 3.21.5)'
prov_case "t64: the floor arrives on either name"   "$T64" "" "$PMAP" 'libgtk-3-0 (>= 1.0)' 'libgtk-3-0t64 (>= 3.21.5)'
prov_case "t64: every floor too low, highest named" "$T64" \
  'TOOLOW libgtk-3-0t64 (>= 3.21.5) declared (>= 3.0)' "$PMAP" \
  'libgtk-3-0 (>= 1.0)' 'libgtk-3-0t64 (>= 3.0)'
prov_case "t64: bare on both names is still a gap"  "$T64" \
  'UNCONSTRAINED libgtk-3-0t64 (>= 3.21.5)' "$PMAP" 'libgtk-3-0' 'libgtk-3-0t64'

# The same defect through the sorted path the gate actually uses. This is the
# verbatim `Depends` field of the shipped v0.101.0-dev.1 .deb.
real_depends='libc6 (>= 2.34), libcairo-gobject2 (>= 1.10.0), libcairo2 (>= 1.10.0), libgcc-s1 (>= 4.2), libgdk-pixbuf-2.0-0 (>= 2.36.9), libglib2.0-0 (>= 2.66.0), libgtk-3-0 (>= 3.21.5), libjavascriptcoregtk-4.1-0, libpango-1.0-0 (>= 1.14.0), libsoup-3.0-0 (>= 3.0.3), libwebkit2gtk-4.1-0 (>= 2.41.90), libwebkit2gtk-4.1-0, libgtk-3-0'
sorted_d="$(mktemp)"; sorted_c="$(mktemp)"
printf '%s\n' "$real_depends" | smoke_normalize_depends >"$sorted_d"
# The premise: normalize must carry BOTH entries through. De-duplicating by name
# would leave the gap check judging a list the package does not have.
for dupname in libgtk-3-0 libwebkit2gtk-4.1-0; do
  if [ "$(grep -c "^$dupname\( \|$\)" "$sorted_d")" = 2 ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s kept %s copies\n' "both $dupname entries survive normalize" \
      "$(grep -c "^$dupname\( \|$\)" "$sorted_d")" >&2
  fi
done
# The other half of the premise: the BARE entry sorts AHEAD of the floored one,
# which is the whole defect. A sort that reverses it would leave this block
# testing nothing, so it fails here instead and the fixture gets re-picked.
for dupname in libgtk-3-0 libwebkit2gtk-4.1-0; do
  if [ "$(grep "^$dupname\( \|$\)" "$sorted_d" | head -1)" = "$dupname" ]; then
    pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s first was: %s\n' "the bare $dupname sorts ahead of the floored one" \
      "$(grep "^$dupname\( \|$\)" "$sorted_d" | head -1)" >&2
  fi
done
# The whole computed list: `libjavascriptcoregtk-4.1-0` is the one entry with no
# floor, and it is what exercises the presence-only path.
printf 'libc6 (>= 2.34)\nlibgtk-3-0 (>= 3.21.5)\nlibjavascriptcoregtk-4.1-0\nlibwebkit2gtk-4.1-0 (>= 2.41.90)\n' >"$sorted_c"
sorted_out="$(smoke_depends_gaps "$sorted_d" "$sorted_c")"
if [ -z "$sorted_out" ]; then pass=$((pass + 1)); else
  fail=$((fail + 1))
  printf 'FAIL  %-58s got: %s\n' "the shipped Depends, sorted as the gate sorts it" "$sorted_out" >&2
fi
# And the gate still fires on the same sorted list when a floor really is absent.
printf 'libpangocairo-1.0-0 (>= 1.14.0)\n' >"$sorted_c"
if smoke_depends_gaps "$sorted_d" "$sorted_c" | grep -q '^MISSING libpangocairo-1.0-0'; then
  pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  the sorted real list must still report a genuinely absent dep" >&2
fi
rm -f "$sorted_d" "$sorted_c"

# check-deb-depends.sh only ever runs inside a container, so nothing else here
# would notice it being left unparseable.
if bash -n "$here/check-deb-depends.sh" 2>/dev/null; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  check-deb-depends.sh does not parse" >&2
fi

# Every image the smoke runs on needs an expectation file, or check A silently
# does not run there — said at desk time rather than at release time.
while read -r smoke_image; do
  [ -n "$smoke_image" ] || continue
  if [ -f "$here/expected-deb-depends.${smoke_image/:/-}.txt" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s no expected-deb-depends.%s.txt\n' \
      "every smoke image has a dependency expectation" "${smoke_image/:/-}" >&2
  fi
done < <(bash "$here/run-smoke.sh" --print-images 2>/dev/null || true)

# ── N1: the bundle scan must survive a file with no GLIBC_ symbols LAST ──────
# `[ -n "$v" ] && printf` as a loop body's last statement makes the `while` exit
# non-zero, pipefail carries it, and set -e skips every check below. Which file
# lands last is `find` order, so the gate was a coin flip per build.
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
  # A helper in usr/bin that is not the Exec target is where a too-new glibc
  # arrives, and the scan used to miss it: the ceiling is a property of the WHOLE
  # bundle. The fixture patches a real ELF's version string in place.
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

# Everything one-check-per-invocation has to get right is BETWEEN invocations,
# and every way of getting it wrong looks like a pass. Driven as a CHILD PROCESS,
# because in-process would test a shape production never uses.
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

# The workflow's step ids, and the guard's expectation of what should report.
drive "$runner_dir/s0" --print-checks
expect_rows "$(printf 'one\tcheck one\ntwo\tcheck two\nthree\tcheck three')" \
  "--print-checks is <id><TAB><name> in run order"
expect_runner_rc 0 "--print-checks exits 0"

drive "$runner_dir/s1"
expect_rows "$(printf 'check one|pass\ncheck two|pass\ncheck three|pass')" "the whole run reports every check"
expect_runner_rc 0 "a clean whole run exits 0"

FAKE_BREAK=two drive "$runner_dir/s2"
expect_rows "$(printf 'check one|pass\ncheck two|FAIL\ncheck three|pass')" \
  "a failed check still lets the next one report"
expect_runner_rc 1 "a whole run with a failure exits 1"

# The CI shape. `check two` reads MARK, which exists only if the state file
# carried it across processes.
drive "$runner_dir/s3" --only one
expect_rows "check one|pass" "--only prints exactly one row"
expect_runner_rc 0 "a passing --only exits 0"
drive "$runner_dir/s3" --only two
expect_rows "check two|pass" "state crosses the process boundary"
expect_runner_rc 0 "the second --only exits 0"

# THE ORDER GUARD: running a later check first is how the split could stop
# honouring the sequence that makes the closure check mean anything.
drive "$runner_dir/s4" --only two
expect_rows "check two|FAIL" "a check whose predecessor never ran FAILS"
expect_runner_rc 1 "and exits non-zero"
expect_runner_err "has to run after: check one" "the diagnosis names the missing predecessor"

drive "$runner_dir/s5" --only one
drive "$runner_dir/s5" --only three
expect_rows "check three|FAIL" "one skipped predecessor is still refused"
expect_runner_err "has to run after: check two" "and the skipped one is named"

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

# Sourcing cannot REMOVE a variable no longer in the file, so a stale GATE_OK
# stays in scope and every check reports on the install before it.
mkdir -p "$runner_dir/s11"
printf 'GATE_OK=1\nMARK=hello\n' >"$runner_dir/s11/state.env"
FAKE_BREAK=one drive "$runner_dir/s11"
expect_rows "$(printf 'check one|FAIL\ncheck two|FAIL\ncheck three|FAIL')" \
  "a stale state file does not carry a previous run's install into this one"
expect_runner_err "'check one' check did not pass" "the gate refuses them, not a stale GATE_OK"

# THE STATE FILE IS THE ONLY SOURCE OF STATE, the caller's environment included:
# an inherited RAN_* or GATE_OK would satisfy the order guard for checks that
# never ran.
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

# UNYT_SMOKE_RESULTS accumulates across invocations: on Linux the summary reads
# it back out of a container that may since have died.
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
# With the checks spread across steps a check can stop happening, and a shorter
# table is exactly as green as a clean one.
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
# FAILS CLOSED: with no list, nothing can be found missing.
bash "$here/summarise-checks.sh" --label L --results "$sum_dir/results" -- false >/dev/null 2>&1
if [ $? -eq 2 ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  an unreadable check list must be an invocation error" >&2; fi
bash "$here/summarise-checks.sh" --label L --results "$sum_dir/results" -- true >/dev/null 2>&1
if [ $? -eq 2 ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  an empty check list must be an invocation error" >&2; fi
# pwsh and bash both emit CRLF on Windows and the summary compares them from
# git-bash: unstripped, a flawless run reports twelve checks as DID NOT RUN.
sum_case 'one|pass
two|warn
three|pass
' 0 "CRLF from PowerShell still matches its rows" "warn" crlf
# The table reads a row's SECOND field and stops, so an extra field rides along
# unseen.
sum_case 'one|pass
two|pass|and something else
three|pass
' 1 "a row carrying more than a verdict" "malformed result row"
# The other half: a row nobody looks up. A renamed check reports under its old
# name forever and the table never mentions it.
sum_case 'one|pass
two|pass
three|pass
nobody-declares-this|pass
' 1 "a row naming a check that is not declared" "no check declares it"
sum_case 'one|pass
two|probably
three|pass
' 1 "a verdict outside pass/warn/FAIL" "reported the verdict"
# THE RESULT COLUMN, not the annotation: that column is what reaches
# $GITHUB_STEP_SUMMARY, and it is the green a reader believes.
sum_out() { # <rows> — the summary's own stdout and stderr
  printf '%s' "$1" >"$sum_dir/results"
  bash "$here/summarise-checks.sh" --label L --results "$sum_dir/results" \
    -- bash -c 'printf "a\tone\nb\ttwo\nc\tthree\n"' 2>&1
}
sum_cell() { # <rows> <expected RESULT for check `two`> <description>
  local out; out="$(sum_out "$1")"
  if printf '%s\n' "$out" | grep -qE "^L +two +$2\$"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL  %-58s\n%s\n' "$3" "$out" >&2; fi
}
sum_cell 'one|pass
two|pass|and something else
three|pass
' MALFORMED "a row carrying more than a verdict must not print as one"
# The third field UNSET rather than junk: read gives it the empty string, so an
# emptiness test admitted the row.
sum_case 'one|pass
two|pass|
three|pass
' 1 "a row with a trailing empty field" "malformed result row"
sum_cell 'one|pass
two|pass|
three|pass
' MALFORMED "and it does not print as one either"
sum_cell 'one|pass
two|probably
three|pass
' MALFORMED "a verdict outside pass/warn/FAIL must not print as itself"
sum_cell 'one|pass
two|
three|pass
' MALFORMED "an empty verdict is malformed, not a check that never reported"
# One defect, one annotation: an empty verdict used to produce two.
out="$(sum_out 'one|pass
two|
three|pass
')"
n="$(printf '%s\n' "$out" | grep -c '::error::' || true)"
if [ "$n" = 1 ]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL  %-58s %s annotations\n%s\n' "an empty verdict is one defect" "$n" "$out" >&2; fi
# read drops an unterminated final line; the table's awk does not.
sum_case 'one|pass
three|pass
two|pass|junk' 1 "a malformed row with no trailing newline" "malformed result row"
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
  # THE SUFFIXES MUST MATCH THE DOWNLOADERS. A lane skips when the inventory says
  # its artifact is absent, so a drifted suffix does not fail — it skips that lane
  # forever, silently. The DMG suffixes are deliberately absent: they reach their
  # lanes through `matrix.asset`, and the row-count assertions below guard them.
  suffixes="$(grep -oE '^[A-Z]+_SUFFIX="[^"]+"' "$here/release-inventory.sh" | cut -d'"' -f2)"
  while IFS= read -r suffix; do
    [ -n "$suffix" ] || continue
    if grep -qF -- "$suffix" "$wf"; then pass=$((pass + 1)); else
      fail=$((fail + 1))
      printf 'FAIL  %-58s %s\n' "inventory suffix no lane downloads" "$suffix" >&2
    fi
  done <<EOF
$suffixes
EOF

  # The other direction — an id in the workflow that no script owns — is left to
  # runtime, where it exits 2 as an invocation error. Asserting it here would need
  # the Windows registry, and that needs pwsh.

  # PHASE 1 MUST NOT BE SWALLOWABLE. `static-checks-advisory` exists so a red
  # signing check does not fail a release run; a phase-1 lane going green by the
  # same flag would restore the hole this suite was built to close. Asserted BOTH
  # ways and paired PER JOB, since two totals can agree while being wrong about
  # every job.
  #
  # Sliced from `jobs:` first (workflow_dispatch/workflow_call are 2-space keys
  # too), matched broadly, and a trailing comment on the key is admitted —
  # rejecting it would attribute the next flag to the job before.
  #
  # The job id declares the phase, so an id this does not recognise FAILS rather
  # than being assumed into either one.
  phases="$(printf '%s\n' "$(sed -n '/^jobs:/,$p' "$wf")" | awk '
    function emit() { if (job != "") print job, flag }
    /^  [A-Za-z_][A-Za-z0-9_-]*:[ \t]*(#.*)?$/ {
      emit(); job = $0; sub(/^  /, "", job); sub(/:.*$/, "", job); flag = 0; n++; next
    }
    /^    continue-on-error: \$\{\{ inputs\.static-checks-advisory == true \}\}[ \t]*$/ { flag = 1; next }
    # Any other continue-on-error is its own answer: a hand-written `true` would
    # soften a lane in every run, dispatched ones included.
    /^    continue-on-error:/ { flag = 2 }
    END { emit(); if (n == 0) print "<no jobs found>", 0 }')"
  bad=""
  opens=0
  statics=0
  while read -r job flag; do
    [ -n "$job" ] || continue
    case "$job" in
      opens-*) want=0; opens=$((opens + 1)) ;;
      static-*) want=1; statics=$((statics + 1)) ;;
      # An advisory setup job would make this very assertion toothless.
      inventory) want=0 ;;
      *) bad="${bad:+$bad }$job(is it phase 1 or phase 2? name it opens-* or static-*)"; continue ;;
    esac
    [ "$flag" = "$want" ] || bad="${bad:+$bad }$job(advisory=$flag, expected $want)"
  done <<EOF
$phases
EOF
  if [ -z "$bad" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "a release-smoke job is in the wrong phase" "$bad" >&2
  fi
  # Floors, because "every job is correctly flagged" is also true of a workflow
  # with no phase-1 jobs left in it.
  if [ "$opens" -ge 3 ] && [ "$statics" -ge 3 ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "a phase lost its lanes" \
      "$opens phase-1 job(s) and $statics phase-2 job(s); expected at least 3 of each" >&2
  fi

  # ── and every OTHER way a phase-1 lane could stop answering ────────────────
  # The flag is one of four ways, and the only one the block above can see. A
  # lane that launches nothing, one softened a level down, one gated off and one
  # cut from its inventory rows are all green runs that proved nothing. Comment
  # lines are stripped throughout: this asserts what RUNS.
  job_body() { # <job id> — the job's lines, minus its own key line and comments
    awk -v want="$1" '
      /^  [A-Za-z_][A-Za-z0-9_-]*:[ \t]*(#.*)?$/ {
        job = $0; sub(/^  /, "", job); sub(/:.*$/, "", job); inside = (job == want); next
      }
      inside && $0 !~ /^ *#/ { print }' "$wf"
  }
  # DISCOVERED, not listed: a fourth phase-1 lane whose only step is `echo` would
  # satisfy a hardcoded three and prove nothing.
  opens_ids="$(printf '%s\n' "$phases" | awk '$1 ~ /^opens-/ { print $1 }')"
  while IFS= read -r job; do
    [ -n "$job" ] || continue
    body="$(job_body "$job")"
    missing=""
    launch="$(printf '%s\n' "$body" | grep -cF -- "load-proving/prove.py" || true)"
    [ "$launch" -ne 0 ] || missing="a load-proving/prove.py launch"
    verdict="$(printf '%s\n' "$body" | grep -cF -- "load-proving/publish_verdict.py" || true)"
    [ "$verdict" -ne 0 ] || missing="${missing:+$missing }load-proving/publish_verdict.py"
    # AND ITS OWN SUITE, BEFORE THE DOWNLOAD: a lane that never showed its
    # thresholds can still come out red is a lane whose green says nothing.
    harness="$(printf '%s\n' "$body" | grep -n -- 'unittest discover' | head -1 | cut -d: -f1)"
    download="$(printf '%s\n' "$body" | grep -n -- 'download-release-asset.sh' | head -1 | cut -d: -f1)"
    if [ -z "$harness" ]; then
      missing="${missing:+$missing }a step running the load-proving suite"
    elif [ -n "$download" ] && [ "$harness" -gt "$download" ]; then
      missing="${missing:+$missing }its suite runs after the download, not before"
    fi
    # THE SECOND WAY TO SOFTEN A LANE. The phase check above reads the JOB key,
    # four spaces in; a step-level `continue-on-error: true` sits at eight and
    # turns one lane green just as completely.
    soft="$(printf '%s\n' "$body" | grep -c 'continue-on-error' || true)"
    [ "$soft" -eq 0 ] || missing="${missing:+$missing }$soft continue-on-error in the job"
    # A SKIPPED JOB IS GREEN — GitHub concludes a run on what ran — so an `if:`
    # is the third way, and the one no flag check can see. `!cancelled()` must be
    # there, and nothing that makes the lane conditional on how the run was
    # started: gating phase 1 on `github.event_name == 'workflow_dispatch'` would
    # leave a hand-run smoke perfect and every release proving nothing.
    gate="$(printf '%s\n' "$body" | awk '
      /^    if:/ { inif = 1; print; next }
      inif && /^      / { print; next }
      inif { inif = 0 }')"
    printf '%s\n' "$gate" | grep -qF -- '!cancelled()' ||
      missing="${missing:+$missing }an if: gate containing !cancelled()"
    for banned in 'inputs\.' 'github\.event' '\.result'; do
      printf '%s\n' "$gate" | grep -qE -- "$banned" &&
        missing="${missing:+$missing }an if: gate reading $banned"
    done
    # Without `needs:` the outputs it gates on are empty forever, so the lane
    # never runs again and nothing goes red to say so.
    printf '%s\n' "$body" | grep -qE '^    needs: inventory$' ||
      missing="${missing:+$missing }needs: inventory"
    # AND THE GATE AND THE MATRIX MUST NAME THE SAME OUTPUT. Both names being
    # declared satisfies the correspondence check below while a lane gated on the
    # Windows rows builds itself from the Linux ones.
    gate_ref="$(printf '%s\n' "$gate" |
      grep -oE 'needs\.inventory\.outputs\.[a-z_]+' | cut -d. -f4 | sort -u | tr '\n' ' ')"
    rows_ref="$(printf '%s\n' "$body" |
      grep -oE 'fromJSON\(needs\.inventory\.outputs\.[a-z_]+' | cut -d. -f4 | sort -u | tr '\n' ' ')"
    [ "$gate_ref" = "$rows_ref" ] ||
      missing="${missing:+$missing }gates on [$gate_ref] but builds its matrix from [$rows_ref]"
    # A launch step that never ran leaves no verdict file and no PROVE_RC, and
    # only a step that runs anyway can say so.
    printf '%s\n' "$body" | grep -qE '^      - name: The verdict$' ||
      missing="${missing:+$missing }a 'The verdict' step of its own"
    # The frames are what the lane produces; `ignore` would publish an empty
    # artifact as a complete one. macOS is `warn` on purpose — see the lane.
    printf '%s\n' "$body" | grep -q 'if-no-files-found: ignore' &&
      missing="${missing:+$missing }if-no-files-found: ignore"
    if [ -z "$missing" ]; then pass=$((pass + 1)); else
      fail=$((fail + 1))
      printf 'FAIL  %-58s %s\n' "$job cannot be trusted to answer" "$missing" >&2
    fi
  done <<EOF
$opens_ids
EOF

  # AGAINST THE DOWNLOAD: three lanes all proving linux would pass every check
  # above.
  while IFS='|' read -r job script arg; do
    [ -n "$job" ] || continue
    body="$(job_body "$job")"
    if printf '%s\n' "$body" | grep -qF -- "load-proving/$script" &&
       printf '%s\n' "$body" | grep -qF -- "$arg"; then pass=$((pass + 1)); else
      fail=$((fail + 1))
      printf 'FAIL  %-58s %s\n' "$job does not launch its own platform's artifact" \
        "$script with $arg" >&2
    fi
  done <<'PHASE1'
opens-linux|prove.py linux|"$ARTIFACT"
opens-macos|prove.py macos|"$DMG"
opens-windows|prove.py windows|"$INSTALLER"
PHASE1

  # ── and the name each lane goes under in the Checks list ───────────────────
  # THE ID DECLARES THE PHASE TO THIS FILE; THE NAME DECLARES IT TO A HUMAN, and
  # the Checks list is the only one of the two a reader ever sees. Every
  # assertion above reads the id, so all of them are satisfied by a blocking lane
  # named as though it were advisory.
  #
  # A PREFIX, not the whole name: the per-target suffix is the lane's to write.
  #
  # `^    name:` is only ever the job's: a step's is `      - name:`, six in.
  # Either quote style, or none — the yaml admits all three.
  job_name() { # <job id> — its display name, unquoted
    job_body "$1" | sed -n 's/^    name: *//p' | head -1 | sed "s/^['\"]//; s/['\"]\$//"
  }
  misnamed=""
  while read -r job _; do
    [ -n "$job" ] || continue
    case "$job" in
      opens-*) want="test opens app — " ;;
      static-*) want="test static checks — " ;;
      inventory) want="setup test" ;;
      # An id in neither phase already failed the block above.
      *) continue ;;
    esac
    got="$(job_name "$job")"
    case "$got" in
      "$want"*) ;;
      *) misnamed="${misnamed:+$misnamed }$job(reads '${got:-<unnamed>}', not '$want…')" ;;
    esac
  done <<EOF
$phases
EOF
  if [ -z "$misnamed" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "a lane's name and its id disagree about the phase" "$misnamed" >&2
  fi

  # ── and every ROW of a matrixed lane must render a DIFFERENT name ──────────
  # `${{ matrix.x }}` BEING IN THE NAME IS NOT THE PROPERTY. opens-windows runs
  # three rows over {runner, kind}: a name interpolating only `kind` holds the
  # substring and still renders windows-2022/nsis and windows-2025/nsis
  # identically. So the rows are RESOLVED and the rendered names compared.
  full_assets='a_linux.deb
a_linux.AppImage
a_aarch64_darwin.dmg
a_x64_darwin.dmg
a_x64_windows.exe
a_x64_windows.msi'
  inv_out="$(UNYT_SMOKE_ASSETS="$full_assets" bash "$here/release-inventory.sh" 000 2>/dev/null)"
  # <json array> → one row per line, as `key=value;key=value;`
  #
  # SPLIT ON `}` WITH A TRAILING NEWLINE GUARANTEED, not `sed 's/},{/}\n{/'`:
  # sed leaves the last row without a newline, `read` discards a final partial
  # line, and the closing row of every lane vanishes.
  json_rows() {
    printf '%s\n' "$1" | tr '}' '\n' | while IFS= read -r row; do
      # First colon only, so a value like `ubuntu:22.04` survives intact.
      pairs="$(printf '%s\n' "$row" | grep -oE '"[a-z_]+":"[^"]*"' |
        sed 's/"//g; s/:/=/' | tr '\n' ';')"
      [ -n "$pairs" ] || continue
      printf '%s\n' "$pairs"
    done
  }
  render_row() { # <name template> <key=value;…> — the name as GitHub renders it
    # NO MATRIX VALUE EVER REACHES sed. Interpolated into `s|…|$v|`, a value
    # holding `|` or `\1` aborts the command and renders the row EMPTY — counted
    # by neither total below, so both tallies agree and the collision goes with
    # it. An `&` is worse: it silently puts the placeholder back. So sed carries
    # no data and bash does the substituting.
    local out rest="$2" kv k v
    out="$(printf '%s' "$1" | sed 's/\${{ *matrix\.\([a-z_]*\) *}}/${{matrix.\1}}/g')"
    # Every row ends in `;`, so this consumes the whole string. No IFS splitting
    # and no `$2` unquoted: a value is data, never a glob.
    while [ -n "$rest" ]; do
      kv="${rest%%;*}"; rest="${rest#*;}"
      [ -n "$kv" ] || continue
      k="${kv%%=*}"; v="${kv#*=}"
      out="${out//"\${{matrix.$k}}"/$v}"
    done
    printf '%s\n' "$out"
  }
  literal_rows() { # <job body> — rows of a matrix written literally in the yaml
    local decls
    decls="$(printf '%s\n' "$1" | sed -n 's/^        \([a-z_]*\): \[\(.*\)\]$/\1|\2/p')"
    # ONE KEY ONLY: two would be a cross product, and emitting each key's values
    # as rows of their own asserts against a matrix GitHub does not run.
    [ "$(printf '%s\n' "$decls" | grep -c . || true)" -eq 1 ] || return 1
    printf '%s\n' "$decls" | while IFS='|' read -r key vals; do
      printf '%s\n' "$vals" | tr -d ' ' | tr ',' '\n' |
        while IFS= read -r v; do [ -n "$v" ] || continue; printf '%s=%s;\n' "$key" "$v"; done
    done
  }
  rows_for() { # <job id> — its matrix rows; non-zero for a lane this cannot resolve
    # THE SOURCE THE JOB ITSELF NAMES, never a table keyed on the job id: a
    # second home for "which rows does this lane run" resolves confidently
    # against rows GitHub will not run the moment a lane is re-sourced.
    local body src keys
    body="$(job_body "$1")"
    src="$(printf '%s\n' "$body" |
      grep -oE 'fromJSON\(needs\.inventory\.outputs\.[a-z_]+' | cut -d. -f4 | head -1)"
    case "$src" in
      prove_linux | prove_windows | dmgs)
        json_rows "$(printf '%s\n' "$inv_out" | sed -n "s/^$src=//p")" ;;
      # The setup job builds this one in a shell step of its own, so the rows are
      # the distro list slugged the way that step slugs it, and the keys are read
      # back off the step.
      # </dev/null: this runs inside a loop reading the job list on stdin, and a
      # callee that read it would silently end that loop early.
      images)
        keys="$(job_body inventory | grep -oE '\\"[a-z_]+\\":' |
          tr -d '\\":' | sort -u | tr '\n' ' ')"
        [ "$keys" = "image slug " ] || return 1
        bash "$here/run-smoke.sh" --print-images </dev/null | while IFS= read -r i; do
          [ -n "$i" ] || continue
          printf 'image=%s;slug=%s;\n' "$i" "$(printf '%s' "$i" | tr ':/' '--')"
        done ;;
      # No fromJSON anywhere in the job: the matrix is written out in the yaml.
      '') literal_rows "$body" ;;
      *) return 1 ;;
    esac
  }
  collided=""
  unwired=""
  all_names=""
  matrixed=0
  resolved=0
  while read -r job _; do
    [ -n "$job" ] || continue
    case "$job" in opens-* | static-*) ;; *) continue ;; esac
    printf '%s\n' "$(job_body "$job")" | grep -qE '^      matrix:' || continue
    matrixed=$((matrixed + 1))
    name="$(job_name "$job")"
    rows="$(rows_for "$job")" || { unwired="${unwired:+$unwired }$job"; continue; }
    rendered="$(while IFS= read -r r; do
      [ -n "$r" ] || continue
      render_row "$name" "$r"
    done <<ROWS
$rows
ROWS
)"
    n="$(printf '%s\n' "$rendered" | grep -c . || true)"
    u="$(printf '%s\n' "$rendered" | sort -u | grep -c . || true)"
    resolved=$((resolved + n))
    all_names="$all_names$rendered
"
    { [ "$n" -gt 0 ] && [ "$n" = "$u" ]; } ||
      collided="${collided:+$collided }$job($n row(s) render $u distinct name(s))"
  done <<EOF
$phases
EOF
  if [ -z "$collided" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "two rows of a lane render the same check name" "$collided" >&2
  fi
  # A LANE THIS CANNOT RESOLVE IS A FAILURE, not a lane to skip: passing over the
  # one matrix it does not recognise is how the check above stops checking.
  if [ -z "$unwired" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "a matrixed lane whose rows nothing here resolves" "$unwired" >&2
  fi
  # AND A FLOOR ON HOW MANY IT EXAMINED: the `matrix:` detector is anchored at six
  # spaces, so reindenting the yaml would otherwise exempt every lane.
  if [ "$matrixed" -ge 6 ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "the matrixed-lane check examined too few lanes" \
      "$matrixed of the 6 matrixed lanes; the rest were skipped, not checked" >&2
  fi
  # AND A FLOOR ON THE ROWS: a parser that drops the last row of every lane still
  # examines all six lanes and finds no collision among what is left — the bug
  # json_rows shipped with. A floor, not the count, because a new distro adds.
  if [ "$resolved" -ge 15 ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "the name check resolved fewer rows than exist" \
      "$resolved row(s) across $matrixed lane(s); expected at least 15" >&2
  fi
  # AND ACROSS LANES: two lanes rendering the same name is the same unreadable
  # Checks list, and neither lane's own comparison can see it.
  utot="$(printf '%s' "$all_names" | sort -u | grep -c . || true)"
  if [ "$resolved" -gt 0 ] && [ "$resolved" = "$utot" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "two lanes render the same check name" \
      "$resolved row(s) across every lane render $utot distinct name(s)" >&2
  fi

  # This file cannot notice that it was never called, so it asserts the call site
  # instead.
  inv_body="$(job_body inventory)"
  if printf '%s\n' "$inv_body" | grep -qF 'bash scripts/smoke/test-oracle.sh' &&
     [ "$(printf '%s\n' "$inv_body" | grep -c 'continue-on-error' || true)" -eq 0 ]; then
    pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "the setup job stopped running this file, or softened it" \
      "an advisory oracle makes every assertion here decoration" >&2
  fi

  # THE STEP AS IT RUNS, not the strings in it: `|| true` on the verdict call or
  # a redirect that eats its status leaves both greps above satisfied and turns a
  # NOT PROVEN lane green. So the step is extracted verbatim and driven against a
  # stub prover and the REAL publish_verdict.py, under GitHub's shell options.
  step_run() { # <job id> <step-name substring> — the run: body, dedented
    job_body "$1" | awk -v want="$2" '
      $0 ~ "^      - name: .*" want { instep = 1; next }
      /^      - name: / { instep = 0 }
      instep && /^        run: \|/ { inrun = 1; next }
      inrun && /^          / { sub(/^          /, ""); print; next }
      inrun { inrun = 0 }'
  }
  # A matrix value is not available to a shell here; all that matters is that the
  # lane label reaches the verdict as one word.
  dematrix() { sed 's/\${{ *matrix\.[a-z]* *}}/deb/g'; }
  launch_step="$(step_run opens-linux 'Launch it and photograph' | dematrix)"
  verdict_step="$(step_run opens-linux 'The verdict' | dematrix)"
  # The steps invoke python3. Every runner they run on has it; a bare container
  # does not, and a SKIP says which of the two this is.
  if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP  the phase-1 launch and verdict steps (no python3 to drive them)" >&2
    launch_step=""
    verdict_step=""
  fi
  if [ -n "$launch_step" ] && [ -n "$verdict_step" ]; then
    # BOTH STEPS, in order, with $GITHUB_ENV carried between them as the runner
    # carries it — that handoff is how the launch's exit code reaches the verdict.
    # The job's colour is red if EITHER step is red, which is what is returned.
    run_lane() { # <stub exit> <stub stdout> <run the launch step at all?>
      local dir rc=0 line
      dir="$(mktemp -d)"
      mkdir -p "$dir/scripts/smoke/load-proving"
      cp "$here/load-proving/publish_verdict.py" "$dir/scripts/smoke/load-proving/"
      # A stub prover, in the language the step invokes it in.
      {
        echo 'import sys'
        [ -z "$2" ] || printf 'print(%s)\n' "$(python3 -c 'import sys; print(repr(sys.argv[1]))' "$2")"
        echo "sys.exit($1)"
      } >"$dir/scripts/smoke/load-proving/prove.py"
      : >"$dir/env"
      if [ "$3" = launched ]; then
        ( cd "$dir" && ARTIFACT=x RUNNER_TEMP="$dir" GITHUB_ENV="$dir/env" \
            GITHUB_STEP_SUMMARY="$dir/summary.md" \
            bash -eo pipefail -c "$launch_step" >/dev/null 2>&1 ) || rc=1
      fi
      # `if: always()`, so the verdict step runs whatever the launch did.
      while IFS= read -r line; do export "${line?}"; done <"$dir/env"
      ( cd "$dir" && RUNNER_TEMP="$dir" GITHUB_STEP_SUMMARY="$dir/summary.md" \
          bash -eo pipefail -c "$verdict_step" >/dev/null 2>&1 ) || rc=1
      unset PROVE_RC
      rm -rf "$dir"
      echo "$rc"
    }
    # The last is the one the split exists for: a launch step that never ran
    # leaves no verdict and no PROVE_RC.
    while IFS='|' read -r code verdict ran want desc; do
      [ -n "$desc" ] || continue
      got="$(run_lane "$code" "$verdict" "$ran")"
      if { [ "$want" = red ] && [ "$got" -ne 0 ]; } ||
         { [ "$want" = green ] && [ "$got" -eq 0 ]; }; then pass=$((pass + 1)); else
        fail=$((fail + 1))
        printf 'FAIL  %-58s wanted %s, the lane came out %s\n' "$desc" "$want" "$got" >&2
      fi
    done <<'LAUNCHES'
0|VERDICT linux deb: PROVEN — 1847 distinct, 50.0% dominant|launched|green|a proven lane reaches the job green
1|VERDICT linux deb: NOT PROVEN — the window was blank|launched|red|a blank window must fail the job
1||launched|red|a prover that says nothing must fail the job
2|VERDICT linux deb: CANNOT PROVE — no capture path|launched|red|a lane that could not look must fail the job
0|VERDICT linux deb: PROVEN — 1847 distinct, 50.0% dominant|skipped|red|a launch step that never ran must fail the job
LAUNCHES
  elif command -v python3 >/dev/null 2>&1; then
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "the phase-1 launch or verdict step could not be extracted" \
      "a step name or its run: block moved" >&2
  fi

  # A lane gates on `needs.inventory.outputs.<x>`; an <x> the job never declares,
  # or one release-inventory.sh never prints, is EMPTY at runtime — the gate
  # reads false, the lane skips, and nothing says why. Both directions.
  printed="$(printf '%s\n' "$inv_out" | grep -oE '^[a-z_]+=' | tr -d '=')"
  declared="$(sed -n '/^    outputs:/,/^    steps:/p' "$wf" | grep -oE '^      [a-z_]+:' | tr -d ' :')"
  missing=""
  refs="$(grep -oE 'needs\.inventory\.outputs\.[a-z_]+' "$wf" | cut -d. -f4 | sort -u)"
  # NO REFERENCES IS NOT A CLEAN RESULT: the loop below would iterate zero times
  # and count a pass, at the exact moment the gates changed shape. A floor, not
  # the count, because a new lane legitimately adds one.
  refcount="$(printf '%s\n' "$refs" | grep -c . || true)"
  [ "$refcount" -ge 6 ] || missing="only $refcount gate(s) read an inventory output"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    printf '%s\n' "$declared" | grep -qx -- "$ref" ||
      missing="${missing:+$missing }$ref(no such job output)"
    # `images` is the workflow's own step output; everything else comes from the
    # script, and a matrix built from an unprinted name is an empty matrix.
    [ "$ref" = images ] && continue
    printf '%s\n' "$printed" | grep -qx -- "$ref" ||
      missing="${missing:+$missing }$ref(release-inventory.sh prints no such line)"
  done <<EOF
$refs
EOF
  if [ -z "$missing" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "a lane gates on an output nothing produces" "$missing" >&2
  fi

  # THE STEP RUN, not the shape of its source: asserting that some line containing
  # `continue` precedes the summarise call is satisfied by a comment. Extracted
  # verbatim from the yaml and driven against a stub summariser, with
  # $GITHUB_STEP_SUMMARY caught in a file.
  # shellcheck disable=SC2016  # sed scripts and the stub below are literals, not expansions
  win="$(sed -n '/^  static-windows:/,/^  [a-z]/p' "$wf" | sed -n '/^          rc=0$/,/^          exit "\$rc"$/p' | sed 's/^          //')"
  if [ -n "$win" ]; then
    win_dir="$(mktemp -d)"
    mkdir -p "$win_dir/scripts/smoke"
    cat >"$win_dir/scripts/smoke/summarise-checks.sh" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = --label ] && echo "SUMMARISED $2"; shift; done
STUB
    win_run() { # <EXPECT_EXE> <EXPECT_MSI> — the step's own shell options
      ( cd "$win_dir" && rm -f published.md &&
        RUNNER_TEMP="$win_dir" GITHUB_STEP_SUMMARY="$win_dir/published.md" \
          LABEL=L RELEASE=r STATIC_NOTE="" EXE=e MSI=m \
          EXPECT_EXE="$1" EXPECT_MSI="$2" bash -eo pipefail -c "$win" >/dev/null 2>&1
        echo "rc=$?"; cat published.md )
    }
    got="$(win_run false true)"
    if [ "$(printf '%s\n' "$got" | grep -c 'SUMMARISED')" = 1 ] &&
       printf '%s\n' "$got" | grep -q 'SUMMARISED L/\.msi' &&
       printf '%s\n' "$got" | grep -qx 'rc=0'; then pass=$((pass + 1)); else
      fail=$((fail + 1))
      printf 'FAIL  %-58s %s\n' "an absent installer must not be summarised" \
        "$(printf '%s' "$got" | tr '\n' ' ')" >&2
    fi
    if printf '%s\n' "$got" | grep -q 'exe — not in this release'; then pass=$((pass + 1)); else
      fail=$((fail + 1))
      printf 'FAIL  %-58s %s\n' "and the summary must say the lane was skipped" \
        "$(printf '%s' "$got" | tr '\n' ' ')" >&2
    fi
    if printf '%s\n' "$(win_run false false)" | grep -qx 'rc=0'; then
      fail=$((fail + 1))
      printf 'FAIL  %-58s %s\n' "a lane that smoked neither installer read clean" \
        "an empty table publishes as a passing verdict" >&2
    else pass=$((pass + 1)); fi
    rm -rf "$win_dir"
  else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "the Windows summary step could not be extracted" \
      "the rc=0 and exit anchors it is sliced between moved" >&2
  fi

  # AN ALLOWLIST, not a ban on the two names we happen to have used: a dispatch
  # input called anything at all, wired into a phase-1 gate, softens the one run
  # that is supposed to answer red for everything.
  dispatch_inputs="$(sed -n '/^  workflow_dispatch:/,/^  workflow_call:/p' "$wf" |
    grep -oE '^      [a-z-]+:' | tr -d ' :' | sort -u | tr '\n' ' ')"
  if [ "$dispatch_inputs" = "release " ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "workflow_dispatch takes more than a release id" \
      "[$dispatch_inputs] — a hand-dispatched smoke must answer red for both phases" >&2
  fi

  # The input that covered the WHOLE workflow must not come back under its old
  # name: `non-blocking: true` would read as harmless and silence phase 1 again.
  if [ "$(grep -c 'non-blocking' "$wf" || true)" -ne 0 ]; then
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "release-smoke.yaml still knows the workflow-wide switch" \
      "non-blocking softened every phase; static-checks-advisory replaced it" >&2
  else pass=$((pass + 1)); fi

  # THE NOTE THE STEP SUMMARY CARRIES has to agree with the wiring: inverted, it
  # tells the reader of a hand-dispatched run that a failure blocks nothing.
  note="$(sed -n '/^  STATIC_NOTE:/,/^jobs:/p' "$wf")"
  wrong=""
  for want in 'inputs.static-checks-advisory == true' \
              'Phase 1 (does it open) is not advisory' \
              'it does fail THIS run'; do
    printf '%s\n' "$note" | grep -qF -- "$want" || wrong="${wrong:+$wrong; }$want"
  done
  if [ -z "$wrong" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s missing: %s\n' "the advisory note no longer says what is true" "$wrong" >&2
  fi
else
  echo "SKIP  workflow/registry correspondence (no release-smoke.yaml)" >&2
fi

# ── a tag the msi cannot carry must die in stage 1 ───────────────────────────
# msi-version.sh is the only thing that rejects a tag the trigger admits: the
# trigger is a glob, so it takes any `-dev.*`, numeric or not.
rel="$here/../../.github/workflows/release-tauri-app.yaml"
if [ -f "$rel" ]; then
  stage1="$(sed -n '/^  publish-happ:/,/^  release-tauri-app:/p' "$rel")"
  stage2="$(sed -n '/^  release-tauri-app:/,/^  smoke-test:/p' "$rel")"
  # A slice that stopped matching makes every assertion below pass on nothing.
  for slice in "$stage1" "$stage2"; do
    if [ -n "$slice" ]; then pass=$((pass + 1)); else
      fail=$((fail + 1))
      printf 'FAIL  %-58s %s\n' "a release-tauri-app job slice came out empty" "a job key was renamed" >&2
    fi
  done
  # WHOLE lines: `# bash …--self-test` still contains the substring, and
  # `id: msiver` still contains `id: msi`.
  in_stage() { # <slice> <line, verbatim> <description>
    if printf '%s\n' "$1" | grep -qxF -- "$2"; then pass=$((pass + 1)); else
      fail=$((fail + 1)); printf 'FAIL  %-58s %s\n' "$3" "$2" >&2; fi
  }
  in_stage "$stage1" '          bash scripts/msi-version.sh --self-test' \
    "stage 1 must prove the derivation still works"
  in_stage "$stage1" '        id: msi' "the derivation step must keep the id its output reads"
  if printf '%s\n' "$stage1" | grep -qF -- 'steps.msi.outputs.MSI_VERSION'; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "stage 1 must publish the derived version" "as a job output the build can read" >&2
  fi
  if printf '%s\n' "$stage2" | grep -qF -- 'needs.publish-happ.outputs.msiVersion'; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "the build job must consume the stage-1 value" "not derive one of its own" >&2
  fi
  if printf '%s\n' "$stage2" | grep -qF -- '.bundle.windows.wix.version'; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "nothing writes the key the bundler reads" "bundle.windows.wix.version" >&2
  fi
  # BOTH halves. Without the version half a stable release writes an empty
  # wix.version and the bundler rejects it — the user-facing channel, this time.
  pin_if="$(printf '%s\n' "$stage2" | sed -n '/name: Pin the MSI product version/,/run:/p' | grep -m1 '^ *if:')"
  if printf '%s\n' "$pin_if" | grep -qF -- "runner.os == 'Windows'" &&
     printf '%s\n' "$pin_if" | grep -qF -- "msiVersion != ''"; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "the msi pin is not gated on Windows AND a version" "${pin_if:-<no if: found>}" >&2
  fi
  if printf '%s\n' "$stage2" | grep -qF -- 'msi-version.sh'; then
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "the build job derives the msi version itself" \
      "a bad tag then fails four platform builds in, not in seconds" >&2
  else pass=$((pass + 1)); fi
  # The channels msi-version.sh is written against; add one and every tag on it
  # dies in stage 1. The case patterns are QUOTED, or `[0-9]` would be read as a
  # character class and match both.
  tags="$(sed -n '/^    tags:$/,/^jobs:$/p' "$rel" | grep -oE '"[^"]+"' | tr -d '"')"
  unknown=""
  for tag in $tags; do
    case "$tag" in
      'v[0-9]+.[0-9]+.[0-9]+' | 'v[0-9]+.[0-9]+.[0-9]+-dev.*') ;;
      *) unknown="${unknown:+$unknown }$tag" ;;
    esac
  done
  if [ -n "$tags" ] && [ -z "$unknown" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "a release tag channel msi-version.sh cannot derive" \
      "${unknown:-no tag patterns found at all}" >&2
  fi

  # The release calls the smoke with the static phase advisory. Two ways that goes
  # wrong, neither visible in a green run: the call stops asking, or it starts
  # softening phase 1 as well.
  # Bounded at the next job key, not run to EOF: smoke-test is last today, and a
  # job added after it would fold in and be judged as part of the call.
  stage3="$(sed -n '/^  smoke-test:/,/^  [a-z]/p' "$rel")"
  if [ -n "$stage3" ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "the smoke-test job slice came out empty" "the job key was renamed" >&2
  fi
  in_stage "$stage3" '      static-checks-advisory: true' \
    "a release run must ask for an advisory static phase"
  # THIS NAME IS PAID FOR SIXTEEN TIMES: GitHub prefixes every called job with it,
  # so a description here pushes the part that differs off the end of every line
  # of the Checks list.
  in_stage "$stage3" '    name: Stage 3' \
    "the stage-3 name prefixes all 16 smoke lanes, so it stays the stage"
  if [ "$(printf '%s\n' "$stage3" | grep -cE '^ *(non-blocking|continue-on-error):' || true)" -ne 0 ]; then
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "the release softens the whole smoke" \
      "phase 1 would go green with the app never having opened" >&2
  else pass=$((pass + 1)); fi
  # AND THE CALL ITSELF MUST NOT BE CONDITIONAL ON HOW THE RUN STARTED: a skipped
  # job is green, so `if: github.event_name == 'workflow_dispatch'` here would
  # leave every release calling no smoke, with nothing red anywhere.
  stage3_if="$(printf '%s\n' "$stage3" | grep -m1 '^    if:')"
  if printf '%s\n' "$stage3_if" | grep -qF -- '!cancelled()' &&
     [ "$(printf '%s\n' "$stage3_if" | grep -cE 'github\.event|inputs\.' || true)" -eq 0 ]; then
    pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "the release can stop calling the smoke" \
      "${stage3_if:-<no if: found>}" >&2
  fi
  in_stage "$stage3" '    uses: ./.github/workflows/release-smoke.yaml' \
    "the release must call the smoke workflow"

  # A GATE MAY NOT RIDE A ROLLING LABEL. macos-latest moved to macOS 26, whose
  # screen-capture rules differ from the ones phase 1 is proven against, so a gate
  # on it would change what "proven" means with no commit to point at.
  # windows-latest/ubuntu-latest are not the same risk: the Windows lanes name
  # both images explicitly and the Linux static lane runs in containers.
  #
  # Full-line comments stripped, because the label is named in the comments that
  # explain all this; a trailing one is left, since a line that still RUNS on it
  # is exactly what this looks for.
  #
  # COUNTED, never `| grep -q`: under `pipefail` the -q exits on the first match
  # and the upstream grep dies of SIGPIPE, so the pipeline reports 141 and the
  # `if` reads it as "no match".
  if [ "$(grep -v '^[[:space:]]*#' "$wf" | grep -c 'macos-latest' || true)" -ne 0 ]; then
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "a smoke lane rides the rolling macOS image" \
      "gates run macos-15 / macos-15-intel — the images phase 1 is proven on" >&2
  else pass=$((pass + 1)); fi

  # THE BUILD IS THE OPPOSITE RULE, deliberately: these legs produce what users
  # install, so pinning them changes the product rather than a gate. macos-latest
  # is REQUIRED here, and both a pin and a move fail — the artifact is meant to be
  # built on a newer macOS than the gates install it on.
  build_macos="$(grep -v '^[[:space:]]*#' "$rel" |
    grep -oE 'platform: macos[a-z0-9.-]*' | sed 's/platform: //' | sort -u | tr '\n' ' ')"
  if [ "$build_macos" = "macos-latest " ]; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL  %-58s %s\n' "the macOS build legs no longer roll" \
      "[$build_macos] — pinning what ships is its own decision, not a test change" >&2
  fi
else
  echo "SKIP  release-tauri-app stage-1 checks (no release-tauri-app.yaml)" >&2
fi

# ── the inventory decides which lanes run, so it must not be able to lie ─────
# A lane skips when its artifact is absent — right for a build that failed, wrong
# for an inventory that reports nothing by accident.
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

# The row COUNT is the assertion: a row dropped from LINUX_PROVE_ROWS or
# WINDOWS_PROVE_ROWS is an installer nobody launches again, and no lane goes red
# to say so. Counted by the kind key, which every row of both matrices carries.
rows_of() { # <inventory output> <output name>
  printf '%s\n' "$1" | grep "^$2=" | grep -o '"kind"' | grep -c . || true
}
if [ "$(rows_of "$got" prove_linux)" = 2 ] && [ "$(rows_of "$got" prove_windows)" = 3 ]; then
  pass=$((pass + 1)); else
  fail=$((fail + 1))
  printf 'FAIL  %-58s %s\n' "a full release should launch every installer" \
    "$(printf '%s\n' "$got" | grep '^prove_')" >&2
fi
# The .msi is the row that exists on ONE image while the .exe runs on two, so a
# release without it must lose exactly that row and keep both NSIS lanes.
got="$(inv "$(printf '%s\n' "$full" | grep -v -- x64_windows.msi)")"
if [ "$(rows_of "$got" prove_windows)" = 2 ] &&
   ! printf '%s\n' "$got" | grep '^prove_windows=' | grep -q '"msi"'; then
  pass=$((pass + 1)); else
  fail=$((fail + 1))
  printf 'FAIL  %-58s %s\n' "a release with no .msi should lose one Windows lane" \
    "$(printf '%s\n' "$got" | grep '^prove_windows=')" >&2
fi
got="$(inv "$(printf '%s\n' "$full" | grep -v -- linux.AppImage)")"
if [ "$(rows_of "$got" prove_linux)" = 1 ] &&
   printf '%s\n' "$got" | grep '^prove_linux=' | grep -q '"deb"'; then
  pass=$((pass + 1)); else
  fail=$((fail + 1))
  printf 'FAIL  %-58s %s\n' "a release with no AppImage should keep the .deb lane" \
    "$(printf '%s\n' "$got" | grep '^prove_linux=')" >&2
fi
# The .exe is the one asset TWO rows depend on, so it is the case where dropping
# one artifact must remove more than one lane and still leave the .msi's.
got="$(inv "$(printf '%s\n' "$full" | grep -v -- x64_windows.exe)")"
if [ "$(rows_of "$got" prove_windows)" = 1 ] &&
   printf '%s\n' "$got" | grep '^prove_windows=' | grep -q '"msi"'; then
  pass=$((pass + 1)); else
  fail=$((fail + 1))
  printf 'FAIL  %-58s %s\n' "a release with no .exe should lose both NSIS lanes" \
    "$(printf '%s\n' "$got" | grep '^prove_windows=')" >&2
fi
# AN INSTALLER NO SUFFIX CLAIMS. The all-four-absent guard cannot see a single
# renamed artifact, and the lane for it would stop existing in silence.
if inv_rc "$(printf '%s\n' "$full" | sed 's/aarch64_darwin/arm64_darwin/')"; then
  fail=$((fail + 1))
  printf 'FAIL  %-58s %s\n' "a renamed installer read as a clean inventory" \
    "its lane would silently stop running" >&2
else pass=$((pass + 1)); fi
# And the assets a release legitimately carries alongside them must not trip it:
# the happ, the DNA, and the updater bundles with their signatures.
if inv_rc "$full
unyt.happ
alliance.dna
x_x64_linux.AppImage.tar.gz
x_x64_linux.AppImage.tar.gz.sig
x_x64_windows.nsis.zip
x_x64_windows.msi.zip
x_aarch64_darwin.app.tar.gz"; then pass=$((pass + 1)); else
  fail=$((fail + 1))
  printf 'FAIL  %-58s %s\n' "a normal release tripped the unclaimed-installer guard" \
    "$(inv "$full
x_x64_windows.msi.zip" 2>&1 | tail -1)" >&2
fi

# `macos-15` → `macos-26` is neither `-latest` nor proven, and nothing in the ban
# above would say so. A CLOSED SET, therefore — the images the 7/7 proof was
# taken on. The build legs are deliberately not in it.
got="$(inv "$full")"
runners="$(printf '%s\n' "$got" | grep -o '"runner":"macos[^"]*"' | cut -d'"' -f4 | sort -u | tr '\n' ' ')"
if [ "$runners" = "macos-15 macos-15-intel " ]; then pass=$((pass + 1)); else
  fail=$((fail + 1))
  printf 'FAIL  %-58s %s\n' "the macOS lanes moved off their proven images" "[$runners]" >&2
fi
# A row with a field missing must not become a lane with an empty runner or an
# empty suffix — which would download nothing and launch it.
# awk, not `sed 's/\t/'`: BSD sed reads \t in a pattern as a literal `t`, so on
# macOS the copy would come out unmutated and this would assert nothing.
short="$(mktemp)"
awk '{ sub(/^windows-2025\tmsi\t/, "msi\t"); print }' "$here/release-inventory.sh" >"$short"
# shellcheck disable=SC2016  # the row holds the variable's NAME; expanding it here would assert the wrong file
if ! grep -q '^msi	\$MSI_SUFFIX' "$short"; then
  fail=$((fail + 1))
  printf 'FAIL  %-58s %s\n' "the short-row fixture did not mutate" \
    "the assertion below would pass on an unchanged file" >&2
elif UNYT_SMOKE_ASSETS="$full" bash "$short" 000 >/dev/null 2>&1; then
  fail=$((fail + 1))
  printf 'FAIL  %-58s %s\n' "a matrix row that lost a field still built a lane" \
    "the lane would run with an empty runner or suffix" >&2
else pass=$((pass + 1)); fi
rm -f "$short"
got="$(inv "$full")"

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

got="$(inv 'x_linuxXdeb
x_linux.AppImage
x_x64_windows.exe')"
if printf '%s\n' "$got" | grep -qx 'deb=false'; then pass=$((pass + 1)); else
  fail=$((fail + 1))
  printf 'FAIL  %-58s %s\n' "a suffix must match literally, not as a regex" "$got" >&2
fi

# One macOS build failing costs one matrix row, not the lane.
got="$(inv "$(printf '%s\n' "$full" | grep -v aarch64_darwin)")"
if printf '%s\n' "$got" | grep -q 'dmgs=\[{"runner":"macos-15-intel"' &&
   ! printf '%s\n' "$got" | grep -q 'aarch64'; then pass=$((pass + 1)); else
  fail=$((fail + 1)); printf 'FAIL  %s\n' "a missing arm64 DMG should drop only its row" >&2; fi

# The shape of run 31800038674, where every build failed: skipping all four lanes
# would be a green run that smoked nothing.
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

# The FAIL lines go to stderr inside a collapsed step log — so nothing sends you
# looking. The annotation is the only thing that surfaces on its own.
if [ "$fail" -ne 0 ]; then
  echo "::error title=Smoke oracle regressed::$fail assertion(s) failed — the checks' own guarantees are not holding; see this step's log for which"
fi

# A floor on the COUNT, not just on failures: truncate this file and it would
# otherwise report "3 passed, 0 failed" and exit 0. Raise it when adding cases.
# DELIBERATELY 3 BELOW a full run of 235: the GLIBC-patch branch costs exactly 2
# on a machine that cannot patch a version, and the tie-break's en_US.UTF-8 leg
# costs 1 where that locale is not generated. Do not "tidy" it up to match.
if [ "$pass" -lt 232 ]; then
  echo "::error::only $pass assertions ran; expected at least 232 — the test file is truncated or a block was skipped"
  exit 1
fi
[ "$fail" -eq 0 ]
