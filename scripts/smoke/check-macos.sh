#!/usr/bin/env bash
# Does the macOS build a release shipped actually run on an ordinary user's Mac?
#
#   check-macos.sh <artifact.dmg>           every check, then the summary table
#   check-macos.sh --print-checks           <id><TAB><name>, one per line, in run order
#   check-macos.sh --only <id> <artifact>   exactly that check; one row on stdout
#   check-macos.sh --report <artifact.dmg>  the ungated report block, nothing else
#   check-macos.sh --cleanup                detach and remove the state directory
#
# EXIT STATUS: 0 the check passed, 1 it FAILED, 2 the INVOCATION was wrong (an
# unknown id, a missing argument). Two rather than one for the last, so a caller
# cannot read a mistyped id as a failing artifact — the same distinction check 8
# draws between a rejected build and a rejected invocation.
#
# ONE CHECK PER CI STEP is what --only exists for: the workflow runs each check
# as its own GitHub Actions step, so the step list reads like the summary table
# instead of hiding it inside a single green blob. A step is a SEPARATE PROCESS,
# so what check 1 mounts and extracts cannot live in a shell variable — it goes
# into UNYT_SMOKE_STATE, and a check that cannot find it there FAILS. "The check
# did not run" and "the check passed" must never be the same colour; that is the
# same rule every guard below applies to its own tools, one level out.
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
# to go red, on both the whole-run and the --only path. Nine defects in this
# suite made a check silently pass, and all nine were found that way rather than
# by reading the code.
#
# Every check below is invoked BY NAME through run_check (and cleanup through a
# trap), which shellcheck cannot see, so it reports each one as dead code. The
# directive has to precede the first command to apply to the whole file.
# shellcheck disable=SC2329
set -uo pipefail

MODE=all
ONLY=""
DMG=""
case "${1:-}" in
  --print-checks)
    MODE=print
    [ "$#" -eq 1 ] || { echo "::error::--print-checks takes no other argument" >&2; exit 2; }
    ;;
  --cleanup)
    MODE=cleanup
    [ "$#" -eq 1 ] || { echo "::error::--cleanup takes no other argument" >&2; exit 2; }
    ;;
  --only)
    MODE=only
    [ "$#" -eq 3 ] || { echo "::error::usage: check-macos.sh --only <id> <artifact.dmg> (ids: --print-checks)" >&2; exit 2; }
    ONLY="$2"
    DMG="$3"
    ;;
  --report)
    MODE=report
    [ "$#" -eq 2 ] || { echo "::error::usage: check-macos.sh --report <artifact.dmg>" >&2; exit 2; }
    DMG="$2"
    ;;
  --*)
    echo "::error::unknown option '$1' — see the usage block at the top of this script" >&2
    exit 2
    ;;
  *)
    DMG="${1:?usage: check-macos.sh <artifact.dmg>}"
    ;;
esac
# The modes that assess an artifact need one; --print-checks and --cleanup take
# none, which is what lets the workflow read the check list before it has
# downloaded anything.
if [ -n "$DMG" ]; then
  [ -f "$DMG" ] || { echo "::error::artifact not found: $DMG" >&2; exit 1; }
fi

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

# The Apple Developer team every Mach-O in the bundle must be signed by
# (release-tauri-app.yaml's APPLE_TEAM_ID). Not a secret — a team identifier is
# public in every signature we ship — but it is not recorded in this repo, so it
# is left empty until someone fills it in. EMPTY DOES NOT DISABLE THE CHECK: the
# signature must still name a Developer ID Application authority and carry SOME
# team, and every Mach-O in the bundle must agree on which. Setting it turns
# "signed by a real team" into "signed by OUR team".
UNYT_EXPECTED_TEAM_ID="${UNYT_EXPECTED_TEAM_ID:-}"

# How long `hdiutil attach` may take before it is treated as stuck. Generous for
# a 50MB image on a busy runner, and far below any job timeout, so a stall is
# diagnosed here rather than as an unexplained six-hour hang.
UNYT_HDIUTIL_TIMEOUT="${UNYT_HDIUTIL_TIMEOUT:-120}"

