#!/usr/bin/env bash
# A signing key in $RUNNER_TEMP, which dies with the job, as $GITHUB_OUTPUT lines key=, password= and
# pubkey=:
#   throwaway-key.sh >>"$GITHUB_OUTPUT"
# Needs the signer that `npm ci --prefix scripts/tauri-signer` installs.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

password="$(openssl rand -hex 32)"
echo "::add-mask::$password" >&2
"$here/tauri-signer/node_modules/.bin/tauri" signer generate --ci -p "$password" -w "$RUNNER_TEMP/throwaway.key" >/dev/null
key="$(cat "$RUNNER_TEMP/throwaway.key")"
pubkey="$(cat "$RUNNER_TEMP/throwaway.key.pub")"
printf 'key=%s\npassword=%s\npubkey=%s\n' "$key" "$password" "$pubkey"
