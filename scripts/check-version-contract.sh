#!/usr/bin/env bash
# Prints the app's version, and fails unless the release tag, src-tauri/Cargo.toml's [package] version,
# tauri.conf.json and that package's Cargo.lock entry all carry it:
#   check-version-contract.sh <release tag>      e.g. v0.93.0 or v0.93.1-dev.2
# The package version is CARGO_PKG_VERSION, from which the app derives its app_id and fallback network
# seed, and so the chains a binary reattaches to.
set -euo pipefail

TAG="${1:?usage: check-version-contract.sh <release tag>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CARGO="$ROOT/unyt/src-tauri/Cargo.toml"
CONF="$ROOT/unyt/src-tauri/tauri.conf.json"
LOCK="$ROOT/unyt/Cargo.lock"

fail() { echo "version-contract: $*" >&2; exit 1; }

tag_version="${TAG#v}"

[ -f "$CARGO" ] || fail "missing $CARGO (is the unyt submodule checked out?)"
[ -f "$CONF" ] || fail "missing $CONF"
[ -f "$LOCK" ] || fail "missing $LOCK"

package_field() { # <key>
  awk -F'"' -v key="$1" '
    /^\[/ { in_pkg = ($0 ~ /^\[package\][[:space:]]*$/) }
    in_pkg && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { print $2; exit }
  ' "$CARGO"
}
cargo_version="$(package_field version)"
conf_version="$(jq -r '.version' "$CONF" | tr -d '\r')"
lock_version="$(awk -F'"' -v name="$(package_field name)" '
  /^\[\[package\]\]/ { ours = 0 }
  $1 == "name = " && $2 == name { ours = 1 }
  ours && $1 == "version = " { print $2; exit }
' "$LOCK")"

[ -n "$cargo_version" ] || fail "could not read [package] version from $CARGO"
{ [ -n "$conf_version" ] && [ "$conf_version" != "null" ]; } || fail "could not read .version from $CONF"

[ "$tag_version" = "$cargo_version" ] ||
  fail "tag $TAG (release version $tag_version) disagrees with src-tauri Cargo.toml version $cargo_version"
[ "$conf_version" = "$cargo_version" ] ||
  fail "tauri.conf.json version $conf_version disagrees with src-tauri Cargo.toml version $cargo_version"
[ "$lock_version" = "$cargo_version" ] ||
  fail "Cargo.lock has ${lock_version:-no} version for the app package, not src-tauri Cargo.toml's $cargo_version"

echo "$cargo_version"
