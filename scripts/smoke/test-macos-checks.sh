#!/usr/bin/env bash
# Can every macOS check actually FAIL?
#
#   scripts/smoke/test-macos-checks.sh
#
# WHY THIS EXISTS. This suite's hard rule is that a check must be able to fail:
# nine defects in it made a check silently pass, and every one was found by
# feeding a deliberately broken input, never by reading the code. The macOS lane
# is the hardest place to honour that rule, because the repo has no Mac — so the
# checks would otherwise ship having never been observed to go either way.
#
# The answer is to run the REAL check-macos.sh end to end against a stub
# toolchain: hdiutil, otool, codesign, spctl, stapler, plutil, lipo and friends
# are shell scripts on PATH that print canned output, and a fake .app is built
# from real Mach-O magic bytes. Every scenario below breaks exactly one thing and
# requires that check — and only that check — to go red. Same reasoning as
# test-oracle.sh: it drives the real call sites, because a copy of the logic
# would pass while the real script stayed broken.
#
# ASSERT WHICH DIAGNOSIS FIRED, NOT JUST THAT THE ROW WENT RED. Several checks
# here are layered — an ad-hoc signature also lacks an Authority line, a dead
# otool trips both the per-file and the aggregate guard — so a colour-only
# assertion stays green when a guard is deleted, because a DIFFERENT guard still
# reddens the row. Mutation testing found exactly that: three guards could be
# removed without a single assertion noticing. `expect_err` is the fix; do not
# "simplify" an assertion back to checking the row alone.
#
# A MUTANT PROVES NOTHING UNTIL YOU HAVE WATCHED IT FAIL FOR THE REASON YOU
# INTENDED. The first mutation written for the universal-slice fix removed the
# wrong thing and passed clean; recorded as-is it would have certified a guard
# that was never exercised. Check the mutant's failure message, not just its
# exit status.
#
# The same method found two instructions that would each have shipped a check
# incapable of failing, and neither was reachable by reasoning about them —
# only by building the fixture meant to prove them and watching it not fail:
#   - reading only LC_BUILD_VERSION found NOTHING the moment it met a real
#     x86_64 binary, which is half the artifacts
#   - taking the max deployment target across slices passed a fixture written
#     expecting rejection, because a too-new x86_64 slice hides behind an arm64
#     slice legitimately at the same version
#
# WHAT THIS DOES NOT PROVE. The stubs encode what the real tools print, which for
# otool is verbatim output captured from the shipped v0.100.0 artifacts (both
# architectures), and for the signing tools is Apple's documented output, NOT
# something this repo has observed. So this proves the script's logic — every
# branch, in both directions — and cannot prove that the real spctl/stapler/
# syspolicy_check wording matches. That half is verified the first time the lane
# runs on a macOS runner.
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
# The same shape as the bugs this file exists to catch, one level up.
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

# ── the real thing, captured ──────────────────────────────────────────────────
# Verbatim `otool` output from the v0.100.0 release artifacts, which is what
# makes the fixtures worth anything. The two architectures do NOT use the same
# load command — aarch64 carries LC_BUILD_VERSION (`minos`), x86_64 the older
# LC_VERSION_MIN_MACOSX (`version`) — and a reader that knows only the modern one
# finds nothing on the x86_64 build. That is the single most important thing
# these fixtures pin.
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
  mkdir -p "$bin"

  cat >"$bin/hdiutil" <<'EOF'
#!/usr/bin/env bash
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
  # STUB_BREAK=otool_dead is the TOOL failing rather than the artifact being bad:
  # it prints its complaint to stderr (which the script's 2>/dev/null swallows)
  # and exits non-zero, which is what a stale xcode-select path actually does.
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
  -L) printf '%s:\n' "$f"; cat "$STUB_FIXTURE/otool/$b.L" 2>/dev/null ;;
  -l)
    if [ -n "$arch" ] && [ -f "$STUB_FIXTURE/otool/$b.$arch.l" ]; then
      cat "$STUB_FIXTURE/otool/$b.$arch.l"
    else
      cat "$STUB_FIXTURE/otool/$b.l" 2>/dev/null
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
target="${@: -1}"
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
if [ "${1:-}" = stapler ] && [ "${2:-}" = validate ]; then
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
  # THE REAL SHAPE OF A FAILING REPORT. syspolicy_check reports PER CHECK, so a
  # build with a fatal notarization problem still prints that its codesign check
  # passed — and the failure carries none of the words a naive fail pattern looks
  # for. A pass token matching `pass` anywhere matches the WRONG LINE here, which
  # is a green row on a build Apple's own tool calls undistributable. Vocabulary
  # from Apple's documented output (developer forums 706442).
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
# `version`/`claim`/`arch` are the knobs the scenarios turn.
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
    printf '%s\n' "$OTOOL_L_CLEAN" >"$dir/otool/$m.L"
    printf '%s\n' "$lc" >"$dir/otool/$m.l"
  done

  # A UNIVERSAL main binary: two slices, two different minimums, two different
  # floors. FIX_UNIVERSAL_X86 sets what the x86_64 slice demands — 10.13 is
  # correct, 11.0 is the bug that hides behind the arm64 slice, since the max
  # across slices is 11.0 either way.
  if [ -n "${FIX_UNIVERSAL:-}" ]; then
    mkdir -p "$dir/lipo"
    printf 'x86_64 arm64\n' >"$dir/lipo/unyt-sandbox"
    printf '%s\n' "$LC_ARM64" >"$dir/otool/unyt-sandbox.arm64.l"
    if [ "${FIX_UNIVERSAL_X86:-10.13}" = "10.13" ]; then
      printf '%s\n' "$LC_X86" >"$dir/otool/unyt-sandbox.x86_64.l"
    else
      printf 'Load command 9\n      cmd LC_VERSION_MIN_MACOSX\n  cmdsize 16\n  version %s\n      sdk 26.5\n' \
        "${FIX_UNIVERSAL_X86}" >"$dir/otool/unyt-sandbox.x86_64.l"
    fi
  fi
  : >"$dir/artifact.dmg"
}

