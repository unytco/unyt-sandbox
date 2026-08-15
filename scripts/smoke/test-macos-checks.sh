#!/usr/bin/env bash
# Can every macOS check actually FAIL?
#
#   scripts/smoke/test-macos-checks.sh
#
# Drives the REAL check-macos.sh against a stub toolchain on PATH; each scenario
# breaks one thing and requires that check — and only it — to go red. The repo
# has no Mac, so this is the only place these checks are observed to fail at all.
#
# ASSERT WHICH DIAGNOSIS FIRED, never just that the row went red. Four guards
# were deleted during mutation testing with every colour-only assertion still
# passing, because each left the row red for a different reason. `expect_err` is
# the fix — do not simplify an assertion back to the row alone.
#
# ASSERT THROUGH THE CALL SITE'S SHAPE. The Windows harness drove the real
# functions and still shipped a defect, because it called them bare where
# production wrapped them in `@(...)`.
#
# A mutant proves nothing until you have watched it fail for the intended reason.
#
# Both paths are driven: one process, and `--only` nine times over a shared state
# directory — the split invents a failure the single-process path cannot have.
#
# DOES NOT PROVE the real spctl/stapler/syspolicy wording; the signing stubs are
# Apple's documented output, not something observed here.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$here/check-macos.sh"
[ -f "$SCRIPT" ] || { echo "::error::check-macos.sh not found next to this test" >&2; exit 1; }

pass=0
fail=0
note() { printf '      %s\n' "$1" >&2; }

ROOT="$(mktemp -d)"

# THIS FILE'S OWN ZERO GUARD. Everything below only runs if control reaches the
# tally at the end, and `set -uo pipefail` has no `-e` — so a truncated file, an
# injected `exit 0`, or an early return produces NO OUTPUT AND STATUS 0, which
# reads as "every check is proven able to fail" while nothing was proven at all.
COMPLETED=""
# shellcheck disable=SC2317  # invoked through the EXIT trap
finish() {
  local rc=$?
  rm -rf "$ROOT"
  if [ -z "$COMPLETED" ]; then
    echo "::error::the regression test exited before completing (status $rc) — a truncated file," >&2
    echo "  an early exit, or a killed run. NOTHING below was proven; do not read this as a pass." >&2
    exit 1
  fi
  exit "$rc"
}
trap finish EXIT INT TERM

# ── the caller's environment, set here rather than inherited ──────────────────
# release-smoke.yaml runs this harness with UNYT_SMOKE_STATE and
# UNYT_SMOKE_RESULTS already in the environment, and that is what hid the one bug
# this harness shipped: run_scenario handed the real script no state directory of
# its own, so every scenario mounted into that one shared directory and a
# scenario found the PREVIOUS one's extracted bundle — nine green checks on a
# disk image with no .app in it. Bare, the script mints a temp directory per
# invocation and nothing leaks, so the same file reported 435/435 locally and
# 433/2 in CI.
#
# Setting it HERE makes the run independent of how it was invoked: every
# invocation below — run_scenario, only_check and mode_check alike — runs in the
# shape CI has, and the two guards at the end of this file say whether any of
# them reached it. Seeded rather than left absent, because --cleanup removes the
# directory it is given: a leak can DELETE as well as write, and an
# absence-only check reads a deletion as a pass.
ISO_AMBIENT="$ROOT/caller"
mkdir -p "$ISO_AMBIENT/state"
printf 'sentinel\n' >"$ISO_AMBIENT/state/keep"
printf 'seed|pass\n' >"$ISO_AMBIENT/rows.txt"
export UNYT_SMOKE_STATE="$ISO_AMBIENT/state"
export UNYT_SMOKE_RESULTS="$ISO_AMBIENT/rows.txt"

# THE PREMISE OF THOSE GUARDS, read back through a CHILD. They assert that
# nothing leaked into the caller's environment, which is vacuously true if there
# is no caller's environment — and demoting the two lines above from `export` to
# a plain assignment would do exactly that while every variable still reads
# correctly here. Only a child answers the question the scenarios ask.
iso_seen="$(bash -c 'printf "%s|%s" "${UNYT_SMOKE_STATE:-}" "${UNYT_SMOKE_RESULTS:-}"')"
if [ "$iso_seen" = "$ISO_AMBIENT/state|$ISO_AMBIENT/rows.txt" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  the caller's smoke environment does not reach a child process: '$iso_seen'" >&2
fi

# ── the real thing, captured ──────────────────────────────────────────────────
# Verbatim from the v0.100.0 artifacts. The two arches do NOT share a load
# command — aarch64 LC_BUILD_VERSION, x86_64 the older LC_VERSION_MIN_MACOSX —
# and a reader knowing only the modern one finds nothing on x86_64.
OTOOL_L_CLEAN='	/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit (compatibility version 45.0.0, current version 2685.60.104)
	/usr/lib/libobjc.A.dylib (compatibility version 1.0.0, current version 228.0.0)
	/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit (compatibility version 1.0.0, current version 624.2.5)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)
	/usr/lib/libiconv.2.dylib (compatibility version 7.0.0, current version 7.0.0)'

LC_ARM64='Load command 8
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform macos
      sdk 26.5
    minos 11.0
   ntools 1
     tool ld
  version 1053.12'

LC_X86='Load command 9
      cmd LC_VERSION_MIN_MACOSX
  cmdsize 16
  version 10.13
      sdk 26.5'

# ── the stub toolchain ────────────────────────────────────────────────────────
# One directory of executables, prepended to PATH. Each reads $STUB_BREAK to
# decide whether to behave or to misbehave in exactly one way.
make_stubs() {
  local bin="$1"
  mkdir -p "$bin" "$(dirname "$bin")/calls"

  cat >"$bin/hdiutil" <<'EOF'
#!/usr/bin/env bash
# Records whether the target still existed: --cleanup must detach BEFORE
# removing, or it is an rm -rf walking into a still-attached image.
if [ -e "${@: -1}" ]; then printf '%s\n' "$*"; else printf '%s [target-gone]\n' "$*"; fi \
  >>"$STUB_FIXTURE/calls/hdiutil"
case "${1:-}" in
  attach)
    [ "${STUB_BREAK:-}" = mount ] && { echo "hdiutil: attach failed - no mountable file systems" >&2; exit 1; }
    # A disk image with a licence agreement waits for a keypress. Without a
    # bound this is a job hanging to the runner's six-hour ceiling.
    [ "${STUB_BREAK:-}" = hdiutil_hang ] && { sleep 300; exit 0; }
    shift; mp=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -mountpoint) mp="$2"; shift 2 ;;
        -*) shift ;;
        *) shift ;;
      esac
    done
    mkdir -p "$mp"
    if [ "${STUB_BREAK:-}" = noapp ]; then echo "read me" >"$mp/README.txt"; exit 0; fi
    # A glob, not `mnt/.`: BSD cp (which is what a macOS runner has) does not
    # treat a trailing `/.` as "the contents of" the way GNU cp does. Glob
    # matches are not word-split, so the space in "Unyt Sandbox.app" is safe.
    cp -a "$STUB_FIXTURE/mnt/"* "$mp/"
    exit 0 ;;
  detach) exit 0 ;;
esac
exit 0
EOF

  cat >"$bin/ditto" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_BREAK:-}" = ditto ] && { echo "ditto: cannot copy" >&2; exit 1; }
cp -a "$1" "$2"
EOF

  # `plutil -extract <key> raw -o - <file>` against the fixture's real XML plist,
  # so a scenario mutates the plist rather than the stub.
  cat >"$bin/plutil" <<'EOF'
#!/usr/bin/env bash
key=""; file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -extract) key="$2"; shift 2 ;;
    raw|-o) shift ;;
    -) shift ;;
    *) file="$1"; shift ;;
  esac
done
[ -f "$file" ] || { echo "plutil: $file: No such file" >&2; exit 1; }
val="$(sed -n "\%<key>$key</key>%{n;s%.*<string>\(.*\)</string>.*%\1%p;}" "$file")"
[ -n "$val" ] || { echo "plutil: $file: does not contain key \"$key\"" >&2; exit 1; }
printf '%s\n' "$val"
EOF

  # Per-file canned output, written by the scenario next to the fixture.
  cat >"$bin/otool" <<'EOF'
#!/usr/bin/env bash
if [ "${STUB_BREAK:-}" = otool_dead ]; then
  echo "xcrun: error: unable to find utility \"otool\", not a developer tool or in PATH" >&2
  exit 72
fi
# The other way to read nothing: otool succeeds and prints only its own header,
# with no indented dependency lines. Exit status says everything is fine.
if [ "${STUB_BREAK:-}" = otool_header_only ] && [ "${1:-}" = "-L" ]; then
  printf '%s:\n' "$2"
  exit 0
fi
# `-arch <a> -l <file>` as well as `-L <file>` / `-l <file>`, because a universal
# binary is read one slice at a time. Per-arch fixtures are <name>.<arch>.l, with
# <name>.l as the thin fallback.
mode=""; arch=""; f=""
while [ $# -gt 0 ]; do
  case "$1" in
    -arch) arch="$2"; shift 2 ;;
    -L|-l) mode="$1"; shift ;;
    *) f="$1"; shift ;;
  esac
