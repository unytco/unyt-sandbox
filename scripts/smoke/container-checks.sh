#!/usr/bin/env bash
# The whole check sequence, run INSIDE a pristine container. Driven by
# run-smoke.sh; not normally invoked by hand.
#
#   container-checks.sh <artifact.deb>              every check, then the rows
#   container-checks.sh --only <id> <artifact.deb>  one check, one row
#   container-checks.sh --print-checks              <id><TAB><name>, in run order
#
# THE ORDER IS LOAD-BEARING: closure must be proven before any tooling is
# installed, or `apt-get install xvfb` satisfies the very dependency the package
# failed to declare. `--only` is the obvious way for that to stop being
# honoured, so smoke_order_ok enforces it rather than assuming it.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$here/common.sh"

# id|display name|function, IN RUN ORDER. The one definition of the sequence.
UNYT_SMOKE_CHECKS=(
  "install|install on pristine image|check_install"
  "version|installed version matches the artifact|check_version"
  "binary-compat|binary compatibility (glibc ceiling, unresolved symbols)|check_binary_compat"
  "depends|declared dependencies match the binary|check_depends"
  "launch|launches, stays up, shuts down|check_launch"
)
UNYT_SMOKE_GATE=install
UNYT_SMOKE_STATE_VARS=(GATE_OK PKG BIN)

MODE=all
ONLY=""
case "${1:-}" in
  --print-checks) MODE=print ;;
  --only) MODE=only; ONLY="${2:?usage: container-checks.sh --only <check-id> <artifact.deb>}"; shift 2 ;;
esac

if [ "$MODE" != print ]; then
  DEB="${1:?usage: container-checks.sh [--only <check-id>] <artifact.deb>}"
  export DEBIAN_FRONTEND=noninteractive

  # Printed on every invocation, i.e. once per CI step: which distro a row came
  # from is the first thing anyone reads it against.
  echo "===== distro =====" >&2
  ( . /etc/os-release && echo "  $PRETTY_NAME" ) >&2
  echo "  glibc: $(ldd --version | head -1)" >&2
fi

# 1. Dependency closure on a PRISTINE image — nothing else installed yet.
check_install() {
  apt-get update -qq >/dev/null 2>&1
  if ! apt-get install -y "$DEB" >/tmp/apt.log 2>&1; then
    echo "::error::apt-get install failed on a pristine image:" >&2
    tail -25 /tmp/apt.log >&2
    return 1
  fi
  echo "  installed; apt pulled in $(grep -c '^Unpacking' /tmp/apt.log || echo '?') packages" >&2
  PKG="$(dpkg-deb -f "$DEB" Package)"
  BIN="$(dpkg -L "$PKG" | grep -E '^/usr/bin/' | head -1)"
  echo "  package: $PKG · binary: ${BIN:-<none>}" >&2
  if [ -z "$BIN" ]; then
    # Every check below is about that binary, and an empty path makes each of
    # them fail for a reason that reads as a different defect. Say it here, once,
    # where it is actually true.
    echo "::error::$PKG installed but ships nothing under /usr/bin — there is no application" >&2
    echo "  binary for the checks below to look at." >&2
    return 1
  fi
  # Recorded LAST and only on success: GATE_OK is what every check below reads to
  # mean "there is an install here to look at".
  smoke_state_set PKG "$PKG" && smoke_state_set BIN "$BIN" && smoke_state_set GATE_OK 1 || {
    echo "::error::could not record the install in $(smoke_state_file) — every check below" >&2
    echo "  would then blame this one for not having run." >&2
    return 1
  }
  return 0
}

check_version() {
  local want got
  want="$(dpkg-deb -f "$DEB" Version)"
  got="$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null || true)"
  echo "  artifact says '$want', dpkg says '${got:-none}'" >&2
  if [ "$got" != "$want" ]; then
    # apt exits 0 without doing anything when an equal-or-newer version is already
    # present, which would leave every check below testing a different binary.
    echo "::error::$PKG is at '${got:-none}', expected '$want' — apt did not install this artifact" >&2
    return 1
  fi
  echo "OK: the installed package is the artifact under test" >&2
  return 0
}

# 2. Binary compatibility — still before any tooling that could add libraries.
#    (binutils/dpkg-dev bring no GTK/WebKit stack, so installing them here cannot
#    mask a UI dependency, and the closure evidence above is already recorded.)
install_build_tooling() { apt-get install -y -qq binutils dpkg-dev >/dev/null 2>&1; }

check_binary_compat() {
  install_build_tooling
  bash "$here/check-binary-compat.sh" "$BIN"
}

check_depends() {
  install_build_tooling
  bash "$here/check-deb-depends.sh" "$DEB" "$BIN"
}

# 3. Launch. Xvfb stands in for the user's monitor; it adds nothing to the app's
#    own dependency closure, and by now that closure is already proven.
check_launch() {
  apt-get install -y -qq xvfb >/dev/null 2>&1
  bash "$here/launch-and-assert.sh" "$BIN"
}

smoke_dispatch "$MODE" "$ONLY"
