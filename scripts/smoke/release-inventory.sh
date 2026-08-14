#!/usr/bin/env bash
# What is actually on a release, as $GITHUB_OUTPUT lines:
#   release-inventory.sh <release-id-or-tag>
# Lanes gate on these, so a platform whose build failed skips instead of running
# checks that all report "the file isn't there".
# Env: GH_TOKEN, UNYT_SMOKE_REPO. UNYT_SMOKE_ASSETS (newline list of names)
# answers from itself instead of the API — how test-oracle.sh drives this.
set -euo pipefail

REF="${1:?usage: release-inventory.sh <release-id-or-tag>}"
REPO="${UNYT_SMOKE_REPO:-${GITHUB_REPOSITORY:-unytco/unyt-sandbox}}"

# Keep these in lockstep with the suffixes the lanes pass to
# download-release-asset.sh; a typo here silently skips a lane forever, which is
# the failure this whole file exists to prevent.
DEB_SUFFIX="linux.deb"
APPIMAGE_SUFFIX="linux.AppImage"
EXE_SUFFIX="x64_windows.exe"
MSI_SUFFIX="x64_windows.msi"

# runner<TAB>arch<TAB>asset-suffix — the macOS matrix, filtered below to the DMGs
# that exist. Each arch needs its own runner: a check runs the bundle it just
# downloaded.
MACOS_ROWS="macos-15	aarch64	aarch64_darwin.dmg
macos-15-intel	x86_64	x64_darwin.dmg"

if [ -n "${UNYT_SMOKE_ASSETS+set}" ]; then
  assets="$UNYT_SMOKE_ASSETS"
else
  command -v gh >/dev/null || { echo "::error::gh CLI not found" >&2; exit 1; }
  if [[ "$REF" =~ ^[0-9]+$ ]]; then
    release_id="$REF"
  else
    release_id="$(gh api "repos/$REPO/releases?per_page=100" --paginate \
      --jq "[.[] | select(.tag_name == \"$REF\") | .id] | first // empty")"
    if [ -z "$release_id" ]; then
      echo "::error::no release tagged '$REF' in $REPO (drafts included — check the token's access)" >&2
      exit 1
    fi
  fi
  assets="$(gh api "repos/$REPO/releases/$release_id" --jq '.assets[].name')"
fi

has() { printf '%s\n' "$assets" | grep -qE "$1\$" && echo true || echo false; }

deb="$(has "$DEB_SUFFIX")"
appimage="$(has "$APPIMAGE_SUFFIX")"
exe="$(has "$EXE_SUFFIX")"
msi="$(has "$MSI_SUFFIX")"

dmgs="["
while IFS=$'\t' read -r runner arch suffix; do
  [ -n "$runner" ] || continue
  [ "$(has "$suffix")" = true ] || continue
  [ "$dmgs" = "[" ] || dmgs="$dmgs,"
  dmgs="$dmgs{\"runner\":\"$runner\",\"arch\":\"$arch\",\"asset\":\"$suffix\"}"
done <<<"$MACOS_ROWS"
dmgs="$dmgs]"

{
  echo "deb=$deb"
  echo "appimage=$appimage"
  echo "exe=$exe"
  echo "msi=$msi"
  echo "dmgs=$dmgs"
} | tee /dev/stderr

# A release with NOTHING on it is a broken release, not an empty one — say so
# rather than skipping every lane and leaving a green run that smoked nothing.
if [ "$deb$appimage$exe$msi$dmgs" = "falsefalsefalsefalse[]" ]; then
  echo "::error::release '$REF' carries none of the installers this suite knows how to smoke — every lane would skip and the run would pass having checked nothing"
  exit 1
fi
