#!/usr/bin/env bash
# What does the AppImage actually require of the machine it lands on?
#
#   check-appimage.sh <extracted-AppDir>
#
# No `Depends:` to diff — instead a bundle of libraries copied off the BUILD
# machine, which is its own hazard (tauri-apps/tauri#15665).
#
# appimagelint cannot run here: its readelf needs GLIBC_2.38, above our oldest
# target, and it cannot FUSE-mount on 24.04 even with /dev/fuse and SYS_ADMIN.
#
# The gate is the glibc ceiling across the WHOLE BUNDLE: for v0.100.0 the inner
# binary needs 2.34 while bundled libwebkit2gtk needs 2.35.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$here/common.sh"

APPDIR="${1:?usage: check-appimage.sh <extracted-AppDir>}"
[ -d "$APPDIR" ] || { echo "::error::not a directory: $APPDIR" >&2; exit 1; }
command -v objdump >/dev/null || { echo "::error::objdump not found (apt-get install binutils)" >&2; exit 1; }

status=0

# THE APP'S OWN BINARY, named by the .desktop file's Exec — not
# `find usr/bin | head -1`, which is directory order and therefore a coin flip.
desktop_exec="$(grep -hm1 '^Exec=' "$APPDIR"/*.desktop 2>/dev/null | sed 's/^Exec=//; s/[[:space:]].*//' || true)"
inner="$APPDIR/usr/bin/$desktop_exec"
if [ -z "$desktop_exec" ] || [ ! -x "$inner" ]; then
  echo "::error::cannot tell which binary this AppImage runs: .desktop Exec='${desktop_exec:-<none>}'" >&2
  echo "  is missing or not executable under usr/bin. Refusing to guess — scanning the wrong" >&2
  echo "  binary is how this check silently stopped covering the application." >&2
  exit 1
fi

# EVERY ELF IN THE BUNDLE, found by MAGIC BYTES rather than by name.
elf_list="$(mktemp)"
trap 'rm -f "$elf_list" "$elf_list.versions"' EXIT
while IFS= read -r f; do
  case "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" in
    7f454c46) printf '%s\n' "$f" ;;
  esac
done < <(find "$APPDIR" -type f -print) >"$elf_list"

if ! grep -q . "$elf_list"; then
  echo "::error::no ELF files anywhere under $APPDIR — is this really an extracted AppDir?" >&2
  exit 1
fi
echo "--- $(grep -c . "$elf_list") ELF file(s) in the bundle ---" >&2

while read -r f; do
  # `|| true`: most files here import no GLIBC_ symbols at all, and under
  # `set -e` + pipefail the empty grep would abort the whole scan silently.
  v="$(objdump -T "$f" 2>/dev/null | grep -oP 'GLIBC_\K[0-9.]+' | sort -Vu | tail -1 || true)"
  # `if`, NOT `[ -n "$v" ] && printf`: as an AND-list a LAST file with no GLIBC_
  # symbols makes the `while` return 1, pipefail carries it, and set -e skips
  # every check below. `find` order made it a coin flip per build.
  if [ -n "$v" ]; then printf '%s %s\n' "$v" "$f"; fi
done <"$elf_list" | sort -V >"$elf_list.versions"

max_ver="$(awk 'END{print $1}' "$elf_list.versions")"
worst="$(awk 'END{print $2}' "$elf_list.versions")"
rm -f "$elf_list.versions"

inner_ver="$(objdump -T "$inner" 2>/dev/null | grep -oP 'GLIBC_\K[0-9.]+' | sort -Vu | tail -1 || true)"

echo "--- glibc ceiling of the bundle ---" >&2
echo "  inner binary requires: ${inner_ver:-none}" >&2
echo "  WHOLE BUNDLE requires: ${max_ver:-none}  (from ${worst##*/})" >&2
echo "  supported floor:       $UNYT_OLDEST_GLIBC" >&2

if [ -z "$max_ver" ]; then
  echo "::error::no GLIBC version symbols anywhere in the bundle — is this really an AppDir?" >&2
  status=1
elif [ "$(printf '%s\n%s\n' "$max_ver" "$UNYT_OLDEST_GLIBC" | sort -V | tail -1)" != "$UNYT_OLDEST_GLIBC" ]; then
  echo "::error::the bundle needs glibc $max_ver (${worst##*/}) but the oldest supported target has $UNYT_OLDEST_GLIBC" >&2
  echo "  A library bundled from a newer build host does this. Build the AppImage on the oldest" >&2
  echo "  supported distro, or stop bundling that library." >&2
  status=1
else
  echo "OK: the whole bundle runs on glibc $UNYT_OLDEST_GLIBC" >&2
fi

# Reported, not gated: nothing else records the AppImage's implicit dependency
# contract on the host.
echo "--- libraries NOT bundled, so required from the system ---" >&2
external="$(ldd "$inner" 2>/dev/null | grep 'not found' | awk '{print $1}' | sort -u || true)"
if [ -n "$external" ]; then
  printf '%s\n' "$external" | sed 's/^/  /' >&2
  echo "  ($(printf '%s\n' "$external" | grep -c .) libraries — the AppImage assumes the host provides these)" >&2
else
  echo "  (none — fully self-contained)" >&2
fi

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
