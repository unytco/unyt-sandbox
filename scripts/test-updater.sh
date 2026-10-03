#!/usr/bin/env bash
# updater-signing.sh, updater-asset-names.sh, updater-provenance.sh, updater-sign.sh,
# updater-manifests.sh and check-sha256.sh against fixtures signed with throwaway keys, and
# check-build-credentials.sh against the workflows. Needs minisign on PATH (install-minisign.sh), node for
# the Tauri signer, and mikefarah's yq v4.
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
check "a build row takes the happ stage 1 built" bash "$here/check-sha256.sh" "$tmp/unyt.happ" "$published"
check "a build row refuses any other happ" \
  refuses "other.happ has sha256" bash "$here/check-sha256.sh" "$tmp/other.happ" "$published"
check "a build row refuses a happ when stage 1 gave no digest" \
  refuses "2: usage:" bash "$here/check-sha256.sh" "$tmp/unyt.happ" ""

# A release as its build rows stage it: each row signs with a key it generates, the bundler signs both
# arc factors' builds under one file name, and updater-provenance.sh copies each under its asset name
# and records it. The release key then signs them again.
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
# A path ending in / is the .app directory tauri-action lists beside the bundler's .app.tar.gz. The
# bundler signs every installer but the dmg. Writes $tmp/misnamed for a build not staged under its
# asset name, and counts in $staged every file a stage should hold.
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
    staged=$((staged + 1))
    cmp -s "$path" "$published" || echo "$published" >>"$tmp/misnamed"
    [[ "$path" != *.dmg ]] || continue
    staged=$((staged + 1))
    cmp -s "$path.sig" "$published.sig" || echo "$published.sig" >>"$tmp/misnamed"
  done
}
mkdir -p "$tmp/bundled"
staged=0
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
staged_as_named() { [ ! -e "$tmp/misnamed" ] && [ "$(find "$tmp/bundled" -type f | wc -l)" -eq "$staged" ]; }
check "every build is staged under its asset name, beside its build signature" staged_as_named
mkdir -p "$tmp/no-updater/Unyt.app" "$tmp/no-updater.out"
recorded_app() { recorded macOS ARM64 "--target aarch64-apple-darwin" default "$tmp/no-updater.out" "$tmp/no-updater/Unyt.app"; }
unpacked() { refuses "tauri-action packed no" recorded_app && [ -z "$(ls "$tmp/no-updater.out")" ]; }
check "a macOS .app that tauri-action did not pack stages nothing" unpacked
printf 'the app tauri-action packed' >"$tmp/no-updater/Unyt.app.tar.gz"
recorded_app >/dev/null
check "a macOS build with no updater bundle stages the one tauri-action packs" \
  test "$(ls "$tmp/no-updater.out")" = "$(asset default aarch64_darwin.app.tar.gz)"
