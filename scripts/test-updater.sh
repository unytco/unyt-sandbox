#!/usr/bin/env bash
# updater-signing.sh, updater-provenance.sh, updater-sign.sh and updater-manifests.sh against fixtures
# signed with throwaway keys. Needs minisign on PATH (install-minisign.sh), and npx for the Tauri signer.
set -euo pipefail

command -v minisign >/dev/null || {
  echo "minisign not found: scripts/install-minisign.sh puts the pinned one on PATH" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
export GITHUB_RUN_ATTEMPT=1
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
    -t "${4:-timestamp:1	file:$name	version:1.2.3}" >/dev/null
  base64 -w0 <"$tmp/sig" >"$1/$name.sig"
}
release() { # <dir>: also writes <dir>.provenance, what its builds recorded publishing
  mkdir -p "$1"
  local arc t
  for arc in default zero; do
    for t in $targets; do sign "$1" "$(asset "$arc" "${t#*:}")"; done
  done
  (cd "$1" && for sig in *.sig; do sha256sum "${sig%.sig}"; done) >"$1.provenance"
}
manifests() { # <asset-dir> <out-dir> [<pubkey>]
  mkdir -p "$2"
  env -u GITHUB_REPOSITORY bash "$here/updater-manifests.sh" v1.2.3 1.2.3 "${3:-$(pubkey ours)}" "$1" "$2"
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

# Stands in for npx, so a refusal is proven to come before anything is signed.
mkdir "$tmp/stub"
printf '#!/bin/sh\ntouch "$0.called"\nexit 1\n' >"$tmp/stub/npx"
chmod +x "$tmp/stub/npx"
signs_nothing() { # <error text> <asset-dir> [<started>]
  rm -f "$tmp/stub/npx.called"
  refuses "$1" env PATH="$tmp/stub:$PATH" \
    bash "$here/updater-sign.sh" 1.2.3 "$(pubkey ours)" "$2" "${3-0}" "$2.provenance" &&
    [ ! -e "$tmp/stub/npx.called" ]
}
case_with() { # <setup>: sets $dir to a new release with <setup> applied
  dir="$tmp/case$((pass + fail))"
  release "$dir"
  "$1" "$dir"
}
refused() { # <description> <error text> <setup> [signing]
  local what="$1" want="$2" dir
  case_with "$3"
  check "$what" refuses "$want" manifests "$dir" "$dir.out"
  [ "${4:-}" != signing ] || check "$what, and nothing is signed" signs_nothing "$want" "$dir"
}
sign_refused() { # <description> <error text> <setup> [<started>]
  local dir
  case_with "$3"
  check "$1" signs_nothing "$2" "$dir" "${@:4}"
}
drop_sig() { rm "$1/$(asset zero x64_windows.msi).sig"; }
drop_artifact() { rm "$1/$(asset default x64_darwin.app.tar.gz)"; }
other_key() { sign "$1" "$(asset default amd64_linux.deb)" other; }
tampered() { printf 'x' >>"$1/$(asset zero amd64_linux.AppImage)"; }
swapped() { cp "$1/$(asset default amd64_linux.deb).sig" "$1/$(asset default amd64_linux.AppImage).sig"; }
stale() { sign "$1" "$(asset zero x64_windows.msi)" ours "timestamp:0	file:$(asset zero x64_windows.msi)	version:1.2.2"; }
unversioned() { sign "$1" "$(asset default x64_windows.exe)" ours "timestamp:0	file:$(asset default x64_windows.exe)"; }
doubled() { sign "$1" "unyt_1.2.3_Other.Name_default-arc_amd64_linux.deb"; }
legacy() {
  local name; name="$(asset default amd64_linux.AppImage)"
  minisign -S -l -s "$tmp/ours.key" -m "$1/$name" -x "$tmp/sig" -t "timestamp:0	file:$name	version:1.2.3" >/dev/null
  base64 -w0 <"$tmp/sig" >"$1/$name.sig"
}
garbled() { printf '*' >>"$1/$(asset zero amd64_linux.deb).sig"; }
published_as() { cp "$1" "$2" && cp "$1.sig" "$2.sig"; } # <signed artifact> <asset path>
built_as() { # <asset-dir> <bundler's file name> <asset>
  sign "$tmp" "$2"
  published_as "$tmp/$2" "$1/$3"
}
bundler_named() { built_as "$1" Unyt_1.2.3_amd64.AppImage "$(asset default amd64_linux.AppImage)"; }
deb_as_appimage() { built_as "$1" Unyt_1.2.3_amd64.deb "$(asset default amd64_linux.AppImage)"; }
exe_as_msi() { built_as "$1" Unyt_1.2.3_x64-setup.exe "$(asset zero x64_windows.msi)"; }
earlier_run() { sign "$1" "$(asset zero x64_windows.msi)" ours "timestamp:0	file:$(asset zero x64_windows.msi)	version:1.2.3"; }
other_arc() { published_as "$1/$(asset zero amd64_linux.AppImage)" "$1/$(asset default amd64_linux.AppImage)"; }
other_installer() { published_as "$1/$(asset default amd64_linux.deb)" "$1/$(asset default amd64_linux.AppImage)"; }
other_arch() { published_as "$1/$(asset zero aarch64_darwin.app.tar.gz)" "$1/$(asset zero x64_darwin.app.tar.gz)"; }
unrecorded() { grep -vF " $(asset zero x64_windows.exe)" "$1.provenance" >"$1.kept" && mv "$1.kept" "$1.provenance"; }
unpublished() { rm "$1/$(asset default aarch64_darwin.app.tar.gz)"{,.sig}; }
recorded_longer() { sed -i "s/ $(asset default amd64_linux.AppImage)\$/&.tar.gz/" "$1.provenance"; }
recorded_twice() { grep -F " $(asset default x64_windows.msi)" "$1.provenance" >"$1.twice" && cat "$1.twice" >>"$1.provenance"; }

refused "a missing signature fails rather than drop a platform" \
  "no zero-arc signature ending in x64_windows.msi.sig" drop_sig
refused "a signature whose artifact is not on the release fails" "is not on the release" \
  drop_artifact signing
refused "a signature by a key the app does not pin fails" "with the key the app pins" other_key signing
refused "an artifact changed after signing fails" "with the key the app pins" tampered signing
refused "a signature paired with another artifact fails" "with the key the app pins" swapped signing
refused "a signature for another version fails" "is not signed for 1.2.3" stale signing
refused "a signature that names no version fails" "is not signed for 1.2.3" unversioned signing
refused "two signatures for one platform fail" \
  "2 default-arc signatures end in amd64_linux.deb.sig" doubled
refused "a signature in minisign's legacy mode fails" "Legacy (non-prehashed) signature found" \
  legacy signing
refused "a signature that is not base64 fails" "is not base64" garbled signing
check "a pinned key that is not base64 fails the release" \
  refuses "the pinned public key is not base64" manifests "$tmp/full" "$tmp/badkey.out" "*"
refused "a signature under the bundler's name fails the manifests" "is signed for another file" \
  bundler_named
refused "a signature naming the other arc's asset fails the manifests" \
  "is signed for another file" other_arc
refused "a signature naming another installer's asset fails the manifests" \
  "is signed for another file" other_installer
unclaimed() { echo "$1 is not the build this run published under that name"; } # <asset>
sign_refused "a deb build under the AppImage's name is refused before signing" \
  "$(unclaimed "$(asset default amd64_linux.AppImage)")" deb_as_appimage
sign_refused "an exe build under the msi's name is refused before signing" \
  "$(unclaimed "$(asset zero x64_windows.msi)")" exe_as_msi
sign_refused "a zero-arc build and its signature under the default-arc name are refused before signing" \
  "$(unclaimed "$(asset default amd64_linux.AppImage)")" other_arc
sign_refused "an arm64 macOS build and its signature under the x64 name are refused before signing" \
  "$(unclaimed "$(asset zero x64_darwin.app.tar.gz)")" other_arch
sign_refused "an artifact no build recorded publishing is refused before signing" \
  "no build job of this run recorded publishing $(asset zero x64_windows.exe)" unrecorded
sign_refused "a record of a longer name does not vouch for the asset it contains" \
  "no build job of this run recorded publishing $(asset default amd64_linux.AppImage)" recorded_longer
sign_refused "a recorded asset missing from the release is refused before signing" \
  "$(asset default aarch64_darwin.app.tar.gz), which a build of this run published, is not on the release" \
  unpublished
sign_refused "an asset recorded twice is refused before signing" \
  "this run's builds published $(asset default x64_windows.msi) more than once" recorded_twice
sign_refused "an earlier run's build among this run's is refused before signing" \
  "$(asset zero x64_windows.msi).sig was signed before this run started" earlier_run 1
check "a run start that never reached the script is refused before signing" \
  signs_nothing "4: usage:" "$tmp/full" ""
rerun() { GITHUB_RUN_ATTEMPT=2 signs_nothing "$@"; }
check "a re-run of the release run is refused before signing" \
  rerun "attempt 2 of this run: only a run's first attempt signs" "$tmp/full"

mkdir -p "$tmp/unsigned"
check "signing a release with no signatures fails" \
  refuses "no signatures in" bash "$here/updater-sign.sh" 1.2.3 "$(pubkey ours)" "$tmp/unsigned" 0 /dev/null

# A release as tauri-action publishes it: the bundler signs both arc factors' builds under one file
# name, the upload renames them, and each build job records what it published.
tauri() { npx --yes @tauri-apps/cli@2.11.5 "$@"; }
tauri signer generate --ci -p test -w "$tmp/tauri.key" >/dev/null
with_key() { TAURI_SIGNING_PRIVATE_KEY="$(cat "$tmp/tauri.key")" TAURI_SIGNING_PRIVATE_KEY_PASSWORD=test "$@"; }
printf '{"productName": "Unyt", "version": "1.2.3"}' >"$tmp/tauri.conf.json"
# jq.exe as a Windows runner's Git Bash runs it.
mkdir "$tmp/windows"
printf '#!/bin/sh\n%s "$@" | sed "s/$/\\r/"\n' "$(command -v jq)" >"$tmp/windows/jq"
chmod +x "$tmp/windows/jq"
recorded() { # <runner os> <runner arch> <build args> <arc> <artifact path>...: what the job records
  local path="$PATH" os="$1" arch="$2" args="$3" arc="$4"
  shift 4
  if [ "$os" = Windows ]; then path="$tmp/windows:$PATH" && set -- "${@//\//\\}"; fi
  PATH="$path" RUNNER_OS="$os" RUNNER_ARCH="$arch" bash "$here/updater-provenance.sh" \
    "$tmp/tauri.conf.json" "$arc" "$args" "$(jq -nc '$ARGS.positional' --args "$@")"
}
build() { # <arc> <runner os> <runner arch> <build args> <bundler's path>[:<asset suffix>]...
  local arc="$1" os="$2" arch="$3" args="$4" spec path made=()
  shift 4
  for spec; do
    path="$tmp/target/$arc/${spec%%:*}"
    mkdir -p "$(dirname "$path")"
    printf 'the %s-arc %s build' "$arc" "${spec%%:*}" >"$path"
    made+=("$path")
    [ "$spec" != "${spec#*:}" ] || continue
    with_key tauri signer sign --app-version 1.2.3 "$path" >/dev/null
    published_as "$path" "$tmp/bundled/$(asset "$arc" "${spec#*:}")"
    made+=("$path.sig")
  done
  recorded "$os" "$arch" "$args" "$arc" "${made[@]}" >>"$tmp/bundled.provenance"
}
mkdir -p "$tmp/bundled"
started="$(date +%s)"
for arc in default zero; do
  build "$arc" macOS ARM64 "--target aarch64-apple-darwin" \
    aarch64-apple-darwin/release/bundle/dmg/Unyt_1.2.3_aarch64.dmg \
    aarch64-apple-darwin/release/bundle/macos/Unyt.app.tar.gz:aarch64_darwin.app.tar.gz
  build "$arc" macOS ARM64 "--target x86_64-apple-darwin" \
    x86_64-apple-darwin/release/bundle/dmg/Unyt_1.2.3_x64.dmg \
    x86_64-apple-darwin/release/bundle/macos/Unyt.app.tar.gz:x64_darwin.app.tar.gz
  build "$arc" Linux X64 "--bundles deb,appimage" \
    release/bundle/deb/Unyt_1.2.3_amd64.deb:amd64_linux.deb \
    release/bundle/appimage/Unyt_1.2.3_amd64.AppImage:amd64_linux.AppImage
  build "$arc" Windows X64 "" \
    release/bundle/msi/Unyt_1.2.3_x64_en-US.msi:x64_windows.msi \
    release/bundle/nsis/Unyt_1.2.3_x64-setup.exe:x64_windows.exe
done
check "a build on a runner with no known asset name records nothing" \
  refuses 'no asset name for a macOS ARM64 build with args ""' recorded macOS ARM64 "" default
for os in Linux Windows; do
  check "an arm64 $os build records nothing" \
    refuses "no asset name for a $os ARM64 build" recorded "$os" ARM64 "" default
done
printf '{"productName": "Unyt (Sandbox)", "version": "1.2.3"}' >"$tmp/renamed.conf.json"
check "a product name GitHub renames is recorded as the release names it" \
  test "$(RUNNER_OS=Linux RUNNER_ARCH=X64 bash "$here/updater-provenance.sh" "$tmp/renamed.conf.json" \
    default "" "[\"$tmp/target/default/release/bundle/deb/Unyt_1.2.3_amd64.deb.sig\"]" | cut -d' ' -f3)" \
  = unyt_1.2.3_Unyt.Sandbox._default-arc_amd64_linux.deb
printf 'an rpm' >"$tmp/target/x.rpm"
cp "$tmp/target/x.rpm" "$tmp/target/x.rpm.sig"
check "a build that signed an artifact the updater never installs records nothing" \
  refuses "x.rpm is signed, but no updater installs it" \
  recorded Linux X64 "" default "$tmp/target/x.rpm" "$tmp/target/x.rpm.sig"
check "a release as tauri-action publishes it fails" refuses "is signed for another file" \
  manifests "$tmp/bundled" "$tmp/bundled.out" "$(cat "$tmp/tauri.key.pub")"
cp -r "$tmp/bundled" "$tmp/relabelled"
published_as "$tmp/relabelled/$(asset zero amd64_linux.AppImage)" "$tmp/relabelled/$(asset default amd64_linux.AppImage)"
cp -r "$tmp/relabelled" "$tmp/relabelled.built"
signed_and_published() { # <asset-dir> <pubkey>
  with_key bash "$here/updater-sign.sh" 1.2.3 "$2" "$1" "$started" "$tmp/bundled.provenance" &&
    manifests "$1" "$1.out" "$2"
}
check "signed by the Tauri signer under its asset names, it publishes its manifests" \
  signed_and_published "$tmp/bundled" "$(cat "$tmp/tauri.key.pub")"
check "signing again signs the signatures the first signing left under the asset names" \
  signed_and_published "$tmp/bundled" "$(cat "$tmp/tauri.key.pub")"
check "a zero-arc build relabelled as the default-arc one publishes nothing" \
  refuses "$(unclaimed "$(asset default amd64_linux.AppImage)")" \
  signed_and_published "$tmp/relabelled" "$(cat "$tmp/tauri.key.pub")"
check "and every signature is left as its build made it" diff -r "$tmp/relabelled.built" "$tmp/relabelled"
check "nor do the manifests publish the relabelled release" refuses "is signed for another file" \
  manifests "$tmp/relabelled" "$tmp/relabelled.out" "$(cat "$tmp/tauri.key.pub")"

echo "updater scripts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
