#!/usr/bin/env bash
# The AppImage check sequence, run INSIDE a pristine container. Driven by
# run-smoke.sh; not normally invoked by hand.
#
#   container-checks-appimage.sh <artifact.AppImage>              every check
#   container-checks-appimage.sh --only <id> <artifact.AppImage>  one check
#   container-checks-appimage.sh --print-checks                   <id><TAB><name>
#
# Differs from the .deb sequence in what "pristine" can prove. A .deb declares
# dependencies and apt resolves them, so a bare image tests that contract. An
# AppImage declares nothing and bundles most of what it needs, so a bare image
# only tells you it is not 100% self-contained — which no AppImage is. The
# structural checks therefore run first on the untouched bundle, and the launch
# gets a GTK baseline: a machine that could not run ANY GTK app is not the
# machine this is about.
#
# The order still matters for the same reason it does next door, and `--only`
# (one check per CI step) is enforced against it by smoke_order_ok in common.sh.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$here/common.sh"

UNYT_SMOKE_CHECKS=(
  "extract|extracts without FUSE|check_extract"
  "bundle|bundle glibc ceiling + system requirements|check_bundle"
  "launch|launches, stays up, shuts down|check_launch"
)
UNYT_SMOKE_GATE=extract
UNYT_SMOKE_STATE_VARS=(GATE_OK)

# Fixed paths inside the container rather than state, so every invocation agrees
# on them without having to be told.
APP=/tmp/app.AppImage
APPDIR=/tmp/squashfs-root

MODE=all
ONLY=""
case "${1:-}" in
  --print-checks) MODE=print ;;
  --only) MODE=only; ONLY="${2:?usage: container-checks-appimage.sh --only <check-id> <artifact>}"; shift 2 ;;
esac

if [ "$MODE" != print ]; then
  ARTIFACT="${1:?usage: container-checks-appimage.sh [--only <check-id>] <artifact.AppImage>}"
  export DEBIAN_FRONTEND=noninteractive
  # APPIMAGE_EXTRACT_AND_RUN avoids FUSE entirely, which is the portable answer:
  # 22.04 needs libfuse2 and 24.04 renamed it libfuse2t64, and neither is present
  # on a clean image. Extraction is also how the structural checks get at the bundle.
  export APPIMAGE_EXTRACT_AND_RUN=1

  echo "===== distro =====" >&2
  ( . /etc/os-release && echo "  $PRETTY_NAME" ) >&2
  echo "  glibc: $(ldd --version | head -1)" >&2
fi

check_extract() {
  # The artifact is mounted read-only and typically not +x; copy it somewhere
  # writable so it can be executed and extracted.
  cp "$ARTIFACT" "$APP" && chmod +x "$APP" || {
    echo "::error::could not copy $ARTIFACT to $APP" >&2
    return 1
  }
  # A re-run must not extract on top of a previous AppDir: leftovers from an
  # older bundle would be scanned as if this one shipped them.
  rm -rf "$APPDIR"
  cd /tmp || return 1
  if "$APP" --appimage-extract >/dev/null 2>&1 && [ -d "$APPDIR" ]; then
    echo "  $(find "$APPDIR" -name '*.so*' -type f | wc -l) bundled libraries" >&2
    smoke_state_set GATE_OK 1 || {
      echo "::error::could not record the extraction in $(smoke_state_file) — every check below" >&2
      echo "  would then blame this one for not having run." >&2
      return 1
    }
    return 0
  fi
  echo "::error::--appimage-extract failed; nothing else can run" >&2
  return 1
}

# Structural checks on the untouched bundle, before anything is installed.
check_bundle() {
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq binutils >/dev/null 2>&1
  bash "$here/check-appimage.sh" "$APPDIR"
}

check_launch() {
  local desktop_exec inner_bin
  # The desktop baseline, plus a display. `libwebkit2gtk-4.1-0` is named on purpose
  # rather than the individual sonames check-appimage.sh reports: apt resolves ITS
  # transitive closure per distro, and that closure is exactly the host stack a
  # WebKit app needs. A hand-listed set is distro-specific and silently wrong
  # elsewhere — the first version of this listed Ubuntu's requirements and then
  # failed on debian:13, which additionally needs libgpg-error and libcom_err.
  #
  # This does NOT weaken the check. The AppImage prefers its own bundled libraries
  # via LD_LIBRARY_PATH, so it still runs its own WebKit; what the baseline
  # guarantees is a machine that could run a GTK/WebKit app at all. Precisely what
  # the bundle expects from the host is the separate report in check_bundle, which
  # is where that fact belongs.
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq libwebkit2gtk-4.1-0 libgbm1 libgl1 libegl1 xvfb >/dev/null 2>&1

  # The app runs as the inner binary, not as the .AppImage filename, so the launch
  # oracle is told what process to watch.
  #
  # READ FROM THE .desktop FILE, NOT `find usr/bin | head -1`. This bundle ships
  # xdg-mime alongside the app, and `find` returns directory order, not sorted
  # order — so which of the two came first was a coin flip per machine. On a
  # developer's box it was the app; on the CI runner it was xdg-mime, and the
  # launch oracle then watched for a process by that name, never saw one, and
  # failed a WORKING artifact at the 20s mark on all four images. The same value
  # also feeds the ui_ready probe below, so the breadcrumb was being looked for in
  # xdg-mime — a skip that happened to be right for v0.100.0 and would have been
  # silently wrong for any newer build. Same bug class as check-appimage.sh's N1:
  # `find` order is not an answer to "which file do I want".
  #
  # The .desktop file at the AppDir root is the AppImage's own statement of what it
  # runs (`Exec=unyt-sandbox`), which is exactly the question being asked.
  desktop_exec="$(grep -hm1 '^Exec=' "$APPDIR"/*.desktop 2>/dev/null |
    sed 's/^Exec=//; s/[[:space:]].*//')"
  inner_bin="$APPDIR/usr/bin/$desktop_exec"
  if [ -z "$desktop_exec" ] || [ ! -x "$inner_bin" ]; then
    # No guessing. Picking some other executable is how this failed in the first
    # place, and a launch check watching the wrong process reports a red that says
    # nothing about the artifact.
    echo "::error::cannot tell which binary this AppImage runs: .desktop Exec='${desktop_exec:-<none>}'" >&2
    echo "  is missing or not executable under usr/bin. Candidates present:" >&2
    find "$APPDIR/usr/bin" -type f -executable -exec basename {} \; 2>/dev/null | sed 's/^/    /' >&2
    return 1
  fi
  echo "  AppImage runs as '$desktop_exec' (from the .desktop Exec)" >&2
  export UNYT_SMOKE_PROC_NAME="$desktop_exec"
  # The breadcrumb string lives in the compressed squashfs, so probe the extracted
  # binary rather than the .AppImage file.
  export UNYT_SMOKE_UI_READY_PROBE="$inner_bin"
  bash "$here/launch-and-assert.sh" "$APP"
}

smoke_dispatch "$MODE" "$ONLY"
