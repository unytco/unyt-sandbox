#!/usr/bin/env bash
# Dependency-drift gate. Runs INSIDE a container that has the .deb installed.
#
#   check-deb-depends.sh <artifact.deb> <installed-binary>
#
# Two comparisons, reported separately because they mean different things:
#
#   A. COMPUTED vs EXPECTED (expected-deb-depends.<distro>-<ver>.txt, per image)
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
# TWO RULES FOR WRITING THAT LIST, both learned the hard way and neither
# expressible in the config itself, since JSON takes no comments:
#
#  1. USE THE NON-t64 NAMES. Ubuntu's time_t transition renamed libgtk-3-0 ->
#     libgtk-3-0t64 and libglib2.0-0 -> libglib2.0-0t64 on 24.04+ and Debian 13,
#     and one declared list cannot name both. The t64 packages declare versioned
#     `Provides:` of the old names, and a versioned dependency resolves against a
#     versioned Provides — verified by installing a .deb carrying the real binary
#     and the non-t64 names on all four images. Check A's per-image expectation
#     files still record the t64 names, because that is what dpkg-shlibdeps
#     computes there; the Provides map above is what reconciles the two.
#
#  2. USE THE MAXIMUM FLOOR ACROSS THE MATRIX, not the oldest image's.
#     libglib2.0-0 computes (>= 2.65.1) on ubuntu:22.04 and (>= 2.66.0) on the
#     rest. Declaring the lower value would read as TOOLOW on three of the four
#     images; the higher one is satisfied by jammy's 2.72, so it is the only
#     value that is both true everywhere and green everywhere.
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
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$here/common.sh"
DEB="${1:?usage: check-deb-depends.sh <artifact.deb> <installed-binary>}"
BIN="${2:?installed binary path required}"
# D1: dpkg-shlibdeps resolves a soname to whatever package owns it ON THIS IMAGE,
# and those names differ across distros — ubuntu:24.04 renamed libgtk-3-0 to
# libgtk-3-0t64 and libglib2.0-0 to libglib2.0-0t64 in the time_t transition. One
# shared expectation would therefore be red on every image but the one it was
# captured on, and a permanently-red check is one nobody reads. So the
# expectation is per-image, keyed on the distro's own ID+VERSION_ID.
# `set -u` would abort the whole check on an image with no VERSION_ID (Debian
# testing/sid), so default it rather than letting an unbound variable kill the gate.
image_id="$( . /etc/os-release && printf '%s-%s' "${ID:-unknown}" "${VERSION_ID:-rolling}" )"
EXPECTED="$here/expected-deb-depends.$image_id.txt"

for tool in dpkg-shlibdeps dpkg-deb; do
  command -v "$tool" >/dev/null || { echo "::error::$tool not found (apt-get install dpkg-dev)" >&2; exit 1; }
done

# One dependency per line, trimmed and sorted, so the sets compare as text.
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
  # FAIL rather than warn: the matrix named this image, so an absent expectation
  # means check A silently does not run there — a gate that skips itself on the
  # image you just added is the failure mode this whole file exists to avoid.
  echo "::error::no expectation recorded for $image_id ($(basename "$EXPECTED")) — check A cannot run" >&2
  echo "  Capture it with: scripts/smoke/run-smoke.sh --print-computed-depends <artifact.deb> $image_id" >&2
  status=1
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

# B. under-declaration, via the shared comparison (see common.sh) so the
# regression test drives this exact code rather than a copy of it.
declared_f="$work/declared.txt"; printf '%s\n' "$declared" >"$declared_f"
computed_f="$work/computed.txt"; printf '%s\n' "$computed" >"$computed_f"
# Build the Provides map for the computed names ON THIS IMAGE: apt is the only
# authority for whether `libgtk-3-0t64` satisfies a declared `libgtk-3-0`, and
# the answer differs per distro. Verified: the t64 packages declare versioned
# Provides of the old names on 24.04, debian:13 and 26.04, and a synthetic .deb
# declaring the non-t64 names installs on all four images.
provides_f="$work/provides.txt"; : >"$provides_f"
while read -r cdep; do
  [ -n "$cdep" ] || continue
  cn="${cdep%% *}"; cn="${cn%%:*}"
  pv="$(apt-cache show "$cn" 2>/dev/null | sed -n 's/^Provides: //p' | head -1 || true)"
  # `libgtk-3-0 (= 3.24.41)` -> `libgtk-3-0`; commas separate alternatives.
  pv="$(printf '%s' "$pv" | tr ',' '\n' | sed 's/(.*)//; s/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' ' ' || true)"
  [ -n "$pv" ] && printf '%s %s\n' "$cn" "$pv" >>"$provides_f"
done <"$computed_f"

gaps="$(smoke_depends_gaps "$declared_f" "$computed_f" "$provides_f")"

if [ -n "$gaps" ]; then
  echo "::error::the package UNDER-DECLARES its dependencies:" >&2
  n_missing="$(printf '%s\n' "$gaps" | grep -c '^MISSING ' || true)"
  n_unconstrained="$(printf '%s\n' "$gaps" | grep -c '^UNCONSTRAINED ' || true)"
  n_toolow="$(printf '%s\n' "$gaps" | grep -c '^TOOLOW ' || true)"
  if [ "$n_missing" != 0 ]; then
    echo "  absent from Depends: ($n_missing)" >&2
    printf '%s\n' "$gaps" | sed -n 's/^MISSING /    /p' >&2
  fi
  if [ "$n_unconstrained" != 0 ]; then
    echo "  declared WITHOUT the required version floor ($n_unconstrained):" >&2
    printf '%s\n' "$gaps" | sed -n 's/^UNCONSTRAINED /    /p' >&2
  fi
  if [ "$n_toolow" != 0 ]; then
    echo "  declared with a floor BELOW what the binary needs ($n_toolow):" >&2
    printf '%s\n' "$gaps" | sed -n 's/^TOOLOW /    /p' >&2
  fi
  n_nofloor="$(printf '%s\n' "$gaps" | grep -c '^NOFLOOR ' || true)"
  n_badversion="$(printf '%s\n' "$gaps" | grep -c '^BADVERSION ' || true)"
  n_unparseable="$(printf '%s\n' "$gaps" | grep -c '^UNPARSEABLE ' || true)"
  if [ "$n_nofloor" != 0 ]; then
    echo "  declared with a relation that is NOT a lower bound ($n_nofloor) — an upper" >&2
    echo "  bound or an equality constrains nothing below itself:" >&2
    printf '%s\n' "$gaps" | sed -n 's/^NOFLOOR /    /p' >&2
  fi
  if [ "$n_badversion" != 0 ]; then
    echo "  declared with an unparseable version ($n_badversion) — dpkg accepts these" >&2
    echo "  against anything, so the floor would not be enforced:" >&2
    printf '%s\n' "$gaps" | sed -n 's/^BADVERSION /    /p' >&2
  fi
  if [ "$n_unparseable" != 0 ]; then
    echo "  computed entry could not be parsed ($n_unparseable) — refusing to skip its floor:" >&2
    printf '%s\n' "$gaps" | sed -n 's/^UNPARSEABLE /    /p' >&2
  fi
  echo "" >&2
  echo "  Fix: add or raise them in bundle.linux.deb.depends in unyt/src-tauri/tauri.conf.json." >&2
  echo "  tauri-bundler writes that list verbatim and never computes one." >&2
  status=1
else
  echo "OK: every computed dependency is declared, with a covering version floor" >&2
fi

exit "$status"
