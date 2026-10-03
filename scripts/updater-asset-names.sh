#!/usr/bin/env bash
# Fails unless the app's asset name table equals the one this pipeline signs and publishes under:
#   updater-asset-names.sh <updater.rs>
# <updater.rs> is the app's src-tauri/src/updater.rs. An app whose table differs refuses every update
# this release offers it.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

RS="${1:?usage: updater-asset-names.sh <updater.rs>}"

# The match arms of release_asset, as updater_assets rows: the plugin's installer key is the
# BundleType's name in lower case.
app="$(sed -n '/fn release_asset(/,/=> return None/p' "$RS" |
  sed -n 's/^ *("\([^"]*\)", BundleType::\([A-Za-z]*\)) => "\([^"]*\)",$/\1-\2	\3/p' |
  awk -F'\t' '{ print tolower($1) "\t" $2 }' | sort)"
[ -n "$app" ] || fail "$RS has no release_asset table, so this pipeline cannot know the names that app accepts"
mismatch="$(diff <(updater_assets | sort) <(echo "$app"))" ||
  fail "the asset names in $RS differ from updater_assets in updater-verify.sh (< pipeline, > app): $(tr '\n' ' ' <<<"$mismatch")"
