#!/usr/bin/env bash
# Every installer one build job published, as the `<sha256>  <asset>` lines updater-sign.sh and the
# release's SHA256SUMS read:
#   updater-provenance.sh <tauri.conf.json> <arc factor> <build args> <artifact paths>
# <build args> are the job's tauri-action args and <artifact paths> its artifactPaths output. Each
# asset is named as the workflow's assetNamePattern renders it. Env: RUNNER_OS and RUNNER_ARCH. Needs jq.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

usage="usage: updater-provenance.sh <tauri.conf.json> <arc factor> <build args> <artifact paths>"
CONF="${1:?$usage}"
ARC="${2:?$usage}"
ARGS="${3?$usage}"
PATHS="${4:?$usage}"

# [arch]_[platform], as tauri-action renders them for this build.
case "$RUNNER_OS $RUNNER_ARCH $ARGS" in
  "macOS "*" --target aarch64-apple-darwin") target=aarch64_darwin ;;
  "macOS "*" --target x86_64-apple-darwin") target=x64_darwin ;;
  "Linux X64 "*) target=amd64_linux ;;
  "Windows X64 "*) target=x64_windows ;;
  *) fail "no asset name for a $RUNNER_OS $RUNNER_ARCH build with args \"$ARGS\"" ;;
esac

# On Windows, jq ends its lines with a carriage return and tauri-action's paths use backslashes.
json() { jq -r "$@" | tr -d '\r'; }
version="$(json -e .version "$CONF")"
product="$(json -e .productName "$CONF")"
# GitHub renames these in an uploaded asset's name; tauri-action finds assets by the same rule.
product="${product//[ ()\[\]\{\}]/.}"
product="${product//../.}"
json '.[] | select(endswith(".sig") | not)' <<<"$PATHS" | tr '\\' / |
  while IFS= read -r artifact; do
    # tauri-action lists the macOS .app directory, and uploads its .app.tar.gz instead.
    [ ! -d "$artifact" ] || continue
    case "$artifact" in
      *.app.tar.gz) ext=.app.tar.gz ;;
      *.AppImage) ext=.AppImage ;;
      *.deb) ext=.deb ;;
      *.msi) ext=.msi ;;
      *.exe) ext=.exe ;;
      *.dmg) ext=.dmg ;;
      *) fail "$artifact is published, but is no installer this release names" ;;
    esac
    sum="$(sha256 "$artifact")"
    echo "$sum  unyt_${version}_${product}_$ARC-arc_$target$ext"
  done
