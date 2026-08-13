#!/usr/bin/env bash
# Does the macOS build a release shipped actually run on an ordinary user's Mac?
#
#   check-macos.sh <artifact.dmg>
#
# STATIC CHECKS ONLY, and that is a decision rather than a gap. This suite asks
# "will this build work on a user's machine", so scaffolding may change the app's
# SURROUNDINGS but never the artifact or its dependency set — and on macOS every
# dynamic option breaks that rule or does not exist: tauri-driver has no macOS
# support at all, and Apple's EULA caps virtualization at two VMs per physical
# Mac, so there is no pristine-VM equivalent of the Linux lane's containers.
# A WebDriver UI test was built for this and deliberately discarded. Do not
# retry either; what remains is what the artifact itself declares, and that is
# where macOS's real shipping failures live:
#
#   - Gatekeeper refuses an unsigned, unnotarized or unstapled build outright,
#     and the user sees "damaged and can't be opened", not a signing error.
#   - A link against a library that exists only on the BUILD machine
#     (/opt/homebrew, /usr/local) resolves there and nowhere else.
#   - A deployment target ABOVE what the bundle claims to support: the app
#     launches on the OS its Info.plist advertises and dies in dyld.
#
# THIS IS A SEPARATE LANE from the Linux one on purpose: macOS has no equivalent
# of dpkg's dependency metadata, so there is nothing to diff and it needs its own
# answer rather than a matrix row.
#
# ARCH MUST MATCH THE RUNNER. An aarch64 build cannot be assessed on an Intel
# runner (Gatekeeper and dyld both refuse it), so the caller pairs each DMG with
# its own runner and check 3 below proves the pairing rather than assuming it.
#
# The Linux lane's shape carries over: one `check|result` row per check, a
# summary table, and a hard rule that every check must be ABLE to fail —
# test-macos-checks.sh proves that by driving this script end to end against
# stubbed tools, feeding each check a deliberately broken input and requiring it
# to go red. Nine defects in this suite made a check silently pass, and all nine
# were found that way rather than by reading the code.
#
# Every check below is invoked BY NAME through run_check (and cleanup through a
# trap), which shellcheck cannot see, so it reports each one as dead code. The
# directive has to precede the first command to apply to the whole file.
# shellcheck disable=SC2329
set -uo pipefail

DMG="${1:?usage: check-macos.sh <artifact.dmg>}"
[ -f "$DMG" ] || { echo "::error::artifact not found: $DMG" >&2; exit 1; }

# ── the support floor ─────────────────────────────────────────────────────────
# The analogue of common.sh's UNYT_OLDEST_GLIBC, and the same contract: a shipped
# binary may not require MORE than the oldest OS we promise to run on. 10.13 is
# what release-tauri-app.yaml sets as MACOSX_DEPLOYMENT_TARGET and what the app's
# Info.plist claims as LSMinimumSystemVersion — one number, asserted here against
# what the Mach-O load commands actually say.
UNYT_OLDEST_MACOS="10.13"

# arm64 macOS did not exist before Big Sur, so EVERY arm64 binary reports at
# least 11.0 and the 10.13 floor above is unreachable there. Measured, not
# assumed: v0.100.0's aarch64 binary reports minos 11.0 while its Info.plist
# claims 10.13, and treating that as a violation would paint the arm64 lane red
# for a build with nothing wrong with it. The effective floor is therefore the
# HIGHER of the two, per architecture — which keeps the check sharp on arm64
# (a bundled dylib built at 11.3 still fails) instead of disabling it.
UNYT_ARM64_MIN_MACOS="11.0"

# Prefixes that exist on a developer's Mac and on no user's. Homebrew's two
# prefixes (Intel /usr/local, Apple-silicon /opt/homebrew) plus MacPorts.
UNYT_BUILD_MACHINE_PREFIXES='/usr/local/ /opt/homebrew/ /opt/local/'

