#!/usr/bin/env bash
# Download one asset of a release into <out-dir> and print its path.
#
#   download-release-asset.sh <release-id-or-tag> <asset-name-suffix> <out-dir>
#   e.g. download-release-asset.sh 368727714 _default-arc_amd64_linux.deb ./out
#        download-release-asset.sh v0.100.0   _default-arc_amd64_linux.deb ./out
#
# Env: GH_TOKEN (a PAT with repo scope, GIT_PAT in CI), UNYT_SMOKE_REPO (default
# unytco/unyt-sandbox).
set -euo pipefail

REF="${1:?usage: download-release-asset.sh <release-id-or-tag> <asset-suffix> <out-dir>}"
SUFFIX="${2:?asset name suffix required (e.g. _default-arc_amd64_linux.deb)}"
OUT_DIR="${3:?output directory required}"
REPO="${UNYT_SMOKE_REPO:-${GITHUB_REPOSITORY:-unytco/unyt-sandbox}}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$here/common.sh"

command -v gh >/dev/null || { echo "::error::gh CLI not found" >&2; exit 1; }

release_id="$(smoke_release_id "$REF" "$REPO")"

# Assets are matched by SUFFIX so the caller never has to know the version: the
# release names them unyt_<version>_Unyt_<arc>-arc_<arch>_<platform><ext>.
matches="$(smoke_gh_api "repos/$REPO/releases/$release_id" \
  --jq "[.assets[] | select(.name | endswith(\"$SUFFIX\"))] | .[] | \"\(.id)\t\(.name)\t\(.size)\"")"
match_count="$(printf '%s' "$matches" | grep -c . || true)"

if [ "$match_count" = "0" ]; then
  echo "::error::release $release_id ($REPO) has no asset ending in '$SUFFIX'. Assets present:" >&2
  gh api "repos/$REPO/releases/$release_id" --jq '.assets[].name' >&2 || true
  exit 1
fi
# Picking one of several silently would mean smoke-testing an arbitrary variant,
# and every release ships two Linux debs now: one per arc factor.
if [ "$match_count" != "1" ]; then
  echo "::error::'$SUFFIX' matches $match_count assets on release $release_id — narrow the suffix:" >&2
  printf '%s\n' "$matches" | cut -f2 >&2
  exit 1
fi

IFS=$'\t' read -r asset_id asset_name asset_size <<<"$matches"

mkdir -p "$OUT_DIR"
out="$OUT_DIR/$asset_name"
echo "Downloading $asset_name ($asset_size bytes) from release $release_id of $REPO" >&2
smoke_gh_api_to "$out" -H "Accept: application/octet-stream" "repos/$REPO/releases/assets/$asset_id"

got_size="$(stat -c %s "$out" 2>/dev/null || stat -f %z "$out")"
if [ "$got_size" != "$asset_size" ]; then
  echo "::error::$asset_name downloaded as $got_size bytes, expected $asset_size" >&2
  head -c 400 "$out" >&2 || true
  exit 1
fi

echo "$out"