# publish-builds gathers what the rows staged, one directory per row.
gathered() { # <productName> <rows-dir>: gathers it into <rows-dir>.out
  mkdir -p "$2.out" && bash "$here/gather-release-assets.sh" 1.2.3 "$1" "$2" "$2.out"
}
mkdir -p "$tmp/rows/0"
cp "$tmp/bundled"/* "$tmp/rows/0/"
gathers_every_build() { gathered Unyt "$tmp/rows" && diff <(ls "$tmp/bundled") <(ls "$tmp/rows.out"); }
check "every build the rows stage is gathered for the release" gathers_every_build
staged_rows() { # <case> <row>/<name>...: a gathering of rows that staged those names
  local spec
  for spec in "${@:2}"; do mkdir -p "$tmp/$1/${spec%/*}" && printf 'staged' >"$tmp/$1/$spec"; done
}
gather_refused() { # <description> <error text> <productName> <row>/<name>...
  staged_rows "case$((pass + fail))" "${@:4}"
  check "$1" refuses "$2" gathered "$3" "$tmp/case$((pass + fail))"
}
gather_refused "a row that stages the happ fails" "staged unyt.happ, which is no build asset of this release" \
  Unyt "0/$(asset default amd64_linux.deb)" 1/unyt.happ
gather_refused "two rows that stage one name fail" "two build rows staged $(asset zero x64_windows.msi)" \
  Unyt "0/$(asset zero x64_windows.msi)" "1/$(asset zero x64_windows.msi)"
gather_refused "a row that stages an arc factor the release does not build fails" "no build asset of this release" \
  Unyt "0/unyt_1.2.3_Unyt_half-arc_amd64_linux.deb"
gather_refused "a row that stages a signature for a dmg fails" "no build asset of this release" \
  Unyt "0/$(asset default x64_darwin.dmg).sig"
gather_refused "a row that stages another version fails" "no build asset of this release" \
  Unyt "0/unyt_1.2.2_Unyt_default-arc_amd64_linux.deb"
gather_refused "a row that stages part of an asset name fails" "no build asset of this release" Unyt 0/x64_windows.exe
gather_refused "a row that stages a name across two lines fails" "no build asset of this release" \
  Unyt "0/$(asset default amd64_linux.deb)"$'\n'"$(asset default amd64_linux.deb).sig"
gather_refused "a row that stages a directory under an asset name fails" "which is not a file" \
  Unyt "0/$(asset default amd64_linux.deb)/inside"
mkdir "$tmp/no-rows"
check "rows that staged nothing fail" refuses "no build row staged anything" gathered Unyt "$tmp/no-rows"
staged_rows renamed-rows 0/unyt_1.2.3_Unyt.Sandbox._default-arc_amd64_linux.deb
check "a product name GitHub renames is gathered as the release names it" \
  gathered "Unyt (Sandbox)" "$tmp/renamed-rows"
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
check "a build that made nothing records nothing" \
  refuses "tauri-action found nothing this build made" recorded Linux X64 "" default "$tmp"
check "a build tauri-action reported nothing for records nothing" refuses "tauri-action found nothing this build made" \
  env RUNNER_OS=Linux RUNNER_ARCH=X64 bash "$here/updater-provenance.sh" "$tmp/tauri.conf.json" default "" "" "$tmp"
mkdir "$tmp/twice" "$tmp/twice.out"
printf 'one deb' >"$tmp/twice/Unyt_1.2.3_amd64.deb"
printf 'another deb' >"$tmp/twice/unyt_1.2.3_amd64.deb"
check "a build with two artifacts under one asset name records nothing" \
  refuses "two of this build's artifacts are named $(asset default amd64_linux.deb)" \
  recorded Linux X64 "" default "$tmp/twice.out" "$tmp/twice/Unyt_1.2.3_amd64.deb" "$tmp/twice/unyt_1.2.3_amd64.deb"
printf 'an rpm' >"$tmp/target/x.rpm"
cp "$tmp/target/x.rpm" "$tmp/target/x.rpm.sig"
check "a build that lists a file no release names records nothing" \
  refuses "x.rpm is no installer this release names" \
  recorded Linux X64 "" default "$tmp" "$tmp/target/x.rpm" "$tmp/target/x.rpm.sig"
check "a release as its builds stage it fails" refuses "is signed for another file" \
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
check "no code that builds the app can reach a credential that can change a release" \
  credentials "$workflows"/*.y*ml
mkdir "$tmp/workflow"
edited() { # <sed edit of release-tauri-app.yaml>: fails when the edit changed nothing
  sed "$1" "$workflows/release-tauri-app.yaml" >"$tmp/workflow/release-tauri-app.yaml" &&
    ! cmp -s "$workflows/release-tauri-app.yaml" "$tmp/workflow/release-tauri-app.yaml"
}
edit_refused() { edited "$2" && refuses "$1" credentials "$tmp/workflow/release-tauri-app.yaml"; }
release_edit() { check "$1" edit_refused "$2" "$3"; } # <description> <error text> <sed edit>
after() { echo "s/^\\(          $1\\)\$/\\1\\n          $2/"; } # <line> <line to add after it>
release_edit "the release PAT handed to tauri-action fails" "release-tauri-app reads secrets.git_pat" \
  "$(after 'APPLE_TEAM_ID: .*' 'GITHUB_TOKEN: ${{ secrets.GIT_PAT }}')"
release_edit "the release PAT handed to stage 1's nix fails" "build-happ reads secrets.git_pat" \
  "$(after 'nix_path: .*' 'github_access_token: ${{ secrets.GIT_PAT }}')"
release_edit "every secret handed to a build fails" "release-tauri-app reads the secrets context" \
  "$(after 'APPLE_TEAM_ID: .*' 'ALL: ${{ toJSON(secrets) }}')"
release_edit "a secret read by index fails" "release-tauri-app reads the secrets context" \
  "$(after 'APPLE_TEAM_ID: .*' "PAT: \${{ secrets['GIT_PAT'] }}")"
release_edit "a secret in a script's comment fails, as Actions fills it in" "build-happ reads secrets.git_pat" \
  's/^\(          sum="$(sha256sum <unyt\/workdir\/unyt.happ)"\)$/\1 # ${{ secrets.GIT_PAT }}/'
release_edit "a credential every job of the workflow holds fails" "the workflow, and so every job, reads secrets.git_pat" \
  's/^jobs:$/env:\n  GH_TOKEN: ${{ secrets.GIT_PAT }}\n&/'
release_edit "a credential every job holds, written after the jobs, fails" \
  "the workflow, and so every job, reads secrets.git_pat" '$a env:\n  GH_TOKEN: ${{ secrets.GIT_PAT }}'
release_edit "a holder's credential reached through a YAML alias fails" "release-tauri-app reads secrets.git_pat" \
  "$(after 'bodyFile: .*' 'x: \&pat ${{ secrets.GIT_PAT }}'); $(after 'APPLE_TEAM_ID: .*' 'X: *pat')"
release_edit "a holder's credential reached through an alias in a flow sequence fails" \
  "release-tauri-app reads secrets.git_pat" \
  "$(after 'bodyFile: .*' 'x: [\&pat "${{ secrets.GIT_PAT }}"]'); $(after 'APPLE_TEAM_ID: .*' 'X: [*pat]')"
release_edit "a YAML merge key fails" "uses a YAML merge key" \
  "$(after 'bodyFile: .*' 'x: \&base {a: 1}'); $(after 'APPLE_TEAM_ID: .*' '<<: *base')"
release_edit "a key named twice fails" "names a key twice" \
  '0,/^      contents: read$/s//&\n      contents: write/'
release_edit "a YAML tag fails" "uses the YAML tags !!binary" "$(after 'nix_path: .*' 'x: !!binary aGk=')"
release_edit "a secret spelled with a YAML escape fails" "release-tauri-app reads secrets.git_pat" \
  "$(after 'APPLE_TEAM_ID: .*' 'X: "${{ \\x73ecrets.GIT_PAT }}"')"
release_edit "a write spelled with a YAML escape fails" "build-happ holds a token that can write" \
  '0,/^      contents: read$/s//      contents: "\\x77rite"/'
release_edit "permissions keyed otherwise fail the same" "build-happ holds a token that can write" \
  '0,/^    permissions:$/{//{N;s/.*/    permissions :\n      contents: write/}}'
