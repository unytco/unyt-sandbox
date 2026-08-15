#!/usr/bin/env bash
# Does the macOS build a release shipped actually run on an ordinary user's Mac?
#
#   check-macos.sh <artifact.dmg>           every check, then the summary table
#   check-macos.sh --print-checks           <id><TAB><name>, one per line, in run order
#   check-macos.sh --only <id> <artifact>   exactly that check; one row on stdout
#   check-macos.sh --report <artifact.dmg>  the ungated report block, nothing else
#   check-macos.sh --cleanup                detach and remove the state directory
#
# EXIT: 0 pass, 1 the check FAILED, 2 the INVOCATION was wrong — so a mistyped
# id can never read as a failing artifact.
#
# PHASE 2 OF THE RELEASE SMOKE — what the artifact IS, never what it does once a
# user opens it. That second question is phase 1's: `opens-macos` in
# release-smoke.yaml launches this same DMG and photographs the app's own window
# (scripts/smoke/load-proving/prove-macos.sh). What no runner offers either way
# is a PRISTINE Mac — Apple's licence caps VMs at two per host, so there is no
# equivalent of the Linux containers, and these checks examine the artifact
# rather than a first-run machine's reaction to it.
#
# A WEBDRIVER TEST WAS BUILT FOR THIS AND DISCARDED, and here is what would have
# to change for that to be worth revisiting. Apple ships no WebDriver for
# WKWebView, so `tauri-driver` covers Windows and Linux only; macOS is drivable
# in 2026 solely by EMBEDDING a server in the app (tauri-plugin-wdio-webdriver,
# or CrabNebula's fork behind a paid key). A binary carrying that plugin is not
# the binary users install, and the installed binary is the whole subject of this
# suite. So: retry it if a driver can attach to an UNMODIFIED signed .app, or if
# we decide a second instrumented build is worth maintaining next to the shipped
# one.
#
# A CI step is a separate process, so check 1's extracted bundle lives in
# UNYT_SMOKE_STATE and a check that cannot find it FAILS — "did not run" and
# "passed" must never be the same colour.
#
# Checks are invoked by name through run_check, which shellcheck reads as dead
# code; the directive must precede the first command to cover the file.
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
# A shipped binary may not require more than the oldest OS we promise to run on.
# Must match MACOSX_DEPLOYMENT_TARGET and Info.plist's LSMinimumSystemVersion.
UNYT_OLDEST_MACOS="10.13"

# arm64 macOS postdates Big Sur, so every arm64 binary reports >= 11.0 and the
# 10.13 floor is unreachable there. The effective floor is the HIGHER of the two,
# per arch — keeps the check sharp on arm64 rather than disabling it.
UNYT_ARM64_MIN_MACOS="11.0"

# Prefixes that exist on a developer's Mac and on no user's. Homebrew's two
# prefixes (Intel /usr/local, Apple-silicon /opt/homebrew) plus MacPorts.
UNYT_BUILD_MACHINE_PREFIXES='/usr/local/ /opt/homebrew/ /opt/local/'

# Not a secret, just not recorded here. EMPTY DOES NOT DISABLE THE CHECK: every
# Mach-O must still name a Developer ID authority and agree on one team. Setting
# it turns "signed by a real team" into "signed by OUR team".
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

# PROVE this sort has -V first: BSD sort without it orders 9.0 above 10.13, and
# every floor comparison below would be wrong in the permissive direction.
if [ "$(printf '10.13\n9.0\n' | sort -V 2>/dev/null | tail -1)" != "10.13" ]; then
  echo "::error::this sort does not do version ordering (-V), so no deployment-target" >&2
  echo "  comparison here can be trusted. Refusing to report checks that cannot be right." >&2
  exit 1
fi
# "$1 is within (<=) the floor $2"
version_within() { [ "$(version_max "$1" "$2")" = "$2" ]; }

# Magic bytes, not `file`'s wording — which differs per implementation, so a
# grep of it quietly matches nothing off a Mac (where the regression test runs).
is_macho() {
  case "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" in
    cffaedfe|cefaedfe|feedface|feedfacf|cafebabe|cafebabf) return 0 ;;
    *) return 1 ;;
  esac
}

# EVERY Mach-O, not just Contents/MacOS: `codesign --deep` has been observed to
# miss an unsigned binary in Contents/Resources. Written to a file, not piped, so
# callers cannot lose the loop's exit status.
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

# The oldest macOS an ARCH can run at all — see UNYT_MACOS_FLOOR above.
arch_floor() {
  case "$1" in
    arm64*) version_max "$UNYT_OLDEST_MACOS" "$UNYT_ARM64_MIN_MACOS" ;;
    *) printf '%s\n' "$UNYT_OLDEST_MACOS" ;;
  esac
}

# TWO load commands: our aarch64 carries LC_BUILD_VERSION, its x86_64 twin the
# older LC_VERSION_MIN_MACOSX. Reading only the modern one finds nothing on
# x86_64, and "nothing found" must not read as "no requirement" — fails closed.
# Per SLICE: an arm64 slice at 11.0 is correct, an x86_64 slice at 11.0 has
# dropped every Intel Mac on 10.13-10.15.
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

# An rpath into /opt/homebrew is the same bug as a direct link. Legitimately
# empty, unlike the dependencies above — most binaries carry no LC_RPATH.
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
# UNYT_SMOKE_STATE outlives the process, which is what makes one-check-per-step
# possible. Without it, a temp directory of our own and the old behaviour.
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

