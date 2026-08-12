#!/usr/bin/env bash
# What does the AppImage actually require of the machine it lands on?
#
#   check-appimage.sh <extracted-AppDir>
#
# An AppImage carries NO dependency metadata — there is no `Depends:` to diff, so
# the .deb's drift gate has no equivalent here. What it has instead is a bundle of
# libraries copied off the BUILD machine, and that is its own hazard: a library
# bundled from a newer host imports newer glibc symbols and the whole AppImage
# then refuses to start on an older distro, with no packaging error to explain it
# (tauri-apps/tauri#15665 — over-bundled libwayland/glib/gstreamer breaking
# AppImages built on newer Ubuntu).
#
# So the gate is the glibc ceiling across the WHOLE BUNDLE, not just the
# executable. That distinction is load-bearing: for v0.100.0 the inner binary
# needs 2.34 while the bundled libwebkit2gtk needs 2.35, so checking only the
# executable would report a floor one release older than the truth.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$here/common.sh"

APPDIR="${1:?usage: check-appimage.sh <extracted-AppDir>}"
[ -d "$APPDIR" ] || { echo "::error::not a directory: $APPDIR" >&2; exit 1; }
command -v objdump >/dev/null || { echo "::error::objdump not found (apt-get install binutils)" >&2; exit 1; }

status=0

# ── the ceiling, across every ELF the bundle ships ────────────────────────────
inner="$(find "$APPDIR/usr/bin" -type f -executable 2>/dev/null | head -1)"
[ -n "$inner" ] || { echo "::error::no executable under $APPDIR/usr/bin" >&2; exit 1; }

# Every ELF in the bundle, each reduced to the highest GLIBC_ it imports; the
# bundle's ceiling is the max over all of them.
elf_list="$(mktemp)"
trap 'rm -f "$elf_list"' EXIT
{ printf '%s\n' "$inner"; find "$APPDIR" -name '*.so*' -type f; } >"$elf_list"

while read -r f; do
  # `|| true`: most files here import no GLIBC_ symbols at all, and under
  # `set -e` + pipefail the empty grep would abort the whole scan silently.
  v="$(objdump -T "$f" 2>/dev/null | grep -oP 'GLIBC_\K[0-9.]+' | sort -Vu | tail -1 || true)"
  [ -n "$v" ] && printf '%s %s\n' "$v" "$f"
done <"$elf_list" | sort -V >"$elf_list.versions"

max_ver="$(awk 'END{print $1}' "$elf_list.versions")"
worst="$(awk 'END{print $2}' "$elf_list.versions")"
rm -f "$elf_list.versions"

inner_ver="$(objdump -T "$inner" 2>/dev/null | grep -oP 'GLIBC_\K[0-9.]+' | sort -Vu | tail -1 || true)"

echo "--- glibc ceiling of the bundle ---" >&2
echo "  inner binary requires: ${inner_ver:-none}" >&2
echo "  WHOLE BUNDLE requires: ${max_ver:-none}  (from ${worst##*/})" >&2
echo "  supported floor:       $UNYT_MAX_GLIBC" >&2

if [ -z "$max_ver" ]; then
  echo "::error::no GLIBC version symbols anywhere in the bundle — is this really an AppDir?" >&2
  status=1
elif [ "$(printf '%s\n%s\n' "$max_ver" "$UNYT_MAX_GLIBC" | sort -V | tail -1)" != "$UNYT_MAX_GLIBC" ]; then
  echo "::error::the bundle needs glibc $max_ver (${worst##*/}) but the oldest supported target has $UNYT_MAX_GLIBC" >&2
  echo "  A library bundled from a newer build host does this. Build the AppImage on the oldest" >&2
  echo "  supported distro, or stop bundling that library." >&2
  status=1
else
  echo "OK: the whole bundle runs on glibc $UNYT_MAX_GLIBC" >&2
fi

# ── what it still expects FROM the system ────────────────────────────────────
# Reported, not gated: an AppImage is not required to bundle everything, and a
# real desktop has X11/fontconfig. But nothing else records this list, and it is
# the AppImage's implicit dependency contract — the thing a user hits when the
# download "just doesn't start" on a minimal system.
echo "--- libraries NOT bundled, so required from the system ---" >&2
external="$(ldd "$inner" 2>/dev/null | grep 'not found' | awk '{print $1}' | sort -u || true)"
if [ -n "$external" ]; then
  printf '%s\n' "$external" | sed 's/^/  /' >&2
  echo "  ($(printf '%s\n' "$external" | grep -c .) libraries — the AppImage assumes the host provides these)" >&2
else
  echo "  (none — fully self-contained)" >&2
fi

# ── AppRun environment hazards ───────────────────────────────────────────────
# The other half of tauri#15665: a plugin search path baked at build time that
# points OUTSIDE the AppDir loads the build machine's plugins, or nothing at all.
echo "--- AppRun search paths pointing outside the bundle ---" >&2
hazard=""
for var in GST_PLUGIN_SYSTEM_PATH GST_PLUGIN_PATH GIO_EXTRA_MODULES GDK_PIXBUF_MODULE_FILE GTK_PATH; do
  line="$(grep -rhE "^export $var=" "$APPDIR/AppRun" "$APPDIR"/apprun-hooks/*.sh 2>/dev/null | head -1 || true)"
  [ -n "$line" ] || continue
  # A path is safe when every entry is under $APPDIR (or is a plain system dir
  # the OS owns); a bare build-machine path with no $APPDIR at all is the bug.
  if ! printf '%s' "$line" | grep -q 'APPDIR'; then
    echo "::warning::  $var is set without \$APPDIR: $line" >&2
    hazard=1
  else
    echo "  OK $var (rooted in \$APPDIR)" >&2
  fi
done
[ -n "$hazard" ] || echo "  no build-machine paths baked in" >&2

exit "$status"
