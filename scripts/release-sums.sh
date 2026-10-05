#!/usr/bin/env bash
# The release's SHA256SUMS, and SHA256SUMS.minisig, its signature by the release key:
#   release-sums.sh <version> <pubkey> <provenance> <stage-1 sums> <out-dir>
# <provenance> holds the lines updater-provenance.sh wrote in this run's build jobs, <stage-1 sums> the
# sha256sum lines stage 1 wrote for the files it publishes, and <pubkey> is the base64 public key the
# app pins. Env: TAURI_SIGNING_PRIVATE_KEY and TAURI_SIGNING_PRIVATE_KEY_PASSWORD. Needs minisign on
# PATH and the signer that `npm ci --prefix scripts/tauri-signer` installs.
#
# Not SHA256SUMS.sig: the manifests job takes every .sig on the release for an updater signature.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

usage="usage: release-sums.sh <version> <pubkey> <provenance> <stage-1 sums> <out-dir>"
VERSION="${1:?$usage}"
PUBKEY="${2:?$usage}"
PROVENANCE="${3:?$usage}"
STAGE1="${4:?$usage}"
OUT="${5:?$usage}"

[ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" ] ||
  fail "TAURI_SIGNING_PRIVATE_KEY is not set: the release environment holds it and its password"
sums="$(sort -k2,2 - "$PROVENANCE" <<<"$STAGE1")"
odd="$(grep -vE '^[0-9a-f]{64}  [^/[:space:]]+$' <<<"$sums" || true)"
[ -z "$odd" ] || fail "SHA256SUMS would carry lines that check no release asset: ${odd//$'\n'/ | }"
twice="$(awk '{ print $2 }' <<<"$sums" | uniq -d)"
[ -z "$twice" ] || fail "SHA256SUMS would name ${twice//$'\n'/ } more than once"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$sums" >"$tmp/SHA256SUMS"
"$here/tauri-signer/node_modules/.bin/tauri" signer sign --app-version "$VERSION" "$tmp/SHA256SUMS" >/dev/null
signed_fields "$tmp" SHA256SUMS "$PUBKEY" "$VERSION" >/dev/null
cp "$tmp/SHA256SUMS" "$OUT/"
base64 -d <"$tmp/SHA256SUMS.sig" >"$OUT/SHA256SUMS.minisig"
