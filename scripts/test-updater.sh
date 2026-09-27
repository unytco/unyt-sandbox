#!/usr/bin/env bash
# updater-signing.sh and updater-manifests.sh against fixtures.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

check() { # <description> <command...>
  local what="$1"
  shift
  if "$@"; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    echo "FAIL  $what" >&2
  fi
}
refuses() { # <error text> <command...>
  local want="$1" out
  shift
  if out="$("$@" 2>&1)"; then return 1; fi
  [[ "$out" == *"$want"* ]]
}

bytes() { # <hex>
  printf '%b' "$(printf '%s' "$1" | sed 's/../\\x&/g')"
}
zeros() { head -c "$1" /dev/zero; }
# A minisign public key and signature with key id <hex>, base64 over the file as Tauri stores both.
# Only the key id and the trusted comment are real: the scripts never verify the key bytes.
pubkey() {
  printf 'untrusted comment: minisign public key: %s\n%s\n' "$1" \
    "$({ printf Ed; bytes "$1"; zeros 32; } | base64 -w0)" | base64 -w0
}
signature() { # <key id> <trusted comment>
  printf 'untrusted comment: signature\n%s\ntrusted comment: %s\n%s\n' \
    "$({ printf ED; bytes "$1"; zeros 64; } | base64 -w0)" "$2" "$(zeros 64 | base64 -w0)" | base64 -w0
}

KEY=0123456789abcdef
OTHER=fedcba9876543210

conf() { printf '%s' "$1" >"$tmp/conf.json" && echo "$tmp/conf.json"; }
gate() { bash "$here/updater-signing.sh" "$@"; }

check "an app with no updater releases unsigned" \
  test "$(gate "$(conf '{"plugins":{}}')")" = "enabled=false"
check "a config that does not parse fails the release" \
  refuses "parse error" bash "$here/updater-signing.sh" "$(conf '{"plugins":')"
check "an updater with no key fails the release" \
  refuses "is not a minisign public key" \
  env HAS_SIGNING_KEY=true bash "$here/updater-signing.sh" "$(conf '{"plugins":{"updater":{"pubkey":""}}}')"
check "a placeholder public key fails the release" \
  refuses "is not a minisign public key" \
  env HAS_SIGNING_KEY=true bash "$here/updater-signing.sh" "$(conf '{"plugins":{"updater":{"pubkey":"REPLACE_ME"}}}')"
real_conf="$(conf "{\"plugins\":{\"updater\":{\"pubkey\":\"$(pubkey $KEY)\"}}}")"
check "a pinned key with no signing secret fails the release" \
  refuses "secret is not set" env -u HAS_SIGNING_KEY bash "$here/updater-signing.sh" "$real_conf"
check "a pinned key whose secret CI reports absent fails the release" \
  refuses "secret is not set" env HAS_SIGNING_KEY=false bash "$here/updater-signing.sh" "$real_conf"
check "a pinned key with its secret signs, and hands the key on" \
  test "$(HAS_SIGNING_KEY=true gate "$real_conf")" = "$(printf 'enabled=true\npubkey=%s' "$(pubkey $KEY)")"

targets="linux-x86_64-deb:amd64_linux.deb linux-x86_64-appimage:amd64_linux.AppImage
darwin-aarch64-app:aarch64_darwin.app.tar.gz darwin-x86_64-app:x64_darwin.app.tar.gz
windows-x86_64-msi:x64_windows.msi windows-x86_64-nsis:x64_windows.exe"
asset() { echo "unyt_1.2.3_Unyt.Sandbox_$1-arc_$2"; } # <arc> <suffix>
# Each signature names its asset, so a manifest pairing one platform with another's is caught.
sign() { signature "${3:-$KEY}" "timestamp:0	file:$2	version:${4:-1.2.3}" >"$1/$2.sig"; }
release() { # <dir>
  mkdir -p "$1"
  local arc t
  for arc in default zero; do
    for t in $targets; do sign "$1" "$(asset "$arc" "${t#*:}")"; done
  done
}
manifests() { # <sig-dir> <out-dir>
  mkdir -p "$2"
  env -u GITHUB_REPOSITORY bash "$here/updater-manifests.sh" v1.2.3 1.2.3 "$(pubkey $KEY)" "$1" "$2"
}

release "$tmp/full"
check "a full release writes both manifests" manifests "$tmp/full" "$tmp/out"
for arc in default zero; do
  m="$tmp/out/updater-$arc-arc.json"
  check "the $arc-arc manifest names its version" test "$(jq -r .version "$m")" = "1.2.3"
  check "the $arc-arc manifest carries every installer the app can run from" \
    test "$(jq -r '.platforms | keys | length' "$m")" = 6
  for t in $targets; do
    name="$(asset "$arc" "${t#*:}")"
    check "$arc-arc ${t%%:*} points at its own asset on the release" \
      test "$(jq -r --arg t "${t%%:*}" '.platforms[$t].url' "$m")" = \
      "https://github.com/unytco/unyt-sandbox/releases/download/v1.2.3/$name"
    check "$arc-arc ${t%%:*} carries that asset's signature" \
      test "$(jq -r --arg t "${t%%:*}" '.platforms[$t].signature' "$m")" = "$(cat "$tmp/full/$name.sig")"
  done
done

release "$tmp/partial"
rm "$tmp/partial/$(asset zero x64_windows.msi).sig"
check "a missing signature fails rather than drop a platform" \
  refuses "no zero-arc signature ending in x64_windows.msi.sig" manifests "$tmp/partial" "$tmp/o1"

release "$tmp/rekeyed"
sign "$tmp/rekeyed" "$(asset default amd64_linux.deb)" $OTHER
check "a signature by a key the app does not pin fails" \
  refuses "is not signed by the key the app pins" manifests "$tmp/rekeyed" "$tmp/o2"

release "$tmp/stale"
sign "$tmp/stale" "$(asset zero x64_windows.msi)" $KEY 1.2.2
check "a signature for another version fails" \
  refuses "is not signed for 1.2.3" manifests "$tmp/stale" "$tmp/o3"

release "$tmp/unversioned"
signature $KEY "timestamp:0	file:x" >"$tmp/unversioned/$(asset default x64_windows.exe).sig"
check "a signature that names no version fails" \
  refuses "is not signed for 1.2.3" manifests "$tmp/unversioned" "$tmp/o4"

release "$tmp/doubled"
sign "$tmp/doubled" "unyt_1.2.3_Other.Name_default-arc_amd64_linux.deb"
check "two signatures for one platform fail" \
  refuses "2 default-arc signatures end in amd64_linux.deb.sig" manifests "$tmp/doubled" "$tmp/o5"

echo "updater scripts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
