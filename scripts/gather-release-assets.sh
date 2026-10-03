#!/usr/bin/env bash
# Moves what every build row staged into <out-dir>, and fails on a name that is no build asset of this
# release or that two rows staged:
#   gather-release-assets.sh <version> <productName> <rows-dir> <out-dir>
# <rows-dir> holds one directory per build row, as download-artifact leaves them. A row runs build
# code, so nothing it staged is trusted to name only its own builds.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

usage="usage: gather-release-assets.sh <version> <productName> <rows-dir> <out-dir>"
VERSION="${1:?$usage}"
PRODUCT="${2:?$usage}"
ROWS="${3:?$usage}"
OUT="${4:?$usage}"

expected="$(build_assets "$VERSION" "$(release_product "$PRODUCT")")"
shopt -s nullglob
staged=("$ROWS"/*/*)
[ "${#staged[@]}" -gt 0 ] || fail "no build row staged anything in $ROWS"
for file in "${staged[@]}"; do
  name="$(basename "$file")"
  [ -f "$file" ] || fail "a build row staged $name, which is not a file"
  grep -qxF -- "$name" <<<"$expected" || fail "a build row staged $name, which is no build asset of this release"
  [ ! -e "$OUT/$name" ] || fail "two build rows staged $name"
  mv "$file" "$OUT/$name"
done
