#!/usr/bin/env bash
# Whether this release signs its updates, as $GITHUB_OUTPUT lines:
#   updater-signing.sh <tauri.conf.json>      prints  enabled=true|false  [pubkey=<key>]
#
# An app with no updater config releases unsigned. One with it updates in-app only to a release
# signed with its pinned key, so a release that pins no usable key fails here.
set -euo pipefail

CONF="${1:?usage: updater-signing.sh <tauri.conf.json>}"

fail() {
  echo "::error::$*" >&2
  exit 1
}

updater="$(jq -c '.plugins.updater // empty' "$CONF")"
if [ -z "$updater" ]; then
  echo "enabled=false"
  exit 0
fi

# Base64 over a minisign public key file: a comment line, then base64 of "Ed", an 8-byte key id and
# the 32-byte key.
is_minisign_pubkey() {
  local text key
  text="$(printf '%s' "$1" | base64 -d 2>/dev/null)" || return 1
  [[ "$(sed -n 1p <<<"$text")" == "untrusted comment: "* ]] || return 1
  key="$(sed -n 2p <<<"$text" | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n')" || return 1
  [ "${#key}" -eq 84 ] && [ "${key:0:4}" = 4564 ]
}

pubkey="$(jq -r '.pubkey // empty' <<<"$updater")"
is_minisign_pubkey "$pubkey" ||
  fail "plugins.updater.pubkey in $CONF is not a minisign public key: pin the one \`cargo tauri signer generate\` printed"

echo "enabled=true"
echo "pubkey=$pubkey"
