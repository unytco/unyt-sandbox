#!/usr/bin/env bash
# The updater manifests of a release, one per arc factor:
#   updater-manifests.sh <tag> <version> <pubkey> <asset-dir> <out-dir>
# <asset-dir> holds the release's .sig assets and the artifacts they sign, under their asset names.
# <out-dir> gets updater-default-arc.json and updater-zero-arc.json, which the app fetches from the
# release. Needs minisign on PATH (install-minisign.sh).
#
# One per arc factor so a build is only ever offered its own variant: tauri-action's single
# latest.json keeps whichever arc's build uploaded last.
set -euo pipefail

usage="usage: updater-manifests.sh <tag> <version> <pubkey> <asset-dir> <out-dir>"
TAG="${1:?$usage}"
VERSION="${2:?$usage}"
PUBKEY="${3:?$usage}"
ASSETS="${4:?$usage}"
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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '%s' "$PUBKEY" | base64 -d >"$tmp/pinned.pub" 2>/dev/null ||
  fail "the pinned public key is not base64"

# The app refuses an artifact the pinned key did not sign, or signed for another version, while the
# bundler at most warns about either, so the release would go green with every update refused.
for sig in "$ASSETS"/*.sig; do
  [ -e "$sig" ] || fail "no signatures in $ASSETS"
  name="$(basename "$sig" .sig)"
  [ -f "$ASSETS/$name" ] || fail "$name, which $name.sig signs, is not on the release"
  base64 -d <"$sig" >"$tmp/minisig" 2>/dev/null || fail "$name.sig is not base64"
  verified="$(minisign -Vm "$ASSETS/$name" -x "$tmp/minisig" -p "$tmp/pinned.pub" 2>&1)" ||
    fail "$name.sig does not verify $name with the key the app pins: $(tr '\n' ' ' <<<"$verified")"
  comment="$(sed -n 's/^Trusted comment: //p' <<<"$verified")"
  [ "$(tr '\t' '\n' <<<"$comment" | sed -n 's/^version://p')" = "$VERSION" ] ||
    fail "$name.sig is not signed for $VERSION, so the app would refuse it"
done

for arc in default zero; do
  platforms='{}'
  while IFS=$'\t' read -r suffix target; do
    set -- "$ASSETS"/*"_${arc}-arc$suffix"
    [ -e "$1" ] || fail "no $arc-arc signature ending in ${suffix#_}: that build would never be offered this update"
    [ "$#" -eq 1 ] || fail "$# $arc-arc signatures end in ${suffix#_}"
    platforms="$(jq --arg target "$target" --rawfile sig "$1" \
      --arg url "https://github.com/$REPO/releases/download/$TAG/$(basename "$1" .sig)" \
      '.[$target] = {url: $url, signature: ($sig | gsub("\\s"; ""))}' <<<"$platforms")"
  done <<<"$TARGETS"
  jq -n --arg version "$VERSION" --argjson platforms "$platforms" \
    '{version: $version, platforms: $platforms}' >"$OUT/updater-$arc-arc.json"
done
