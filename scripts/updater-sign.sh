#!/usr/bin/env bash
# Signs each updater artifact of a release with the release key, under the name the release publishes
# it as:
#   updater-sign.sh <version> <asset-dir> <started> <provenance>
# <asset-dir> holds the release's .sig assets and the artifacts they sign, under their asset names;
# each .sig is overwritten. <started> is when this release run started, in Unix seconds. <provenance>
# holds the lines updater-provenance.sh wrote in this run's build jobs. Env: TAURI_SIGNING_PRIVATE_KEY,
# TAURI_SIGNING_PRIVATE_KEY_PASSWORD and GITHUB_RUN_ATTEMPT. Needs the signer that
# `npm ci --prefix scripts/tauri-signer` installs.
#
# The build jobs sign with a key they generate and discard, so a build signature proves nothing, and
# its trusted comment is read without verifying it. Only a build job's record says which asset a build
# is: the bundler's file name does not say which arc factor or target a build is, an asset can be
# renamed on the release, and a re-pushed tag leaves an earlier run's builds on it.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

usage="usage: updater-sign.sh <version> <asset-dir> <started> <provenance>"
VERSION="${1:?$usage}"
ASSETS="${2:?$usage}"
STARTED="${3:?$usage}"
PROVENANCE="${4:?$usage}"

[ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" ] ||
  fail "TAURI_SIGNING_PRIVATE_KEY is not set: the release environment holds it and its password"
# A re-run reads build records that an earlier attempt's smoke could have replaced.
[ "${GITHUB_RUN_ATTEMPT:-}" = 1 ] ||
  fail "attempt ${GITHUB_RUN_ATTEMPT:-unknown} of this run: only a run's first attempt signs, so delete the draft and start a new run"
twice="$(awk '{ print $2 }' "$PROVENANCE" | sort | uniq -d)"
[ -z "$twice" ] || fail "this run's builds published ${twice//$'\n'/ } more than once"
for sig in "$ASSETS"/*.sig; do
  [ -e "$sig" ] || fail "no signatures in $ASSETS"
  name="$(basename "$sig" .sig)"
  [ -f "$ASSETS/$name" ] || fail "$name, which $name.sig signs, is not on the release"
  minisig="$(base64 -d <"$sig" 2>/dev/null)" || fail "$name.sig is not base64"
  sum="$(sha256 "$ASSETS/$name")"
  recorded="$(awk -v name="$name" '$2 == name { print $1 }' "$PROVENANCE")"
  [ -n "$recorded" ] || fail "no build job of this run recorded publishing $name"
  [ "$recorded" = "$sum" ] || fail "$name is not the build this run published under that name"
  signed="$(sed -n 's/^trusted comment: //p' <<<"$minisig" | tr '\t' '\n' | sed -n 's/^timestamp://p')"
  [[ "$signed" =~ ^[0-9]+$ ]] || fail "$name.sig names no signing time"
  [ "$signed" -ge "$STARTED" ] ||
    fail "$name.sig was signed before this run started, so it is an earlier run's build"
done
# A dmg is in the records for SHA256SUMS, but no updater installs it, so it carries no signature.
awk '$2 !~ /\.dmg$/ { print $2 }' "$PROVENANCE" | while read -r name; do
  [ -e "$ASSETS/$name.sig" ] || fail "$name, which a build of this run published, is not on the release"
done
for sig in "$ASSETS"/*.sig; do
  "$here/tauri-signer/node_modules/.bin/tauri" signer sign --app-version "$VERSION" "${sig%.sig}" >/dev/null
done