results=()
record() { results+=("$1|$2"); }
run_check() {
  local name="$1"; shift
  echo "" >&2
  echo "===== $name =====" >&2
  if "$@"; then record "$name" pass; else record "$name" FAIL; fi
}

# One summary, printed from BOTH exit paths. An early abort that printed rows in
# some other shape would be invisible to whatever reads the log — and an aborted
# run is exactly when the reader needs to see the rows.
print_summary_and_exit() {
  local row name result overall=0 label
  label="macos-$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)/$(uname -m)"
  echo ""
  echo "############################################################"
  echo "# summary"
  echo "############################################################"
  printf '%-18s %-52s %s\n' "IMAGE" "CHECK" "RESULT"
  for row in "${results[@]}"; do
    IFS='|' read -r name result <<<"$row"
    printf '%-18s %-52s %s\n' "$label" "$name" "$result"
    [ "$result" = pass ] || overall=1
  done
  [ "$overall" -eq 0 ] && echo "" && echo "All checks passed."
  exit "$overall"
}

# ── helpers ───────────────────────────────────────────────────────────────────

# Highest of two dotted versions, `sort -V` being the same comparison
# check-binary-compat.sh uses for glibc. 10.13 < 11.0 < 26.5 all sort correctly.
version_max() { printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1; }

# ...but PROVE that this sort has -V before depending on it. macOS ships BSD
# sort, not GNU, and a sort without version ordering falls back to a
# lexicographic one that puts 9.0 above 10.13 — every floor comparison below
# would then be wrong, and wrong in the permissive direction, which is the one
# that reads as a pass.
if [ "$(printf '10.13\n9.0\n' | sort -V 2>/dev/null | tail -1)" != "10.13" ]; then
  echo "::error::this sort does not do version ordering (-V), so no deployment-target" >&2
  echo "  comparison here can be trusted. Refusing to report checks that cannot be right." >&2
  exit 1
fi
# "$1 is within (<=) the floor $2"
version_within() { [ "$(version_max "$1" "$2")" = "$2" ]; }

# Mach-O by MAGIC BYTES, not by `file`'s wording: the phrasing differs between
# macOS's file(1) and every other implementation, so a grep of it is a check that
# quietly matches nothing on the wrong host — and this script is deliberately
# runnable off a Mac for its own regression test.
# No `--` before the path: BSD od's option handling is not GNU's, and the paths
# here are always absolute, so there is nothing for it to guard against.
is_macho() {
  case "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" in
    cffaedfe|cefaedfe|feedface|feedfacf|cafebabe|cafebabf) return 0 ;;
    *) return 1 ;;
  esac
}

# EVERY Mach-O in the bundle, not just Contents/MacOS. A bundled dependency
# carrying a different deployment target than the app claims, or linking against
# the build machine's Homebrew, is a documented real-world failure and lives in
# Contents/Frameworks or Contents/Resources — exactly where `codesign --deep` has
# been observed to miss an unsigned binary. Written to a file rather than piped
# so the callers cannot lose the loop's exit status (see check-appimage.sh's N1).
MACHOS=""
find_machos() {
  MACHOS="$WORK/machos.list"
  : >"$MACHOS"
  # `IFS= read -r`, and every expansion quoted: the bundle is "Unyt Sandbox.app",
  # so a path with a space is the normal case here, not an edge case.
  while IFS= read -r f; do
    is_macho "$f" && printf '%s\n' "$f" >>"$MACHOS"
  done < <(find "$APP" -type f -print)
  return 0
}

# The macOS floor a single Mach-O demands. TWO load commands, because the two
# architectures we ship do not use the same one: v0.100.0's aarch64 binary
# carries LC_BUILD_VERSION (`minos 11.0`) and its x86_64 twin carries the older
# LC_VERSION_MIN_MACOSX (`version 10.13`). Reading only LC_BUILD_VERSION — the
# obvious modern choice — finds NOTHING on the x86_64 build, and "nothing found"
# must never read as "no requirement", so the caller fails closed on an empty
# result. Both shapes verified against the real v0.100.0 artifacts.
macho_min_os() {
  otool -l "$1" 2>/dev/null | awk '
    $1 == "cmd" && ($2 == "LC_BUILD_VERSION" || $2 == "LC_VERSION_MIN_MACOSX") { c = $2; next }
    c == "LC_BUILD_VERSION"     && $1 == "minos"   { print $2; c = "" }
    c == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print $2; c = "" }
  ' | sort -V | tail -1
}

