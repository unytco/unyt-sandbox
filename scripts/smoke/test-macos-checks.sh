#!/usr/bin/env bash
# Can every macOS check actually FAIL?
#
# Drives the REAL check-macos.sh against a stub toolchain on PATH; each scenario
# breaks one thing and requires that check — and only it — to go red. The repo
# has no Mac, so this is the only place these checks are observed to fail at all.
#
# ASSERT WHICH DIAGNOSIS FIRED, never just that the row went red: a check can go
# red for a reason that has nothing to do with what a scenario broke, and a
# colour-only assertion passes on every one of them. That is what `expect_err` is
# for — never simplify an assertion back to the row alone.
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

# THIS FILE'S OWN ZERO GUARD. `set -uo pipefail` has no `-e`, so a truncated file
# or an early return produces NO OUTPUT AND STATUS 0 — which reads as "every
# check is proven able to fail" while nothing was proven at all.
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

# release-smoke.yaml runs this harness with UNYT_SMOKE_STATE and
# UNYT_SMOKE_RESULTS already in the environment, which is what hid the one bug
# this harness shipped: every scenario mounted into that one shared directory,
# and a scenario found the PREVIOUS one's extracted bundle — nine green checks on
# a disk image with no .app in it. Bare, the script mints a temp directory per
# invocation, so the same file reported 435/435 locally and 433/2 in CI.
#
# Setting it HERE makes every invocation below run in the shape CI has. Seeded
# rather than left absent, because --cleanup removes the directory it is given:
# a leak can DELETE as well as write.
ISO_AMBIENT="$ROOT/caller"
mkdir -p "$ISO_AMBIENT/state"
printf 'sentinel\n' >"$ISO_AMBIENT/state/keep"
printf 'seed|pass\n' >"$ISO_AMBIENT/rows.txt"
export UNYT_SMOKE_STATE="$ISO_AMBIENT/state"
export UNYT_SMOKE_RESULTS="$ISO_AMBIENT/rows.txt"

# THE PREMISE OF THOSE GUARDS, read back through a CHILD: "nothing leaked into
# the caller's environment" is vacuously true if there is no caller's
# environment, which is what demoting the two `export`s above would produce.
iso_seen="$(bash -c 'printf "%s|%s" "${UNYT_SMOKE_STATE:-}" "${UNYT_SMOKE_RESULTS:-}"')"
if [ "$iso_seen" = "$ISO_AMBIENT/state|$ISO_AMBIENT/rows.txt" ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  the caller's smoke environment does not reach a child process: '$iso_seen'" >&2
fi

# Verbatim from the v0.100.0 artifacts. The two arches do NOT share a load
# command: aarch64 LC_BUILD_VERSION, x86_64 the older LC_VERSION_MIN_MACOSX.
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
    # A glob, not `mnt/.`: BSD cp does not treat a trailing `/.` as "the
    # contents of" the way GNU cp does. Glob matches are not word-split, so the
    # space in "Unyt Sandbox.app" is safe.
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

  # A sort WITHOUT -V: macOS ships BSD sort, and a lexicographic fallback puts
  # 9.0 above 10.13 — wrong in the direction that reads as a pass.
  if [ -n "${FIX_NO_SORT_V:-}" ]; then
    # REMOVE the flag, don't blank it: `"${@/-V/}"` leaves an EMPTY argument
    # behind, which real sort rejects — so the scenario would pass because sort
    # errored rather than because it sorted lexicographically.
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

  # `--verify` says whether the signature is intact; `-dv` says WHO signed it. An
  # ad-hoc signature answers the first perfectly and fails the second.
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
# Before STUB_BREAK, because a tool pointed at nothing cannot report on a build.
# No fail-vocabulary in the message on purpose: the non-zero status is what has
# to carry it.
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
  # and no statement that the whole assessment succeeded. With `pass` matching
  # anywhere this is green, and the fail pattern has nothing to match.
  syspolicy_partial)
    echo "Codesign check passed."
    exit 0 ;;
  # A PASSING report that mentions errors only to count zero of them. The fail
  # vocabulary is deliberately broad, so without the zero-count exclusion this
  # reds a build that is fine.
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
  # THE SAME LINE, which the two-line case above cannot test: a filter dropping
  # any line CONTAINING a zero-count discards this failure whole.
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

