#!/usr/bin/env bash
# updater-signing.sh and updater-manifests.sh against fixtures signed with throwaway minisign keys.
# Needs minisign on PATH (install-minisign.sh).
set -euo pipefail

command -v minisign >/dev/null || {
  echo "minisign not found: scripts/install-minisign.sh puts the pinned one on PATH" >&2
  exit 1
}

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

# Tauri stores a public key and a signature as base64 over the minisign file.
for k in ours other; do
  minisign -G -W -p "$tmp/$k.pub" -s "$tmp/$k.key" >/dev/null
done
pubkey() { base64 -w0 <"$tmp/$1.pub"; }
b64() { printf '%s' "$1" | base64 -w0; }

conf() { printf '%s' "$1" >"$tmp/conf.json" && echo "$tmp/conf.json"; }
gate() { bash "$here/updater-signing.sh" "$@"; }
gate_refuses() { # <description> <pubkey>
  check "$1" refuses "is not a minisign public key" \
    env HAS_SIGNING_KEY=true bash "$here/updater-signing.sh" \
    "$(conf "{\"plugins\":{\"updater\":{\"pubkey\":\"$2\"}}}")"
}

check "an app with no updater releases unsigned" \
  test "$(gate "$(conf '{"plugins":{}}')")" = "enabled=false"
check "a config that does not parse fails the release" \
  refuses "parse error" bash "$here/updater-signing.sh" "$(conf '{"plugins":')"
gate_refuses "an updater with no key fails the release" ""
gate_refuses "a placeholder public key fails the release" "REPLACE_ME"
gate_refuses "a key that is only its comment line fails the release" \
  "$(b64 'untrusted comment: minisign public key')"
key_line="$(sed -n 2p "$tmp/ours.pub")"
gate_refuses "a key without its comment line fails the release" \
  "$(b64 "$key_line
$key_line")"
gate_refuses "a key line of the wrong length fails the release" \
  "$(b64 "untrusted comment: minisign public key
${key_line:0:40}")"
gate_refuses "a key for another algorithm fails the release" \
  "$(b64 "untrusted comment: minisign public key
$({ printf XX; printf '%s' "$key_line" | base64 -d | tail -c +3; } | base64 -w0)")"
real_conf="$(conf "{\"plugins\":{\"updater\":{\"pubkey\":\"$(pubkey ours)\"}}}")"
check "a pinned key with no signing secret fails the release" \
  refuses "secret is not set" env -u HAS_SIGNING_KEY bash "$here/updater-signing.sh" "$real_conf"
check "a pinned key whose secret CI reports absent fails the release" \
  refuses "secret is not set" env HAS_SIGNING_KEY=false bash "$here/updater-signing.sh" "$real_conf"
check "a pinned key with its secret signs, and hands the key on" \
  test "$(HAS_SIGNING_KEY=true gate "$real_conf")" = "$(printf 'enabled=true\npubkey=%s' "$(pubkey ours)")"

targets="linux-x86_64-deb:amd64_linux.deb linux-x86_64-appimage:amd64_linux.AppImage
darwin-aarch64-app:aarch64_darwin.app.tar.gz darwin-x86_64-app:x64_darwin.app.tar.gz
windows-x86_64-msi:x64_windows.msi windows-x86_64-nsis:x64_windows.exe"
asset() { echo "unyt_1.2.3_Unyt_$1-arc_$2"; } # <arc> <suffix>
sign() { # <dir> <asset> [<key> [<trusted comment>]]
  local name="$2"
  [ -f "$1/$name" ] || printf 'the %s artifact' "$name" >"$1/$name"
  minisign -S -s "$tmp/${3:-ours}.key" -m "$1/$name" -x "$tmp/sig" \
    -t "${4:-timestamp:0	file:$name	version:1.2.3}" >/dev/null
  base64 -w0 <"$tmp/sig" >"$1/$name.sig"
}
release() { # <dir>
  mkdir -p "$1"
  local arc t
  for arc in default zero; do
    for t in $targets; do sign "$1" "$(asset "$arc" "${t#*:}")"; done
  done
}
manifests() { # <asset-dir> <out-dir>
  mkdir -p "$2"
  env -u GITHUB_REPOSITORY bash "$here/updater-manifests.sh" v1.2.3 1.2.3 "$(pubkey ours)" "$1" "$2"
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

refused() { # <description> <error text> <setup...>
  local what="$1" want="$2" dir="$tmp/case$((pass + fail))"
  shift 2
  release "$dir"
  "$@" "$dir"
  check "$what" refuses "$want" manifests "$dir" "$dir.out"
}
drop_sig() { rm "$1/$(asset zero x64_windows.msi).sig"; }
drop_artifact() { rm "$1/$(asset default x64_darwin.app.tar.gz)"; }
other_key() { sign "$1" "$(asset default amd64_linux.deb)" other; }
tampered() { printf 'x' >>"$1/$(asset zero amd64_linux.AppImage)"; }
swapped() { cp "$1/$(asset default amd64_linux.deb).sig" "$1/$(asset default amd64_linux.AppImage).sig"; }
stale() { sign "$1" "$(asset zero x64_windows.msi)" ours "timestamp:0	file:x	version:1.2.2"; }
unversioned() { sign "$1" "$(asset default x64_windows.exe)" ours "timestamp:0	file:x"; }
doubled() { sign "$1" "unyt_1.2.3_Other.Name_default-arc_amd64_linux.deb"; }

refused "a missing signature fails rather than drop a platform" \
  "no zero-arc signature ending in x64_windows.msi.sig" drop_sig
refused "a signature whose artifact is not on the release fails" "is not on the release" drop_artifact
refused "a signature by a key the app does not pin fails" "with the key the app pins" other_key
refused "an artifact changed after signing fails" "with the key the app pins" tampered
refused "a signature paired with another artifact fails" "with the key the app pins" swapped
refused "a signature for another version fails" "is not signed for 1.2.3" stale
refused "a signature that names no version fails" "is not signed for 1.2.3" unversioned
refused "two signatures for one platform fail" \
  "2 default-arc signatures end in amd64_linux.deb.sig" doubled

echo "updater scripts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