done
b="$(basename "$f")"
case "$mode" in
  -L) printf '%s:\n' "$f"; cat "$STUB_FIXTURE/otool/$b.deps" 2>/dev/null ;;
  -l)
    if [ -n "$arch" ] && [ -f "$STUB_FIXTURE/otool/$b.$arch.loadcmds" ]; then
      cat "$STUB_FIXTURE/otool/$b.$arch.loadcmds"
    else
      cat "$STUB_FIXTURE/otool/$b.loadcmds" 2>/dev/null
    fi ;;
esac
exit 0
EOF

  # Per-file arch lists, so one fixture can be universal while the rest are thin.
  cat >"$bin/lipo" <<'EOF'
#!/usr/bin/env bash
f="${@: -1}"
if [ -f "$STUB_FIXTURE/lipo/$(basename "$f")" ]; then
  cat "$STUB_FIXTURE/lipo/$(basename "$f")"
else
  printf '%s\n' "${STUB_BIN_ARCH:-x86_64}"
fi
EOF

  cat >"$bin/uname" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-m" ] && { printf '%s\n' "${STUB_RUNNER_ARCH:-x86_64}"; exit 0; }
exec /usr/bin/uname "$@"
EOF

  # A sort WITHOUT -V, to prove the guard on it fires. macOS ships BSD sort, and
  # a lexicographic fallback puts 9.0 above 10.13 — every floor comparison would
  # then be wrong in the direction that reads as a pass.
  if [ -n "${FIX_NO_SORT_V:-}" ]; then
    # REMOVE the flag, don't blank it: `"${@/-V/}"` leaves an EMPTY argument
    # behind, which real sort rejects — so the scenario would pass because sort
    # errored, not because it sorted lexicographically, and the guard under test
    # would never actually be exercised.
    cat >"$bin/sort" <<'EOF'
#!/usr/bin/env bash
args=()
for a in "$@"; do [ "$a" = "-V" ] || args+=("$a"); done
exec /usr/bin/sort "${args[@]}"
EOF
  fi

  cat >"$bin/sw_vers" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -productName) echo macOS ;;
  -productVersion) echo 15.3 ;;
esac
EOF

  # Two modes, because the check asks two questions. `--verify` says whether the
  # signature is intact; `-dv` says WHO signed it. An ad-hoc signature answers
  # the first perfectly and fails the second, which is the whole point of the
  # adhoc scenario below.
  cat >"$bin/codesign" <<'EOF'
#!/usr/bin/env bash
f="${@: -1}"
case "$*" in
  *-dv*)
    case "${STUB_BREAK:-}" in
      adhoc)
        if [ "$(basename "$f")" = "libunyt.dylib" ]; then
          echo "Executable=$f" >&2
          echo "Identifier=libunyt" >&2
          echo "Signature=adhoc" >&2
          echo "TeamIdentifier=not set" >&2
          exit 0
        fi ;;
      noteam)
        echo "Executable=$f" >&2
        echo "Authority=Developer ID Application: Unyt (ABCDE12345)" >&2
        echo "TeamIdentifier=not set" >&2
        exit 0 ;;
      applesigned)
        echo "Executable=$f" >&2
        echo "Authority=Apple Mac OS Application Signing" >&2
        echo "TeamIdentifier=APPLE" >&2
        exit 0 ;;
      twoteams)
        if [ "$(basename "$f")" = "helper" ]; then
          echo "Executable=$f" >&2
          echo "Authority=Developer ID Application: Someone Else (ZZZZZ99999)" >&2
          echo "TeamIdentifier=ZZZZZ99999" >&2
          exit 0
        fi ;;
    esac
    echo "Executable=$f" >&2
    echo "Identifier=co.unyt.unyt.sandbox" >&2
    echo "Authority=Developer ID Application: Unyt (ABCDE12345)" >&2
    echo "Authority=Developer ID Certification Authority" >&2
    echo "TeamIdentifier=ABCDE12345" >&2
    exit 0 ;;
esac
if [ "${STUB_BREAK:-}" = unsigned ] && [ "$(basename "$f")" = "helper" ]; then
  echo "$f: code object is not signed at all" >&2
  exit 1
fi
# An ad-hoc signature VERIFIES. That is the trap: --verify alone cannot see it.
echo "$f: valid on disk" >&2
echo "$f: satisfies its Designated Requirement" >&2
exit 0
EOF

  cat >"$bin/spctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_FIXTURE/calls/spctl"
target="${@: -1}"
[ -e "$target" ] || { echo "spctl: $target: No such file or directory" >&2; exit 1; }
case "${STUB_BREAK:-}" in
  gatekeeper_rejected)
    echo "$target: rejected" >&2
    echo "source=no usable signature" >&2
    exit 3 ;;
  gatekeeper_unnotarized)
    echo "$target: accepted" >&2
    echo "source=Unnotarized Developer ID" >&2
    echo "origin=Developer ID Application: Unyt (TEAMID)" >&2
    exit 0 ;;
  # Exit 0 without ever saying "accepted". The assessment did not happen, and
  # "did not happen" must not read the same as "passed".
  gatekeeper_silent)
    echo "source=Notarized Developer ID" >&2
    exit 0 ;;
esac
echo "$target: accepted" >&2
echo "source=Notarized Developer ID" >&2
echo "origin=Developer ID Application: Unyt (TEAMID)" >&2
exit 0
EOF

  cat >"$bin/xcrun" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_FIXTURE/calls/xcrun"
if [ "${1:-}" = stapler ] && [ "${2:-}" = validate ]; then
  if [ ! -e "${3:-}" ]; then
    echo "Processing: ${3:-}"
    echo "The staple and validate action failed! Error 66."
    exit 66
  fi
  if [ "${STUB_BREAK:-}" = stapler ]; then
    echo "Processing: $3"
    echo "The staple and validate action failed! Error 65."
    exit 65
  fi
  echo "Processing: $3"
  echo "The validate action worked!"
  exit 0
fi
exit 0
EOF

  cat >"$bin/syspolicy_check" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_FIXTURE/calls/syspolicy_check"
# Before STUB_BREAK, because a tool pointed at nothing cannot report on a build
# whatever else is being simulated. No fail-vocabulary in the message on purpose:
# the non-zero status is what has to carry it, which is the branch check 8 leans
# on when Apple documents no status at all.
[ -e "${2:-}" ] || { echo "syspolicy_check: ${2:-}: No such file or directory"; exit 74; }
case "${STUB_BREAK:-}" in
  syspolicy_usage) echo "Usage: syspolicy_check <check> <path>"; exit 64 ;;
  syspolicy) echo "App failed pre-distribution checks: not notarized"; exit 1 ;;
  # Apple documents NO exit status for this tool, so "exit 0 means pass" is an
  # assumption. This is that assumption being wrong: the tool exits 0 while
  # saying the build is unacceptable.
  syspolicy_zero_but_failed) echo "App failed pre-distribution checks: not notarized"; exit 0 ;;
  # And this is the other half: exit 0 with wording nobody taught the check.
  # Unknown must not read as pass.
  syspolicy_unknown) echo "Assessment complete. 3 items evaluated."; exit 0 ;;
  # syspolicy_check reports PER CHECK, so a fatally unnotarized build still
  # prints that codesign passed — a `pass` token matches the WRONG line.
  syspolicy_mixed)
    echo "Codesign check passed."
    echo "Notary Ticket Missing"
    echo "Severity: Fatal"
    echo "Type: Distribution Error"
    exit 0 ;;
  syspolicy_mixed_count)
    echo "2 of 3 checks passed."
    echo "Notary Ticket Missing"
    exit 0 ;;
  # A per-check "passed" and NOTHING ELSE — no failure vocabulary to catch it,
  # and no statement that the whole assessment succeeded. This is what isolates
  # the pass token: with `pass` matching anywhere it is green, and the widened
  # fail pattern cannot save it because there is nothing to match.
  syspolicy_partial)
    echo "Codesign check passed."
    exit 0 ;;
  # A PASSING report that mentions errors only to count zero of them. The fail
  # vocabulary is deliberately broad, so without the zero-count exclusion this
  # reds a build that is fine — the kind of noise that teaches people to ignore
  # the row.
  syspolicy_verbose_pass)
    echo "App passed all pre-distribution checks and is ready for distribution."
    echo "0 errors, 0 warnings"
    exit 0 ;;
  # And the other direction: zero-counts present AND a real failure. Dropping
  # the count lines must not drop the finding with them.
  syspolicy_zero_and_fatal)
    echo "0 warnings"
    echo "Notary Ticket Missing"
    exit 0 ;;
  # THE SAME LINE, which the two-line case above cannot test. A filter that drops
  # any line CONTAINING a zero-count discards this failure whole — the filter
  # eating the finding it was meant to sit beside.
  syspolicy_fatal_same_line)
    echo "Notary Ticket Missing, 0 errors in codesign"
    exit 0 ;;
  # The green that shipped on a906f15: the filter ate a failure carrying a
  # zero-count, then the pass sentence satisfied the pass check.
  syspolicy_green_trap)
    echo "App passed all pre-distribution checks and is ready for distribution."
    echo "Notary Ticket Missing, 0 errors in codesign"
    exit 0 ;;
