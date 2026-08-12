#!/usr/bin/env bash
# Will this binary actually run on the oldest OS we support?
#
#   check-binary-compat.sh <installed-binary>
#
# A build machine newer than the target produces a binary that installs fine and
# dies at exec. The versioned-symbol ceiling is the honest way to see that
# without booting the old OS: the highest GLIBC_x.y the binary imports is the
# minimum glibc it can ever run on.
#
# `objdump`, not `nm`: binutils before 2.35 does not print version tags with
# `nm -D`, so the same command silently reports nothing on an older image.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$here/common.sh"

BIN="${1:?usage: check-binary-compat.sh <installed-binary>}"
[ -x "$BIN" ] || { echo "::error::not executable: $BIN" >&2; exit 1; }
command -v objdump >/dev/null || { echo "::error::objdump not found (apt-get install binutils)" >&2; exit 1; }

status=0

max_symver() { objdump -T "$BIN" | grep -oP "$1"'_\K[0-9.]+' | sort -Vu | tail -1; }

glibc_max="$(max_symver GLIBC || true)"
glibcxx_max="$(max_symver GLIBCXX || true)"

echo "--- versioned-symbol ceiling of ${BIN##*/} ---" >&2
echo "  GLIBC   max required: ${glibc_max:-none}  (supported floor: $UNYT_MAX_GLIBC)" >&2
echo "  GLIBCXX max required: ${glibcxx_max:-none (does not link libstdc++)}" >&2

if [ -z "$glibc_max" ]; then
  echo "::error::no GLIBC_ version symbols found — is $BIN really a dynamically linked ELF?" >&2
  status=1
elif [ "$(printf '%s\n%s\n' "$glibc_max" "$UNYT_MAX_GLIBC" | sort -V | tail -1)" != "$UNYT_MAX_GLIBC" ]; then
  echo "::error::needs glibc $glibc_max but the oldest supported target has $UNYT_MAX_GLIBC — this build cannot run there" >&2
  status=1
else
  echo "OK: glibc requirement $glibc_max is within $UNYT_MAX_GLIBC" >&2
fi

# Unresolved symbols. Authoritative for the EXECUTABLE; findings against shipped
# .so files are advisory (a plugin legitimately resolves symbols from its host),
# which is why only the executable is gated.
echo "--- ldd -r (unresolved) ---" >&2
missing_libs="$(ldd "$BIN" 2>/dev/null | grep 'not found' || true)"
undef_syms="$(ldd -r "$BIN" 2>&1 | grep 'undefined symbol' || true)"
if [ -n "$missing_libs" ]; then
  echo "::error::shared libraries the package did not bring in:" >&2
  printf '%s\n' "$missing_libs" | sed 's/^/  /' >&2
  status=1
elif [ -n "$undef_syms" ]; then
  echo "::error::undefined symbols at load time:" >&2
  printf '%s\n' "$undef_syms" | head -20 | sed 's/^/  /' >&2
  status=1
else
  echo "OK: no missing libraries, no undefined symbols" >&2
fi

# RPATH/RUNPATH baked into a shipped binary points at the BUILD machine's
# filesystem; on a user's machine it is at best dead weight and at worst a load
# of something unintended. Advisory — reported, not gated.
rpath="$(readelf -d "$BIN" 2>/dev/null | grep -iE 'rpath|runpath' || true)"
if [ -n "$rpath" ]; then
  echo "::warning::binary carries RPATH/RUNPATH:" >&2
  printf '%s\n' "$rpath" | sed 's/^/  /' >&2
else
  echo "OK: no RPATH/RUNPATH" >&2
fi

exit "$status"
