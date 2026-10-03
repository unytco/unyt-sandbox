#!/usr/bin/env bash
# updater-signing.sh, updater-asset-names.sh, updater-provenance.sh, updater-sign.sh,
# updater-manifests.sh and check-sha256.sh against fixtures signed with throwaway keys, and
# check-build-credentials.sh against the workflows. Needs minisign on PATH (install-minisign.sh), and
# node for the Tauri signer.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v minisign >/dev/null || {
  echo "minisign not found: scripts/install-minisign.sh puts the pinned one on PATH" >&2
  exit 1
}
[ -x "$here/tauri-signer/node_modules/.bin/tauri" ] || {
  echo "the Tauri signer is not installed: npm ci --prefix scripts/tauri-signer --ignore-scripts" >&2
  exit 1
}

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
    bash "$here/updater-signing.sh" "$(conf "{\"plugins\":{\"updater\":{\"pubkey\":\"$2\"}}}")"
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
check "a pinned key signs, and hands the key on" \
  test "$(gate "$(conf "{\"plugins\":{\"updater\":{\"pubkey\":\"$(pubkey ours)\"}}}")")" = \
  "$(printf 'enabled=true\npubkey=%s' "$(pubkey ours)")"

# release_asset as the app has it.
cat >"$tmp/updater.rs" <<'EOF'
/// Must match the name the release pipeline publishes and signs each asset under.
fn release_asset(
    product: &str,
    version: &str,
    arc_factor: &str,
    target: &str,
    bundle: BundleType,
) -> Option<String> {
    let platform = match (target, bundle) {
        ("linux-x86_64", BundleType::Deb) => "amd64_linux.deb",
        ("linux-x86_64", BundleType::AppImage) => "amd64_linux.AppImage",
        ("darwin-aarch64", BundleType::App) => "aarch64_darwin.app.tar.gz",
        ("darwin-x86_64", BundleType::App) => "x64_darwin.app.tar.gz",
        ("windows-x86_64", BundleType::Msi) => "x64_windows.msi",
        ("windows-x86_64", BundleType::Nsis) => "x64_windows.exe",
        _ => return None,
    };
    Some(format!(
        "unyt_{version}_{product}_{}-arc_{platform}",
        arc(arc_factor)
    ))
}
EOF
app_edit() { # <error text> <description> <sed edit of release_asset>
  sed "$3" "$tmp/updater.rs" >"$tmp/edited.rs"
  check "$2" refuses "$1" bash "$here/updater-asset-names.sh" "$tmp/edited.rs"
}
app_table() { app_edit "differ from updater_assets" "$@"; }
app_naming() { app_edit "builds its asset names otherwise" "$@"; }
check "an app that names its assets as the release does passes" \
  bash "$here/updater-asset-names.sh" "$tmp/updater.rs"
sed '/^ *Some(format!($/{N;N;N;s/\n */ /g}' "$tmp/updater.rs" >"$tmp/reflowed.rs"
check "an app that only lays its naming out otherwise passes" \
  bash "$here/updater-asset-names.sh" "$tmp/reflowed.rs"
app_naming "an app that orders the name otherwise fails the release" 's/{version}_{product}/{product}_{version}/'
app_naming "an app that puts a space in the name fails the release" 's/-arc_{platform}/-arc_ {platform}/'
app_naming "an app that names another version fails the release" \
  's/^ *Some(format!($/    let version = "0.0.0";\n&/'
app_naming "an app that never reaches a row fails the release" \
  '/_ => return None,/d; s/^ *("windows-x86_64", BundleType::Nsis)/        _ => return None,\n&/'
mkdir -p "$tmp/renamed"
cp "$here/updater-asset-names.sh" "$tmp/renamed/"
sed 's/"unyt_\$1_\$2_/"unyt_$2_$1_/' "$here/updater-verify.sh" >"$tmp/renamed/updater-verify.sh"
check "a release that renames its assets fails for an app that does not" \
  refuses "builds its asset names otherwise" bash "$tmp/renamed/updater-asset-names.sh" "$tmp/updater.rs"
