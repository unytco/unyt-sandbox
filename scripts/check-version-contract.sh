#!/usr/bin/env bash
# Assert the three version strings agree, then echo the canonical version to stdout.
#
# The app's src-tauri package version is the SOURCE OF TRUTH: it becomes CARGO_PKG_VERSION →
# get_version() → app_id and the fallback network seed, i.e. the string that decides which chains
# a binary reattaches to. A pushed tag or a tauri.conf.json that disagrees with it must fail the
# release before any artifact is built, so the tag-derived release kind (release-patterns spec) is
# trustworthy.
#
# Usage:  check-version-contract.sh <git-tag>      e.g.  v0.93.0   or   v0.93.1-rc.2
# Exit 0 + echo the canonical version (e.g. "0.93.0") on agreement; non-zero + a reason on mismatch.
set -euo pipefail

TAG="${1:?usage: check-version-contract.sh <git-tag>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CARGO="$ROOT/unyt/src-tauri/Cargo.toml"
CONF="$ROOT/unyt/src-tauri/tauri.conf.json"

fail() { echo "version-contract: $*" >&2; exit 1; }

# The tag's release version: strip a leading v and any -rc.* / prerelease suffix (v0.93.1-rc.2 → 0.93.1).
tag_version="${TAG#v}"
tag_version="${tag_version%%-*}"

[ -f "$CARGO" ] || fail "missing $CARGO (is the unyt submodule checked out?)"
[ -f "$CONF" ] || fail "missing $CONF"

# The [package] version of src-tauri/Cargo.toml — the source of truth. Any '[...]' header resets the
# section flag, so a version key under some other table can never be mistaken for it.
cargo_version="$(awk -F'"' '
  /^\[/ { in_pkg = ($0 ~ /^\[package\]/) }
  in_pkg && /^[[:space:]]*version[[:space:]]*=/ { print $2; exit }
' "$CARGO")"
conf_version="$(jq -r '.version' "$CONF")"

[ -n "$cargo_version" ] || fail "could not read [package] version from $CARGO"
{ [ -n "$conf_version" ] && [ "$conf_version" != "null" ]; } || fail "could not read .version from $CONF"

[ "$tag_version" = "$cargo_version" ] ||
  fail "tag $TAG (release version $tag_version) disagrees with src-tauri Cargo.toml version $cargo_version"
[ "$conf_version" = "$cargo_version" ] ||
  fail "tauri.conf.json version $conf_version disagrees with src-tauri Cargo.toml version $cargo_version"

echo "$cargo_version"