# ── running one scenario ──────────────────────────────────────────────────────
# stdout (the summary table) is captured separately from stderr (the narration),
# so a row is read only from the table and never from a `===== name =====`
# header that happens to contain the same words.
OUT=""; RC=0; ERR=""
# The FIX_* knobs are set by the caller as prefix assignments. They are cleared
# again HERE, on the way out: bash's scoping for a prefix assignment to a
# function is subtle enough that a leaked FIX_VERSION would silently mis-build
# every scenario after it, and a fixture that is not what the assertion assumes
# is the one failure mode a test cannot report.
scenario_reset() {
  FIX_VERSION=""; FIX_CLAIM=""; FIX_FLAVOUR=""; FIX_MUTATE=""; FIX_DMG_NAME=""
  FIX_NO_MACHO=""; FIX_NO_SORT_V=""; FIX_UNIVERSAL=""; FIX_UNIVERSAL_X86=""
}
scenario_reset

run_scenario() { # <name> [env assignments...]
  local name="$1"; shift
  local dir="$ROOT/$name"
  mkdir -p "$dir"
  build_fixture "$dir" "${FIX_VERSION:-0.100.0}" "${FIX_CLAIM:-10.13}" "${FIX_FLAVOUR:-x86}"
  make_stubs "$dir/bin"
  [ -n "${FIX_MUTATE:-}" ] && "$FIX_MUTATE" "$dir"
  local dmg="$dir/${FIX_DMG_NAME:-unyt_0.100.0_Unyt.Sandbox_default-arc_x64_darwin.dmg}"
  mv "$dir/artifact.dmg" "$dmg"
  ERR="$dir/stderr.log"
  OUT="$(env "$@" \
    PATH="$dir/bin:$PATH" \
    STUB_FIXTURE="$dir" \
    bash "$SCRIPT" "$dmg" 2>"$ERR")"
  RC=$?
  scenario_reset
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
# NOTE: reads $ERR, which run_scenario re-points on every call — so an expect_err
# always refers to the MOST RECENT scenario, and moving one above its
# run_scenario silently asserts against the previous scenario's log. Kept as a
# global rather than threaded through because every call site sits directly
# under its scenario; if that stops being true, pass the log explicitly.
expect_err() { # <substring> <description>
  if grep -qF -e "$1" "$ERR"; then pass=$((pass + 1)); return; fi
  fail=$((fail + 1))
  printf 'FAIL  %-58s no "%s" in the diagnosis\n' "$2" "$1" >&2
}
expect_rc() { # <expected-nonzero|zero> <description>
  local ok=no
  case "$1" in
    zero)    [ "$RC" -eq 0 ] && ok=yes ;;
    nonzero) [ "$RC" -ne 0 ] && ok=yes ;;
  esac
  if [ "$ok" = yes ]; then pass=$((pass + 1)); return; fi
  fail=$((fail + 1))
  printf 'FAIL  %-58s exit status was %s, expected %s\n' "$2" "$RC" "$1" >&2
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

# ── 3. architecture ───────────────────────────────────────────────────────────
run_scenario break-arch STUB_BIN_ARCH=arm64 STUB_RUNNER_ARCH=x86_64
expect_row "the bundle's architecture matches the runner" FAIL \
  "an aarch64 bundle on an Intel runner"
expect_rc nonzero "a mispaired runner goes red"

# ── 4. build-machine paths ────────────────────────────────────────────────────
mutate_homebrew() {
  printf '%s\n\t/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib (compatibility version 3.0.0, current version 3.0.0)\n' \
    "$OTOOL_L_CLEAN" >"$1/otool/libunyt.dylib.L"
}
FIX_MUTATE=mutate_homebrew run_scenario break-homebrew
expect_only_failure "no build-machine library paths in any Mach-O" \
  "a bundled dylib linking against /opt/homebrew"

