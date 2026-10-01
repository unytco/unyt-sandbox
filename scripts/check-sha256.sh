#!/usr/bin/env bash
# Fails unless a file's sha256 is the one given:
#   check-sha256.sh <file> <sha256>
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

usage="usage: check-sha256.sh <file> <sha256>"
FILE="${1:?$usage}"
WANT="${2:?$usage}"

got="$(sha256 "$FILE")"
[ "$got" = "$WANT" ] || fail "$FILE has sha256 $got, not the $WANT it was published with"