results=()
LAST_RESULT=""
record() { results+=("$1|$2"); }
run_check() {
  local name="$1"; shift
  echo "" >&2
  echo "===== $name =====" >&2
  if "$@"; then LAST_RESULT=pass; else LAST_RESULT=FAIL; fi
  record "$name" "$LAST_RESULT"
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

# The oldest macOS a given ARCHITECTURE can run at all. arm64 macOS did not exist
# before Big Sur, so every arm64 binary reports at least 11.0 and the 10.13 floor
# is unreachable there; measured, not assumed (v0.100.0's aarch64 binary reports
# minos 11.0 under a 10.13 claim). The effective floor is the higher of the two,
# which keeps the check sharp on arm64 rather than disabling it.
arch_floor() {
  case "$1" in
    arm64*) version_max "$UNYT_OLDEST_MACOS" "$UNYT_ARM64_MIN_MACOS" ;;
    *) printf '%s\n' "$UNYT_OLDEST_MACOS" ;;
  esac
}

# The macOS floor a single Mach-O SLICE demands. TWO load commands, because the
# two architectures we ship do not use the same one: v0.100.0's aarch64 binary
# carries LC_BUILD_VERSION (`minos 11.0`) and its x86_64 twin carries the older
# LC_VERSION_MIN_MACOSX (`version 10.13`). Reading only LC_BUILD_VERSION — the
# obvious modern choice — finds NOTHING on the x86_64 build, and "nothing found"
# must never read as "no requirement", so the caller fails closed on an empty
# result. Both shapes verified against the real v0.100.0 artifacts.
#
# PER SLICE, because a universal binary carries one per architecture with
# DIFFERENT minimums, and they are judged against different floors: an arm64
# slice at 11.0 is correct while an x86_64 slice at 11.0 has silently dropped
# every Intel Mac on 10.13-10.15.
macho_min_os() { # <file> [arch]
  local f="$1" a="${2:-}"
  if [ -n "$a" ]; then set -- -arch "$a" -l "$f"; else set -- -l "$f"; fi
  otool "$@" 2>/dev/null | awk '
    $1 == "cmd" && ($2 == "LC_BUILD_VERSION" || $2 == "LC_VERSION_MIN_MACOSX") { c = $2; next }
    c == "LC_BUILD_VERSION"     && $1 == "minos"   { print $2; c = "" }
    c == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print $2; c = "" }
  ' | sort -V | tail -1
}

# The libraries a Mach-O records as dependencies.
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

# ── the state directory ───────────────────────────────────────────────────────
# What check 1 extracts, and what every later check reads. UNYT_SMOKE_STATE names
# a directory that OUTLIVES the process, which is what makes one-check-per-step
# possible; without it we take a temp directory of our own and the run behaves
# exactly as it always has.
WORK=""
STATE_FILE=""
STATE_OWNED=""
MOUNT=""
APP=""
EXEC_NAME=""
MAIN_BIN=""

init_state() {
  if [ -n "${UNYT_SMOKE_STATE:-}" ]; then
    WORK="$UNYT_SMOKE_STATE"
    mkdir -p "$WORK" || { echo "::error::cannot create the state directory $WORK" >&2; exit 1; }
  else
    WORK="$(mktemp -d)"
    STATE_OWNED=1
  fi
  STATE_FILE="$WORK/state.env"
  trap cleanup EXIT INT TERM
}