# The same bug wearing the other hat: an rpath baked at build time. A check that
# only reads otool -L never sees it.
mutate_rpath() {
  printf '%s\nLoad command 20\n      cmd LC_RPATH\n  cmdsize 32\n     path /usr/local/lib (offset 12)\n' \
    "$LC_X86" >"$1/otool/unyt-sandbox.l"
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

# THE ARM64 HOLE. Apple Silicon binaries are ad-hoc codesigned by DEFAULT, and an
# ad-hoc signature passes `--verify --strict` — without -R, code is checked only
# against its own designated requirement, which ad-hoc trivially satisfies. So a
# dylib the signing step missed is caught on x86_64 and invisible on arm64,
# which is half the artifacts. The stub verifies it happily; only `-dv` tells.
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
# Fail must be broad and win; pass must be the one documented whole sentence.
run_scenario break-syspolicy-mixed STUB_BREAK=syspolicy_mixed
expect_only_failure "passes Apple's own distribution assessment" \
  "a per-check 'passed' inside a FATAL report is not a pass"
expect_err "not ready for distribution" "the failure block decides, not the passing line"

run_scenario break-syspolicy-counted STUB_BREAK=syspolicy_mixed_count
expect_only_failure "passes Apple's own distribution assessment" \
  "'2 of 3 checks passed' plus a missing ticket is not a pass"

# ISOLATES THE PASS TOKEN. The two scenarios above are caught by the widened
# FAIL pattern, so they say nothing about how narrow the pass pattern is — a
# report with a per-check "passed" and no failure vocabulary at all is the only
# input that can tell the two apart. Only the documented whole sentence is a
# pass; a partial report is "cannot tell", which is not green.
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

# The zero-count ON THE SAME LINE as the failure. A filter that drops any line
# containing one discards this whole, and the row then lands on cannot-tell —
# red, but for the wrong reason and only by luck of the pass check reading the
# unfiltered output. Pinned to the failure branch so the filter cannot quietly
# widen into eating findings.
run_scenario break-syspolicy-fatal-same-line STUB_BREAK=syspolicy_fatal_same_line
expect_only_failure "passes Apple's own distribution assessment" \
  "a failure carrying its own zero-count on one line"
expect_err "not ready for distribution" "the failure is read, not filtered away with the count"

# ── 9. deployment target ──────────────────────────────────────────────────────
# The documented real-world failure: a bundled dependency built against a newer
# deployment target than the app claims. It launches on the OS the Info.plist
# advertises and dies in dyld.
mutate_dylib_too_new() {
  printf 'Load command 8\n      cmd LC_BUILD_VERSION\n  cmdsize 32\n platform macos\n      sdk 26.5\n    minos 12.0\n   ntools 1\n     tool ld\n' \
    >"$1/otool/libunyt.dylib.l"
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
mutate_no_version_cmd() { : >"$1/otool/libunyt.dylib.l"; }
FIX_MUTATE=mutate_no_version_cmd run_scenario break-no-version
expect_row "deployment target within the supported floor" FAIL \
  "a Mach-O declaring no deployment target at all"

# ── universal binaries: one floor per slice ───────────────────────────────────
# Reading only the FIRST lipo slice judged an arm64 build against x86_64's 10.13
# floor — a false red on a build with nothing wrong with it, which costs someone
# an afternoon. We ship per-arch DMGs today, so this is future-proofing, and the
# check gets MORE valuable if universal-apple-darwin is ever shipped.
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
# The scenarios above all break the ARTIFACT. This one breaks otool itself, and
# it is a distinct hole: the artifact is perfect and genuinely links
# /opt/homebrew, but with otool silent and non-zero the sweep reads zero paths,
# finds no violations, and reports green. The guard has to sit on the population
# actually inspected — the load paths — not on the files iterated over.
mutate_homebrew_real() {
  printf '%s\n\t/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib (compatibility version 3.0.0, current version 3.0.0)\n' \
    "$OTOOL_L_CLEAN" >"$1/otool/libunyt.dylib.L"
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
# A bundle with no Mach-O in it at all — a husk, or an extraction that produced
# one. Three checks sweep "every Mach-O", and a sweep over nothing finds no
# violations, so without an explicit guard each of them reports the same green
# row as a genuinely clean bundle. This scenario is what proves the guards are
# there: mutation-testing check-macos.sh showed all three surviving removal of
# the guard until it existed.
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

COMPLETED=1
echo "macos check regression: $pass passed, $fail failed"
# A floor on the COUNT, not just on failures: truncate this file and it would
# otherwise report "2 passed, 0 failed" and exit 0. Raise it when adding
# scenarios.
if [ "$pass" -lt 282 ]; then
  echo "::error::only $pass assertions ran; expected at least 282 — the test file is truncated or a block was skipped" >&2
  exit 1
fi
[ "$fail" -eq 0 ]