# The libraries a Mach-O records as dependencies.
#
# RETURNS NON-ZERO WHEN IT READ NOTHING, and that distinction is the whole point:
# every Mach-O links at least libSystem, so an empty result is ALWAYS a broken
# tool and NEVER a clean binary. `2>/dev/null` hides otool's own diagnosis — a
# stale `xcode-select` path makes the xcrun shim print to stderr and exit
# non-zero — so without this the scan below would sweep zero paths, find no
# violations, and report the same green row as a genuinely clean bundle.
macho_dep_paths() {
  local out
  # Skip otool -L's header (the file's own path, unindented) — only the
  # tab-indented dependency lines are what the binary will actually load.
  out="$(otool -L "$1" 2>/dev/null | awk '/^[[:space:]]/ { print $1 }')"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# The runtime search paths baked into it. An rpath pointing at /opt/homebrew is
# the same bug as a direct link against it — check-binary-compat.sh flags the ELF
# equivalent for the same reason. LEGITIMATELY EMPTY, unlike the dependencies
# above: most binaries carry no LC_RPATH at all, so this one gets no floor.
macho_rpaths() {
  otool -l "$1" 2>/dev/null | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { r = 1; next }
    r && $1 == "path" { print $2; r = 0 }
  '
}

# Both, for the report at the end. Callers that GATE use the two separately, so
# they can tell "read nothing" from "found nothing".
macho_load_paths() {
  macho_dep_paths "$1" || true
  macho_rpaths "$1"
}

# ── 1. mount, extract, detach ─────────────────────────────────────────────────
# Everything else runs against the COPY, so a silent failure here would leave
# every check below assessing an empty directory. Each step is therefore checked
# on its own, and the extracted bundle has to look like an app before we go on.
WORK="$(mktemp -d)"
MOUNT=""
APP=""
# shellcheck disable=SC2317  # invoked through the EXIT trap
cleanup() {
  if [ -n "$MOUNT" ]; then
    hdiutil detach -quiet "$MOUNT" 2>/dev/null ||
      hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true
  fi
  # Only ever the directory mktemp just handed us.
  case "$WORK" in
    /*/*) rm -rf "$WORK" ;;
  esac
}
trap cleanup EXIT INT TERM

echo "===== runner =====" >&2
echo "  $(sw_vers -productName 2>/dev/null || echo macOS) $(sw_vers -productVersion 2>/dev/null || echo '?') on $(uname -m)" >&2
echo "  artifact: $(basename "$DMG")" >&2

echo "" >&2
echo "===== mount and extract =====" >&2
mnt="$WORK/mnt"
mkdir -p "$mnt"
mount_ok=1
# An explicit -mountpoint, rather than parsing hdiutil's tab-separated plist-ish
# output for where it landed: one less thing to misparse, and it keeps the mount
# inside the directory the trap already cleans up.
if ! hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mnt" "$DMG" >&2; then
  echo "::error::hdiutil could not mount $(basename "$DMG") — the disk image is unreadable" >&2
  mount_ok=""
else
  MOUNT="$mnt"
  app_src="$(find "$mnt" -maxdepth 1 -name '*.app' -print | head -1)"
  if [ -z "$app_src" ]; then
    echo "::error::the disk image mounted but contains no .app:" >&2
    ls -la "$mnt" >&2
    mount_ok=""
  else
    APP="$WORK/$(basename "$app_src")"
    # `ditto`, not `cp -R`: it is the documented way to copy a bundle and it
    # preserves the extended attributes and symlinks a code signature is
    # computed over. A copy that quietly drops them turns every signing check
    # below into a test of the copy rather than of the artifact.
    if ! ditto "$app_src" "$APP" >&2; then
      echo "::error::ditto could not copy $app_src out of the image" >&2
      mount_ok=""
    fi
  fi
  hdiutil detach -quiet "$MOUNT" >&2 || hdiutil detach -quiet -force "$MOUNT" >&2 || true
  MOUNT=""
fi

# The copy must look like an app before anything asserts things about it.
EXEC_NAME=""
if [ -n "$mount_ok" ]; then
  EXEC_NAME="$(plutil -extract CFBundleExecutable raw -o - "$APP/Contents/Info.plist" 2>/dev/null)"
  if [ -z "$EXEC_NAME" ] || [ ! -f "$APP/Contents/MacOS/$EXEC_NAME" ]; then
    echo "::error::the extracted bundle has no Contents/MacOS/<CFBundleExecutable> — got '${EXEC_NAME:-<no Info.plist>}'" >&2
    mount_ok=""
  fi
fi

if [ -z "$mount_ok" ]; then
  # Everything downstream assesses the extracted copy; stop here rather than run
  # nine checks against an empty directory and report their verdicts as facts.
  record "mounts and yields a .app bundle" FAIL
  print_summary_and_exit
fi
record "mounts and yields a .app bundle" pass
MAIN_BIN="$APP/Contents/MacOS/$EXEC_NAME"
echo "  extracted $(basename "$APP") (main binary: $EXEC_NAME)" >&2

find_machos
echo "  $(grep -c . "$MACHOS") Mach-O file(s) in the bundle" >&2

# ── 2. the .app inside is the version the filename claims ─────────────────────
# The DMG is assembled from a separately built .app, so a stale or mismatched
# bundle can be packaged under a new release's name — the same class of mistake
# the Linux lane catches by comparing the installed dpkg version to the artifact.
check_version_matches_artifact() {
  local want got
  # Release assets are named unyt_<version>_Unyt.Sandbox_<...>_<arch>_darwin.dmg.
  want="$(basename "$DMG" | sed -n 's/^unyt_\([0-9][0-9.]*\)_.*/\1/p')"
  got="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null)"
  echo "  filename says '$want', Info.plist says '${got:-<none>}'" >&2
  if [ -z "$want" ]; then
    # Not a release-named file (a locally built DMG, say). Unknown is not a pass:
    # the check cannot answer its question, and a green row would claim it did.
    echo "::error::cannot read a version out of '$(basename "$DMG")' — expected unyt_<version>_..." >&2
    return 1
  fi
  if [ -z "$got" ]; then
    echo "::error::Info.plist has no CFBundleShortVersionString" >&2
    return 1
  fi
  if [ "$want" != "$got" ]; then
    echo "::error::the DMG is named $want but packages version $got" >&2
    return 1
  fi
  echo "OK: the bundle is version $got" >&2
  return 0
}
run_check "the bundled app is the version the artifact claims" check_version_matches_artifact

# ── 3. the bundle's architecture matches this runner ──────────────────────────
# Guards the MEANING of every check below: Gatekeeper, dyld and codesign all
# refuse a foreign-arch binary, so assessing the aarch64 DMG on an Intel runner
# would report failures that say nothing about the artifact. Read off the binary
# with lipo rather than trusted from the matrix.
check_arch_matches_runner() {
  local archs runner
  archs="$(lipo -archs "$MAIN_BIN" 2>/dev/null)"
  runner="$(uname -m)"
  echo "  binary: ${archs:-<unreadable>} · runner: $runner" >&2
  if [ -z "$archs" ]; then
    echo "::error::lipo could not read an architecture out of $MAIN_BIN" >&2
    return 1
  fi
  # uname -m says arm64 on Apple silicon and x86_64 on Intel — the same spelling
  # lipo uses, so no translation table is needed.
  case " $archs " in
    *" $runner "*) echo "OK: the bundle runs natively on this runner" >&2; return 0 ;;
  esac
  echo "::error::this is a $archs build but the runner is $runner — pair the DMG with a matching runner" >&2
  return 1
}
run_check "the bundle's architecture matches the runner" check_arch_matches_runner

