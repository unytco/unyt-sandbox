#!/usr/bin/env bash
# Signs each updater artifact of a release under the name the release publishes it as:
#   updater-sign.sh <version> <pubkey> <asset-dir> <started> <provenance>
# <asset-dir> holds the release's .sig assets and the artifacts they sign, under their asset names;
# each .sig is overwritten. <pubkey> is the base64 public key the app pins. <started> is when this
# release run started, in Unix seconds. <provenance> holds the lines updater-provenance.sh wrote in
# this run's build jobs. Env: TAURI_SIGNING_PRIVATE_KEY, TAURI_SIGNING_PRIVATE_KEY_PASSWORD and
# GITHUB_RUN_ATTEMPT. Needs npx and minisign on PATH.
#
# The bundler signs each artifact under a local file name both arc factors share, before tauri-action
# renames it for upload, and the app refuses a signature for any file but its own release asset. A
# re-pushed tag leaves an earlier run's builds on the release. The bundler's file name does not say
# which arc factor or target a build is, and an asset can be renamed on the release, so only its build
# job's record says which asset a build is.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

usage="usage: updater-sign.sh <version> <pubkey> <asset-dir> <started> <provenance>"
VERSION="${1:?$usage}"
PUBKEY="${2:?$usage}"
ASSETS="${3:?$usage}"
STARTED="${4:?$usage}"
PROVENANCE="${5:?$usage}"

# A re-run reads build records that an earlier attempt's smoke could have replaced.
[ "${GITHUB_RUN_ATTEMPT:-}" = 1 ] ||
  fail "attempt ${GITHUB_RUN_ATTEMPT:-unknown} of this run: only a run's first attempt signs, so re-tag the release"
twice="$(awk '{ print $2 }' "$PROVENANCE" | sort | uniq -d)"
[ -z "$twice" ] || fail "this run's builds published ${twice//$'\n'/ } more than once"
for sig in "$ASSETS"/*.sig; do
  [ -e "$sig" ] || fail "no signatures in $ASSETS"
  name="$(basename "$sig" .sig)"
  fields="$(signed_fields "$ASSETS" "$name" "$PUBKEY" "$VERSION")"
  sum="$(sha256 "$ASSETS/$name")"
  recorded="$(awk -v name="$name" '$2 == name { print $1 }' "$PROVENANCE")"
  [ -n "$recorded" ] || fail "no build job of this run recorded publishing $name"
  [ "$recorded" = "$sum" ] || fail "$name is not the build this run published under that name"
  [ "$(sed -n 's/^timestamp://p' <<<"$fields")" -ge "$STARTED" ] ||
    fail "$name.sig was signed before this run started, so it is an earlier run's build"
done
awk '{ print $2 }' "$PROVENANCE" | while read -r name; do
  [ -e "$ASSETS/$name.sig" ] || fail "$name, which a build of this run published, is not on the release"
done
for sig in "$ASSETS"/*.sig; do
  npx --yes @tauri-apps/cli@2.11.5 signer sign --app-version "$VERSION" "${sig%.sig}" >/dev/null
done
