#!/usr/bin/env bash
# The release's SHA256SUMS, and SHA256SUMS.minisig, its signature by the release key:
#   release-sums.sh <version> <productName> <pubkey> <provenance> <stage-1 sums> <asset-dir> <out-dir>
# <provenance> holds the lines updater-provenance.sh wrote in this run's build jobs, <stage-1 sums> the
# sha256sum lines stage 1 wrote for the files it publishes, and <pubkey> is the base64 public key the
# app pins. <asset-dir> holds what the release carries of them: every .dmg, every artifact a .sig
# signs, and the files stage 1 publishes. Build code wrote the records, so the release key signs only
# a line that names an asset of this release and the bytes the release carries under that name.
# Env: TAURI_SIGNING_PRIVATE_KEY and TAURI_SIGNING_PRIVATE_KEY_PASSWORD. Needs minisign on PATH and the
# signer that `npm ci --prefix scripts/tauri-signer` installs.
#
# Not SHA256SUMS.sig: the manifests job takes every .sig on the release for an updater signature.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

usage="usage: release-sums.sh <version> <productName> <pubkey> <provenance> <stage-1 sums> <asset-dir> <out-dir>"
VERSION="${1:?$usage}"
PRODUCT="${2:?$usage}"
PUBKEY="${3:?$usage}"
PROVENANCE="${4:?$usage}"
STAGE1="${5:?$usage}"
ASSETS="${6:?$usage}"
OUT="${7:?$usage}"

[ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" ] ||
  fail "TAURI_SIGNING_PRIVATE_KEY is not set: the release environment holds it and its password"
sums="$(sort -k2,2 - "$PROVENANCE" <<<"$STAGE1")"
if odd="$(LC_ALL=C grep -avE '^[0-9a-f]{64}  [^/[:space:]]+$' <<<"$sums")"; then
  fail "SHA256SUMS would carry lines that check no release asset: ${odd//$'\n'/ | }"
elif [ "$?" -ne 1 ]; then
  fail "could not read the lines SHA256SUMS would carry"
fi
twice="$(awk '{ print $2 }' <<<"$sums" | uniq -d)"
[ -z "$twice" ] || fail "SHA256SUMS would name ${twice//$'\n'/ } more than once"
stage1="$(awk '{ print $2 }' <<<"$STAGE1" | LC_ALL=C sort | tr '\n' ' ')"
[ "$stage1" = "alliance.dna unyt.happ unyt.webhapp unyt_cli " ] ||
  fail "stage 1 recorded ${stage1}rather than alliance.dna unyt.happ unyt.webhapp unyt_cli"
builds="$(build_assets "$VERSION" "$(release_product "$PRODUCT")" | grep -v '\.sig$')"
while read -r _ name; do
  grep -qxF -- "$name" <<<"$builds" || fail "a build of this run recorded $name, which is no build asset of this release"
done <"$PROVENANCE"
while read -r sum name; do
  [ -f "$ASSETS/$name" ] || fail "$name, which this run recorded building, is not on the release"
  [ "$(sha256 "$ASSETS/$name")" = "$sum" ] || fail "$name on the release is not the build this run recorded"
done <<<"$sums"
for file in "$ASSETS"/*; do
  name="$(basename "$file")"
  [ -f "$file" ] && [[ "$name" != *.sig ]] || continue
  awk -v name="$name" '$2 == name { found = 1 } END { exit !found }' <<<"$sums" ||
    fail "$name is on the release, but no build of this run recorded it"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$sums" >"$tmp/SHA256SUMS"
"$here/tauri-signer/node_modules/.bin/tauri" signer sign --app-version "$VERSION" "$tmp/SHA256SUMS" >/dev/null
signed_fields "$tmp" SHA256SUMS "$PUBKEY" "$VERSION" >/dev/null
cp "$tmp/SHA256SUMS" "$OUT/"
base64 -d <"$tmp/SHA256SUMS.sig" >"$OUT/SHA256SUMS.minisig"
