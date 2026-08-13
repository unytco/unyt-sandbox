#!/usr/bin/env bash
# The whole check sequence, run INSIDE a pristine container. Driven by
# run-smoke.sh; not normally invoked by hand.
#
#   container-checks.sh <artifact.deb>
#
# THE ORDER IS LOAD-BEARING. The dependency-closure check has to happen before
# anything else is installed: `apt-get install xvfb` (or binutils, or a test
# harness) drags in libraries of its own, and any one of them could satisfy a
# dependency the package failed to declare — turning the exact bug this exists to
# find into a pass. So: install the package alone, prove closure, and only then
# add tooling. This is also why the test runs in a container at all rather than
# on a CI runner, which is a build image with hundreds of libraries preinstalled.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEB="${1:?usage: container-checks.sh <artifact.deb>}"
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

# 1. Dependency closure on a PRISTINE image — nothing else installed yet.
echo "" >&2
echo "===== install (pristine) =====" >&2
apt-get update -qq >/dev/null 2>&1
if apt-get install -y "$DEB" >/tmp/apt.log 2>&1; then
  record "install on pristine image" pass
  echo "  installed; apt pulled in $(grep -c '^Unpacking' /tmp/apt.log || echo '?') packages" >&2
else
  record "install on pristine image" FAIL
  echo "::error::apt-get install failed on a pristine image:" >&2
  tail -25 /tmp/apt.log >&2
  # Everything downstream needs the app installed; stop here.
  printf '%s\n' "${results[@]}"
  exit 1
fi

pkg="$(dpkg-deb -f "$DEB" Package)"
want="$(dpkg-deb -f "$DEB" Version)"
got="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
if [ "$got" != "$want" ]; then
  # apt exits 0 without doing anything when an equal-or-newer version is already
  # present, which would leave every check below testing a different binary.
  echo "::error::$pkg is at '${got:-none}', expected '$want' — apt did not install this artifact" >&2
  record "installed version matches the artifact" FAIL
else
  record "installed version matches the artifact" pass
fi
BIN="$(dpkg -L "$pkg" | grep -E '^/usr/bin/' | head -1)"
echo "  binary: $BIN" >&2

# 2. Binary compatibility — still before any tooling that could add libraries.
#    (binutils/dpkg-dev bring no GTK/WebKit stack, so installing them here cannot
#    mask a UI dependency, but the closure evidence above is already recorded.)
apt-get install -y -qq binutils dpkg-dev >/dev/null 2>&1
run_check "binary compatibility (glibc ceiling, unresolved symbols)" \
  bash "$here/check-binary-compat.sh" "$BIN"
run_check "declared dependencies match the binary" \
  bash "$here/check-deb-depends.sh" "$DEB" "$BIN"

# 3. Launch. Xvfb stands in for the user's monitor; it adds nothing to the app's
#    own dependency closure, and by now that closure is already proven.
apt-get install -y -qq xvfb >/dev/null 2>&1
run_check "launches, stays up, shuts down" \
  bash "$here/launch-and-assert.sh" "$BIN"

echo "" >&2
printf '%s\n' "${results[@]}"