# ── 4. nothing points at the build machine ────────────────────────────────────
check_no_build_machine_paths() {
  local f p prefix deps hits=0 total=0 paths=0
  while IFS= read -r f; do
    total=$((total + 1))
    # THE GUARD BELONGS ON THE PATHS, NOT THE FILES. Counting files answers "was
    # there anything to scan"; it does not answer "did we manage to read any of
    # it". With otool broken, every file is iterated, no path is ever examined,
    # and the loop below finds no violations — a pass produced by reading
    # nothing. Checked per file, because one unreadable binary among many is
    # exactly where a violation would hide.
    if ! deps="$(macho_dep_paths "$f")"; then
      echo "::error::otool -L read no dependencies from ${f#"$APP"/}." >&2
      echo "  Every Mach-O links at least libSystem, so this is a broken otool — a stale" >&2
      echo "  xcode-select path does it — not a clean binary. Refusing to report a scan" >&2
      echo "  that read nothing." >&2
      return 1
    fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      paths=$((paths + 1))
      # shellcheck disable=SC2086  # the constant is a space-separated list, split on purpose
      for prefix in $UNYT_BUILD_MACHINE_PREFIXES; do
        case "$p" in
          "$prefix"*)
            echo "::error::  ${f#"$APP"/} loads $p" >&2
            hits=$((hits + 1))
            ;;
        esac
      done
    done < <(printf '%s\n' "$deps"; macho_rpaths "$f")
  done <"$MACHOS"
  if [ "$total" -eq 0 ]; then
    # No Mach-O at all means the scan proved nothing; an empty sweep must not
    # report the same green row as a clean one.
    echo "::error::no Mach-O files found in the bundle — nothing was scanned" >&2
    return 1
  fi
  if [ "$paths" -eq 0 ]; then
    # Belt to the per-file brace above: the population this check inspects is
    # load paths, so the aggregate gets its own floor too.
    echo "::error::$total Mach-O file(s) yielded no load paths at all — nothing was inspected" >&2
    return 1
  fi
  if [ "$hits" -gt 0 ]; then
    echo "::error::$hits reference(s) to a developer machine's prefixes ($UNYT_BUILD_MACHINE_PREFIXES)" >&2
    echo "  These resolve on the build machine and on no user's Mac." >&2
    return 1
  fi
  echo "OK: $paths load path(s) across $total Mach-O file(s), none referencing $UNYT_BUILD_MACHINE_PREFIXES" >&2
  return 0
}
run_check "no build-machine library paths in any Mach-O" check_no_build_machine_paths