# %q and sourced back: the bundle is "Unyt Sandbox.app", so a path with a space
# is the normal case. State no check reads is state that goes stale unnoticed.
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
  # The file existing is not the state existing — a lost extracted copy would
  # hand a check a path to nothing. Clear it so nobody acts on half.
  APP=""; MAIN_BIN=""
  return 1
}

# ABSENT STATE IS A FAILURE, NEVER A SKIP: a check that cannot see the bundle
# did not run, and a green row would say it did.
require_state() {
  load_state && return 0
  echo "::error::no extracted bundle in $WORK — '$(check_name mount)' has to run first," >&2
  echo "  in the same UNYT_SMOKE_STATE directory. This check did not run; it did not pass." >&2
  return 1
}

# ── 1. mount, extract, detach ─────────────────────────────────────────────────
# Everything else runs against the COPY, so each step here is checked on its own.
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
      # A re-run must not ditto a second bundle INSIDE the first: that doubles
      # the Mach-O enumeration while still looking valid.
      rm -rf "$APP"
      # `ditto`, not `cp -R`: preserves the xattrs and symlinks a signature is
      # computed over, so the signing checks test the artifact and not the copy.
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
  # The state file is this check's only output to the rest, so failing to write
  # one must red THIS check — it is the one that knows why.
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
# The DMG is assembled from a separately built .app, so a stale bundle can be
# packaged under a new release's name.
check_version_matches_artifact() {
  local want got
  # Release assets are named unyt_<version>_Unyt.Sandbox_<...>_<arch>_darwin.dmg.
  # The pre-release tail is PART of the version: stopping at the `-` reads nothing
  # out of unyt_0.101.0-dev.0_… and reds the check on every -dev release. -E, not a
  # BRE `\?`, which BSD sed on the macOS runner does not have.
  want="$(basename "$DMG" | sed -nE 's/^unyt_([0-9][0-9.]*(-[0-9A-Za-z.]+)?)_.*/\1/p')"
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
# Gatekeeper, dyld and codesign all refuse a foreign-arch binary, so a mispaired
# runner reports failures that say nothing about the artifact. Read with lipo,
# not trusted from the matrix.
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

    # Guard the PATHS, not the files: with otool broken every file is iterated,
    # no path examined, no violation found, and the row goes green having read
    # nothing.
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
# Per file, from our own list — NOT `codesign --deep --strict`, which has missed
# an unsigned binary in Contents/Resources and is deprecated since Ventura.
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
# `accepted` alone is not enough — an ad-hoc build is accepted on the machine
# that made it. The source line is what says notarized. spctl reports on stderr.
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
# Notarized but unstapled works only while Apple's service is reachable.
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
# `distribution`, not `notary-submission`: the artifact is already notarized, so
# the question is whether it passes on a user's Mac.
# UNVERIFIED — this repo has no Mac. Fails CLOSED, and reports a usage error as
# such so nobody debugs the artifact when the invocation is wrong.
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
  # Apple documents no exit status, so the OUTPUT decides. The patterns are
  # deliberately asymmetric: syspolicy_check reports per check, so a fatally
  # unnotarized build still prints "Codesign check passed" — a broad pass token
  # matched the wrong line and greened a build Apple calls undistributable.
  # So FAIL is broad and wins; PASS is the one documented whole sentence. A
  # wrong guess about wording is then a false RED, never a false green.
  #
  # Zero-count lines are dropped first, and ONLY when the line is nothing else:
  # dropping any line CONTAINING one would discard
  # `Notary Ticket Missing, 0 errors in codesign` — the filter eating the finding.
  # Do not anchor the fail words: two of the three documented failures carry the
  # significant word at the END.
  scan="$(printf '%s' "$out" |
    grep -viE '^[[:space:]]*0 (errors?|warnings?|issues?|problems?)([[:space:],;]*(and )?0 (errors?|warnings?|issues?|problems?))*[[:space:].]*$')"
  if [ "$rc" -ne 0 ] ||
    printf '%s' "$scan" | grep -qiE 'fail|missing|error|fatal|severity|rejected|unacceptable|denied|not (notarized|signed|accepted|ready)'; then
    echo "::error::syspolicy_check says this build is not ready for distribution (exit $rc)" >&2
    return 1
  fi
  if ! printf '%s' "$out" | grep -qiF 'ready for distribution'; then
    # Cannot tell is NOT a pass: unrecognised wording means the check could not
    # do its job. Fails towards the operator, naming itself as the thing to fix.
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
# Declared (LSMinimumSystemVersion) vs required (load commands). Both directions
# are real: demanding more than claimed dies in dyld on the OS it advertises;
# claiming more than our floor drops users we promised to serve.
check_deployment_target() {
  local f a v slices claimed bundle_max="" worst="" floor status=0 total=0 slices_seen=0

  while IFS= read -r f; do
    total=$((total + 1))
    slices="$(lipo -archs "$f" 2>/dev/null)"
    if [ -z "$slices" ]; then
      echo "::error::  lipo read no architecture from ${f#"$APP"/} — cannot judge its deployment target" >&2
      return 1
    fi
    # Per SLICE, not per file: taking the first slice judged an arm64 build
    # against x86_64's floor and reported a false red.
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
# Not gated: the DMG's own stapling is Tauri's business, and the linkage list is
# the bundle's implicit contract with the OS that nothing else records.
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
# id | display name | function. THE one definition of what runs and in what
# order — the whole-run path, --only and --print-checks all read it.
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
    # A --only run killed mid-way leaves the image mounted; the mountpoint is
    # derived from the state dir, so a later process can still find it.
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