app_table "an app expecting another nsis asset name fails the release" 's/x64_windows\.exe/x64_windows-setup.exe/'
app_table "an app that maps another bundle to an asset fails the release" 's/BundleType::Nsis/BundleType::Msi/'
app_table "an app with no row for a release asset fails the release" '/BundleType::Deb/d'
app_table "an app with a row the release publishes nothing for fails the release" \
  's/^\( *\)_ => return None,/\1("linux-x86_64", BundleType::Rpm) => "x86_64_linux.rpm",\n&/'
app_table "an app that looks an asset up under another target fails the release" 's/"darwin-x86_64"/"darwin-aarch64"/'
app_table "an app that looks an asset up under its target in another case fails the release" 's/"linux-x86_64"/"Linux-x86_64"/'
sed '/fn release_asset(/,/^}/d' "$tmp/updater.rs" >"$tmp/untabled.rs"
check "an app with no asset name table fails the release" \
  refuses "has no release_asset table" bash "$here/updater-asset-names.sh" "$tmp/untabled.rs"

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

# updater-sign.sh beside a stand-in for the signer, so a refusal is proven to come before anything is
# signed.
signer="$tmp/stub/tauri-signer/node_modules/.bin/tauri"
mkdir -p "$(dirname "$signer")"
cp "$here/updater-sign.sh" "$here/updater-verify.sh" "$tmp/stub/"
printf '#!/bin/sh\ntouch "$0.called"\nexit 1\n' >"$signer"
chmod +x "$signer"
signs_nothing() { # <error text> <asset-dir> [<started>]; env RELEASE_KEY, unset for a stand-in
  rm -f "$signer.called"
  refuses "$1" env TAURI_SIGNING_PRIVATE_KEY="${RELEASE_KEY-stand-in}" \
    bash "$tmp/stub/updater-sign.sh" 1.2.3 "$2" "${3-0}" "$2.provenance" &&
    [ ! -e "$signer.called" ]
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
untimed() { sign "$1" "$(asset zero amd64_linux.deb)" ours "file:$(asset zero amd64_linux.deb)	version:1.2.3"; }
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
refused "a signature by a key the app does not pin fails" "with the key the app pins" other_key
refused "an artifact changed after signing fails" "with the key the app pins" tampered
refused "a signature paired with another artifact fails" "with the key the app pins" swapped
refused "a signature for another version fails" "is not signed for 1.2.3" stale
refused "a signature that names no version fails" "is not signed for 1.2.3" unversioned
refused "two signatures for one platform fail" \
  "2 default-arc signatures end in amd64_linux.deb.sig" doubled
refused "a signature in minisign's legacy mode fails" "Legacy (non-prehashed) signature found" legacy
refused "a signature that is not base64 fails" "is not base64" garbled signing
sign_refused "a build signature that names no signing time is refused before signing" \
  "$(asset zero amd64_linux.deb).sig names no signing time" untimed
check "a pinned key that is not base64 fails the release" \
  refuses "the pinned public key is not base64" manifests "$tmp/full" "$tmp/badkey.out" "*"
refused "a signature under the bundler's name fails the manifests" "is signed for another file" \
  bundler_named
refused "a signature naming the other arc's asset fails the manifests" \
  "is signed for another file" other_arc
refused "a signature naming another installer's asset fails the manifests" \
  "is signed for another file" other_installer
unclaimed() { echo "$1 is not the build this run published under that name"; } # <asset>
sign_refused "an artifact changed after its build recorded it is refused before signing" \
  "$(unclaimed "$(asset zero amd64_linux.AppImage)")" tampered
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
  signs_nothing "3: usage:" "$tmp/full" ""
rerun() { GITHUB_RUN_ATTEMPT=2 signs_nothing "$@"; }
check "a re-run of the release run is refused before signing" \
  rerun "attempt 2 of this run: only a run's first attempt signs" "$tmp/full"
keyless() { RELEASE_KEY='' signs_nothing "$@"; }
check "a run without the release environment's key is refused before signing" \
  keyless "TAURI_SIGNING_PRIVATE_KEY is not set" "$tmp/full"

mkdir -p "$tmp/unsigned"
check "signing a release with no signatures fails" \
  refuses "no signatures in" env TAURI_SIGNING_PRIVATE_KEY=stand-in \
  bash "$here/updater-sign.sh" 1.2.3 "$tmp/unsigned" 0 /dev/null

printf 'the happ stage 1 built' >"$tmp/unyt.happ"
printf 'another happ' >"$tmp/other.happ"
published="$(sha256sum <"$tmp/unyt.happ" | cut -d' ' -f1)"
check "a build row takes the happ stage 1 published" bash "$here/check-sha256.sh" "$tmp/unyt.happ" "$published"
check "a build row refuses any other happ" \
  refuses "other.happ has sha256" bash "$here/check-sha256.sh" "$tmp/other.happ" "$published"
check "a build row refuses a happ when stage 1 published no digest" \
  refuses "2: usage:" bash "$here/check-sha256.sh" "$tmp/unyt.happ" ""

# A release as tauri-action publishes it: each build job signs with a key it generates, the bundler
# signs both arc factors' builds under one file name, the upload renames them, and each build job
# records what it published. The release key then signs them again.
tauri() { "$here/tauri-signer/node_modules/.bin/tauri" "$@"; }
for k in build release; do tauri signer generate --ci -p test -w "$tmp/$k.key" >/dev/null; done
with_key() { # <build|release> <command...>
  local key="$tmp/$1.key"
  shift
  TAURI_SIGNING_PRIVATE_KEY="$(cat "$key")" TAURI_SIGNING_PRIVATE_KEY_PASSWORD=test "$@"
}
release_pubkey="$(cat "$tmp/release.key.pub")"
printf '{"productName": "Unyt", "version": "1.2.3"}' >"$tmp/tauri.conf.json"
# jq.exe as a Windows runner's Git Bash runs it.
mkdir "$tmp/windows"
printf '#!/bin/sh\n%s "$@" | sed "s/$/\\r/"\n' "$(command -v jq)" >"$tmp/windows/jq"
chmod +x "$tmp/windows/jq"
recorded() { # <runner os> <runner arch> <build args> <arc> <out-dir> <artifact path>...: what the job records
  local path="$PATH" os="$1" arch="$2" args="$3" arc="$4" out="$5"
  shift 5
  if [ "$os" = Windows ]; then path="$tmp/windows:$PATH" && set -- "${@//\//\\}"; fi
  PATH="$path" RUNNER_OS="$os" RUNNER_ARCH="$arch" bash "$here/updater-provenance.sh" \
    "$tmp/tauri.conf.json" "$arc" "$args" "$(jq -nc '$ARGS.positional' --args "$@")" "$out"
}
# A path ending in / is a directory tauri-action lists but does not upload. The bundler signs every
# installer but the dmg. Writes $tmp/misnamed for a build not published under its asset name.
build() { # <arc> <runner os> <runner arch> <build args> <bundler's path>[:<asset suffix>]...
  local arc="$1" os="$2" arch="$3" args="$4" spec path published made=()
  shift 4
  for spec; do
    path="$tmp/target/$arc/${spec%%:*}"
    if [ "$path" != "${path%/}" ]; then mkdir -p "$path" && made+=("${path%/}") && continue; fi
    mkdir -p "$(dirname "$path")"
    printf 'the %s-arc %s build' "$arc" "${spec%%:*}" >"$path"
    made+=("$path")
    [[ "$path" != *.dmg ]] || continue
    with_key build tauri signer sign --app-version 1.2.3 "$path" >/dev/null
    made+=("$path.sig")
  done
  recorded "$os" "$arch" "$args" "$arc" "$tmp/bundled" "${made[@]}" >>"$tmp/bundled.provenance"
  for spec; do
    [[ "$spec" == *:* ]] || continue
    path="$tmp/target/$arc/${spec%%:*}"
    published="$tmp/bundled/$(asset "$arc" "${spec#*:}")"
    cmp -s "$path" "$published" || echo "$published" >>"$tmp/misnamed"
    [[ "$path" == *.dmg ]] || cmp -s "$path.sig" "$published.sig" || echo "$published.sig" >>"$tmp/misnamed"
  done
}
mkdir -p "$tmp/bundled"
started="$(date +%s)"
for arc in default zero; do
  build "$arc" macOS ARM64 "--target aarch64-apple-darwin" \
    aarch64-apple-darwin/release/bundle/dmg/Unyt_1.2.3_aarch64.dmg:aarch64_darwin.dmg \
    aarch64-apple-darwin/release/bundle/macos/Unyt.app/ \
    aarch64-apple-darwin/release/bundle/macos/Unyt.app.tar.gz:aarch64_darwin.app.tar.gz
  build "$arc" macOS ARM64 "--target x86_64-apple-darwin" \
    x86_64-apple-darwin/release/bundle/dmg/Unyt_1.2.3_x64.dmg:x64_darwin.dmg \
    x86_64-apple-darwin/release/bundle/macos/Unyt.app/ \
    x86_64-apple-darwin/release/bundle/macos/Unyt.app.tar.gz:x64_darwin.app.tar.gz
  build "$arc" Linux X64 "--bundles deb,appimage" \
    release/bundle/deb/Unyt_1.2.3_amd64.deb:amd64_linux.deb \
    release/bundle/appimage/Unyt_1.2.3_amd64.AppImage:amd64_linux.AppImage
  build "$arc" Windows X64 "" \
    release/bundle/msi/Unyt_1.2.3_x64_en-US.msi:x64_windows.msi \
    release/bundle/nsis/Unyt_1.2.3_x64-setup.exe:x64_windows.exe
done
published_as_named() { [ ! -e "$tmp/misnamed" ] && [ "$(find "$tmp/bundled" -type f | wc -l)" -eq 28 ]; }
check "every build is published under its asset name, beside its build signature" published_as_named
mkdir -p "$tmp/unsigned/Unyt.app" "$tmp/unsigned.out"
printf 'the app tauri-action packed' >"$tmp/unsigned/Unyt.app.tar.gz"
recorded macOS ARM64 "--target aarch64-apple-darwin" default "$tmp/unsigned.out" "$tmp/unsigned/Unyt.app" >/dev/null
check "a macOS build with no updater bundle publishes the one tauri-action packs" \
  test "$(ls "$tmp/unsigned.out")" = "$(asset default aarch64_darwin.app.tar.gz)"
# The release's SHA256SUMS, as the updater-manifests job writes it.
sums_check_every_installer() { # <asset-dir> <records>
  (cd "$1" && sort -k2,2 "$2" | sha256sum --check --strict --quiet) &&
    [ "$(wc -l <"$2")" -eq "$(find "$1" -type f ! -name '*.sig' | wc -l)" ]
}
check "SHA256SUMS from the builds' records checks every installer the release publishes" \
  sums_check_every_installer "$tmp/bundled" "$tmp/bundled.provenance"
check "a build on a runner with no known asset name records nothing" \
  refuses 'no asset name for a macOS ARM64 build with args ""' recorded macOS ARM64 "" default "$tmp"
for os in Linux Windows; do
  check "an arm64 $os build records nothing" \
    refuses "no asset name for a $os ARM64 build" recorded "$os" ARM64 "" default "$tmp"
done
printf '{"productName": "Unyt (Sandbox)", "version": "1.2.3"}' >"$tmp/renamed.conf.json"
mkdir "$tmp/renamed.out"
check "a product name GitHub renames is recorded as the release names it" \
  test "$(RUNNER_OS=Linux RUNNER_ARCH=X64 bash "$here/updater-provenance.sh" "$tmp/renamed.conf.json" \
    default "" "[\"$tmp/target/default/release/bundle/deb/Unyt_1.2.3_amd64.deb\"]" "$tmp/renamed.out" |
    cut -d' ' -f3)" = unyt_1.2.3_Unyt.Sandbox._default-arc_amd64_linux.deb
printf 'an rpm' >"$tmp/target/x.rpm"
cp "$tmp/target/x.rpm" "$tmp/target/x.rpm.sig"
check "a build that published a file no release names records nothing" \
  refuses "x.rpm is published, but is no installer this release names" \
  recorded Linux X64 "" default "$tmp" "$tmp/target/x.rpm" "$tmp/target/x.rpm.sig"
check "a release as tauri-action publishes it fails" refuses "is signed for another file" \
  manifests "$tmp/bundled" "$tmp/bundled.out" "$(cat "$tmp/build.key.pub")"
check "a release only its build key signed fails" refuses "with the key the app pins" \
  manifests "$tmp/bundled" "$tmp/bundled.out" "$release_pubkey"
cp -r "$tmp/bundled" "$tmp/relabelled"
published_as "$tmp/relabelled/$(asset zero amd64_linux.AppImage)" "$tmp/relabelled/$(asset default amd64_linux.AppImage)"
cp -r "$tmp/relabelled" "$tmp/relabelled.built"
signed_and_published() { # <asset-dir>
  with_key release bash "$here/updater-sign.sh" 1.2.3 "$1" "$started" "$tmp/bundled.provenance" &&
    manifests "$1" "$1.out" "$release_pubkey"
}
check "built under a throwaway key and signed again with the release key, it publishes its manifests" \
  signed_and_published "$tmp/bundled"
check "signing again signs the signatures the first signing left under the asset names" \
  signed_and_published "$tmp/bundled"
check "a zero-arc build relabelled as the default-arc one publishes nothing" \
  refuses "$(unclaimed "$(asset default amd64_linux.AppImage)")" signed_and_published "$tmp/relabelled"
check "and every signature is left as its build made it" diff -r "$tmp/relabelled.built" "$tmp/relabelled"
check "nor do the manifests publish the relabelled release" refuses "with the key the app pins" \
  manifests "$tmp/relabelled" "$tmp/relabelled.out" "$release_pubkey"

workflows="$here/../.github/workflows"
credentials() { bash "$here/check-build-credentials.sh" "$@"; }
check "no job that builds the app holds a credential that can change a release" \
  test "$(credentials "$workflows"/*.y*ml)" = "release-tauri-app.yaml build-happ
release-tauri-app.yaml release-tauri-app"
mkdir "$tmp/workflow"
edited() { # <sed edit of release-tauri-app.yaml>: fails when the edit changed nothing
  sed "$1" "$workflows/release-tauri-app.yaml" >"$tmp/workflow/release-tauri-app.yaml" &&
    ! cmp -s "$workflows/release-tauri-app.yaml" "$tmp/workflow/release-tauri-app.yaml"
}
edit_refused() { edited "$2" && refuses "$1" credentials "$tmp/workflow/release-tauri-app.yaml"; }
release_edit() { check "$1" edit_refused "$2" "$3"; } # <description> <error text> <sed edit>
release_edit "the release PAT handed back to tauri-action fails" "release-tauri-app: it holds secrets.GIT_PAT" \
  's/^\(          APPLE_TEAM_ID: .*\)$/\1\n          GITHUB_TOKEN: ${{ secrets.GIT_PAT }}/'
release_edit "the release PAT handed to stage 1's nix fails" "build-happ: it holds secrets.GIT_PAT" \
  's/^\(          nix_path: .*\)$/\1\n          github_access_token: ${{ secrets.GIT_PAT }}/'
release_edit "a credential every job of the workflow holds fails" "its workflow holds secrets.GIT_PAT" \
  's/^jobs:$/env:\n  GH_TOKEN: ${{ secrets.GIT_PAT }}\n&/'
release_edit "a build job whose token can write fails" "build-happ: its token can write" \
  '0,/^      contents: read$/s//      contents: write/'
release_edit "a build job that takes the workflow's permissions fails" \
  "build-happ: it declares no permissions of its own" '0,/^    permissions:$/s//    # permissions:/'
release_edit "a publishing job that runs build code fails" "publish-builds: its token can write" \
  's/^\(        run: gh release upload .*\)$/\1\n      - run: yarn install/'
commented() {
  edited 's/^\(          projectPath: unyt\)$/\1 # never secrets.GIT_PAT/' &&
    credentials "$tmp/workflow/release-tauri-app.yaml" >/dev/null
}
check "a comment naming the release PAT in a build job holds nothing" commented

echo "updater scripts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
