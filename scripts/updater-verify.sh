#!/usr/bin/env bash
# Sourced by the release scripts, never run. signed_fields needs minisign on PATH.

fail() {
  echo "::error::$*" >&2
  exit 1
}

sha256() { sha256sum <"$1" | cut -d' ' -f1; } # <file>

# Each installer the updater runs from: the `<os>-<arch>-<installer>` key the updater plugin looks up
# for the running bundle, and the end of the name its asset is published under. release_asset in the
# app's src-tauri/src/updater.rs holds the same table, and updater-asset-names.sh fails a release
# where the two differ.
updater_assets() {
  printf '%s\t%s\n' \
    linux-x86_64-deb amd64_linux.deb \
    linux-x86_64-appimage amd64_linux.AppImage \
    darwin-aarch64-app aarch64_darwin.app.tar.gz \
    darwin-x86_64-app x64_darwin.app.tar.gz \
    windows-x86_64-msi x64_windows.msi \
    windows-x86_64-nsis x64_windows.exe
}

# The trusted comment of <dir>/<name>.sig, one field per line, once it verifies <dir>/<name> with
# <pubkey>, the base64 public key the app pins, and names <version>. -H refuses minisign's legacy mode,
# as the app does: a genuine signature relabelled as legacy verifies the artifact's 64 byte hash as if
# it were the file.
signed_fields() { # <dir> <name> <pubkey> <version>
  local verified fields
  printf '%s' "$3" | base64 -d >/dev/null 2>&1 || fail "the pinned public key is not base64"
  [ -f "$1/$2" ] || fail "$2, which $2.sig signs, is not on the release"
  base64 -d <"$1/$2.sig" >/dev/null 2>&1 || fail "$2.sig is not base64"
  verified="$(minisign -VHm "$1/$2" -x <(base64 -d <"$1/$2.sig") \
    -p <(printf '%s' "$3" | base64 -d) 2>&1)" ||
    fail "$2.sig does not verify $2 with the key the app pins: $(tr '\n' ' ' <<<"$verified")"
  fields="$(sed -n 's/^Trusted comment: //p' <<<"$verified" | tr '\t' '\n')"
  [ "$(sed -n 's/^version://p' <<<"$fields")" = "$4" ] ||
    fail "$2.sig is not signed for $4, so the app would refuse it"
  echo "$fields"
}
