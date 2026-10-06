#!/usr/bin/env bash
# Writes the version a release tag names into the app checked out at unyt/: src-tauri/tauri.conf.json,
# src-tauri/Cargo.toml's [package] version, and that package's entry in the workspace Cargo.lock, so a
# --locked build takes it unchanged:
#   set-app-version.sh <release tag>      e.g. v0.110.0 or v0.110.0-dev.1
# The workspace version is left alone: the zomes and unyt_cli take theirs from it, and the zomes' wasm
# would change with it.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

TAG="${1:?usage: set-app-version.sh <release tag>}"
APP="$here/../unyt"
CONF="$APP/src-tauri/tauri.conf.json"
CARGO="$APP/src-tauri/Cargo.toml"
LOCK="$APP/Cargo.lock"
for file in "$CONF" "$CARGO" "$LOCK"; do [ -f "$file" ] || fail "no $file: is the app checked out?"; done
n='(0|[1-9][0-9]*)'
[[ "$TAG" =~ ^v($n\.$n\.$n(-dev\.$n)?)$ ]] || fail "tag $TAG is not vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-dev.N"
VERSION="${BASH_REMATCH[1]}"

# A Windows checkout ends its lines with a carriage return, which each edit keeps.
section_value() { # <section header> <key> <file>: the first <key> = "..." under <section header>
  awk -F'"' -v section="$1" -v key="$2" '
    { line = $0; sub(/\r$/, "", line) }
    line ~ /^\[/ { inside = (line == section) }
    inside && line ~ "^[[:space:]]*" key "[[:space:]]*=" { print $2; exit }' "$3"
}
name="$(section_value '[package]' name "$CARGO")"
[ -n "$name" ] || fail "$CARGO names no [package]"

replace() { # <file> <awk program>: rewrites <file> through the program, which exits 3 unless it edited one line
  local out rc=0
  out="$(mktemp)"
  awk -v version="$VERSION" -v name="$name" "$2" "$1" >"$out" || rc=$?
  [ "$rc" -eq 0 ] || { rm -f "$out"; [ "$rc" -eq 3 ] || fail "cannot read $1"; return 3; }
  cat "$out" >"$1" || { rm -f "$out"; fail "cannot write $1"; }
  rm -f "$out"
}
replace "$CARGO" '
  { line = $0; cr = sub(/\r$/, "", line) ? "\r" : "" }
  line ~ /^\[/ { inside = (line == "[package]") }
  inside && !done && line ~ /^[[:space:]]*version[[:space:]]*=/ { print "version = \"" version "\"" cr; done = 1; next }
  { print }
  END { if (!done) exit 3 }' || fail "$CARGO has no [package] version"
replace "$LOCK" '
  { line = $0; cr = sub(/\r$/, "", line) ? "\r" : "" }
  line == "[[package]]" { ours = 0 }
  line == "name = \"" name "\"" { ours = 1; print; next }
  ours && line ~ /^version = / { print "version = \"" version "\"" cr; ours = 0; hits++; next }
  { print }
  END { if (hits != 1) exit 3 }' || fail "$LOCK has no one entry for $name"
conf="$(jq --arg version "$VERSION" '.version = $version' "$CONF")"
printf '%s\n' "$conf" >"$CONF" || fail "cannot write $CONF"
