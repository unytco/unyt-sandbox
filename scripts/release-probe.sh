#!/usr/bin/env bash
# What a release of this repo's app would do with an app tree, publishing nothing:
#   release-probe.sh <app-dir>
# Each check prints ok, FAIL with the reason under it, or one waits line for each value identity.json
# or network.json has not set yet, which the release refuses. Fails on any FAIL. Needs jq and
# mikefarah's yq v4. Env: GITHUB_REPOSITORY (default local/probe).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${1:?usage: release-probe.sh <app-dir>}"
export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-local/probe}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failed=0

line() { printf '%-5s %-9s %s\n' "$@"; } # <verdict> <check> <what>
probe() { # <check> <what> <command...>: ok when the command succeeds
  local check="$1" what="$2" out
  shift 2
  if out="$("$@" 2>&1)"; then line ok "$check" "$what"; else
    line FAIL "$check" "$what"
    sed 's/^/      /' <<<"$out"
    failed=1
  fi
}

# On a copy: set-app-version.sh writes into the app beside it.
mkdir -p "$tmp/version/scripts" "$tmp/version/unyt/src-tauri"
cp "$here/set-app-version.sh" "$here/check-version-contract.sh" "$here/updater-verify.sh" "$tmp/version/scripts/"
cp "$APP_DIR/Cargo.lock" "$tmp/version/unyt/"
cp "$APP_DIR/src-tauri/Cargo.toml" "$APP_DIR/src-tauri/tauri.conf.json" "$tmp/version/unyt/src-tauri/"
probe version "a release writes its version into the app, and the version contract holds" \
  bash -c 'bash "$1/set-app-version.sh" v9.9.9-dev.1 && bash "$1/check-version-contract.sh" v9.9.9-dev.1' _ "$tmp/version/scripts"
product="$(jq -r .productName "$here/../identity.json")"
probe identity "the app with identity.json merged over it is $product" \
  bash "$here/release-app.sh" identity "$APP_DIR" "$tmp/merged.json"
probe assets "the app names each updater asset as the release publishes $product's" \
  bash "$here/updater-asset-names.sh" "$APP_DIR/src-tauri/src/updater.rs" "$product"
probe values "the app reads every value the release builds it with" bash "$here/release-app.sh" reads "$APP_DIR"
probe dna "the app commits the hashes a migration release holds its DNA to" \
  bash "$here/check-dna-pin.sh" "$APP_DIR" --committed
probe rust "the app's CI builds with the Rust the release builds with" bash "$here/check-rust-toolchain.sh" \
  "$APP_DIR/.github/workflows/rust.yaml" "$(yq '.env.RUST_TOOLCHAIN' "$here/../.github/workflows/release-tauri-app.yaml")"
if refusal="$(bash "$here/release-app.sh" build-env 2>&1 >/dev/null)"; then
  line ok release "identity.json and network.json set every value: $product on $(jq -r .name "$here/../network.json")"
  probe signing "signs its updates with the key identity.json pins" \
    grep -qx enabled=true <(bash "$here/updater-signing.sh" "$tmp/merged.json" 2>&1)
elif [ -n "$refusal" ] && ! grep -vqE '^::error::(identity|network)\.json has not set [^ ]+ yet: TO BE SET' <<<"$refusal"; then
  while IFS= read -r unset; do line waits release "${unset#::error::}"; done <<<"$refusal"
else
  line FAIL release "is refused for more than a value it has not set"
  sed 's/^/      /' <<<"$refusal"
  failed=1
fi
exit "$failed"
