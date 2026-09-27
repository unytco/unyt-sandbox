#!/usr/bin/env bash
# Whether this release signs its updates, as $GITHUB_OUTPUT lines:
#   updater-signing.sh <tauri.conf.json>      prints  enabled=true|false  [pubkey=<key>]
# Env: HAS_SIGNING_KEY, "true" when the TAURI_SIGNING_PRIVATE_KEY secret is set.
#
# An app with no updater config releases unsigned. One with it updates in-app only to a release
# signed with its pinned key, so a release that cannot sign fails here.
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

pubkey="$(jq -r '.pubkey // empty' <<<"$updater")"
decoded="$(printf '%s' "$pubkey" | base64 -d 2>/dev/null || true)"
case "$decoded" in
  "untrusted comment: minisign public key"*) ;;
  *) fail "plugins.updater.pubkey in $CONF is not a minisign public key: pin the one \`cargo tauri signer generate\` printed" ;;
esac
[ "${HAS_SIGNING_KEY:-}" = true ] ||
  fail "$CONF pins an updater public key but the TAURI_SIGNING_PRIVATE_KEY secret is not set"

echo "enabled=true"
echo "pubkey=$pubkey"
