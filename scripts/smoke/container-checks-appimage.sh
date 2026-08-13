#!/usr/bin/env bash
# The AppImage check sequence, run INSIDE a pristine container. Driven by
# run-smoke.sh; not normally invoked by hand.
#
#   container-checks-appimage.sh <artifact.AppImage>
#
# Differs from the .deb sequence in what "pristine" can prove. A .deb declares
# dependencies and apt resolves them, so a bare image tests that contract. An
# AppImage declares nothing and bundles most of what it needs, so a bare image
# only tells you it is not 100% self-contained — which no AppImage is. The
# structural checks therefore run first on the untouched bundle, and the launch
# gets a GTK baseline: a machine that could not run ANY GTK app is not the
# machine this is about.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT="${1:?usage: container-checks-appimage.sh <artifact.AppImage>}"
export DEBIAN_FRONTEND=noninteractive

results=()
record() { results+=("$1|$2"); }
run_check() {
  local name="$1"; shift
  echo "" >&2
  echo "===== $name =====" >&2
  if "$@"; then record "$name" pass; else record "$name" FAIL; fi
}

echo "===== distro =====" >&2
( . /etc/os-release && echo "  $PRETTY_NAME" ) >&2
echo "  glibc: $(ldd --version | head -1)" >&2

# The artifact is mounted read-only and typically not +x; copy it somewhere
# writable so it can be executed and extracted.
app=/tmp/app.AppImage
cp "$ARTIFACT" "$app" && chmod +x "$app"

# APPIMAGE_EXTRACT_AND_RUN avoids FUSE entirely, which is the portable answer:
# 22.04 needs libfuse2 and 24.04 renamed it libfuse2t64, and neither is present
# on a clean image. Extraction is also how the structural checks get at the bundle.
export APPIMAGE_EXTRACT_AND_RUN=1

echo "" >&2
echo "===== extract =====" >&2
cd /tmp || exit 1
if "$app" --appimage-extract >/dev/null 2>&1 && [ -d /tmp/squashfs-root ]; then
  record "extracts without FUSE" pass
  echo "  $(find /tmp/squashfs-root -name '*.so*' -type f | wc -l) bundled libraries" >&2
else
  record "extracts without FUSE" FAIL
  echo "::error::--appimage-extract failed; nothing else can run" >&2
  printf '%s\n' "${results[@]}"
  exit 1
fi

# Structural checks on the untouched bundle, before anything is installed.
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq binutils >/dev/null 2>&1
run_check "bundle glibc ceiling + system requirements" \
  bash "$here/check-appimage.sh" /tmp/squashfs-root

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
# the bundle expects from the host is the separate report above, which is where
# that fact belongs.
apt-get install -y -qq libwebkit2gtk-4.1-0 libgbm1 libgl1 libegl1 xvfb >/dev/null 2>&1

# The app runs as the inner binary, not as the .AppImage filename, so the launch
# oracle is told what process to watch.
inner_bin="$(find /tmp/squashfs-root/usr/bin -type f -executable | head -1)"
UNYT_SMOKE_PROC_NAME="$(basename "$inner_bin")"
export UNYT_SMOKE_PROC_NAME
# The breadcrumb string lives in the compressed squashfs, so probe the extracted
# binary rather than the .AppImage file.
UNYT_SMOKE_UI_READY_PROBE="$inner_bin"
export UNYT_SMOKE_UI_READY_PROBE
run_check "launches, stays up, shuts down" \
  bash "$here/launch-and-assert.sh" "$app"

echo "" >&2
printf '%s\n' "${results[@]}"
