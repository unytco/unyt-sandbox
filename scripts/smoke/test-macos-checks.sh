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
trap 'rm -rf "$ROOT"' EXIT INT TERM

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
mode="$1"; shift
f="$1"
case "$mode" in
  -L) printf '%s:\n' "$f"; cat "$STUB_FIXTURE/otool/$(basename "$f").L" 2>/dev/null ;;
  -l) cat "$STUB_FIXTURE/otool/$(basename "$f").l" 2>/dev/null ;;
esac
exit 0
EOF

  cat >"$bin/lipo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${STUB_BIN_ARCH:-x86_64}"
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
    cat >"$bin/sort" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/sort "${@/-V/}"
EOF
  fi

  cat >"$bin/sw_vers" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -productName) echo macOS ;;
  -productVersion) echo 15.3 ;;
esac
EOF

  cat >"$bin/codesign" <<'EOF'
#!/usr/bin/env bash
f="${@: -1}"
if [ "${STUB_BREAK:-}" = unsigned ] && [ "$(basename "$f")" = "helper" ]; then
  echo "$f: code object is not signed at all" >&2
  exit 1
fi
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
  FIX_NO_MACHO=""; FIX_NO_SORT_V=""
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

# The enumeration must exclude the non-Mach-O and include all three Mach-Os —
# a scan that quietly covered one file would make several checks meaningless.
if grep -q '3 Mach-O file(s) in the bundle' "$ROOT/baseline-x86/stderr.log"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  the bundle scan did not find exactly the 3 Mach-O files" >&2
  grep 'Mach-O file' "$ROOT/baseline-x86/stderr.log" >&2 || true
fi

echo "macos check regression: $pass passed, $fail failed"
# A floor on the COUNT, not just on failures: truncate this file and it would
# otherwise report "2 passed, 0 failed" and exit 0. Raise it when adding
# scenarios.
if [ "$pass" -lt 125 ]; then
  echo "::error::only $pass assertions ran; expected at least 125 — the test file is truncated or a block was skipped" >&2
  exit 1
fi
[ "$fail" -eq 0 ]