# shellcheck disable=SC2317  # invoked through the EXIT trap
detach_mount() {
  [ -n "$MOUNT" ] || return 0
  hdiutil detach -quiet "$MOUNT" 2>/dev/null ||
    hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true
  MOUNT=""
}
# shellcheck disable=SC2317  # invoked through the EXIT trap
remove_work() {
  # Only ever the directory mktemp just handed us, or the one the caller named.
  case "$WORK" in
    /*/*) rm -rf "$WORK" ;;
  esac
}
# shellcheck disable=SC2317  # invoked through the EXIT trap
cleanup() {
  detach_mount
  # A caller's state directory has to survive this process — the next --only
  # invocation reads the extracted bundle out of it — so only --cleanup removes
  # that one. A temp directory of ours reaches nobody, so it goes here.
  if [ -n "$STATE_OWNED" ]; then remove_work; fi
}

# What the mount check hands to everything after it, and nothing more: state that
# no check reads is state that can go stale unnoticed, and EXEC_NAME is already
# the tail of MAIN_BIN. Written with %q and read back by sourcing — the bundle is
# "Unyt Sandbox.app", so a path with a space is the normal case here — and the
# file is one this script wrote, in a directory it owns.
save_state() {
  {
    printf 'APP=%q\n' "$APP"
    printf 'MAIN_BIN=%q\n' "$MAIN_BIN"
  } >"$STATE_FILE"
}

load_state() {
  [ -f "$STATE_FILE" ] || return 1
  # shellcheck source=/dev/null
  . "$STATE_FILE"
  if [ -n "$APP" ] && [ -d "$APP" ] && [ -n "$MAIN_BIN" ] && [ -f "$MAIN_BIN" ]; then
    # Re-derived per invocation rather than persisted: enumerating a bundle is
    # cheap, and a saved list could go stale against the directory it describes.
    find_machos
    return 0
  fi
  # THE FILE EXISTING IS NOT THE STATE EXISTING. A state directory that lost its
  # extracted copy would otherwise hand a check a path to nothing, and a sweep
  # over nothing is the empty scan every guard in this suite refuses. Clear what
  # sourcing just set, so no caller can act on half of it.
  APP=""; MAIN_BIN=""
  return 1
}

# ABSENT STATE IS A FAILURE, NEVER A SKIP. A check that cannot see the extracted
# bundle did not run, and a green row would say it did — the same rule the guards
# inside the checks apply to their tools ("read nothing" is not "found nothing"),
# one level out. Named here rather than inside the nine checks so that each
# --only invocation still runs exactly the function the whole-run path runs.
require_state() {
  load_state && return 0
  echo "::error::no extracted bundle in $WORK — '$(check_name mount)' has to run first," >&2
  echo "  in the same UNYT_SMOKE_STATE directory. This check did not run; it did not pass." >&2
  return 1
}

# ── 1. mount, extract, detach ─────────────────────────────────────────────────
# Everything else runs against the COPY, so a silent failure here would leave
# every check below assessing an empty directory. Each step is therefore checked
# on its own, and the extracted bundle has to look like an app before we go on.
check_mount() {
  local mnt mount_ok attach_log hd_pid hd_deadline hd_rc app_count app_src
  mnt="$WORK/mnt"
  mkdir -p "$mnt"
  # A failed mount must not leave an EARLIER run's state standing in a directory
  # that outlives the process: the checks after it would then assess a bundle
  # this invocation never produced, and report a verdict about the wrong thing.
  rm -f "$STATE_FILE"
  mount_ok=1
  # An explicit -mountpoint, rather than parsing hdiutil's tab-separated plist-ish
  # output for where it landed: one less thing to misparse, and it keeps the mount
  # inside the directory the trap already cleans up.
  attach_log="$WORK/hdiutil-attach.log"
  hdiutil attach -nobrowse -readonly -noverify -noautoopen \
    -mountpoint "$mnt" "$DMG" >"$attach_log" 2>&1 </dev/null &
  hd_pid=$!
  hd_deadline=$(( $(date +%s) + UNYT_HDIUTIL_TIMEOUT ))
  hd_rc=0
  while kill -0 "$hd_pid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$hd_deadline" ]; then
      kill -TERM "$hd_pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$hd_pid" 2>/dev/null || true
      echo "::error::hdiutil did not finish attaching within ${UNYT_HDIUTIL_TIMEOUT}s — a disk image" >&2
      echo "  carrying a licence agreement waits for a keypress, which would otherwise hang the job." >&2
      hd_rc=124
      break
    fi
    sleep 1
  done
  [ "$hd_rc" -ne 0 ] || { wait "$hd_pid"; hd_rc=$?; }
  if [ "$hd_rc" -ne 0 ]; then
    echo "::error::hdiutil could not mount $(basename "$DMG") (exit $hd_rc) — the disk image is unreadable:" >&2
    sed 's/^/  /' "$attach_log" >&2 || true
    mount_ok=""
  else
    MOUNT="$mnt"
    # `head -1` over find output is directory order, so with two .app bundles this
    # would assess an arbitrary one — the same coin flip that made the AppImage
    # lane watch xdg-mime instead of the app. A release DMG carries exactly one.
    app_count="$(find "$mnt" -maxdepth 1 -name '*.app' -print | grep -c .)"
    app_src="$(find "$mnt" -maxdepth 1 -name '*.app' -print | sort | head -1)"
    if [ "$app_count" -gt 1 ]; then
      echo "::error::the disk image contains $app_count .app bundles — refusing to pick one at random:" >&2
      find "$mnt" -maxdepth 1 -name '*.app' -print | sed 's/^/  /' >&2
      mount_ok=""
    elif [ -z "$app_src" ]; then
      echo "::error::the disk image mounted but contains no .app:" >&2
      ls -la "$mnt" >&2
      mount_ok=""
    else
      APP="$WORK/$(basename "$app_src")"
      # A state directory can outlive the invocation, so a re-run must not ditto a
      # second bundle INSIDE the first: that doubles the Mach-O enumeration while
      # still looking like a valid bundle, which is a wrong answer that reads as a
      # right one.
      rm -rf "$APP"
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

  [ -n "$mount_ok" ] || return 1

  MAIN_BIN="$APP/Contents/MacOS/$EXEC_NAME"
  echo "  extracted $(basename "$APP") (main binary: $EXEC_NAME)" >&2
  # The state file is this check's ONLY output to the checks after it, so a mount
  # that could not write one handed on nothing — and a green row would say it
  # mounted, extracted AND passed the bundle along. The checks after it would
  # then go red naming this one as the thing that never ran, which is true and
  # useless: it is this check that knows why.
  if ! save_state; then
    echo "::error::could not write $STATE_FILE — the bundle was extracted but nothing after this" >&2
    echo "  check can find it. Refusing to report a mount that handed on nothing." >&2
    return 1
  fi

  find_machos
  echo "  $(grep -c . "$MACHOS") Mach-O file(s) in the bundle" >&2
  return 0
}

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

# ── 4. nothing points at the build machine ────────────────────────────────────
check_no_build_machine_paths() {
  local f p prefix deps dep_rc file_paths hits=0 total=0 paths=0
  while IFS= read -r f; do
    total=$((total + 1))
    file_paths=0
    dep_rc=0
    deps="$(macho_dep_paths "$f")" || dep_rc=$?
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      file_paths=$((file_paths + 1))
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

    # THE GUARD BELONGS ON THE PATHS, NOT THE FILES — and on the count, not on
    # otool's exit status. Counting files answers "was there anything to scan",
    # never "did we manage to read any of it": with otool broken every file is
    # iterated, no path is examined, no violation is found, and the row goes
    # green having read nothing.
    if [ "$file_paths" -eq 0 ]; then
      echo "::error::otool read no load paths from ${f#"$APP"/} (exit $dep_rc)." >&2
      echo "  Every Mach-O links at least libSystem, so this is a broken otool — a stale" >&2
      echo "  xcode-select path does it — not a clean binary. Refusing to report a scan" >&2
      echo "  that read nothing." >&2
      return 1
    fi
  done <"$MACHOS"
  if [ "$total" -eq 0 ]; then
    # No Mach-O at all means the scan proved nothing; an empty sweep must not
    # report the same green row as a clean one. Distinct from the per-file guard
    # above, which cannot fire when the loop never runs.
    echo "::error::no Mach-O files found in the bundle — nothing was scanned" >&2
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

# ── 5. every Mach-O is signed, and by whom ────────────────────────────────────
# Per file, from a list this script built itself — NOT `codesign --deep --strict`,
# which has been observed to miss an unsigned binary in Contents/Resources and
# has been deprecated for signing since Ventura. Enumerating means nothing can be
# skipped, and the failure names the exact file.
check_every_macho_signed() {
  local f out rc info team teams="" bad=0 total=0
  while IFS= read -r f; do
    total=$((total + 1))
    out="$(codesign --verify --strict --verbose=2 "$f" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "::error::  ${f#"$APP"/}: $(printf '%s' "$out" | head -2 | tr '\n' ' ')" >&2
      bad=$((bad + 1))
      continue
    fi

    # VERIFYING IS NOT ENOUGH, and on arm64 that gap is the whole check.
    info="$(codesign -dv --verbose=4 "$f" 2>&1)"
    if printf '%s' "$info" | grep -q 'Signature=adhoc'; then
      echo "::error::  ${f#"$APP"/} carries an AD-HOC signature — it verifies, but no Developer ID" >&2
      echo "    signed it, so Gatekeeper will refuse it on a user's Mac." >&2
      bad=$((bad + 1))
      continue
    fi
    if ! printf '%s' "$info" | grep -q '^Authority=Developer ID Application'; then
      echo "::error::  ${f#"$APP"/} is not signed by a Developer ID Application authority:" >&2
      printf '%s' "$info" | grep -E '^(Authority|Signature)=' | head -3 | sed 's/^/      /' >&2
      bad=$((bad + 1))
      continue
    fi
    team="$(printf '%s' "$info" | sed -n 's/^TeamIdentifier=//p' | head -1)"
    if [ -z "$team" ] || [ "$team" = "not set" ]; then
      echo "::error::  ${f#"$APP"/} has no TeamIdentifier — not a Developer ID signature" >&2
      bad=$((bad + 1))
      continue
    fi
    # Pinned when the team is declared, and otherwise self-consistent: a bundle
    # signed by two different teams is a mis-assembled one either way, and this
    # needs no secret to assert.
    if [ -n "$UNYT_EXPECTED_TEAM_ID" ] && [ "$team" != "$UNYT_EXPECTED_TEAM_ID" ]; then
      echo "::error::  ${f#"$APP"/} is signed by team $team, expected $UNYT_EXPECTED_TEAM_ID" >&2
      bad=$((bad + 1))
      continue
    fi
    case " $teams " in
      *" $team "*) ;;
      *) teams="$teams $team" ;;
    esac
  done <"$MACHOS"

  # shellcheck disable=SC2086  # deliberate split: counting the distinct teams
  if [ "$bad" -eq 0 ] && [ "$(set -- $teams; echo $#)" -gt 1 ]; then
    echo "::error::the bundle is signed by more than one team ($teams) — it was assembled from" >&2
    echo "  parts signed by different identities." >&2
    bad=$((bad + 1))
  fi
  if [ "$total" -eq 0 ]; then
    echo "::error::no Mach-O files found in the bundle — nothing was verified" >&2
    return 1
  fi
  if [ "$bad" -gt 0 ]; then
    echo "::error::$bad of $total Mach-O file(s) fail signature verification" >&2
    return 1
  fi
  echo "OK: all $total Mach-O file(s) signed by Developer ID team$teams" >&2
  return 0
}

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
  local out rc scan
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
  # EXIT STATUS ALONE IS NOT ENOUGH, because Apple documents none: the man page
  # has no EXIT STATUS and no DIAGNOSTICS section, so "exit 0 means pass" is an
  # assumption, and a check resting on it would report a pass for a tool that
  # exits 0 while saying the build is unacceptable. This is the same rule check 6
  # applies to spctl, which is accepted only when it BOTH exits 0 and names a
  # notarized source.
  #
  # THE TWO PATTERNS ARE DELIBERATELY ASYMMETRIC, and in this direction only.
  # syspolicy_check reports PER CHECK, so its output mixes verdicts: a build with
  # a fatal notarization problem still prints "Codesign check passed." A pass
  # token matching `pass` anywhere therefore matched the wrong line, and the real
  # failure — `Notary Ticket Missing`, `Severity: Fatal`, `Type: Distribution
  # Error` — carried none of the words the fail pattern looked for. That is a
  # green row on a build Apple's own tool calls undistributable.
  #
  # So: FAIL is broad and wins, PASS is the one documented whole sentence. Any
  # report that says "missing", "error", "fatal" or carries a severity is a
  # failure regardless of how many individual checks passed, and only "ready for
  # distribution" is success. A wrong guess about the wording is then a false RED
  # that says so, never a false green.
  # A line that says ZERO of something is not a failure. A report's
  # `0 errors, 0 warnings` would otherwise trip the `error` token and red a build
  # that passed — and a row that cries wolf on wording is the row people learn to
  # ignore. Dropped before the scan, so the vocabulary itself stays broad.
  #
  # ONLY A LINE THAT IS NOTHING BUT ZERO-COUNTS. Dropping any line that merely
  # CONTAINS one would discard `Notary Ticket Missing, 0 errors in codesign`
  # entirely — the filter eating the finding it was meant to sit beside. This
  # form can only ever ignore a line that says nothing else, so it cannot hide a
  # failure. The narrower cost is that `Summary: 0 errors` still trips the scan;
  # that is the safe direction, and the surface is small because this script
  # never passes --verbose.
  #
  # ANCHORING THE FAIL WORDS TO LINE STARTS WAS CONSIDERED AND IS WRONG. Of the
  # three documented failure lines, only `Severity: Fatal` begins with its
  # significant word; `Notary Ticket Missing` and `Type: Distribution Error`
  # both carry it at the END, so anchoring stops matching two of the three.
  #
  # Precisely, because the difference matters: on its own that DEGRADES a real
  # failure from the fail branch to cannot-tell, which is still red. Turning it
  # green additionally needs the pass sentence present in the same report. Red
  # either way is not the reassurance it sounds like — a check that can only say
  # "I could not read this" about a build Apple rejected has stopped doing its
  # job, and the green case is one plausible line away. Cheap to type, and a
  # regression.
  scan="$(printf '%s' "$out" |
    grep -viE '^[[:space:]]*0 (errors?|warnings?|issues?|problems?)([[:space:],;]*(and )?0 (errors?|warnings?|issues?|problems?))*[[:space:].]*$')"
  if [ "$rc" -ne 0 ] ||
    printf '%s' "$scan" | grep -qiE 'fail|missing|error|fatal|severity|rejected|unacceptable|denied|not (notarized|signed|accepted|ready)'; then
    echo "::error::syspolicy_check says this build is not ready for distribution (exit $rc)" >&2
    return 1
  fi
  if ! printf '%s' "$out" | grep -qiF 'ready for distribution'; then
    # Cannot tell. Not a pass: the wording is undocumented, so an unrecognised
    # answer means this check could not do its job, and a green row would claim
    # it did. Fails LOUDLY towards the operator rather than quietly towards the
    # release — if the real wording differs from these patterns, this is the
    # message that says so, and it names itself as the thing to fix.
    echo "::error::syspolicy_check exited 0 but its output matched no known pass or fail wording," >&2
    echo "  so this check cannot say whether the build is distributable. Apple documents no exit" >&2
    echo "  status for this tool, so the output is the only signal — teach this check the real" >&2
    echo "  wording rather than assuming exit 0 meant success." >&2
    return 1
  fi
  echo "OK: passes Apple's pre-distribution assessment" >&2
  return 0
}

# ── 9. deployment target within the support floor ─────────────────────────────
# The macOS analogue of the .deb's declared-vs-computed dependency gate:
# LSMinimumSystemVersion is what the bundle DECLARES it runs on, and the Mach-O
# load commands are what it actually REQUIRES. Two ways to be wrong, both real:
# a binary demanding more than the bundle claims launches on the OS it advertises
# and dies in dyld, and a bundle claiming more than our support floor has
# silently dropped users we promised to serve.
check_deployment_target() {
  local f a v slices claimed bundle_max="" worst="" floor status=0 total=0 slices_seen=0

  while IFS= read -r f; do
    total=$((total + 1))
    slices="$(lipo -archs "$f" 2>/dev/null)"
    if [ -z "$slices" ]; then
      echo "::error::  lipo read no architecture from ${f#"$APP"/} — cannot judge its deployment target" >&2
      return 1
    fi
    # PER SLICE, NOT PER FILE. A universal binary carries one Mach-O per
    # architecture, each with its own minimum AND its own floor: taking the
    # first slice judged an arm64 build (11.0, correct) against x86_64's 10.13
    # floor and reported a FALSE RED on a build with nothing wrong with it.
    for a in $slices; do
      slices_seen=$((slices_seen + 1))
      v="$(macho_min_os "$f" "$a")"
      if [ -z "$v" ]; then
        # A slice with neither load command tells us nothing about where it
        # runs, and "told us nothing" must not read as "fine" — this is exactly
        # how the x86_64 build slipped past a LC_BUILD_VERSION-only reader.
        echo "::error::  ${f#"$APP"/} ($a) declares no LC_BUILD_VERSION or LC_VERSION_MIN_MACOSX" >&2
        return 1
      fi
      floor="$(arch_floor "$a")"
      if ! version_within "$v" "$floor"; then
        echo "::error::  ${f#"$APP"/} ($a) requires macOS $v but the $a floor is $floor —" >&2
        echo "    on that OS the app starts and dies in dyld. A dependency built with a newer" >&2
        echo "    deployment target than the app does this." >&2
        status=1
      fi
      if [ -z "$bundle_max" ] || [ "$(version_max "$v" "$bundle_max")" != "$bundle_max" ]; then
        bundle_max="$v"; worst="${f##*/} ($a)"
      fi
    done
  done <"$MACHOS"

  if [ "$total" -eq 0 ] || [ "$slices_seen" -eq 0 ] || [ -z "$bundle_max" ]; then
    echo "::error::no Mach-O deployment target could be read — nothing was checked" >&2
    return 1
  fi

  claimed="$(plutil -extract LSMinimumSystemVersion raw -o - "$APP/Contents/Info.plist" 2>/dev/null)"
  echo "  Info.plist claims:     ${claimed:-<none>}" >&2
  echo "  WHOLE BUNDLE requires: $bundle_max  (from $worst)" >&2
  echo "  slices checked:        $slices_seen across $total Mach-O file(s), each against its own floor" >&2

  if [ -z "$claimed" ]; then
    echo "::error::Info.plist has no LSMinimumSystemVersion — the Finder cannot warn a user off" >&2
    echo "  an unsupported Mac, so they get a crash at launch instead." >&2
    return 1
  fi
  if ! version_within "$claimed" "$UNYT_OLDEST_MACOS"; then
    echo "::error::the bundle claims macOS $claimed but we support back to $UNYT_OLDEST_MACOS —" >&2
    echo "  this build has dropped users we promise to serve." >&2
    status=1
  fi
  [ "$status" -eq 0 ] && echo "OK: every slice is within its architecture's floor" >&2
  return "$status"
}