release_edit "a build row that reads a holder's outputs fails" \
  "release-tauri-app reads what a credential holder hands on: needs.publish-happ" \
  "$(after 'APPLE_TEAM_ID: .*' 'RELEASE: ${{ needs.publish-happ.outputs.releaseId }}')"
release_edit "a build row that reads every job's outputs fails" "release-tauri-app reads what a credential holder hands on: needs" \
  "$(after 'APPLE_TEAM_ID: .*' 'ALL: ${{ toJSON(needs) }}')"
release_edit "a build job whose token can write fails" "build-happ holds a token that can write" \
  '0,/^      contents: read$/s//      contents: write/'
release_edit "a quoted write fails" "build-happ holds a token that can write" \
  '0,/^      contents: read$/s//      contents: "write"/'
release_edit "a build job with every permission fails" "build-happ holds a token that can write" \
  '0,/^    permissions:$/{//{N;s/.*/    permissions: write-all/}}'
release_edit "a workflow whose every token can write fails" "build-happ holds a token that can write" \
  '0,/^    permissions:$/{//{N;s/.*/    # none/}}; s/^jobs:$/permissions: write-all\n&/'
release_edit "a workflow whose jobs key is spelled otherwise is read the same" "release-tauri-app reads secrets.git_pat" \
  "s/^jobs:\$/jobs :/; $(after 'APPLE_TEAM_ID: .*' 'GITHUB_TOKEN: ${{ secrets.GIT_PAT }}')"
