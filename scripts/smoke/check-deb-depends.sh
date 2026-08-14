#!/usr/bin/env bash
# Dependency-drift gate. Runs INSIDE a container that has the .deb installed.
#
#   check-deb-depends.sh <artifact.deb> <installed-binary>
#
# Two comparisons: A. computed vs the per-image EXPECTED file (a review gate a
# human edits), and B. DECLARED vs computed, which fails on under-declaration.
#
# B exists because tauri-bundler writes `Depends:` VERBATIM from tauri.conf.json
# and never runs dpkg-shlibdeps (tauri-apps/tauri#7074). So `apt --simulate` and
# `apt satisfy` prove nothing here — they check the declared list is satisfiable,
# and the declared list is exactly what is wrong.
#
# The usual consequence is a missing FLOOR, not a failed install: without
# `libc6 (>= 2.34)` it installs on an older glibc and dies at exec.
#
# Fixing B means editing `bundle.linux.deb.depends`, under two rules JSON cannot
# carry: use the NON-t64 names (the t64 packages declare versioned Provides of
# them), and use the MAXIMUM floor across the matrix, not the oldest image's.
#
# lintian was considered: its one relevant tag ignores the version floor, which
# is the half that matters.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$here/common.sh"
DEB="${1:?usage: check-deb-depends.sh <artifact.deb> <installed-binary>}"
BIN="${2:?installed binary path required}"
# D1: dpkg-shlibdeps names packages as THIS image knows them (the t64 rename),
# so the expectation is per-image. VERSION_ID is defaulted because `set -u` would
# otherwise kill the gate on Debian testing/sid.
image_id="$( . /etc/os-release && printf '%s-%s' "${ID:-unknown}" "${VERSION_ID:-rolling}" )"
EXPECTED="$here/expected-deb-depends.$image_id.txt"

for tool in dpkg-shlibdeps dpkg-deb; do
  command -v "$tool" >/dev/null || { echo "::error::$tool not found (apt-get install dpkg-dev)" >&2; exit 1; }
done

# One dependency per line, trimmed and sorted, so the sets compare as text.
normalize() { tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | { grep -v '^$' || true; } | sort -u; }

declared="$(dpkg-deb -f "$DEB" Depends | normalize)"

# dpkg-shlibdeps insists on a debian/control next to it even with -O (stdout).
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

# D4: a PARTIAL computed list makes under-declaration easier to pass — the gate
# would report "everything declared" because it failed to compute the missing.
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
# apt is the only authority on whether `libgtk-3-0t64` satisfies a declared
# `libgtk-3-0`, and the answer differs per distro.
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
