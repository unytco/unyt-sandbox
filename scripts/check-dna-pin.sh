#!/usr/bin/env bash
# Fails unless the DNA stage 1 built in <app-dir> has the hashes the pinned app commits:
#   check-dna-pin.sh <app-dir> [--committed]
# Run where `make package` left its build. Needs nix: the app's check runs in its nix shell. With
# --committed, only whether the app commits its hashes and the check, before any build.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

APP="${1:?usage: check-dna-pin.sh <app-dir> [--committed]}"
for file in scripts/check-dna-hashes.sh dnas/alliance/build-hashes; do
  [ -f "$APP/$file" ] || fail "the pinned app has no $file, so nothing holds this release's DNA to the hashes its source commits"
done
[ "${2:-}" != --committed ] || exit 0
cd "$APP"
nix develop --no-update-lock-file --accept-flake-config --command bash scripts/check-dna-hashes.sh
