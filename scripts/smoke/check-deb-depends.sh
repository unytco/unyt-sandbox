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
#
# ON lintian — CONSIDERED, NOT USED. Its `missing-dependency-on-libc` tag asks a
# subset of what check B already answers, and answers it less precisely: this
# gate is per-image (so it survives Ubuntu's libgtk-3-0 -> libgtk-3-0t64 rename)
# and it enforces the VERSION FLOOR, which lintian does not — the floor is the
# half that actually matters, since a bare `libc6` still lets the package install
# on a too-old glibc. Adding lintian for one redundant tag would buy nothing and
# cost a dependency, so don't.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEB="${1:?usage: check-deb-depends.sh <artifact.deb> <installed-binary>}"
BIN="${2:?installed binary path required}"
# D1: dpkg-shlibdeps resolves a soname to whatever package owns it ON THIS IMAGE,
# and those names differ across distros — ubuntu:24.04 renamed libgtk-3-0 to
# libgtk-3-0t64 and libglib2.0-0 to libglib2.0-0t64 in the time_t transition. One
# shared expectation would therefore be red on every image but the one it was
# captured on, and a permanently-red check is one nobody reads. So the
# expectation is per-image, keyed on the distro's own ID+VERSION_ID.
image_id="$( . /etc/os-release && printf '%s-%s' "$ID" "$VERSION_ID" )"
EXPECTED="$here/expected-deb-depends.$image_id.txt"

for tool in dpkg-shlibdeps dpkg-deb; do
  command -v "$tool" >/dev/null || { echo "::error::$tool not found (apt-get install dpkg-dev)" >&2; exit 1; }
done

# One dependency per line, trimmed and sorted, so the sets compare as text.
# `|| true` on the grep: it exits 1 when it filters everything out, i.e. for an
# EMPTY `Depends:` — which is the worst under-declaration there is, and under
# `set -e` it killed the script instead of reporting it.
normalize() { tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | { grep -v '^$' || true; } | sort -u; }

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

# D4: `--ignore-missing-info` and the `|| true` above let a PARTIAL result
# through, and a short computed list makes the under-declaration check easier to
# pass — the gate would report "everything declared" precisely because it failed
# to compute the entries that are missing. A library it could not resolve is a
# broken gate, not a clean one.
if grep -qE 'no dependency information found|couldn.t find library|cannot find library' "$shlibdeps_err"; then
  echo "::error::dpkg-shlibdeps could not resolve every library, so the computed set is incomplete:" >&2
  grep -E 'no dependency information found|couldn.t find library|cannot find library' "$shlibdeps_err" | head -5 | sed 's/^/  /' >&2
  echo "  Refusing to compare against a truncated list." >&2
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

# A. drift against the committed expectation for THIS image
if [ ! -f "$EXPECTED" ]; then
  echo "::warning::no expectation recorded for $image_id ($(basename "$EXPECTED")) — recording drift is skipped on this image" >&2
  echo "  Capture it with: scripts/smoke/run-smoke.sh --print-computed-depends <deb> $image_id" >&2
else
expected="$(grep -v '^[[:space:]]*#' "$EXPECTED" | normalize)"
if ! drift="$(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$computed"))"; then
  echo "::error::the binary's real dependencies changed on $image_id — review and update $(basename "$EXPECTED")" >&2
  printf '%s\n' "$drift" | sed 's/^/  /' >&2
  status=1
else
  echo "OK: computed dependencies match $(basename "$EXPECTED")" >&2
fi
fi

# B. under-declaration: every computed entry must be covered by a declared one.
# Compared on PACKAGE NAME, because the declared list carries no version
# constraints at all — reporting each name once is the actionable form.
missing=""
unconstrained=""
while read -r dep; do
  [ -n "$dep" ] || continue
  name="${dep%% *}"
  # D3: package names go in as DATA, not as a regex. `.` matched the wrong name
  # and `c++` is a quantifier, so a correctly-declared libstdc++6 read as missing.
  declared_entry="$(printf '%s\n' "$declared" | grep -F -e "$name" | grep -Ex -e "$name( \(.*\))?" | head -1 || true)"
  if [ -z "$declared_entry" ]; then
    missing="$missing$dep"$'\n'
  elif [ "$dep" != "$name" ] && [ "$declared_entry" = "$name" ]; then
    # D2: the motivating defect IS a missing version floor. Declaring a bare
    # `libc6` while the binary needs `libc6 (>= 2.34)` would otherwise satisfy
    # this check and leave the package installable on a too-old glibc.
    unconstrained="$unconstrained$dep (declared without a version constraint)"$'\n'
  fi
done <<<"$computed"

if [ -n "$missing" ] || [ -n "$unconstrained" ]; then
  echo "::error::the package UNDER-DECLARES its dependencies:" >&2
  [ -n "$missing" ] && {
    echo "  absent from Depends: ($(printf '%s' "$missing" | grep -c .))" >&2
    printf '%s' "$missing" | sed 's/^/    /' >&2
  }
  [ -n "$unconstrained" ] && {
    echo "  declared but WITHOUT the required version floor ($(printf '%s' "$unconstrained" | grep -c .)):" >&2
    printf '%s' "$unconstrained" | sed 's/^/    /' >&2
  }
  echo "" >&2
  echo "  Fix: add them to bundle.linux.deb.depends in unyt/src-tauri/tauri.conf.json." >&2
  echo "  tauri-bundler writes that list verbatim and never computes one." >&2
  status=1
else
  echo "OK: every computed dependency is declared" >&2
fi

exit "$status"