# ── report-only ───────────────────────────────────────────────────────────────
# Not gated, and each for its own reason. The DMG's own assessment: Tauri
# notarizes and staples the .app, and whether it also staples the enclosing image
# is its business, not a property of our build — but it is the first thing
# Gatekeeper looks at on a download, so it is worth seeing. The linkage list: it
# is the bundle's implicit contract with the OS, and nothing else records it.
report_only() {
  echo "" >&2
  echo "===== report only =====" >&2
  echo "--- the disk image's own Gatekeeper assessment ---" >&2
  spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | sed 's/^/  /' >&2 || true
  echo "--- what the main binary links against ---" >&2
  if [ -n "$MAIN_BIN" ]; then
    macho_load_paths "$MAIN_BIN" | sort -u | sed 's/^/  /' >&2
  else
    # Reached only via `--report` against a state directory the mount check has
    # not filled. Still not a failure: this block never gates.
    echo "  (nothing extracted in $WORK — run the mount check first)" >&2
  fi
}

# ── the sequence ──────────────────────────────────────────────────────────────
# id | display name | function. THE one definition of what this suite runs and in
# what order: the whole-run path loops over it, --only selects one entry from it,
# and --print-checks prints it so the workflow can prove that every check
# reported rather than that no step went red. The reasoning for each check is the
# numbered section comment above it.
CHECKS=(
  "mount|mounts and yields a .app bundle|check_mount"
  "version|the bundled app is the version the artifact claims|check_version_matches_artifact"
  "arch|the bundle's architecture matches the runner|check_arch_matches_runner"
  "paths|no build-machine library paths in any Mach-O|check_no_build_machine_paths"
  "signed|every Mach-O in the bundle is signed|check_every_macho_signed"
  "gatekeeper|Gatekeeper accepts it as notarized software|check_gatekeeper"
  "stapled|the notarization ticket is stapled|check_stapled"
  "syspolicy|passes Apple's own distribution assessment|check_syspolicy"
  "deployment|deployment target within the supported floor|check_deployment_target"
)