release_edit "a secret in a block of the workflow's env fails" "the workflow, and so every job, reads secrets.git_pat" \
  's/^jobs:$/env:\n  X: |\n    y # ${{ secrets.GIT_PAT }}\n&/'
release_edit "a build job that takes the default permissions fails" \
  "build-happ takes the repository default permissions" '0,/^    permissions:$/{//{N;d}}'
release_edit "a new job holding the release PAT fails" "extra reads secrets.git_pat" \
  's/^jobs:$/&\n  extra:\n    runs-on: ubuntu-22.04\n    permissions: {}\n    steps:\n      - run: npx tauri build\n        env:\n          GH_TOKEN: ${{ secrets.GIT_PAT }}/'
release_edit "a workflow indented otherwise is read the same" "release-tauri-app reads secrets.git_pat" \
  '/^jobs:$/,$s/^ /   /; s/^\(            APPLE_TEAM_ID: .*\)$/\1\n            GITHUB_TOKEN: ${{ secrets.GIT_PAT }}/'
release_edit "a credential holder that checks out the app fails" \
  "publish-happ holds a credential that can change a release, and builds the app" \
  's/^      - id: create-release$/      - uses: .\/.github\/actions\/checkout-app\n&/'
release_edit "a credential holder that runs a build fails" \
  "publish-builds holds a credential that can change a release, and builds the app" \
  's/^\(          gh release upload .*\)$/\1\n      - run: yarn install/'
release_edit "a credential holder the workflow no longer has fails" \
  "names publish-builds as a credential holder, but has no such job" 's/^  publish-builds:$/  publish-assets:/'
check "a workflow that cannot be read fails" refuses "could not read" credentials "$tmp/workflow/absent.yaml"
for marker in "uses: ./.github/actions/checkout-app" "run: echo \${{ secrets.UNYT_DEPLOY_KEY }}" "submodules: true" \
  "run: git submodule update" "uses: tauri-apps/tauri-action@v0" "run: npx tauri build" "run: nix develop" \
  "run: make package" "run: cargo  build" "run: yarn" "run: npm run build" "with: { repository: unytco/unyt }"; do
  release_edit "the release key's job fails when it carries \"$marker\"" \
    "updater-manifests holds a credential that can change a release, and builds the app" \
    "s|^\(      - name: Install minisign\)\$|      - ${marker//&/\\&}\n\1|"
done
mkdir -p "$tmp/clean"
cp "$workflows/ci.yaml" "$tmp/clean/"
edited "$(after 'APPLE_TEAM_ID: .*' 'GITHUB_TOKEN: ${{ secrets.GIT_PAT }}')"
check "a refused workflow fails the check whatever is checked after it" \
  refuses "release-tauri-app reads secrets.git_pat" credentials "$tmp/workflow/release-tauri-app.yaml" "$tmp/clean/ci.yaml"
check "a refused workflow fails the check whatever is checked before it" \
  refuses "release-tauri-app reads secrets.git_pat" credentials "$tmp/clean/ci.yaml" "$tmp/workflow/release-tauri-app.yaml"
flow_read() { edited '0,/^    permissions:$/{//{N;s/.*/    permissions: { contents: read }/}}' && credentials "$tmp/workflow/release-tauri-app.yaml"; }
check "permissions written as a flow mapping read the same" flow_read

echo "updater scripts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
