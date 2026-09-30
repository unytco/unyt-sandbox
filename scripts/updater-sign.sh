#!/usr/bin/env bash
# Signs each updater artifact of a release under the name the release publishes it as:
#   updater-sign.sh <version> <pubkey> <asset-dir>
# <asset-dir> holds the release's .sig assets and the artifacts they sign, under their asset names;
# each .sig is overwritten. <pubkey> is the base64 public key the app pins. Env:
# TAURI_SIGNING_PRIVATE_KEY and TAURI_SIGNING_PRIVATE_KEY_PASSWORD. Needs npx and minisign on PATH.
#
# The bundler signs each artifact under a local file name both arc factors share, before tauri-action
# renames it for upload, and the app refuses a signature for any file but the release asset built for
# its installer and arc factor. Only an artifact whose build signature verifies for this version is
# signed. Which build sits under which asset name goes unchecked: a build signature names the bundler's
# file, not the asset.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

usage="usage: updater-sign.sh <version> <pubkey> <asset-dir>"
VERSION="${1:?$usage}"
PUBKEY="${2:?$usage}"
ASSETS="${3:?$usage}"

for sig in "$ASSETS"/*.sig; do
  [ -e "$sig" ] || fail "no signatures in $ASSETS"
  signed_fields "$ASSETS" "$(basename "$sig" .sig)" "$PUBKEY" "$VERSION" >/dev/null
done
for sig in "$ASSETS"/*.sig; do
  npx --yes @tauri-apps/cli@2.11.5 signer sign --app-version "$VERSION" "${sig%.sig}" >/dev/null
done