print_checks() {
  local entry id name
  for entry in "${CHECKS[@]}"; do
    IFS='|' read -r id name _ <<<"$entry"
    printf '%s\t%s\n' "$id" "$name"
  done
}

check_name() { # <id>
  local entry id name
  for entry in "${CHECKS[@]}"; do
    IFS='|' read -r id name _ <<<"$entry"
    if [ "$id" = "$1" ]; then printf '%s\n' "$name"; return 0; fi
  done
  return 1
}

runner_banner() {
  echo "===== runner =====" >&2
  echo "  $(sw_vers -productName 2>/dev/null || echo macOS) $(sw_vers -productVersion 2>/dev/null || echo '?') on $(uname -m)" >&2
  echo "  artifact: $(basename "$DMG")" >&2
}

run_all() {
  local entry id name fn
  for entry in "${CHECKS[@]}"; do
    IFS='|' read -r id name fn <<<"$entry"
    run_check "$name" "$fn"
    if [ "$id" = mount ] && [ "$LAST_RESULT" != pass ]; then
      # Everything downstream assesses the extracted copy; stop here rather than
      # run nine checks against an empty directory and report their verdicts as
      # facts.
      print_summary_and_exit
    fi
  done
  report_only
  print_summary_and_exit
}

# The prerequisite gate, then the check itself — wrapped so that run_check still
# invokes the same nine functions the whole-run path invokes, unaltered.
only_run() { # <id> <function>
  case "$1" in
    mount) ;;
    *) require_state || return 1 ;;
  esac
  "$2"
}