# ── 5. every Mach-O is signed ─────────────────────────────────────────────────
# Per file, from a list this script built itself — NOT `codesign --deep --strict`,
# which has been observed to miss an unsigned binary in Contents/Resources and
# has been deprecated for signing since Ventura. Enumerating means nothing can be
# skipped, and the failure names the exact file.
check_every_macho_signed() {
  local f out rc bad=0 total=0
  while IFS= read -r f; do
    total=$((total + 1))
    out="$(codesign --verify --strict --verbose=2 "$f" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "::error::  ${f#"$APP"/}: $(printf '%s' "$out" | head -2 | tr '\n' ' ')" >&2
      bad=$((bad + 1))
    fi
  done <"$MACHOS"
  if [ "$total" -eq 0 ]; then
    echo "::error::no Mach-O files found in the bundle — nothing was verified" >&2
    return 1
  fi
  if [ "$bad" -gt 0 ]; then
    echo "::error::$bad of $total Mach-O file(s) fail signature verification" >&2
    return 1
  fi
  echo "OK: all $total Mach-O file(s) carry a valid signature" >&2
  return 0
}
run_check "every Mach-O in the bundle is signed" check_every_macho_signed

# ── 6. Gatekeeper accepts it, as NOTARIZED software ───────────────────────────
# `accepted` alone is not enough: a locally signed or ad-hoc build can be
# accepted on the machine that made it. The source line is the part that says
# the assessment came from a notarized Developer ID, which is what a user's Mac
# will demand. spctl writes its verbose assessment to stderr.
check_gatekeeper() {
  local out rc
  out="$(spctl -a -vvv -t exec "$APP" 2>&1)"
  rc=$?
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  if [ "$rc" -ne 0 ]; then
    echo "::error::Gatekeeper REJECTED the app (spctl exit $rc) — a user would see 'cannot be opened'" >&2
    return 1
  fi
  if ! printf '%s' "$out" | grep -q 'accepted'; then
    echo "::error::spctl exited 0 without accepting the app — assessment output is not what this check expects" >&2
    return 1
  fi
  if ! printf '%s' "$out" | grep -q 'source=Notarized Developer ID'; then
    echo "::error::accepted, but NOT as notarized Developer ID software:" >&2
    printf '%s' "$out" | grep -E '^source=' | sed 's/^/  /' >&2
    echo "  A user's Mac quarantines a downloaded app and requires notarization to open it." >&2
    return 1
  fi
  echo "OK: accepted by Gatekeeper as notarized Developer ID software" >&2
  return 0
}
run_check "Gatekeeper accepts it as notarized software" check_gatekeeper

# ── 7. the notarization ticket travels with the artifact ──────────────────────
# Notarized but unstapled works only while Apple's service is reachable: offline,
# or during an outage, the first launch fails. Stapling is what makes the ticket
# part of the download.
check_stapled() {
  local out rc
  out="$(xcrun stapler validate "$APP" 2>&1)"
  rc=$?
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  if [ "$rc" -ne 0 ]; then
    echo "::error::no stapled notarization ticket (stapler exit $rc) — first launch fails offline" >&2
    return 1
  fi
  echo "OK: the notarization ticket is stapled to the bundle" >&2
  return 0
}
run_check "the notarization ticket is stapled" check_stapled

# ── 8. Apple's own pre-distribution assessment ────────────────────────────────
# `syspolicy_check` (macOS 14+) is Apple's replacement for reading codesign
# output by hand — it runs the checks the system itself will run. `distribution`
# rather than `notary-submission`: the artifact under test is already notarized
# and stapled, so the question is whether it passes on a user's Mac, which is
# what `distribution` answers; `notary-submission` asks the pre-submission
# question, about a build that has not been through the service yet.
#
# UNVERIFIED BY US: this repo has no Mac, so the exit-status and usage semantics
# below are from Apple's documented behaviour and have never been run. It fails
# CLOSED — a missing tool or a rejected invocation goes red rather than quietly
# passing — and a usage error is reported as such so nobody debugs the artifact
# when the invocation is what is wrong.
check_syspolicy() {
  local out rc
  if ! command -v syspolicy_check >/dev/null 2>&1; then
    echo "::error::syspolicy_check not found — it ships with macOS 14+, so this runner is older" >&2
    echo "  than the lane expects and the assessment could not be made." >&2
    return 1
  fi
  out="$(syspolicy_check distribution "$APP" 2>&1)"
  rc=$?
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  if printf '%s' "$out" | grep -qiE 'usage:|unknown (check|command)|invalid'; then
    echo "::error::syspolicy_check rejected the INVOCATION, not the app — fix the call, not the build" >&2
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "::error::syspolicy_check says this build is not ready for distribution (exit $rc)" >&2
    return 1
  fi
  echo "OK: passes Apple's pre-distribution assessment" >&2
  return 0
}
run_check "passes Apple's own distribution assessment" check_syspolicy

# ── 9. deployment target within the support floor ─────────────────────────────
# The macOS analogue of the .deb's declared-vs-computed dependency gate:
# LSMinimumSystemVersion is what the bundle DECLARES it runs on, and the Mach-O
# load commands are what it actually REQUIRES. Two ways to be wrong, both real:
# a binary demanding more than the bundle claims launches on the OS it advertises
# and dies in dyld, and a bundle claiming more than our support floor has
# silently dropped users we promised to serve.
check_deployment_target() {
  local f v claimed bundle_max="" worst="" arch floor total=0
  arch="$(lipo -archs "$MAIN_BIN" 2>/dev/null | awk '{print $1}')"
  case "$arch" in
    arm64*) floor="$(version_max "$UNYT_OLDEST_MACOS" "$UNYT_ARM64_MIN_MACOS")" ;;
    *)      floor="$UNYT_OLDEST_MACOS" ;;
  esac

  while IFS= read -r f; do
    total=$((total + 1))
    v="$(macho_min_os "$f")"
    if [ -z "$v" ]; then
      # A Mach-O with neither load command tells us nothing about where it runs,
      # and "told us nothing" must not read as "fine" — this is exactly how the
      # x86_64 build would have slipped through a LC_BUILD_VERSION-only reader.
      echo "::error::  ${f#"$APP"/} declares no LC_BUILD_VERSION or LC_VERSION_MIN_MACOSX" >&2
      return 1
    fi
    if [ -z "$bundle_max" ] || [ "$(version_max "$v" "$bundle_max")" != "$bundle_max" ]; then
      bundle_max="$v"; worst="$f"
    fi
  done <"$MACHOS"

  if [ "$total" -eq 0 ] || [ -z "$bundle_max" ]; then
    echo "::error::no Mach-O deployment target could be read — nothing was checked" >&2
    return 1
  fi

  claimed="$(plutil -extract LSMinimumSystemVersion raw -o - "$APP/Contents/Info.plist" 2>/dev/null)"
  echo "  Info.plist claims:     ${claimed:-<none>}" >&2
  echo "  WHOLE BUNDLE requires: $bundle_max  (from ${worst##*/})" >&2
  echo "  effective floor:       $floor  (support floor $UNYT_OLDEST_MACOS, $arch minimum)" >&2

  if [ -z "$claimed" ]; then
    echo "::error::Info.plist has no LSMinimumSystemVersion — the Finder cannot warn a user off" >&2
    echo "  an unsupported Mac, so they get a crash at launch instead." >&2
    return 1
  fi
  local status=0
  if ! version_within "$claimed" "$UNYT_OLDEST_MACOS"; then
    echo "::error::the bundle claims macOS $claimed but we support back to $UNYT_OLDEST_MACOS —" >&2
    echo "  this build has dropped users we promise to serve." >&2
    status=1
  fi
  if ! version_within "$bundle_max" "$floor"; then
    echo "::error::${worst##*/} requires macOS $bundle_max but the effective floor is $floor —" >&2
    echo "  on that OS the app starts and dies in dyld. A dependency built with a newer" >&2
    echo "  deployment target than the app does this." >&2
    status=1
  fi
  [ "$status" -eq 0 ] && echo "OK: everything in the bundle runs on macOS $floor" >&2
  return "$status"
}
run_check "deployment target within the supported floor" check_deployment_target

# ── report-only ───────────────────────────────────────────────────────────────
# Not gated, and each for its own reason. The DMG's own assessment: Tauri
# notarizes and staples the .app, and whether it also staples the enclosing image
# is its business, not a property of our build — but it is the first thing
# Gatekeeper looks at on a download, so it is worth seeing. The linkage list: it
# is the bundle's implicit contract with the OS, and nothing else records it.
echo "" >&2
echo "===== report only =====" >&2
echo "--- the disk image's own Gatekeeper assessment ---" >&2
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | sed 's/^/  /' >&2 || true
echo "--- what the main binary links against ---" >&2
macho_load_paths "$MAIN_BIN" | sort -u | sed 's/^/  /' >&2

print_summary_and_exit