# Three Mach-O files — main binary, a bundled dylib, and a helper in
# Contents/Resources, the place `codesign --deep` has been observed to miss — and
# one non-Mach-O, so the enumeration has something to correctly exclude.
build_fixture() { # <dir> [version] [plist-claim] [lc-flavour]
  local dir="$1" version="${2:-0.100.0}" claim="${3:-10.13}" flavour="${4:-x86}"
  local app="$dir/mnt/Unyt Sandbox.app" lc
  case "$flavour" in
    arm64) lc="$LC_ARM64" ;;
    *)     lc="$LC_X86" ;;
  esac
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks" "$dir/otool"

  # Real Mach-O magic (0xfeedfacf little-endian), because is_macho() reads bytes.
  # FIX_NO_MACHO writes plain scripts instead, producing a bundle the scans find
  # NOTHING in.
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

  # A UNIVERSAL main binary: two slices, two floors. FIX_UNIVERSAL_X86 sets what
  # the x86_64 slice demands — 10.13 is correct, 11.0 is the bug that hides
  # behind the arm64 slice, since the max across slices is 11.0 either way.
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
# invocations, so building and running can no longer be one step.
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

# THE ENVIRONMENT EVERY INVOCATION RUNS UNDER, in one place: an invoker missing
# one variable is enough to share a mountpoint between scenarios. NOTHING THE
# SCRIPT OR ITS STUBS READ IS INHERITED, so a scenario reads and writes only its
# own directory. Call-site assignments are applied after these.
scen_env() { # <results file>
  SCEN_ENV=(
    PATH="$SCEN_DIR/bin:$PATH"
    STUB_FIXTURE="$SCEN_DIR"
    UNYT_SMOKE_STATE="$SCEN_STATE"
    UNYT_SMOKE_RESULTS="$1"
    # Emptied rather than left alone: an exported STUB_BREAK in the caller's shell
    # would otherwise break every scenario at once. Empty is as good as unset —
    # every consumer reads them as ${VAR:-default}.
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

# ONE state directory shared across calls, which is itself under test: on the
# split path what check 1 extracts reaches check 9 through UNYT_SMOKE_STATE
# rather than through a variable.
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

row() { printf '%s\n' "$OUT" | grep -F "$1" | tail -1 | awk '{print $NF}'; }

expect_row() { # <check substring> <pass|FAIL> <description>
  local got; got="$(row "$1")"
  if [ "$got" = "$2" ]; then pass=$((pass + 1)); return; fi
  fail=$((fail + 1))
  printf 'FAIL  %-58s expected %s, got %s\n' "$3" "$2" "${got:-<no row>}" >&2
  note "summary was:"; printf '%s\n' "$OUT" | sed 's/^/      /' >&2
}
# Which DIAGNOSIS the run produced. Where several guards can reject the same
# fixture, the row alone stays red when one is deleted.
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
# The other direction, for output whose ABSENCE is the property: a header printed
# unconditionally cannot tell a report that listed something from one that did
# not.
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
# The WHOLE of stdout, which on the --only path is exactly one row — so a step
# that printed a summary table, a second row, or nothing at all fails here even
# when its verdict was right.
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
# The ids --only takes, in the same order and pairing as CHECKS above — which is
# what --print-checks declares to the workflow.
CHECK_IDS=(mount version arch paths signed gatekeeper stapled syspolicy deployment)
# Every check EXCEPT the named one must still pass: two red rows means the
# breakage leaked.
expect_only_failure() { # <check substring> <description>
  local c
  for c in "${CHECKS[@]}"; do
    if [ "$c" = "$1" ]; then expect_row "$c" FAIL "$2"; else
      expect_row "$c" pass "$2 (collateral: $c)"; fi
  done
  expect_rc nonzero "$2 (the run goes red)"
}

# Without this every scenario below could be "red because everything is red".
FIX_MUTATE="" run_scenario baseline-x86
for c in "${CHECKS[@]}"; do expect_row "$c" pass "baseline x86_64: $c"; done
expect_rc zero "baseline x86_64 exits 0"

# The arm64 build: LC_BUILD_VERSION minos 11.0 against an Info.plist claiming
# 10.13. Measured on the real artifact, and NOT a failure — arm64 macOS starts at
# 11.0, so the claim is unreachable there.
FIX_FLAVOUR=arm64 run_scenario baseline-arm64 STUB_BIN_ARCH=arm64 STUB_RUNNER_ARCH=arm64
expect_row "deployment target within the supported floor" pass \
  "arm64: minos 11.0 under a 10.13 claim is not a violation"
expect_rc zero "baseline arm64 exits 0"

run_scenario break-mount STUB_BREAK=mount
expect_row "mounts and yields a .app bundle" FAIL "a disk image that will not mount"
expect_rc nonzero "an unmountable image goes red"
# hdiutil's own words, which -quiet used to swallow.
expect_err "no mountable file systems" "hdiutil's diagnosis reaches the log"

# A licence-agreement image waits for a keypress, so the mount is bounded.
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

FIX_VERSION=0.99.0 run_scenario break-version
expect_only_failure "the bundled app is the version the artifact claims" \
  "a DMG named 0.100.0 packaging 0.99.0"

FIX_DMG_NAME=handbuilt.dmg run_scenario break-unnamed
expect_row "the bundled app is the version the artifact claims" FAIL \
  "an artifact whose name carries no version"

# THE PRE-RELEASE CHANNEL: read only as far as the `-`, a -dev DMG carries no
# readable version and this check reds on every artifact of every -dev release.
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

run_scenario break-arch STUB_BIN_ARCH=arm64 STUB_RUNNER_ARCH=x86_64
expect_row "the bundle's architecture matches the runner" FAIL \
  "an aarch64 bundle on an Intel runner"
expect_rc nonzero "a mispaired runner goes red"

mutate_homebrew() {
  printf '%s\n\t/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib (compatibility version 3.0.0, current version 3.0.0)\n' \
    "$OTOOL_L_CLEAN" >"$1/otool/libunyt.dylib.deps"
}
FIX_MUTATE=mutate_homebrew run_scenario break-homebrew
expect_only_failure "no build-machine library paths in any Mach-O" \
  "a bundled dylib linking against /opt/homebrew"

# The same bug in an rpath baked at build time, which `otool -L` alone misses.
mutate_rpath() {
  printf '%s\nLoad command 20\n      cmd LC_RPATH\n  cmdsize 32\n     path /usr/local/lib (offset 12)\n' \
    "$LC_X86" >"$1/otool/unyt-sandbox.loadcmds"
}
FIX_MUTATE=mutate_rpath run_scenario break-rpath
expect_only_failure "no build-machine library paths in any Mach-O" \
  "an LC_RPATH pointing at /usr/local"

# The documented blind spot: an unsigned binary in Contents/Resources, which
# `codesign --deep` has been observed to walk straight past.
run_scenario break-unsigned STUB_BREAK=unsigned
expect_only_failure "every Mach-O in the bundle is signed" \
  "an unsigned helper in Contents/Resources"

# Apple Silicon binaries are ad-hoc signed by default and pass `--verify
# --strict`, so a missed dylib is invisible there. Only `-dv` tells.
run_scenario break-adhoc STUB_BREAK=adhoc
expect_only_failure "every Mach-O in the bundle is signed" \
  "an ad-hoc signed dylib that VERIFIES but no Developer ID signed"
# WHICH guard fired: an ad-hoc signature also lacks an Authority line, so
# deleting the ad-hoc guard leaves the row red for a different reason. Mutation
# testing showed exactly that.
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

# The UNYT_EXPECTED_TEAM_ID pin, inert as shipped since the constant is empty.
# Both directions: the right team must not fire, the wrong one must.
run_scenario team-pin-matches UNYT_EXPECTED_TEAM_ID=ABCDE12345
expect_row "every Mach-O in the bundle is signed" pass \
  "a matching team pin does not false-red"
expect_rc zero "a matching team pin leaves the run green"

run_scenario break-team-mismatch UNYT_EXPECTED_TEAM_ID=ZZZZZ99999
expect_only_failure "every Mach-O in the bundle is signed" \
  "a bundle signed by a team other than the pinned one"
expect_err "expected ZZZZZ99999" "the mismatch names both teams"

run_scenario break-gk STUB_BREAK=gatekeeper_rejected
expect_only_failure "Gatekeeper accepts it as notarized software" \
  "an app Gatekeeper rejects outright"

# `accepted`, but not as notarized software: spctl's exit status alone calls this
# a pass, and the download then fails on a user's Mac, where quarantine makes
# notarization mandatory.
run_scenario break-gk-source STUB_BREAK=gatekeeper_unnotarized
expect_only_failure "Gatekeeper accepts it as notarized software" \
  "accepted, but NOT as notarized Developer ID"
expect_err "NOT as notarized Developer ID" "the source line is what rejects it"

# spctl exiting 0 without ever saying "accepted": the assessment did not happen,
# and that must not read the same as one that passed.
run_scenario break-gk-silent STUB_BREAK=gatekeeper_silent
expect_only_failure "Gatekeeper accepts it as notarized software" \
  "spctl exits 0 without accepting anything"
expect_err "without accepting the app" "the missing verdict is diagnosed as such"

run_scenario break-staple STUB_BREAK=stapler
expect_only_failure "the notarization ticket is stapled" \
  "a notarized build with no stapled ticket"

run_scenario break-syspolicy STUB_BREAK=syspolicy
expect_only_failure "passes Apple's own distribution assessment" \
  "Apple's assessment saying it is not distributable"

run_scenario break-syspolicy-usage STUB_BREAK=syspolicy_usage
expect_row "passes Apple's own distribution assessment" FAIL \
  "a usage error is a failure, not a pass"
if grep -q 'rejected the INVOCATION' "$ERR"; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  a usage error was not reported as an invocation problem" >&2; fi

mutate_no_syspolicy() { rm -f "$1/bin/syspolicy_check"; }
FIX_MUTATE=mutate_no_syspolicy run_scenario break-syspolicy-missing
expect_row "passes Apple's own distribution assessment" FAIL \
  "a missing syspolicy_check fails closed"

# Apple documents NO exit status for syspolicy_check, so gating on exit 0 alone
# rests on an assumption. These two scenarios ARE that assumption being wrong, in
# both directions.
run_scenario break-syspolicy-zero STUB_BREAK=syspolicy_zero_but_failed
expect_only_failure "passes Apple's own distribution assessment" \
  "exit 0 while SAYING it failed must not be a pass"
# Pinned to the failure branch: the unknown-wording branch would also turn this
# red, hiding the loss of the failure-marker read.
expect_err "not ready for distribution" "the output, not the exit status, is what rejects it"

run_scenario break-syspolicy-unknown STUB_BREAK=syspolicy_unknown
expect_only_failure "passes Apple's own distribution assessment" \
  "exit 0 with unrecognised wording is 'cannot tell', not 'fine'"

# THE MIXED REPORT that made this check green on an undistributable build:
# syspolicy_check reports per check, so a fatal notarization problem sits in the
# same output as "Codesign check passed.".
run_scenario break-syspolicy-mixed STUB_BREAK=syspolicy_mixed
expect_only_failure "passes Apple's own distribution assessment" \
  "a per-check 'passed' inside a FATAL report is not a pass"
expect_err "not ready for distribution" "the failure block decides, not the passing line"

run_scenario break-syspolicy-counted STUB_BREAK=syspolicy_mixed_count
expect_only_failure "passes Apple's own distribution assessment" \
  "'2 of 3 checks passed' plus a missing ticket is not a pass"

# Isolates the PASS token: the scenarios above all trip the fail pattern.
run_scenario break-syspolicy-partial STUB_BREAK=syspolicy_partial
expect_only_failure "passes Apple's own distribution assessment" \
  "a lone per-check 'passed' is not a distribution verdict"
expect_err "matched no known pass or fail wording" "a partial report is reported as unreadable"

# The bound on a broad fail vocabulary: a passing report that counts ZERO errors
# must not be red, while zero-counts beside a real failure must not smuggle it
# past.
run_scenario syspolicy-verbose-pass STUB_BREAK=syspolicy_verbose_pass
expect_row "passes Apple's own distribution assessment" pass \
  "'0 errors, 0 warnings' in a passing report is not a failure"
expect_rc zero "a verbose passing report leaves the run green"

run_scenario break-syspolicy-zero-and-fatal STUB_BREAK=syspolicy_zero_and_fatal
expect_only_failure "passes Apple's own distribution assessment" \
  "dropping the zero-count lines must not drop the real failure with them"
# WHICH branch: the failure one. An over-greedy exclusion that ate the finding
# along with the counts still reds this row, via "cannot tell".
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

# A bundled dependency built against a newer deployment target than the app
# claims: it launches on the OS the Info.plist advertises and dies in dyld.
mutate_dylib_too_new() {
  printf 'Load command 8\n      cmd LC_BUILD_VERSION\n  cmdsize 32\n platform macos\n      sdk 26.5\n    minos 12.0\n   ntools 1\n     tool ld\n' \
    >"$1/otool/libunyt.dylib.loadcmds"
}
FIX_MUTATE=mutate_dylib_too_new run_scenario break-deployment
expect_only_failure "deployment target within the supported floor" \
  "a bundled dylib requiring macOS 12.0"

FIX_FLAVOUR=arm64 FIX_MUTATE=mutate_dylib_too_new run_scenario break-deployment-arm \
  STUB_BIN_ARCH=arm64 STUB_RUNNER_ARCH=arm64
expect_row "deployment target within the supported floor" FAIL \
  "arm64: a dylib at 12.0 still exceeds the 11.0 floor"

FIX_CLAIM=12.0 run_scenario break-claim
expect_row "deployment target within the supported floor" FAIL \
  "a bundle claiming macOS 12.0 against a 10.13 support floor"

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
# x86_64 slice raised to 11.0 hides behind the arm64 slice, since the maximum is
# 11.0 either way.
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

# Every floor comparison runs through `sort -V`, so a sort without it makes them
# all quietly permissive. The script must refuse to report at all.
FIX_NO_SORT_V=1 run_scenario break-sort
expect_rc nonzero "a sort without -V stops the run instead of reporting"
if grep -q 'does not do version ordering' "$ERR"; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL  a sort without -V was not diagnosed" >&2; fi

# ── the TOOL failing, not the artifact ────────────────────────────────────────
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
# header line, which is why the guard counts paths rather than reading status.
FIX_MUTATE=mutate_homebrew_real run_scenario break-otool-header-only STUB_BREAK=otool_header_only
expect_row "no build-machine library paths in any Mach-O" FAIL \
  "otool exits 0 having printed no dependencies at all"
expect_err "read no load paths" "a header-only otool is caught by the path count, not its status"

# ── an empty scan is not a clean scan ─────────────────────────────────────────
FIX_NO_MACHO=1 run_scenario break-no-macho
expect_row "no build-machine library paths in any Mach-O" FAIL \
  "no Mach-O to scan: the path sweep must not report clean"
expect_row "every Mach-O in the bundle is signed" FAIL \
  "no Mach-O to verify: the signature sweep must not report clean"
expect_row "deployment target within the supported floor" FAIL \
  "no Mach-O to read: the deployment sweep must not report clean"
expect_rc nonzero "a bundle with no Mach-O goes red"
# Which guard: the no-files one, not the per-file path count, which cannot fire
# when the loop never runs.
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

# CI runs each check as its own step, so each is a separate PROCESS reading
# check 1's output off disk — a new way to stop being able to fail.

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

# --print-checks IS the contract between this script and the workflow, so it is
# asserted whole — ids and names, paired, in run order. A list that lost an entry
# would give the workflow eight steps and no way to know a check went missing.
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

# EACH CHECK, BROKEN, ALONE IN ITS PROCESS: a check leaning on state a
# predecessor left in a variable goes quiet here, and quiet is green.
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

build_scenario only-no-mount
i=0
for id in "${CHECK_IDS[@]}"; do
  name="${CHECKS[$i]}"
  i=$((i + 1))
  [ "$id" = mount ] && continue
  only_check "$id"
  expect_only_row "$name" FAIL "--only $id with no mount in the state directory FAILs"
  # EXACTLY 1, the FAILED-check code: this is the one place the two nonzero codes
  # are genuinely confusable, since a missing prerequisite looks like a wrong
  # call.
  expect_rc 1 "--only $id with no mount exits 1: a FAILED check, not a wrong invocation"
  expect_err "mounts and yields a .app bundle" "--only $id names the prerequisite it is missing"
done

# An id nobody runs must be an ERROR, not a silent no-op: a workflow stepping
# through a mistyped id would otherwise show a green step for a check that never
# happened.
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

# EVERY invocation error, on the exact code: a caller that cannot tell 2 from 1
# debugs the artifact when the call was wrong.
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

# A state directory outlives its invocation, so a re-run of check 1 extracts OVER
# the previous bundle rather than inside it: a nested copy still looks like a
# valid bundle while doubling the Mach-O enumeration.
build_scenario only-remount
only_check mount
only_check mount
expect_only_row "mounts and yields a .app bundle" pass "--only mount is repeatable in one state directory"
expect_err "3 Mach-O file(s) in the bundle" "a re-mount re-extracts rather than nesting a second bundle"
only_check paths
expect_only_row "no build-machine library paths in any Mach-O" pass \
  "the checks after a re-mount still see exactly the one bundle"

# A FAILED re-mount must not leave the previous run's state standing: the checks
# after it would assess a bundle THIS invocation never produced.
only_check mount STUB_BREAK=mount
expect_only_row "mounts and yields a .app bundle" FAIL "a re-mount that fails goes red"
only_check signed
expect_only_row "every Mach-O in the bundle is signed" FAIL \
  "after a failed re-mount the checks do not assess the previous run's bundle"
expect_err "mounts and yields a .app bundle" "a failed mount invalidates the state it did not produce"

# A MOUNT THAT CANNOT RECORD WHAT IT EXTRACTED. The state file is check 1's only
# output to the checks after it, so writing it is part of the check: otherwise
# check 1 passes and every check after it reds naming check 1 as never having
# run.
build_scenario only-unwritable-state
mkdir -p "$SCEN_STATE/state.env"
only_check mount
expect_only_row "mounts and yields a .app bundle" FAIL \
  "a mount that cannot record its state does not report pass"
expect_rc nonzero "a mount that handed on nothing goes red"
expect_err "could not write" "the mount check itself says why nothing was handed on"

build_scenario only-spaced-state
SCEN_STATE="$SCEN_DIR/state dir"
only_check mount
expect_only_row "mounts and yields a .app bundle" pass \
  "--only mount extracts into a state directory with a space in its path"
# ...and ONE directory, not the two an unquoted mkdir makes of that path. The
# bundle lands in the right place either way, since the next `mkdir -p` recreates
# the parent — so the stray sibling is the only trace.
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

# THE STATE FILE EXISTING IS NOT THE STATE EXISTING: a directory that lost its
# extracted copy hands a check a path to nothing.
build_scenario only-stale-state
only_check mount
rm -rf "$SCEN_STATE/Unyt Sandbox.app"
only_check signed
expect_only_row "every Mach-O in the bundle is signed" FAIL \
  "--only against a state directory whose bundle has gone"
expect_rc nonzero "a state file pointing at nothing goes red"
expect_err "mounts and yields a .app bundle" "stale state names the prerequisite rather than sweeping nothing"

# Nine steps append to one file, and the guard step compares it against
# --print-checks — so it accumulates in order, alongside the stdout row.
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

# --report never gates: a report block that could turn a step red would be a
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

# --report is the one caller that carries on after failing to load state, so a
# state file naming a bundle that is gone would have it list the linkage of a
# path to nothing — an empty list that reads like a binary with no dependencies.
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
# BEFORE the directory goes: the EXIT trap would detach either way, so ordering
# is the only thing the explicit detach buys.
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

# The sort guard is per process, so it must run in every mode.
FIX_NO_SORT_V=1 build_scenario only-break-sort
only_check deployment
expect_rc nonzero "--only stops on a sort without -V instead of reporting"
expect_err "does not do version ordering" "--only diagnoses a sort without -V"
mode_check print-no-sort --print-checks
expect_rc nonzero "--print-checks stops on a sort without -V too"

# THE BUG THIS BLOCK EXISTS FOR, which reached a release green: `break-noapp`,
# whose image holds only a README, found the previous scenario's extracted bundle
# in the shared state directory and passed all nine checks. What is under test is
# the harness giving each scenario a state directory of its own, not the mount
# check, which was correct throughout.
run_scenario isolation-good
expect_rc zero "scenario isolation: the good image before it still passes"
# The whole-run path reports through stdout and the summary table only, so the
# results file run_scenario names must stay unwritten.
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

# Every invocation in this file ran with the seeded UNYT_SMOKE_STATE and
# UNYT_SMOKE_RESULTS from the top, so these two answer for all of them at once.
# The seeds are COMPARED, not just looked for: --cleanup is an `rm -rf` of the
# directory it is given, so a leak that deletes is as real as one that writes.
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
# assertion reads as a failure rather than a missing one, and compared EXACTLY
# rather than as a floor — every tool is stubbed, so nothing is skipped on any
# machine. Update it when you add or remove a scenario.
if [ "$((pass + fail))" -ne 445 ]; then
  echo "::error::$((pass + fail)) assertions ran; expected exactly 445 — the file was truncated, a block" >&2
  echo "  was skipped, or assertions were added or removed without updating this number." >&2
  exit 1
fi
[ "$fail" -eq 0 ]