esac
echo "App passed all pre-distribution checks and is ready for distribution."
exit 0
EOF

  chmod +x "$bin"/*
}

# ── the fixture bundle ────────────────────────────────────────────────────────
# A .app with three Mach-O files (main binary, a bundled dylib, and a helper in
# Contents/Resources — the place `codesign --deep` has been observed to miss) and
# one non-Mach-O, so the enumeration has something to correctly exclude.
build_fixture() { # <dir> [version] [plist-claim] [lc-flavour]
  local dir="$1" version="${2:-0.100.0}" claim="${3:-10.13}" flavour="${4:-x86}"
  local app="$dir/mnt/Unyt Sandbox.app" lc
  case "$flavour" in
    arm64) lc="$LC_ARM64" ;;
    *)     lc="$LC_X86" ;;
  esac
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks" "$dir/otool"

  # Real Mach-O magic (0xfeedfacf little-endian) — is_macho() reads bytes, so the
  # fixture has to carry them; the trailing text is just padding. FIX_NO_MACHO
  # writes plain scripts instead, producing a bundle the scans find NOTHING in.
  local m
  for m in "$app/Contents/MacOS/unyt-sandbox" "$app/Contents/Resources/helper" \
           "$app/Contents/Frameworks/libunyt.dylib"; do
    if [ -n "${FIX_NO_MACHO:-}" ]; then
      printf '#!/bin/sh\nexit 0\n' >"$m"
    else
      # OCTAL escapes, not \x: this test also runs on a macOS runner, where
      # /bin/bash is 3.2, and \xHH is not portable that far back.
      printf '\317\372\355\376 padding' >"$m"
    fi
    chmod +x "$m"
  done
  # Must NOT be picked up as a Mach-O.
  printf 'icns is not a mach-o' >"$app/Contents/Resources/icon.icns"

  cat >"$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>unyt-sandbox</string>
	<key>CFBundleIdentifier</key>
	<string>co.unyt.unyt.sandbox</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>LSMinimumSystemVersion</key>
	<string>$claim</string>
</dict>
</plist>
EOF

  for m in unyt-sandbox helper libunyt.dylib; do
    printf '%s\n' "$OTOOL_L_CLEAN" >"$dir/otool/$m.deps"
    printf '%s\n' "$lc" >"$dir/otool/$m.loadcmds"
  done

  # A UNIVERSAL main binary: two slices, two different minimums, two different
  # floors. FIX_UNIVERSAL_X86 sets what the x86_64 slice demands — 10.13 is
  # correct, 11.0 is the bug that hides behind the arm64 slice, since the max
  # across slices is 11.0 either way.
  if [ -n "${FIX_UNIVERSAL:-}" ]; then
    mkdir -p "$dir/lipo"
    printf 'x86_64 arm64\n' >"$dir/lipo/unyt-sandbox"
    printf '%s\n' "$LC_ARM64" >"$dir/otool/unyt-sandbox.arm64.loadcmds"
    if [ "${FIX_UNIVERSAL_X86:-10.13}" = "10.13" ]; then
      printf '%s\n' "$LC_X86" >"$dir/otool/unyt-sandbox.x86_64.loadcmds"
    else
      printf 'Load command 9\n      cmd LC_VERSION_MIN_MACOSX\n  cmdsize 16\n  version %s\n      sdk 26.5\n' \
        "${FIX_UNIVERSAL_X86}" >"$dir/otool/unyt-sandbox.x86_64.loadcmds"
    fi
  fi
  : >"$dir/artifact.dmg"
}

# ── running one scenario ──────────────────────────────────────────────────────
# stdout (the summary table) is captured separately from stderr (the narration),
# so a row is read only from the table and never from a `===== name =====`
# header that happens to contain the same words.
OUT=""; RC=0; ERR=""
SCEN_DIR=""; SCEN_DMG=""; SCEN_STATE=""; ONLY_SEQ=0; SCEN_ENV=()
# FIX_* are prefix assignments, cleared in build_scenario: a leaked one would
# mis-build every later scenario, which is the one failure a test cannot report.
scenario_reset() {
  FIX_VERSION=""; FIX_CLAIM=""; FIX_FLAVOUR=""; FIX_MUTATE=""; FIX_DMG_NAME=""
  FIX_NO_MACHO=""; FIX_NO_SORT_V=""; FIX_UNIVERSAL=""; FIX_UNIVERSAL_X86=""
}
scenario_reset

# The fixture and the stub toolchain, without running anything. Split out of
# run_scenario because the --only path drives ONE scenario through SEVERAL
# invocations — each check is its own process there, which is the whole point of
# the split — so building and running can no longer be one step.
build_scenario() { # <name>
  local name="$1"
  SCEN_DIR="$ROOT/$name"
  mkdir -p "$SCEN_DIR"
  build_fixture "$SCEN_DIR" "${FIX_VERSION:-0.100.0}" "${FIX_CLAIM:-10.13}" "${FIX_FLAVOUR:-x86}"
  make_stubs "$SCEN_DIR/bin"
  [ -n "${FIX_MUTATE:-}" ] && "$FIX_MUTATE" "$SCEN_DIR"
  SCEN_DMG="$SCEN_DIR/${FIX_DMG_NAME:-unyt_0.100.0_Unyt.Sandbox_default-arc_x64_darwin.dmg}"
  SCEN_STATE="$SCEN_DIR/state"
  mv "$SCEN_DIR/artifact.dmg" "$SCEN_DMG"
  scenario_reset
  # Cleared alongside the FIX_* prefixes, and for the same reason: an invoker
  # that forgot to rebuild it would otherwise run THIS scenario against the
  # previous one's stubs and state directory.
  SCEN_ENV=()
}

# THE ENVIRONMENT EVERY INVOCATION RUNS UNDER, in one place because the one bug
# this harness shipped was a single invoker missing a variable: run_scenario
# passed PATH and STUB_FIXTURE but not UNYT_SMOKE_STATE, so with that variable
# set in the caller's environment — which is exactly what release-smoke.yaml does
# — every scenario shared one mountpoint, and a scenario found the previous one's
# extracted bundle. NOTHING THE SCRIPT OR ITS STUBS READ IS INHERITED: a scenario
# reads and writes only its own directory, and breaks only what it says it
# breaks. Call-site assignments are applied after these, so a scenario that needs
# its own results file or its own breakage still gets it.
scen_env() { # <results file>
  SCEN_ENV=(
    PATH="$SCEN_DIR/bin:$PATH"
    STUB_FIXTURE="$SCEN_DIR"
    UNYT_SMOKE_STATE="$SCEN_STATE"
    UNYT_SMOKE_RESULTS="$1"
    # The stub toolchain's own knobs, and the two the real script reads. Emptied
    # rather than left alone: each is how ONE scenario breaks ONE thing, so an
    # exported STUB_BREAK in the caller's shell would break every scenario at
    # once and red the suite for a reason that has nothing to do with the checks.
    # Empty is as good as unset — every consumer reads them as ${VAR:-default}.
    STUB_BREAK= STUB_BIN_ARCH= STUB_RUNNER_ARCH=
    UNYT_EXPECTED_TEAM_ID= UNYT_HDIUTIL_TIMEOUT=
  )
}

run_scenario() { # <name> [env assignments...]
  local name="$1"; shift
  build_scenario "$name"
  ERR="$SCEN_DIR/stderr.log"
  scen_env "$SCEN_DIR/rows.txt"
  OUT="$(env "${SCEN_ENV[@]}" "$@" bash "$SCRIPT" "$SCEN_DMG" 2>"$ERR")"
  RC=$?
}

# One --only invocation against an already-built scenario, with ONE state
# directory shared across calls. That sharing is itself under test: on the split
# path each check runs in its own process, so what check 1 extracts has to reach
# check 9 through UNYT_SMOKE_STATE rather than through a variable.
only_check() { # <id> [env assignments...]
  local id="$1"; shift
  ONLY_SEQ=$((ONLY_SEQ + 1))
  ERR="$SCEN_DIR/stderr-$ONLY_SEQ-$id.log"
  scen_env "$SCEN_DIR/only-rows.txt"
  OUT="$(env "${SCEN_ENV[@]}" "$@" bash "$SCRIPT" --only "$id" "$SCEN_DMG" 2>"$ERR")"
  RC=$?
}

# The modes that take no check id — --print-checks, --report, --cleanup — against
# the same state directory, so they see whatever only_check left in it.
mode_check() { # <tag> <script args...>
  local tag="$1"; shift
  ONLY_SEQ=$((ONLY_SEQ + 1))
  ERR="$SCEN_DIR/stderr-$ONLY_SEQ-$tag.log"
  scen_env "$SCEN_DIR/mode-rows.txt"
  OUT="$(env "${SCEN_ENV[@]}" bash "$SCRIPT" "$@" 2>"$ERR")"
  RC=$?
}

# A row's verdict, read from the summary table's last column.
row() { printf '%s\n' "$OUT" | grep -F "$1" | tail -1 | awk '{print $NF}'; }

expect_row() { # <check substring> <pass|FAIL> <description>
  local got; got="$(row "$1")"
  if [ "$got" = "$2" ]; then pass=$((pass + 1)); return; fi
  fail=$((fail + 1))
  printf 'FAIL  %-58s expected %s, got %s\n' "$3" "$2" "${got:-<no row>}" >&2
  note "summary was:"; printf '%s\n' "$OUT" | sed 's/^/      /' >&2
}
# Which DIAGNOSIS the run produced, not merely that it went red. Where several
# guards can reject the same fixture, only this pins the one under test — the
# row alone stays red when the guard is deleted, so the deletion is invisible.
expect_err() { # <substring> <description>
  if grep -qF -e "$1" "$ERR"; then pass=$((pass + 1)); return; fi
  fail=$((fail + 1))
  printf 'FAIL  %-58s no "%s" in the diagnosis\n' "$2" "$1" >&2
}
# The EXACT code: 1 is a failed check, 2 a wrong invocation. Collapsing them
# lets a mistyped id read as a failing artifact.
expect_rc() { # <zero|nonzero|N> <description>
  local ok=no
  case "$1" in
    zero)    [ "$RC" -eq 0 ] && ok=yes ;;
    nonzero) [ "$RC" -ne 0 ] && ok=yes ;;
    *)       [ "$RC" -eq "$1" ] && ok=yes ;;
  esac
  if [ "$ok" = yes ]; then pass=$((pass + 1)); return; fi
  fail=$((fail + 1))
  printf 'FAIL  %-58s exit status was %s, expected %s\n' "$2" "$RC" "$1" >&2
}
# The other direction, for output whose ABSENCE is the property. A header printed
# unconditionally cannot tell a report that listed something from one that listed
# nothing; only asserting that the list itself is missing can.
expect_no_err() { # <substring> <description>
  if ! grep -qF -e "$1" "$ERR"; then pass=$((pass + 1)); return; fi
  fail=$((fail + 1))
  printf 'FAIL  %-58s "%s" was in the diagnosis and should not have been\n' "$2" "$1" >&2
}
# What a tool was actually POINTED AT, read back from the stub's own record.
expect_target() { # <tool> <substring> <description>
  local rec="$SCEN_DIR/calls/$1"
  if [ -f "$rec" ] && grep -qF -e "$2" "$rec"; then pass=$((pass + 1)); return; fi
  fail=$((fail + 1))
  printf 'FAIL  %-58s %s was never pointed at "%s"\n' "$3" "$1" "$2" >&2
  [ -f "$rec" ] && sed 's/^/      /' "$rec" >&2
}
# ...and the call a tool must NOT have made, or must not have made in that state.
expect_no_target() { # <tool> <substring> <description>
  local rec="$SCEN_DIR/calls/$1"
  if [ ! -f "$rec" ] || ! grep -qF -e "$2" "$rec"; then pass=$((pass + 1)); return; fi
  fail=$((fail + 1))
  printf 'FAIL  %-58s %s made a call matching "%s"\n' "$3" "$1" "$2" >&2
  sed 's/^/      /' "$rec" >&2
}
# The WHOLE of stdout, which on the --only path is exactly one row. Asserting all
# of it is what proves "exactly one row": a step that printed a summary table, a
# second row, or nothing at all fails here even when its verdict was right, and
# the workflow reads that stdout as the check's answer.
expect_only_row() { # <check name> <pass|FAIL> <description>
  if [ "$OUT" = "$1|$2" ]; then pass=$((pass + 1)); return; fi
  fail=$((fail + 1))
  printf 'FAIL  %-58s expected exactly "%s", got "%s"\n' "$3" "$1|$2" "$OUT" >&2
}

CHECKS=(
  "mounts and yields a .app bundle"
  "the bundled app is the version the artifact claims"
  "the bundle's architecture matches the runner"
  "no build-machine library paths in any Mach-O"
  "every Mach-O in the bundle is signed"
  "Gatekeeper accepts it as notarized software"
  "the notarization ticket is stapled"
  "passes Apple's own distribution assessment"
  "deployment target within the supported floor"
)
# The ids --only takes, in the same order and pairing as CHECKS above. That
# pairing is what --print-checks declares to the workflow, so the split block
# below asserts the script's list against this one rather than trusting it.
CHECK_IDS=(mount version arch paths signed gatekeeper stapled syspolicy deployment)
# Every check EXCEPT the named one must still pass — a scenario that turned two
# rows red would mean the breakage leaked, and a check that goes red for
# something other than its own subject is not the check it claims to be.
expect_only_failure() { # <check substring> <description>
  local c
  for c in "${CHECKS[@]}"; do
    if [ "$c" = "$1" ]; then expect_row "$c" FAIL "$2"; else
      expect_row "$c" pass "$2 (collateral: $c)"; fi
  done
  expect_rc nonzero "$2 (the run goes red)"
}

# ── 0. the baseline passes ────────────────────────────────────────────────────
# Without this every scenario below could be "red because everything is red".
FIX_MUTATE="" run_scenario baseline-x86
for c in "${CHECKS[@]}"; do expect_row "$c" pass "baseline x86_64: $c"; done
expect_rc zero "baseline x86_64 exits 0"

# The arm64 build: LC_BUILD_VERSION minos 11.0 against an Info.plist that claims
# 10.13. Measured on the real artifact, and it must NOT be a failure — arm64
# macOS starts at 11.0, so the claim is unreachable there. A naive
# claim-vs-binary comparison paints this red for a perfectly good build.
FIX_FLAVOUR=arm64 run_scenario baseline-arm64 STUB_BIN_ARCH=arm64 STUB_RUNNER_ARCH=arm64
expect_row "deployment target within the supported floor" pass \
  "arm64: minos 11.0 under a 10.13 claim is not a violation"
expect_rc zero "baseline arm64 exits 0"

# ── 1. mount ──────────────────────────────────────────────────────────────────
run_scenario break-mount STUB_BREAK=mount
expect_row "mounts and yields a .app bundle" FAIL "a disk image that will not mount"
expect_rc nonzero "an unmountable image goes red"
# hdiutil's own words, which -quiet used to swallow: a corrupt download failed
# with nothing said about why.
expect_err "no mountable file systems" "hdiutil's diagnosis reaches the log"

# A licence-agreement image waits for a keypress. Bounded, or the job hangs to
# the runner's six-hour ceiling with no diagnosis at all.
run_scenario break-mount-hang STUB_BREAK=hdiutil_hang UNYT_HDIUTIL_TIMEOUT=3
expect_row "mounts and yields a .app bundle" FAIL "an image that never finishes attaching"
expect_err "did not finish attaching" "a stalled attach is diagnosed, not waited on"
# The abort path still has to print its table, or the failure is invisible.
if printf '%s\n' "$OUT" | grep -q '^# summary'; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  the early abort printed no summary table" >&2; fi

run_scenario break-noapp STUB_BREAK=noapp
expect_row "mounts and yields a .app bundle" FAIL "an image that mounts but holds no .app"
expect_rc nonzero "an image without a .app goes red"

run_scenario break-ditto STUB_BREAK=ditto
expect_row "mounts and yields a .app bundle" FAIL "a copy out of the image that fails"
expect_rc nonzero "a failed extraction goes red"

# ── 2. version ────────────────────────────────────────────────────────────────
FIX_VERSION=0.99.0 run_scenario break-version
expect_only_failure "the bundled app is the version the artifact claims" \
  "a DMG named 0.100.0 packaging 0.99.0"

# A locally named file the version cannot be read from is UNKNOWN, and unknown
# must not be green: the check could not answer its question.
FIX_DMG_NAME=handbuilt.dmg run_scenario break-unnamed
expect_row "the bundled app is the version the artifact claims" FAIL \
  "an artifact whose name carries no version"

# THE PRE-RELEASE CHANNEL. Read only as far as the `-` and a -dev DMG carries no
# readable version, so this check reds on every artifact of every -dev release —
# a red saying nothing about the build.
FIX_VERSION=0.101.0-dev.0 \
  FIX_DMG_NAME=unyt_0.101.0-dev.0_Unyt.Sandbox_default-arc_x64_darwin.dmg \
  run_scenario dev-version
expect_row "the bundled app is the version the artifact claims" pass \
  "a -dev DMG matching its bundle"
FIX_VERSION=0.101.0 \
  FIX_DMG_NAME=unyt_0.101.0-dev.0_Unyt.Sandbox_default-arc_x64_darwin.dmg \
  run_scenario dev-version-mismatch
expect_row "the bundled app is the version the artifact claims" FAIL \
  "a -dev DMG packaging the stable version"
expect_err "named 0.101.0-dev.0 but packages version 0.101.0" \
  "and the tail is compared, not discarded"

# ── 3. architecture ───────────────────────────────────────────────────────────
run_scenario break-arch STUB_BIN_ARCH=arm64 STUB_RUNNER_ARCH=x86_64
expect_row "the bundle's architecture matches the runner" FAIL \
  "an aarch64 bundle on an Intel runner"
expect_rc nonzero "a mispaired runner goes red"

# ── 4. build-machine paths ────────────────────────────────────────────────────
mutate_homebrew() {
  printf '%s\n\t/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib (compatibility version 3.0.0, current version 3.0.0)\n' \
    "$OTOOL_L_CLEAN" >"$1/otool/libunyt.dylib.deps"
}
FIX_MUTATE=mutate_homebrew run_scenario break-homebrew
expect_only_failure "no build-machine library paths in any Mach-O" \
  "a bundled dylib linking against /opt/homebrew"

# The same bug wearing the other hat: an rpath baked at build time. A check that
# only reads otool -L never sees it.
mutate_rpath() {
  printf '%s\nLoad command 20\n      cmd LC_RPATH\n  cmdsize 32\n     path /usr/local/lib (offset 12)\n' \
    "$LC_X86" >"$1/otool/unyt-sandbox.loadcmds"
}
FIX_MUTATE=mutate_rpath run_scenario break-rpath
expect_only_failure "no build-machine library paths in any Mach-O" \
  "an LC_RPATH pointing at /usr/local"

# ── 5. signatures ─────────────────────────────────────────────────────────────
# The documented blind spot: an unsigned binary in Contents/Resources, which
# `codesign --deep` has been observed to walk straight past.
run_scenario break-unsigned STUB_BREAK=unsigned
expect_only_failure "every Mach-O in the bundle is signed" \
  "an unsigned helper in Contents/Resources"

# The arm64 hole: Apple Silicon binaries are ad-hoc signed by default and pass
# `--verify --strict`, so a missed dylib is invisible there. Only `-dv` tells.
run_scenario break-adhoc STUB_BREAK=adhoc
expect_only_failure "every Mach-O in the bundle is signed" \
  "an ad-hoc signed dylib that VERIFIES but no Developer ID signed"
# WHICH guard fired, not just that the row went red. These checks are layered —
# an ad-hoc signature also lacks an Authority line — so without pinning the
# diagnosis, deleting the ad-hoc guard leaves the row red for a different reason
# and the deletion goes unnoticed. Mutation testing showed exactly that.
expect_err "AD-HOC signature" "the ad-hoc guard is what rejects an ad-hoc signature"

run_scenario break-noteam STUB_BREAK=noteam
expect_only_failure "every Mach-O in the bundle is signed" \
  "a signature with no TeamIdentifier"
expect_err "no TeamIdentifier" "the TeamIdentifier guard is what rejects a team-less signature"

run_scenario break-applesigned STUB_BREAK=applesigned
expect_only_failure "every Mach-O in the bundle is signed" \
  "signed by Apple, but not by a Developer ID Application authority"

# A bundle assembled from parts signed by different identities. Asserted without
# needing the team ID to be declared, which this repo does not record.
run_scenario break-twoteams STUB_BREAK=twoteams
expect_only_failure "every Mach-O in the bundle is signed" \
  "two different signing teams in one bundle"

# The UNYT_EXPECTED_TEAM_ID pin. Inert as shipped, since the constant is empty —
# but it is precisely what someone will rely on the day they fill it in, so it
# gets covered now rather than the first time it matters. Both directions: the
# right team must not fire, the wrong one must.
run_scenario team-pin-matches UNYT_EXPECTED_TEAM_ID=ABCDE12345
expect_row "every Mach-O in the bundle is signed" pass \
  "a matching team pin does not false-red"
expect_rc zero "a matching team pin leaves the run green"

run_scenario break-team-mismatch UNYT_EXPECTED_TEAM_ID=ZZZZZ99999
expect_only_failure "every Mach-O in the bundle is signed" \
  "a bundle signed by a team other than the pinned one"
expect_err "expected ZZZZZ99999" "the mismatch names both teams"

# ── 6. Gatekeeper ─────────────────────────────────────────────────────────────
run_scenario break-gk STUB_BREAK=gatekeeper_rejected
expect_only_failure "Gatekeeper accepts it as notarized software" \
  "an app Gatekeeper rejects outright"

# The one that matters most: `accepted`, but not as notarized software. A check
# reading only spctl's exit status calls this a pass, and the download then fails
# on a user's Mac, where quarantine makes notarization mandatory.
run_scenario break-gk-source STUB_BREAK=gatekeeper_unnotarized
expect_only_failure "Gatekeeper accepts it as notarized software" \
  "accepted, but NOT as notarized Developer ID"
expect_err "NOT as notarized Developer ID" "the source line is what rejects it"

# spctl exiting 0 without ever saying "accepted": the assessment did not happen,
# and that must not read the same as one that passed. Nothing exercised this
# guard before, so it was deletable unnoticed.
run_scenario break-gk-silent STUB_BREAK=gatekeeper_silent
expect_only_failure "Gatekeeper accepts it as notarized software" \
  "spctl exits 0 without accepting anything"
expect_err "without accepting the app" "the missing verdict is diagnosed as such"

# ── 7. stapling ───────────────────────────────────────────────────────────────
run_scenario break-staple STUB_BREAK=stapler
expect_only_failure "the notarization ticket is stapled" \
  "a notarized build with no stapled ticket"

# ── 8. syspolicy_check ────────────────────────────────────────────────────────
run_scenario break-syspolicy STUB_BREAK=syspolicy
expect_only_failure "passes Apple's own distribution assessment" \
  "Apple's assessment saying it is not distributable"

# A wrong invocation must be reported AS a wrong invocation, not as a verdict on
# the artifact — this repo cannot run the tool, so that path is a live risk.
run_scenario break-syspolicy-usage STUB_BREAK=syspolicy_usage
expect_row "passes Apple's own distribution assessment" FAIL \
  "a usage error is a failure, not a pass"
if grep -q 'rejected the INVOCATION' "$ERR"; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  a usage error was not reported as an invocation problem" >&2; fi

# Absent tool: fails CLOSED. "Could not assess" and "assessed fine" must never be
# the same colour.
mutate_no_syspolicy() { rm -f "$1/bin/syspolicy_check"; }
FIX_MUTATE=mutate_no_syspolicy run_scenario break-syspolicy-missing
expect_row "passes Apple's own distribution assessment" FAIL \
  "a missing syspolicy_check fails closed"

# Apple documents NO exit status for syspolicy_check, so gating on exit 0 alone
# rests on an assumption this repo cannot check. These two scenarios ARE that
# assumption being wrong, in both directions — and they are the reason the check
# reads the output as well as the status, exactly as check 6 does for spctl.
run_scenario break-syspolicy-zero STUB_BREAK=syspolicy_zero_but_failed
expect_only_failure "passes Apple's own distribution assessment" \
  "exit 0 while SAYING it failed must not be a pass"
# Pinned to the failure branch specifically: the unknown-wording branch would
# also turn this red, which would hide the loss of the failure-marker read.
expect_err "not ready for distribution" "the output, not the exit status, is what rejects it"

run_scenario break-syspolicy-unknown STUB_BREAK=syspolicy_unknown
expect_only_failure "passes Apple's own distribution assessment" \
  "exit 0 with unrecognised wording is 'cannot tell', not 'fine'"

# THE MIXED REPORT — the one that made this check green on an undistributable
# build. syspolicy_check reports per check, so a fatal notarization problem sits
# in the same output as "Codesign check passed."; a pass token matching `pass`
# anywhere matched that line, and none of Missing/Fatal/Error was a fail token.
run_scenario break-syspolicy-mixed STUB_BREAK=syspolicy_mixed
expect_only_failure "passes Apple's own distribution assessment" \
  "a per-check 'passed' inside a FATAL report is not a pass"
expect_err "not ready for distribution" "the failure block decides, not the passing line"

run_scenario break-syspolicy-counted STUB_BREAK=syspolicy_mixed_count
expect_only_failure "passes Apple's own distribution assessment" \
  "'2 of 3 checks passed' plus a missing ticket is not a pass"

# Isolates the PASS token: the scenarios above trip the fail pattern, so only a
# report with no failure vocabulary says how narrow the pass pattern is.
run_scenario break-syspolicy-partial STUB_BREAK=syspolicy_partial
expect_only_failure "passes Apple's own distribution assessment" \
  "a lone per-check 'passed' is not a distribution verdict"
expect_err "matched no known pass or fail wording" "a partial report is reported as unreadable"

# The cost of a broad fail vocabulary, and the bound on it. A passing report that
# counts ZERO errors must not be red — that is the noise that teaches people to
# ignore the row — while zero-counts sitting beside a real failure must not
# smuggle it past.
run_scenario syspolicy-verbose-pass STUB_BREAK=syspolicy_verbose_pass
expect_row "passes Apple's own distribution assessment" pass \
  "'0 errors, 0 warnings' in a passing report is not a failure"
expect_rc zero "a verbose passing report leaves the run green"

run_scenario break-syspolicy-zero-and-fatal STUB_BREAK=syspolicy_zero_and_fatal
expect_only_failure "passes Apple's own distribution assessment" \
  "dropping the zero-count lines must not drop the real failure with them"
# WHICH branch: the failure one. An over-greedy exclusion that ate the finding
# along with the counts still reds this row — via "cannot tell" — so without
# pinning the branch, a filter wide enough to swallow real findings passes
# unnoticed. Mutation testing showed exactly that.
expect_err "not ready for distribution" "the finding survives the filter, not just the row"

# Zero-count on the SAME line as the failure: a filter dropping any line that
# contains one would discard the finding with it.
run_scenario break-syspolicy-fatal-same-line STUB_BREAK=syspolicy_fatal_same_line
expect_only_failure "passes Apple's own distribution assessment" \
  "a failure carrying its own zero-count on one line"
expect_err "not ready for distribution" "the failure is read, not filtered away with the count"

# The false green that shipped on a906f15 — kept as the defect, not a variant.
run_scenario break-syspolicy-green-trap STUB_BREAK=syspolicy_green_trap
expect_only_failure "passes Apple's own distribution assessment" \
  "a missing notary ticket beside 'ready for distribution' is NOT a pass"
expect_err "not ready for distribution" "the finding wins over the pass sentence"

# ── 9. deployment target ──────────────────────────────────────────────────────
# The documented real-world failure: a bundled dependency built against a newer
# deployment target than the app claims. It launches on the OS the Info.plist
# advertises and dies in dyld.
mutate_dylib_too_new() {
  printf 'Load command 8\n      cmd LC_BUILD_VERSION\n  cmdsize 32\n platform macos\n      sdk 26.5\n    minos 12.0\n   ntools 1\n     tool ld\n' \
    >"$1/otool/libunyt.dylib.loadcmds"
}
FIX_MUTATE=mutate_dylib_too_new run_scenario break-deployment
expect_only_failure "deployment target within the supported floor" \
  "a bundled dylib requiring macOS 12.0"

# On arm64 the floor is 11.0, not 10.13 — the check has to stay sharp there
# rather than being switched off by the relaxation.
FIX_FLAVOUR=arm64 FIX_MUTATE=mutate_dylib_too_new run_scenario break-deployment-arm \
  STUB_BIN_ARCH=arm64 STUB_RUNNER_ARCH=arm64
expect_row "deployment target within the supported floor" FAIL \
  "arm64: a dylib at 12.0 still exceeds the 11.0 floor"

# The bundle quietly dropping support it promises.
FIX_CLAIM=12.0 run_scenario break-claim
expect_row "deployment target within the supported floor" FAIL \
  "a bundle claiming macOS 12.0 against a 10.13 support floor"

# Neither load command present. "Nothing found" must not read as "nothing
# required" — this is the exact shape in which the x86_64 build would slip past a
# reader that knew only LC_BUILD_VERSION.
mutate_no_version_cmd() { : >"$1/otool/libunyt.dylib.loadcmds"; }
FIX_MUTATE=mutate_no_version_cmd run_scenario break-no-version
expect_row "deployment target within the supported floor" FAIL \
  "a Mach-O declaring no deployment target at all"

# ── universal binaries: one floor per slice ───────────────────────────────────
# Reading only the first lipo slice judged an arm64 build against x86_64's
# floor. Future-proofing: we ship per-arch DMGs today.
FIX_UNIVERSAL=1 run_scenario universal-ok STUB_BIN_ARCH=arm64 STUB_RUNNER_ARCH=arm64
expect_row "deployment target within the supported floor" pass \
  "a universal binary: x86_64 at 10.13 and arm64 at 11.0 are both correct"
expect_rc zero "a correct universal build is not red"

# And the opposite error, which taking the MAX across slices would commit: an
# x86_64 slice raised to 11.0 hides behind the arm64 slice that is legitimately
# there — the maximum is 11.0 either way — while every Intel Mac on 10.13-10.15
# has been dropped in silence.
FIX_UNIVERSAL=1 FIX_UNIVERSAL_X86=11.0 run_scenario universal-x86-too-new \
  STUB_BIN_ARCH=arm64 STUB_RUNNER_ARCH=arm64
expect_row "deployment target within the supported floor" FAIL \
  "a universal binary whose x86_64 slice silently requires 11.0"
expect_err "(x86_64) requires macOS 11.0" "the failing SLICE is named, not just the file"

# The positive half of the same pair: the x86_64 shape (LC_VERSION_MIN_MACOSX)
# is read correctly rather than being the case that finds nothing.
if grep -q 'WHOLE BUNDLE requires: 10.13' "$ROOT/baseline-x86/stderr.log"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  the x86_64 LC_VERSION_MIN_MACOSX shape was not read as 10.13" >&2
fi
if grep -q 'WHOLE BUNDLE requires: 11.0' "$ROOT/baseline-arm64/stderr.log"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  the arm64 LC_BUILD_VERSION shape was not read as 11.0" >&2
fi

# ── a sort that cannot compare versions ───────────────────────────────────────
# Every floor comparison runs through `sort -V`, so a sort without it does not
# make one check wrong — it makes them all quietly permissive. The script must
# refuse to report at all.
FIX_NO_SORT_V=1 run_scenario break-sort
expect_rc nonzero "a sort without -V stops the run instead of reporting"
if grep -q 'does not do version ordering' "$ERR"; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  a sort without -V was not diagnosed" >&2; fi

# ── the TOOL failing, not the artifact ────────────────────────────────────────
# Breaks otool, not the artifact: with the tool silent the sweep reads zero
# paths and reports green. Guard the population inspected, not the files.
mutate_homebrew_real() {
  printf '%s\n\t/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib (compatibility version 3.0.0, current version 3.0.0)\n' \
    "$OTOOL_L_CLEAN" >"$1/otool/libunyt.dylib.deps"
}
FIX_MUTATE=mutate_homebrew_real run_scenario break-otool-dead STUB_BREAK=otool_dead
expect_row "no build-machine library paths in any Mach-O" FAIL \
  "otool exits non-zero silently: a violating bundle must NOT read as clean"
expect_rc nonzero "a dead otool goes red"
expect_err "broken otool" "a dead otool is diagnosed as a tool failure"

# The same hole with a CLEAN exit status: otool succeeds and prints only its own
# header line. Exit-status-based guards see nothing wrong; the path count is what
# catches it, which is why the guard counts rather than checking the status.
FIX_MUTATE=mutate_homebrew_real run_scenario break-otool-header-only STUB_BREAK=otool_header_only
expect_row "no build-machine library paths in any Mach-O" FAIL \
  "otool exits 0 having printed no dependencies at all"
expect_err "read no load paths" "a header-only otool is caught by the path count, not its status"

# ── an empty scan is not a clean scan ─────────────────────────────────────────
# A husk with no Mach-O: three checks sweep "every Mach-O", and a sweep over
# nothing reports the same green row as a clean bundle.
FIX_NO_MACHO=1 run_scenario break-no-macho
expect_row "no build-machine library paths in any Mach-O" FAIL \
  "no Mach-O to scan: the path sweep must not report clean"
expect_row "every Mach-O in the bundle is signed" FAIL \
  "no Mach-O to verify: the signature sweep must not report clean"
expect_row "deployment target within the supported floor" FAIL \
  "no Mach-O to read: the deployment sweep must not report clean"
expect_rc nonzero "a bundle with no Mach-O goes red"
# Which guard: the no-files one, not the per-file path count, which cannot fire
# when the loop never runs. Without this the two are interchangeable and either
# could be deleted unnoticed.
expect_err "nothing was scanned" "the no-Mach-O guard is what rejects an empty bundle"

# The enumeration must exclude the non-Mach-O and include all three Mach-Os —
# a scan that quietly covered one file would make several checks meaningless.
if grep -q '3 Mach-O file(s) in the bundle' "$ROOT/baseline-x86/stderr.log"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  the bundle scan did not find exactly the 3 Mach-O files" >&2
  grep 'Mach-O file' "$ROOT/baseline-x86/stderr.log" >&2 || true
fi

# ── the split path: one check per invocation ──────────────────────────────────
# CI runs each check as its own step, so each is a separate PROCESS reading
# check 1's output off disk — a new way to stop being able to fail. Same
# assertions as above: which row, and which diagnosis, never merely that
# something went red.

# The baseline, check by check, in one shared state directory. Nine processes
# where the whole-run path has one, and every row must still be green.
build_scenario only-baseline
i=0
for id in "${CHECK_IDS[@]}"; do
  only_check "$id"
  expect_only_row "${CHECKS[$i]}" pass "--only $id: the baseline passes on its own"
  expect_rc zero "--only $id exits 0 on a pass"
  # What each check actually READ: a green row here says nothing on its own,
  # since each would also go green pointed at nothing.
  case "$id" in
    signed) expect_err "all 3 Mach-O file(s) signed" \
      "--only signed re-derives the enumeration from the state directory" ;;
    deployment) expect_err "3 across 3 Mach-O file(s)" \
      "--only deployment reads every slice of every file the state directory holds" ;;
    gatekeeper) expect_target spctl "$SCEN_STATE/Unyt Sandbox.app" \
      "--only gatekeeper assesses the bundle the mount check extracted" ;;
    stapled) expect_target xcrun "$SCEN_STATE/Unyt Sandbox.app" \
      "--only stapled validates the ticket on that same bundle" ;;
    syspolicy) expect_target syspolicy_check "$SCEN_STATE/Unyt Sandbox.app" \
      "--only syspolicy assesses that same bundle" ;;
  esac
  i=$((i + 1))
done

# --print-checks IS the contract between this script and the workflow: the guard
# step reads it to prove every check reported, so it is asserted whole — ids and
# names, paired, in run order. A list that lost an entry would give the workflow
# eight steps and no way to know a check went missing.
build_scenario only-print-checks
mode_check print --print-checks
expected_checks="$(
  i=0
  for id in "${CHECK_IDS[@]}"; do
    printf '%s\t%s\n' "$id" "${CHECKS[$i]}"
    i=$((i + 1))
  done
)"
if [ "$OUT" = "$expected_checks" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  --print-checks did not list the nine ids and names in order" >&2
  printf '%s\n' "$OUT" | sed 's/^/      /' >&2
fi
expect_rc zero "--print-checks exits 0 and needs no artifact"

# EACH CHECK, BROKEN, ALONE IN ITS PROCESS. The scenarios far above prove each
# check can fail on the whole-run path; these prove it still can when nothing
# else has run in the same process — a check leaning on state a predecessor left
# in a variable would go quiet here, and quiet is green.
build_scenario only-break-mount
only_check mount STUB_BREAK=mount
expect_only_row "mounts and yields a .app bundle" FAIL "--only mount: an image that will not mount"
expect_rc 1 "--only mount exits 1 on an unmountable image, the FAILED-check code"
expect_err "no mountable file systems" "--only mount: hdiutil's own diagnosis reaches the log"

FIX_VERSION=0.99.0 build_scenario only-break-version
only_check mount
expect_only_row "mounts and yields a .app bundle" pass "--only version: its prerequisite mounts first"
only_check version
expect_only_row "the bundled app is the version the artifact claims" FAIL \
  "--only version: a DMG named 0.100.0 packaging 0.99.0"
expect_rc nonzero "--only version goes red on a mismatch"
expect_err "but packages version 0.99.0" "--only version names both versions"

build_scenario only-break-arch
only_check mount STUB_BIN_ARCH=arm64 STUB_RUNNER_ARCH=x86_64
expect_only_row "mounts and yields a .app bundle" pass "--only arch: its prerequisite mounts first"
only_check arch STUB_BIN_ARCH=arm64 STUB_RUNNER_ARCH=x86_64
expect_only_row "the bundle's architecture matches the runner" FAIL \
  "--only arch: an aarch64 bundle on an Intel runner"
expect_rc nonzero "--only arch goes red on a mispaired runner"
expect_err "but the runner is x86_64" "--only arch names the runner it was paired with"

FIX_MUTATE=mutate_homebrew build_scenario only-break-paths
only_check mount
expect_only_row "mounts and yields a .app bundle" pass "--only paths: its prerequisite mounts first"
only_check paths
expect_only_row "no build-machine library paths in any Mach-O" FAIL \
  "--only paths: a bundled dylib linking against /opt/homebrew"
expect_rc nonzero "--only paths goes red on a build-machine prefix"
expect_err "loads /opt/homebrew/opt/openssl@3" "--only paths names the offending load path"

build_scenario only-break-signed
only_check mount STUB_BREAK=adhoc
expect_only_row "mounts and yields a .app bundle" pass "--only signed: its prerequisite mounts first"
only_check signed STUB_BREAK=adhoc
expect_only_row "every Mach-O in the bundle is signed" FAIL \
  "--only signed: an ad-hoc signed dylib that VERIFIES but no Developer ID signed"
expect_rc nonzero "--only signed goes red on an ad-hoc signature"
expect_err "AD-HOC signature" "--only signed: the ad-hoc guard is what rejects it"

build_scenario only-break-gatekeeper
only_check mount STUB_BREAK=gatekeeper_unnotarized
expect_only_row "mounts and yields a .app bundle" pass "--only gatekeeper: its prerequisite mounts first"
only_check gatekeeper STUB_BREAK=gatekeeper_unnotarized
expect_only_row "Gatekeeper accepts it as notarized software" FAIL \
  "--only gatekeeper: accepted, but NOT as notarized Developer ID"
expect_rc nonzero "--only gatekeeper goes red on an unnotarized acceptance"
expect_err "NOT as notarized Developer ID" "--only gatekeeper: the source line is what rejects it"

build_scenario only-break-stapled
only_check mount STUB_BREAK=stapler
expect_only_row "mounts and yields a .app bundle" pass "--only stapled: its prerequisite mounts first"
only_check stapled STUB_BREAK=stapler
expect_only_row "the notarization ticket is stapled" FAIL \
  "--only stapled: a notarized build with no stapled ticket"
expect_rc nonzero "--only stapled goes red on a missing ticket"
expect_err "no stapled notarization ticket" "--only stapled diagnoses the missing ticket"

# THE FALSE GREEN THAT SHIPPED on a906f15, re-run on the split path: a missing
# notary ticket carrying its own zero-count, beside the sentence that says the
# build is ready. Both halves of that trap have to survive the restructuring.
build_scenario only-break-syspolicy
only_check mount STUB_BREAK=syspolicy_green_trap
expect_only_row "mounts and yields a .app bundle" pass "--only syspolicy: its prerequisite mounts first"
only_check syspolicy STUB_BREAK=syspolicy_green_trap
expect_only_row "passes Apple's own distribution assessment" FAIL \
  "--only syspolicy: a missing notary ticket beside 'ready for distribution' is NOT a pass"
expect_rc nonzero "--only syspolicy goes red on the green trap"
expect_err "not ready for distribution" "--only syspolicy: the finding wins over the pass sentence"

FIX_MUTATE=mutate_dylib_too_new build_scenario only-break-deployment
only_check mount
expect_only_row "mounts and yields a .app bundle" pass "--only deployment: its prerequisite mounts first"
only_check deployment
expect_only_row "deployment target within the supported floor" FAIL \
  "--only deployment: a bundled dylib requiring macOS 12.0"
expect_rc nonzero "--only deployment goes red on a too-new dependency"
expect_err "requires macOS 12.0" "--only deployment names the version it cannot accept"

# A CHECK WHOSE PREREQUISITE NEVER RAN — the failure mode the split path invents.
build_scenario only-no-mount
i=0
for id in "${CHECK_IDS[@]}"; do
  name="${CHECKS[$i]}"
  i=$((i + 1))
  [ "$id" = mount ] && continue
  only_check "$id"
  expect_only_row "$name" FAIL "--only $id with no mount in the state directory FAILs"
  # EXACTLY 1, the FAILED-check code. This is the one place the two nonzero codes
  # are genuinely confusable — a missing prerequisite looks like a wrong call —
  # and reporting it as 2 would say the invocation was bad when the truth is that
  # the check did not pass.
  expect_rc 1 "--only $id with no mount exits 1: a FAILED check, not a wrong invocation"
  expect_err "mounts and yields a .app bundle" "--only $id names the prerequisite it is missing"
done

# An id nobody runs must be an ERROR, not a silent no-op: a workflow stepping
# through a mistyped id would otherwise show a green step for a check that never
# happened, which is the one outcome this suite refuses to allow.
build_scenario only-unknown-id
only_check no-such-check
expect_rc 2 "--only with an unknown id exits 2, the INVOCATION-was-wrong code"
expect_err "unknown check id 'no-such-check'" "the unknown id is named back"
if [ -z "$OUT" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  --only with an unknown id printed a row for a check that does not exist" >&2
fi

# EVERY invocation error, on the exact code. 2 rather than 1 is the whole point —
# a caller that cannot tell them apart debugs the artifact when the call was
# wrong — and it is about to be relied on by the workflow and by the Windows
# lane, so it is asserted at every site rather than at the interesting one.
mode_check only-noartifact --only version
expect_rc 2 "--only without an artifact exits 2"
expect_err "usage: check-macos.sh --only" "the usage error says what the invocation should look like"

mode_check only-noid --only
expect_rc 2 "--only with no id at all exits 2"

mode_check report-noartifact --report
expect_rc 2 "--report without an artifact exits 2"
expect_err "usage: check-macos.sh --report" "the --report usage error says what it wanted"

mode_check print-extra --print-checks "$SCEN_DMG"
expect_rc 2 "--print-checks with an argument exits 2"
expect_err "takes no other argument" "--print-checks says it wanted nothing else"

mode_check cleanup-extra --cleanup "$SCEN_DMG"
expect_rc 2 "--cleanup with an argument exits 2"

mode_check unknown-option --bogus
expect_rc 2 "an unknown option exits 2"
expect_err "unknown option '--bogus'" "the unknown option is named back"

# A state directory outlives its invocation, so a re-run of check 1 has to
# extract OVER the previous bundle rather than inside it: a nested copy still
# looks like a valid bundle while doubling the Mach-O enumeration, which is a
# wrong answer wearing a right one's clothes.
build_scenario only-remount
only_check mount
only_check mount
expect_only_row "mounts and yields a .app bundle" pass "--only mount is repeatable in one state directory"
expect_err "3 Mach-O file(s) in the bundle" "a re-mount re-extracts rather than nesting a second bundle"
only_check paths
expect_only_row "no build-machine library paths in any Mach-O" pass \
  "the checks after a re-mount still see exactly the one bundle"

# A FAILED re-mount must not leave the previous run's state standing. The state
# directory outlives the process, so without invalidation the checks after it
# would assess a bundle THIS invocation never produced — a verdict about the
# wrong thing, delivered in green.
only_check mount STUB_BREAK=mount
expect_only_row "mounts and yields a .app bundle" FAIL "a re-mount that fails goes red"
only_check signed
expect_only_row "every Mach-O in the bundle is signed" FAIL \
  "after a failed re-mount the checks do not assess the previous run's bundle"
expect_err "mounts and yields a .app bundle" "a failed mount invalidates the state it did not produce"

# A MOUNT THAT CANNOT RECORD WHAT IT EXTRACTED. The state file is check 1's only
# output to the checks after it, so writing it is part of the check, not
# bookkeeping after it: without that, check 1 reports pass and every check after
# it goes red naming check 1 as the one that never ran — true, and useless.
build_scenario only-unwritable-state
mkdir -p "$SCEN_STATE/state.env"
only_check mount
expect_only_row "mounts and yields a .app bundle" FAIL \
  "a mount that cannot record its state does not report pass"
expect_rc nonzero "a mount that handed on nothing goes red"
expect_err "could not write" "the mount check itself says why nothing was handed on"

# A state directory path with a space in it — the bundle already has one.
build_scenario only-spaced-state
SCEN_STATE="$SCEN_DIR/state dir"
only_check mount
expect_only_row "mounts and yields a .app bundle" pass \
  "--only mount extracts into a state directory with a space in its path"
# ...and ONE directory, not the two an unquoted mkdir makes of that path. Nothing
# else can see the difference: the bundle still lands in the right place either
# way, because the next `mkdir -p` recreates the parent the split left out. The
# stray sibling is the only trace, so it is what gets asserted.
if [ ! -d "$SCEN_DIR/state" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  a state path with a space was split into two directories" >&2
fi
only_check signed
expect_only_row "every Mach-O in the bundle is signed" pass \
  "a later check reads the bundle back out of a state path with a space"
mode_check cleanup-spaced --cleanup
if [ ! -d "$SCEN_STATE" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  --cleanup did not remove a state directory whose path has a space" >&2
fi

# THE STATE FILE EXISTING IS NOT THE STATE EXISTING. Same rule one level down: a
# directory that lost its extracted copy hands a check a path to nothing, and a
# sweep over nothing is the empty scan every guard in this suite refuses.
build_scenario only-stale-state
only_check mount
rm -rf "$SCEN_STATE/Unyt Sandbox.app"
only_check signed
expect_only_row "every Mach-O in the bundle is signed" FAIL \
  "--only against a state directory whose bundle has gone"
expect_rc nonzero "a state file pointing at nothing goes red"
expect_err "mounts and yields a .app bundle" "stale state names the prerequisite rather than sweeping nothing"

# The rows the workflow collects. Nine steps append to one file, and the guard
# step compares it against --print-checks — so the file has to accumulate, in
# order, alongside the stdout row rather than instead of it.
build_scenario only-results-file
only_check mount UNYT_SMOKE_RESULTS="$SCEN_DIR/rows.txt"
only_check version UNYT_SMOKE_RESULTS="$SCEN_DIR/rows.txt"
only_check stapled STUB_BREAK=stapler UNYT_SMOKE_RESULTS="$SCEN_DIR/rows.txt"
expect_only_row "the notarization ticket is stapled" FAIL \
  "the failing invocation whose row the file must carry"
if [ "$(cat "$SCEN_DIR/rows.txt" 2>/dev/null)" = "$(printf '%s\n%s\n%s\n' \
  "mounts and yields a .app bundle|pass" \
  "the bundled app is the version the artifact claims|pass" \
  "the notarization ticket is stapled|FAIL")" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  UNYT_SMOKE_RESULTS did not carry one true row per --only invocation" >&2
  sed 's/^/      /' "$SCEN_DIR/rows.txt" 2>/dev/null >&2
fi

# --report never gates. It exists so the log carries the DMG's own assessment and
# the main binary's linkage; a report block that could turn a step red would be a
# check pretending not to be one.
build_scenario only-report
only_check mount
mode_check report --report "$SCEN_DMG"
expect_rc zero "--report exits 0"
expect_err "/usr/lib/libSystem.B.dylib" "--report lists what the main binary actually links against"
expect_target spctl "$SCEN_DMG" "--report assesses the disk image itself, which nothing else does"

build_scenario only-report-no-state
mode_check report-no-state --report "$SCEN_DMG"
expect_rc zero "--report exits 0 even with nothing extracted"
expect_err "nothing extracted in" "--report says what it could not report on rather than failing"
expect_no_err "/usr/lib/libSystem.B.dylib" \
  "--report with nothing extracted lists no linkage — the same heading, no content"

# --report is the one caller that carries on after failing to load state, so it
# is where a HALF-loaded state would show: a state file naming a bundle that is
# gone would otherwise have it list the linkage of a path to nothing — an empty
# list that reads exactly like a binary with no dependencies.
build_scenario only-report-stale-state
only_check mount
rm -rf "$SCEN_STATE/Unyt Sandbox.app"
mode_check report-stale --report "$SCEN_DMG"
expect_rc zero "--report exits 0 against a state directory whose bundle has gone"
expect_err "nothing extracted in" "--report says so rather than listing the linkage of a path to nothing"
expect_no_err "/usr/lib/libSystem.B.dylib" "a stale state directory produces no linkage list"

# --cleanup is the only thing that removes a caller's state directory: the EXIT
# trap must not, or the next step in the job would find nothing.
build_scenario only-cleanup
only_check mount
if [ -f "$SCEN_STATE/state.env" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  --only mount left no state file for the checks after it" >&2
fi
mode_check cleanup --cleanup
expect_rc zero "--cleanup exits 0"
if [ ! -d "$SCEN_STATE" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  --cleanup left the state directory behind" >&2
fi
mode_check cleanup-again --cleanup
expect_rc zero "--cleanup exits 0 with nothing to clean"

# The detach is the mode's whole reason to exist, and removing the mountpoint
# looks identical from outside — only the stub's record can see it.
build_scenario only-cleanup-detach
mkdir -p "$SCEN_STATE/mnt"
mode_check cleanup-detach --cleanup
expect_rc zero "--cleanup exits 0 with an image left attached"
expect_target hdiutil "detach" "--cleanup detaches the mount a killed run left behind"
expect_target hdiutil "$SCEN_STATE/mnt" "--cleanup detaches THAT mountpoint, derived from the state directory"
# BEFORE the directory goes, not after. The EXIT trap would detach either way, so
# ordering is the only thing the explicit detach in --cleanup buys — and getting
# it wrong means rm -rf walking into an image that is still attached.
expect_no_target hdiutil "[target-gone]" \
  "--cleanup detaches while the mountpoint is still there, then removes it"

# The exit trap, via the half that leaves a trace: TMPDIR pointed at an empty
# dir makes "the trap ran" observable.
build_scenario only-trap-cleanup
mkdir -p "$SCEN_DIR/tmp"
SCEN_STATE=""
only_check mount TMPDIR="$SCEN_DIR/tmp"
expect_only_row "mounts and yields a .app bundle" pass \
  "--only with no state directory still mounts, out of a temp directory of its own"
if [ -z "$(ls -A "$SCEN_DIR/tmp" 2>/dev/null)" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  the EXIT trap left its own work directory behind" >&2
  ls -A "$SCEN_DIR/tmp" | sed 's/^/      /' >&2
fi

# The sort guard is per process, so it must run in every mode — one that skipped
# it would report a floor comparison it cannot make, quietly permissive.
FIX_NO_SORT_V=1 build_scenario only-break-sort
only_check deployment
expect_rc nonzero "--only stops on a sort without -V instead of reporting"
expect_err "does not do version ordering" "--only diagnoses a sort without -V"
mode_check print-no-sort --print-checks
expect_rc nonzero "--print-checks stops on a sort without -V too"

# ── the harness's own isolation ───────────────────────────────────────────────
# THE BUG THIS BLOCK EXISTS FOR, which reached a release green: `break-noapp`,
# whose image holds only a README, found the previous scenario's extracted bundle
# in the shared state directory and passed all nine checks on a disk image with
# no .app in it. Named here rather than left to that one scenario, because what
# is under test is the harness giving each scenario a state directory of its own
# — not the mount check, which was correct throughout.
run_scenario isolation-good
expect_rc zero "scenario isolation: the good image before it still passes"
# The whole-run path reports through stdout and the summary table only, so the
# results file run_scenario names must stay unwritten. Pinning it is what makes
# that assignment more than decoration: a whole run that started appending rows
# would say so here, with the rows already going somewhere harmless.
if [ ! -e "$SCEN_DIR/rows.txt" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  a whole run wrote rows to a results file; only --only reports that way" >&2
  sed 's/^/      /' "$SCEN_DIR/rows.txt" >&2
fi

# The same image break-noapp uses, run straight after a scenario that extracted a
# bundle. It can only go green by seeing that bundle.
run_scenario isolation-noapp STUB_BREAK=noapp
expect_row "mounts and yields a .app bundle" FAIL \
  "a scenario cannot see the previous scenario's extracted bundle"
expect_rc nonzero "a leaked bundle cannot turn an image with no .app green"
expect_err "mounted but contains no .app" \
  "and the diagnosis is the empty image, not whatever a leak left behind"

# The --only path too, since its rows are what the workflow collects: they belong
# in the scenario's own file, never in the caller's.
build_scenario isolation-only
only_check mount
expect_only_row "mounts and yields a .app bundle" pass \
  "scenario isolation: --only mount still passes"
if [ "$(cat "$SCEN_DIR/only-rows.txt" 2>/dev/null)" = "mounts and yields a .app bundle|pass" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  --only wrote its row somewhere other than the scenario's own results file" >&2
fi

# ── nothing reached the caller ────────────────────────────────────────────────
# Every invocation in this file ran with the seeded UNYT_SMOKE_STATE and
# UNYT_SMOKE_RESULTS from the top, so these two answer for all of them at once —
# run_scenario, only_check and mode_check alike — rather than for the handful of
# calls a block of its own could make. The seeds are compared, not just looked
# for: --cleanup is an `rm -rf` of the directory it is given, so a leak that
# DELETES is as real as one that writes.
iso_left="$(find "$ISO_AMBIENT/state" -mindepth 1 2>/dev/null | sort | tr '\n' ' ')"
if [ "$iso_left" = "$ISO_AMBIENT/state/keep " ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  an invocation used the CALLER's UNYT_SMOKE_STATE directory" >&2
  printf '      %s\n' "${iso_left:-<the seeded directory is gone>}" >&2
fi
if [ "$(cat "$ISO_AMBIENT/rows.txt" 2>/dev/null)" = "seed|pass" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  an invocation wrote to the CALLER's UNYT_SMOKE_RESULTS file" >&2
  sed 's/^/      /' "$ISO_AMBIENT/rows.txt" 2>/dev/null >&2
fi

COMPLETED=1
echo "macos check regression: $pass passed, $fail failed"
# THE COUNT, not just the failures: truncate this file and it would otherwise
# report "2 passed, 0 failed" and exit 0. Counted as pass+fail so a FAILING
# assertion is reported as a failure rather than as a missing one, and compared
# EXACTLY rather than as a floor — every tool is stubbed here, so nothing is
# skipped on any machine and the total is the same everywhere. Update it when you
# add or remove a scenario; a number that no longer matches is the point.
if [ "$((pass + fail))" -ne 445 ]; then
  echo "::error::$((pass + fail)) assertions ran; expected exactly 445 — the file was truncated, a block" >&2
  echo "  was skipped, or assertions were added or removed without updating this number." >&2
  exit 1
fi
[ "$fail" -eq 0 ]
