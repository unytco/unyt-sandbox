#!/usr/bin/env bash
# Dependency-drift gate. Runs INSIDE a container that has the .deb installed.
#
#   check-deb-depends.sh <artifact.deb> <installed-binary>
#
# Two comparisons, reported separately because they mean different things:
#
#   A. COMPUTED vs EXPECTED (expected-deb-depends.txt) — fails on any change.
#      This is the review gate: what the binary links against is allowed to
#      change, but a human has to acknowledge it by editing that file.
#
#   B. DECLARED vs COMPUTED — fails when the package under-declares.
#
# WHY B EXISTS. `tauri-bundler` writes a HARDCODED `Depends:` into the .deb: it
# takes `bundle.linux.deb.depends` from tauri.conf.json (default:
# libwebkit2gtk-4.1-0 + libgtk-3-0, plus tray) and NEVER runs `dpkg-shlibdeps`,
# never inspects the binary (tauri-bundler src/bundle/linux/debian.rs; upstream
# tauri-apps/tauri#7074; `lintian` flags it as missing-dependency-on-libc). So
# the declared list is an author's guess, and the version constraints that make
# a dependency meaningful are absent.
#
# This is why `apt-get install --simulate` and `apt satisfy` are useless here:
# they check that the DECLARED list is satisfiable, and the declared list is
# exactly what is wrong. Only recomputing from the binary finds it.
#
# The consequence is not usually a failed install — the declared libgtk/libwebkit
# pull most of the rest in transitively — it is a missing FLOOR. Without
# `libc6 (>= 2.34)` the package installs cleanly on a distro with an older glibc
# and then dies at exec, which the user sees as "it just doesn't start" instead
# of apt refusing the install with a clear reason.
#
# The fix when B fails is additive: add the missing entries to
# `bundle.linux.deb.depends` in unyt/src-tauri/tauri.conf.json.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEB="${1:?usage: check-deb-depends.sh <artifact.deb> <installed-binary>}"
BIN="${2:?installed binary path required}"
EXPECTED="$here/expected-deb-depends.txt"

for tool in dpkg-shlibdeps dpkg-deb; do
  command -v "$tool" >/dev/null || { echo "::error::$tool not found (apt-get install dpkg-dev)" >&2; exit 1; }
done

# One dependency per line, trimmed and sorted, so the sets compare as text.
normalize() { tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort -u; }

declared="$(dpkg-deb -f "$DEB" Depends | normalize)"

# dpkg-shlibdeps insists on a debian/control next to it even with -O (stdout).
# --ignore-missing-info keeps a library with no shlibs file from aborting the run.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/debian"
cat >"$work/debian/control" <<'CONTROL'
Source: unyt-sandbox

Package: unyt-sandbox
Architecture: amd64
Depends: ${shlibs:Depends}
Description: placeholder so dpkg-shlibdeps will run standalone
 Only the computed substvar is used.
CONTROL

shlibdeps_err="$work/shlibdeps.err"
cd "$work"
computed_raw="$(dpkg-shlibdeps -O --ignore-missing-info "$BIN" 2>"$shlibdeps_err" || true)"
cd - >/dev/null
computed="$(printf '%s' "$computed_raw" | sed 's/^shlibs:Depends=//' | normalize)"

if [ -z "$computed" ]; then
  echo "::error::dpkg-shlibdeps computed nothing for $BIN — the gate cannot run" >&2
  cat "$shlibdeps_err" >&2
  exit 1
fi

# `--print` is how expected-deb-depends.txt gets regenerated.
if [ "${UNYT_SMOKE_PRINT_COMPUTED:-}" = "1" ]; then
  printf '%s\n' "$computed"
  exit 0
fi

echo "--- declared by the package (${DEB##*/}) ---" >&2
printf '%s\n' "$declared" | sed 's/^/  /' >&2
echo "--- computed from the binary (dpkg-shlibdeps) ---" >&2
printf '%s\n' "$computed" | sed 's/^/  /' >&2
if [ -s "$shlibdeps_err" ]; then
  echo "--- dpkg-shlibdeps notes ---" >&2
  sed 's/^/  /' "$shlibdeps_err" >&2
fi

status=0

# A. drift against the committed expectation
expected="$(grep -v '^[[:space:]]*#' "$EXPECTED" | normalize)"
if ! drift="$(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$computed"))"; then
  echo "::error::the binary's real dependencies changed — review and update scripts/smoke/expected-deb-depends.txt" >&2
  printf '%s\n' "$drift" | sed 's/^/  /' >&2
  status=1
else
  echo "OK: computed dependencies match expected-deb-depends.txt" >&2
fi

# B. under-declaration: every computed entry must be covered by a declared one.
# Compared on PACKAGE NAME, because the declared list carries no version
# constraints at all — reporting each name once is the actionable form.
missing=""
while read -r dep; do
  [ -n "$dep" ] || continue
  name="${dep%% *}"
  if ! printf '%s\n' "$declared" | grep -qE "^${name}( |$)"; then
    missing="$missing$dep"$'\n'
  fi
done <<<"$computed"

if [ -n "$missing" ]; then
  echo "::error::the package UNDER-DECLARES its dependencies — $(printf '%s' "$missing" | grep -c .) computed entries are absent from Depends:" >&2
  printf '%s' "$missing" | sed 's/^/  /' >&2
  echo "" >&2
  echo "  Fix: add them to bundle.linux.deb.depends in unyt/src-tauri/tauri.conf.json." >&2
  echo "  tauri-bundler writes that list verbatim and never computes one." >&2
  status=1
else
  echo "OK: every computed dependency is declared" >&2
fi

exit "$status"
