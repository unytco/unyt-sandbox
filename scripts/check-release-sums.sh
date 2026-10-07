#!/usr/bin/env bash
# Fails unless SHA256SUMS.minisig verifies SHA256SUMS, and SHA256SUMS names every installer taken back
# from the draft with the sum it has:
#   check-release-sums.sh <version> <pubkey> <sums-dir> <installer-dir>
# <sums-dir> holds the release's SHA256SUMS and SHA256SUMS.minisig, and <pubkey> is the base64 public
# key release-sums.sh signed them for. Needs minisign on PATH.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

usage="usage: check-release-sums.sh <version> <pubkey> <sums-dir> <installer-dir>"
VERSION="${1:?$usage}"
PUBKEY="${2:?$usage}"
SUMS="${3:?$usage}"
INSTALLERS="${4:?$usage}"

[ -f "$SUMS/SHA256SUMS" ] || fail "the release has no SHA256SUMS"
[ -f "$SUMS/SHA256SUMS.minisig" ] || fail "the release has no SHA256SUMS.minisig"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "$SUMS/SHA256SUMS" "$tmp/"
base64 <"$SUMS/SHA256SUMS.minisig" >"$tmp/SHA256SUMS.sig"
fields="$(signed_fields "$tmp" SHA256SUMS "$PUBKEY" "$VERSION")" ||
  fail "the draft's SHA256SUMS.minisig does not sign its SHA256SUMS for $VERSION with the key this run signs with"
[ "$(sed -n 's/^file://p' <<<"$fields")" = SHA256SUMS ] || fail "SHA256SUMS.minisig is signed for another file"

shopt -s nullglob
installers=("$INSTALLERS"/*)
[ "${#installers[@]}" -gt 0 ] || fail "no installers in $INSTALLERS to hand to the smoke"
for file in "${installers[@]}"; do
  name="$(basename "$file")"
  [ -f "$file" ] || fail "$name is not a file"
  sum="$(awk -v name="$name" '$2 == name { print $1 }' "$tmp/SHA256SUMS")"
  [ -n "$sum" ] || fail "$name is on the draft, but SHA256SUMS does not name it"
  got="$(sha256 "$file")"
  [ "$got" = "$sum" ] || fail "$name on the draft is not the build SHA256SUMS names"
done