run_only() { # <id>
  local entry id name fn
  for entry in "${CHECKS[@]}"; do
    IFS='|' read -r id name fn <<<"$entry"
    [ "$id" = "$1" ] || continue
    run_check "$name" only_run "$id" "$fn"
    # Exactly one row on stdout, in the `name|result` shape record() builds the
    # summary table from, so a step reports its verdict without anything having
    # to parse the narration on stderr.
    printf '%s\n' "${results[0]}"
    if [ -n "${UNYT_SMOKE_RESULTS:-}" ]; then
      printf '%s\n' "${results[0]}" >>"$UNYT_SMOKE_RESULTS"
    fi
    [ "$LAST_RESULT" = pass ] && exit 0
    exit 1
  done
  # An id nobody runs is not a silent no-op: the workflow would show a green step
  # for a check that never happened, which is the one thing this suite refuses to
  # do. Exit 2 rather than 1, so a wrong invocation cannot read as a failed check.
  echo "::error::unknown check id '$1' — the ids are:" >&2
  print_checks | sed 's/^/  /' >&2
  exit 2
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "$MODE" in
  print)
    # No artifact, no state directory, no trap: this is the list itself, and
    # whatever reads it must be able to do so before anything is downloaded.
    print_checks
    exit 0
    ;;
  cleanup)
    init_state
    # A --only run killed between attach and detach leaves the image mounted, and
    # the mountpoint is derived from the state directory rather than remembered,
    # so a later process can still find it. Without UNYT_SMOKE_STATE there is by
    # definition nothing to clean — every run's temp directory died with it — so
    # this is a no-op that still exits 0 rather than a special case.
    [ -d "$WORK/mnt" ] && MOUNT="$WORK/mnt"
    detach_mount
    remove_work
    exit 0
    ;;
  report)
    init_state
    runner_banner
    load_state || true
    report_only
    exit 0
    ;;
  only)
    init_state
    runner_banner
    run_only "$ONLY"
    ;;
  all)
    init_state
    runner_banner
    run_all
    ;;
esac
