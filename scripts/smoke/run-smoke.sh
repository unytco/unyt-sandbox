#!/usr/bin/env bash
# Release install-smoke: does the artifact we shipped work on a user's machine?
#
#   run-smoke.sh <artifact.deb> [image ...]
#   run-smoke.sh --print-computed-depends <artifact.deb> [image]
#
# Runs the whole check sequence in a PRISTINE container per image (default:
# ubuntu:22.04, ubuntu:24.04, debian:12) and prints one table per image.
#
# Containers rather than a CI runner, deliberately. A GitHub runner is a build
# image carrying hundreds of preinstalled libraries, so an under-declared
# dependency is already satisfied there and the run goes green while a real
# user's machine fails. A stock distro image is both more faithful and runnable
# on a laptop, which is what makes this iterable.
#
# Needs only Docker on the host — no drivers, no display, nothing installed.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PRINT_COMPUTED=""
if [ "${1:-}" = "--print-computed-depends" ]; then
  PRINT_COMPUTED=1
  shift
fi

DEB="${1:?usage: run-smoke.sh [--print-computed-depends] <artifact.deb|artifact.AppImage> [image ...]}"
shift || true
[ -f "$DEB" ] || { echo "::error::artifact not found: $DEB" >&2; exit 1; }
DEB="$(cd "$(dirname "$DEB")" && pwd)/$(basename "$DEB")"

# The two Linux bundles need different sequences: a .deb declares dependencies
# that apt must resolve, an AppImage declares nothing and bundles them instead.
case "$DEB" in
  *.deb)      DRIVER=container-checks.sh ;;
  *.AppImage) DRIVER=container-checks-appimage.sh ;;
  *) echo "::error::unsupported artifact '$DEB' (expected .deb or .AppImage)" >&2; exit 1 ;;
esac

# ── THE MATRIX ────────────────────────────────────────────────────────────────
# One list, deliberately spanning BOTH ends of the supported range, because the
# two ends fail differently and each hides the other's bug:
#
#   OLD end  — the glibc floor. A binary built on a newer host imports symbols the
#              old runtime lacks; it installs cleanly and dies at exec. This is
#              also where the .deb's missing `libc6 (>= 2.34)` actually bites.
#   NEW end  — library conflicts. Bundled copies of libwayland/glib/gstreamer
#              collide with the host's newer ones (tauri-apps/tauri#15665), which
#              only shows up on a distro newer than the build machine.
#
# Testing only the LTSs in the middle would miss both. Keep both ends when adding.
#
#   ubuntu:22.04  glibc 2.35  our support floor
#   ubuntu:24.04  glibc 2.39  previous LTS, large install base
#   debian:13     glibc 2.41  current Debian stable
#   ubuntu:26.04  glibc 2.43  current Ubuntu LTS, and what `ubuntu:latest` resolves to
#
# debian:12 (2.36) was dropped: it sits between the two Ubuntu LTSs and exercises
# nothing they don't.
UNYT_SMOKE_IMAGES=(ubuntu:22.04 ubuntu:24.04 debian:13 ubuntu:26.04)

IMAGES=("$@")
[ ${#IMAGES[@]} -gt 0 ] || IMAGES=("${UNYT_SMOKE_IMAGES[@]}")

command -v docker >/dev/null || { echo "::error::docker not found" >&2; exit 1; }

# Regeneration path for expected-deb-depends.txt: install into a throwaway
# container and print what dpkg-shlibdeps computes, nothing else.
if [ -n "$PRINT_COMPUTED" ]; then
  [ "$DRIVER" = container-checks.sh ] || { echo "::error::--print-computed-depends applies to a .deb only" >&2; exit 1; }
  docker run --rm \
    -v "$DEB:/artifact/$(basename "$DEB"):ro" \
    -v "$here:/smoke:ro" \
    "${IMAGES[0]}" bash -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y "/artifact/'"$(basename "$DEB")"'" >/dev/null 2>&1
      apt-get install -y -qq binutils dpkg-dev >/dev/null 2>&1
      pkg=$(dpkg-deb -f "/artifact/'"$(basename "$DEB")"'" Package)
      bin=$(dpkg -L "$pkg" | grep -E "^/usr/bin/" | head -1)
      UNYT_SMOKE_PRINT_COMPUTED=1 bash /smoke/check-deb-depends.sh \
        "/artifact/'"$(basename "$DEB")"'" "$bin" 2>/dev/null
    '
  exit $?
fi

overall=0
declare -a summary

for image in "${IMAGES[@]}"; do
  echo ""
  echo "############################################################"
  echo "# $image"
  echo "############################################################"
  # --shm-size: WebKit needs more than Docker's 64MB default or the webview
  # process dies on start for reasons that look nothing like the real cause.
  out="$(docker run --rm --shm-size=1g \
    -v "$DEB:/artifact/$(basename "$DEB"):ro" \
    -v "$here:/smoke:ro" \
    "$image" bash "/smoke/$DRIVER" "/artifact/$(basename "$DEB")" 2>&1)"
  docker_rc=$?
  echo "$out"

  # container-checks.sh ends with `name|result` lines on stdout.
  rows=0
  while IFS='|' read -r name result; do
    [ -n "${result:-}" ] || continue
    rows=$((rows + 1))
    summary+=("$image|$name|$result")
    [ "$result" = pass ] || overall=1
  done < <(printf '%s\n' "$out" | grep -E '\|(pass|FAIL)$')

  # A container that never ran reports NOTHING, and a verdict read only from the
  # rows would then be "no failures" — printing "All checks passed" for an image
  # that was never pulled, a dead daemon, or an OOM kill. Both guards are needed:
  # docker's own status, AND at least one result row, since the driver can also
  # die mid-way after emitting some.
  if [ "$docker_rc" -ne 0 ] || [ "$rows" -eq 0 ]; then
    echo "::error::the checks did not complete on $image (docker exit $docker_rc, $rows result rows)" >&2
    summary+=("$image|CHECKS DID NOT RUN|FAIL")
    overall=1
  fi
done

echo ""
echo "############################################################"
echo "# summary"
echo "############################################################"
printf '%-14s %-52s %s\n' "IMAGE" "CHECK" "RESULT"
for row in "${summary[@]}"; do
  IFS='|' read -r image name result <<<"$row"
  printf '%-14s %-52s %s\n' "$image" "$name" "$result"
done

[ "$overall" -eq 0 ] && echo "" && echo "All checks passed."
exit "$overall"
