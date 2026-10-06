#!/usr/bin/env bash
# Every installer one build job made, as the `<sha256>  <asset>` lines updater-sign.sh and the release's
# SHA256SUMS read, each copied, with its build signature where it has one, into <out-dir> under its
# asset name:
#   updater-provenance.sh <tauri config> <arc factor> <build args> <artifact paths> <out-dir>
# <tauri config> is the app's Tauri configuration with identity.json merged over it, as `release-app.sh
# identity` writes it. <build args> are the job's tauri-action args and <artifact paths> its
# artifactPaths output.
# Env: RUNNER_OS and RUNNER_ARCH. Needs jq.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

usage="usage: updater-provenance.sh <tauri config> <arc factor> <build args> <artifact paths> <out-dir>"
CONF="${1:?$usage}"
ARC="${2:?$usage}"
ARGS="${3?$usage}"
PATHS="${4?$usage}"
OUT="${5:?$usage}"

case "$RUNNER_OS $RUNNER_ARCH $ARGS" in
  "macOS "*" --target aarch64-apple-darwin") target=aarch64_darwin ;;
  "macOS "*" --target x86_64-apple-darwin") target=x64_darwin ;;
  "Linux X64 "*) target=amd64_linux ;;
  "Windows X64 "*) target=x64_windows ;;
  *) fail "no asset name for a $RUNNER_OS $RUNNER_ARCH build with args \"$ARGS\"" ;;
esac
[ -n "$PATHS" ] && [ "$PATHS" != "[]" ] || fail "tauri-action found nothing this build made"

# On Windows, jq ends its lines with a carriage return and tauri-action's paths use backslashes.
json() { jq -r "$@" | tr -d '\r'; }
version="$(json -e .version "$CONF")"
built="$(json -e .productName "$CONF")"
product="$(release_product "$built")"
listed="$(json '.[]' <<<"$PATHS" | tr '\\' /)"
json '.[] | select(endswith(".sig") | not)' <<<"$PATHS" | tr '\\' / |
  while IFS= read -r artifact; do
    # tauri-action lists the macOS .app directory. When the bundler made no .app.tar.gz, tauri-action
    # packs one, uploading or not.
    if [ -d "$artifact" ]; then
      grep -qxF "$artifact.tar.gz" <<<"$listed" && continue
      artifact="$artifact.tar.gz"
      [ -f "$artifact" ] || fail "tauri-action packed no $artifact"
    fi
    case "$artifact" in
      *.app.tar.gz) ext=.app.tar.gz ;;
      *.AppImage) ext=.AppImage ;;
      *.deb) ext=.deb ;;
      *.msi) ext=.msi ;;
      *.exe) ext=.exe ;;
      *.dmg) ext=.dmg ;;
      *) fail "$artifact is no installer this release names" ;;
    esac
    # The bundler names every bundle after the product it built.
    case "$(basename "${artifact%.tar.gz}")" in
      "$built"_* | "$built".app) ;;
      *) fail "$artifact is no $built bundle, so the build did not take identity.json" ;;
    esac
    name="$(asset_name "$version" "$product" "$ARC" "$target$ext")"
    [ ! -e "$OUT/$name" ] || fail "two of this build's artifacts are named $name"
    cp "$artifact" "$OUT/$name"
    [ ! -f "$artifact.sig" ] || cp "$artifact.sig" "$OUT/$name.sig"
    echo "$(sha256 "$artifact")  $name"
  done
