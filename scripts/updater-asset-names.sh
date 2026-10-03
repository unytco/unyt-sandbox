#!/usr/bin/env bash
# Fails unless release_asset in the app names each asset as this pipeline signs and publishes it:
#   updater-asset-names.sh <updater.rs>
# <updater.rs> is the app's src-tauri/src/updater.rs. An app that names an asset otherwise refuses
# every update this release offers it.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

RS="${1:?usage: updater-asset-names.sh <updater.rs>}"

# assetNamePattern as a format! string, where a row names [arch]_[platform][ext].
pattern="$(sed -n "/assetNamePattern: \${{\$/{n;s/^ *format('\(.*\)',\$/\1/p;}" "$here/../.github/workflows/release-tauri-app.yaml" |
  sed 's/\[version\]/{version}/; s/\[name\]/{product}/; s/{0}/{}/; s/\[arch\]_\[platform\]\[ext\]$/{platform}/')"
naming='fn release_asset(
    product: &str,
    version: &str,
    arc_factor: &str,
    target: &str,
    bundle: BundleType,
) -> Option<String> {
    let platform = match (target, bundle) {
        _ => return None,
    };
    Some(format!(
        "'"$pattern"'",
        arc(arc_factor)
    ))
}'
tokens() { tr '\n' ' ' | awk -F'"' -v OFS='"' '{ for (i = 1; i <= NF; i += 2) gsub(/[ \t]/, "", $i) } 1'; }

fn="$(sed -n '/fn release_asset(/,/^}/p' "$RS")"
row='^ *("\([^"]*\)", BundleType::\([A-Za-z]*\)) => "\([^"]*\)",$'
# Its rows, as updater_assets rows: the plugin's installer key is the BundleType's name in lower case.
app="$(sed -n "s/$row/\1-\2	\3/p" <<<"$fn" | awk -F'\t' '{ print tolower($1) "\t" $2 }' | sort)"
[ -n "$app" ] || fail "$RS has no release_asset table, so this pipeline cannot know the names that app accepts"
mismatch="$(diff <(updater_assets | sort) <(echo "$app"))" ||
  fail "the asset names in $RS differ from updater_assets in updater-verify.sh (< pipeline, > app): $(tr '\n' ' ' <<<"$mismatch")"
[ "$(sed "1,/=> return None,/{/$row/d;}" <<<"$fn" | tokens)" = "$(tokens <<<"$naming")" ] ||
  fail "release_asset in $RS builds its asset names otherwise than assetNamePattern in release-tauri-app.yaml"
