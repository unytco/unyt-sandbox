#!/usr/bin/env bash
# Download one asset of a release into <out-dir> and print its path.
#
#   download-release-asset.sh <release-id-or-tag> <asset-name-suffix> <out-dir>
#   e.g. download-release-asset.sh 368727714 _default-arc_amd64_linux.deb ./out
#        download-release-asset.sh v0.100.0   _default-arc_amd64_linux.deb ./out
#
# Env: GH_TOKEN, UNYT_SMOKE_REPO (default unytco/unyt-sandbox). A draft release
# is readable only with a token that can write, which no smoke job holds, so
# UNYT_SMOKE_FROM names a directory to take the asset from instead: the release
# run's own builds, as download-artifact left them.
set -euo pipefail

REF="${1:?usage: download-release-asset.sh <release-id-or-tag> <asset-suffix> <out-dir>}"
SUFFIX="${2:?asset name suffix required (e.g. _default-arc_amd64_linux.deb)}"
OUT_DIR="${3:?output directory required}"
REPO="${UNYT_SMOKE_REPO:-${GITHUB_REPOSITORY:-unytco/unyt-sandbox}}"

if [ -n "${UNYT_SMOKE_FROM:-}" ]; then
  shopt -s nullglob
  found=("$UNYT_SMOKE_FROM"/*"$SUFFIX")
  if [ "${#found[@]}" != 1 ]; then
    echo "::error::${#found[@]} of the builds in $UNYT_SMOKE_FROM end in '$SUFFIX'. Builds present:" >&2
    ls "$UNYT_SMOKE_FROM" >&2 || true
    exit 1
  fi
  mkdir -p "$OUT_DIR"
  cp "${found[0]}" "$OUT_DIR/"
  echo "$OUT_DIR/$(basename "${found[0]}")"
  exit 0
fi

command -v gh >/dev/null || { echo "::error::gh CLI not found" >&2; exit 1; }

# A tag needs resolving to an id; a bare number already is one.
if [[ "$REF" =~ ^[0-9]+$ ]]; then
  release_id="$REF"
else
  release_id="$(gh api "repos/$REPO/releases?per_page=100" --paginate \
    --jq "[.[] | select(.tag_name == \"$REF\") | .id] | first // empty")"
  if [ -z "$release_id" ]; then
    echo "::error::no published release tagged '$REF' in $REPO: a draft is smoked by the run that made it" >&2
    exit 1
  fi
fi

# Assets are matched by SUFFIX so the caller never has to know the version: the
# release names them unyt_<version>_Unyt_<arc>-arc_<arch>_<platform><ext>.
matches="$(gh api "repos/$REPO/releases/$release_id" \
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
gh api -H "Accept: application/octet-stream" "repos/$REPO/releases/assets/$asset_id" >"$out"

# A failed API call still exits 0 into the redirect and leaves a JSON error blob
# on disk, which would then fail much later as a corrupt package — compare the
# byte count the API declared instead.
got_size="$(stat -c %s "$out" 2>/dev/null || stat -f %z "$out")"
if [ "$got_size" != "$asset_size" ]; then
  echo "::error::$asset_name downloaded as $got_size bytes, expected $asset_size" >&2
  head -c 400 "$out" >&2 || true
  exit 1
fi

echo "$out"
