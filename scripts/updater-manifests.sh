#!/usr/bin/env bash
# The updater manifests of a release, one per arc factor:
#   updater-manifests.sh <tag> <version> <pubkey> <sig-dir> <out-dir>
# <sig-dir> holds the release's .sig assets under their asset names. <out-dir> gets
# updater-default-arc.json and updater-zero-arc.json, which the app fetches from the release.
#
# One per arc factor so a build is only ever offered its own variant: tauri-action's single
# latest.json keeps whichever arc's build uploaded last.
set -euo pipefail

usage="usage: updater-manifests.sh <tag> <version> <pubkey> <sig-dir> <out-dir>"
TAG="${1:?$usage}"
VERSION="${2:?$usage}"
PUBKEY="${3:?$usage}"
SIGS="${4:?$usage}"
OUT="${5:?$usage}"
REPO="${GITHUB_REPOSITORY:-unytco/unyt-sandbox}"

# asset-suffix<TAB>updater target, applied to each arc factor. The target is the
# `<os>-<arch>-<installer>` key the updater plugin looks up for the running bundle; the suffix is what
# assetNamePattern publishes.
TARGETS="_amd64_linux.deb.sig	linux-x86_64-deb
_amd64_linux.AppImage.sig	linux-x86_64-appimage
_aarch64_darwin.app.tar.gz.sig	darwin-aarch64-app
_x64_darwin.app.tar.gz.sig	darwin-x86_64-app
_x64_windows.msi.sig	windows-x86_64-msi
_x64_windows.exe.sig	windows-x86_64-nsis"

fail() {
  echo "::error::$*" >&2
  exit 1
}

# The key id in a minisign public key or signature, given the base64 of its file as Tauri stores both.
keynum() {
  printf '%s' "$1" | base64 -d | sed -n 2p | base64 -d | od -An -tx1 -j2 -N8 | tr -d ' \n'
}

# The version the Tauri CLI wrote into a signature's trusted comment.
signed_version() {
  printf '%s' "$1" | base64 -d | sed -n 's/^trusted comment: //p' | tr '\t' '\n' | sed -n 's/^version://p'
}

# The app refuses a signature by another key, or for another version, while the bundler at most warns
# about either, so the release would go green with every update refused.
pinned="$(keynum "$PUBKEY")"
[ "${#pinned}" -eq 16 ] || fail "the pinned public key carries no key id"
for sig in "$SIGS"/*.sig; do
  [ -e "$sig" ] || fail "no signatures in $SIGS"
  [ "$(keynum "$(cat "$sig")")" = "$pinned" ] ||
    fail "$(basename "$sig") is not signed by the key the app pins, so the app would refuse it"
  [ "$(signed_version "$(cat "$sig")")" = "$VERSION" ] ||
    fail "$(basename "$sig") is not signed for $VERSION, so the app would refuse it"
done

for arc in default zero; do
  platforms='{}'
  while IFS=$'\t' read -r suffix target; do
    set -- "$SIGS"/*"_${arc}-arc$suffix"
    [ -e "$1" ] || fail "no $arc-arc signature ending in ${suffix#_}: that build would never be offered this update"
    [ "$#" -eq 1 ] || fail "$# $arc-arc signatures end in ${suffix#_}"
    platforms="$(jq --arg target "$target" --rawfile sig "$1" \
      --arg url "https://github.com/$REPO/releases/download/$TAG/$(basename "$1" .sig)" \
      '.[$target] = {url: $url, signature: ($sig | gsub("\\s"; ""))}' <<<"$platforms")"
  done <<<"$TARGETS"
  jq -n --arg version "$VERSION" --argjson platforms "$platforms" \
    '{version: $version, platforms: $platforms}' >"$OUT/updater-$arc-arc.json"
done
