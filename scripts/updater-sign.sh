#!/usr/bin/env bash
# Signs each updater artifact of a release under the name the release publishes it as:
#   updater-sign.sh <version> <pubkey> <asset-dir> <started>
# <asset-dir> holds the release's .sig assets and the artifacts they sign, under their asset names;
# each .sig is overwritten. <pubkey> is the base64 public key the app pins. <started> is when this
# release run started, in Unix seconds. Env: TAURI_SIGNING_PRIVATE_KEY and
# TAURI_SIGNING_PRIVATE_KEY_PASSWORD. Needs npx and minisign on PATH.
#
# The bundler signs each artifact under a local file name both arc factors share, before tauri-action
# renames it for upload, and the app refuses a signature for any file but its own release asset. A
# re-pushed tag leaves an earlier run's builds on the release. The bundler's file name does not say
# which arc factor or macOS architecture a build is, so that goes unchecked.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

usage="usage: updater-sign.sh <version> <pubkey> <asset-dir> <started>"
VERSION="${1:?$usage}"
PUBKEY="${2:?$usage}"
ASSETS="${3:?$usage}"
STARTED="${4:?$usage}"

same_installer() { # <file> <asset>
  local type
  for type in .deb .AppImage .app.tar.gz .msi .exe; do
    [[ "$1" == *"$type" && "$2" == *"$type" ]] && return
  done
  return 1
}

for sig in "$ASSETS"/*.sig; do
  [ -e "$sig" ] || fail "no signatures in $ASSETS"
  name="$(basename "$sig" .sig)"
  fields="$(signed_fields "$ASSETS" "$name" "$PUBKEY" "$VERSION")"
  file="$(sed -n 's/^file://p' <<<"$fields")"
  same_installer "$file" "$name" ||
    fail "$name.sig signs $file, which is not a build of that installer"
  [ "$(sed -n 's/^timestamp://p' <<<"$fields")" -ge "$STARTED" ] ||
    fail "$name.sig was signed before this run started, so it is an earlier run's build"
done
for sig in "$ASSETS"/*.sig; do
  npx --yes @tauri-apps/cli@2.11.5 signer sign --app-version "$VERSION" "${sig%.sig}" >/dev/null
done
