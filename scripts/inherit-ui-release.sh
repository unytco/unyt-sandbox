#!/usr/bin/env bash
# UI release: inherit the lineage's unyt.happ + alliance.dna byte-for-byte from the parent vM.m.0
# release, guard the inheritance, and repack ONLY the UI into unyt.webhapp. The DNA is NEVER rebuilt
# or repacked — that is the whole point of a UI release (one lineage, one DNA, one app_id).
#
# Usage:  inherit-ui-release.sh <tag> <parent_tag>
# Requires: gh (authenticated via GH_TOKEN) for the parent-release download, and a nix dev shell
# (run inside `unyt/`) for the UI pack. The outer checkout must be fetch-depth 0 so the parent tag's
# submodule pointer and the DNA-source history are available.
set -euo pipefail

TAG="${1:?usage: inherit-ui-release.sh <tag> <parent_tag>}"
PARENT_TAG="${2:?usage: inherit-ui-release.sh <tag> <parent_tag>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="unytco/unyt-sandbox"
fail() { echo "inherit: $*" >&2; exit 1; }

PIN="$ROOT/lineage.json"
[ -f "$PIN" ] || fail "missing lineage.json"
expected_sha="$(jq -r '.happ_sha256' "$PIN")"
{ [ -n "$expected_sha" ] && [ "$expected_sha" != "null" ]; } ||
  fail "lineage.json has no happ_sha256 — prepare the pin from the published $PARENT_TAG asset first"

# 1. Inherit the DNA artifacts from the parent release. A missing parent, or a parent without a
#    unyt.happ asset, fails here — there is no fallback to rebuilding the DNA.
tmp="$(mktemp -d)"
gh release download "$PARENT_TAG" --repo "$REPO" --dir "$tmp" --pattern unyt.happ --pattern alliance.dna ||
  fail "could not download unyt.happ / alliance.dna from parent release $PARENT_TAG (a UI release never rebuilds the DNA)"
[ -f "$tmp/unyt.happ" ] || fail "parent release $PARENT_TAG has no unyt.happ asset"

# 2. Digest guard — release assets are mutable (allowUpdates), so the trusted digest is the committed
#    one. A mismatch means a mutated or wrong-tag asset.
got_sha="$(sha256sum "$tmp/unyt.happ" | awk '{print $1}')"
[ "$got_sha" = "$expected_sha" ] ||
  fail "inherited unyt.happ sha256 $got_sha != committed lineage.json $expected_sha (mutated or wrong-tag release asset)"

# 3. Source-diff guard — a change that would alter the BUILT DNA requires a NEW lineage (a vM.m+1.0
#    migration release), not a UI patch. The DNA wasm compiles `crates/rave_engine` + `dnas/*/zomes/*`
#    (`yarn build:zomes` = cargo build --workspace, excluding only unyt-sandbox / unyt_cli / sweettest),
#    with every dep version pinned by the workspace manifest + lockfile — so DNA-affecting source lives
#    OUTSIDE dnas/ too. Diff ALL of those inputs between the two pinned inner-app commits (NOT the
#    submodule pointer, which changes on every UI release). Keep DNA_SOURCE in step with build:zomes if
#    a new wasm-compiled crate is ever added under crates/. (smart_agreement_library is runtime
#    agreement data, not compiled into the DNA, so it is deliberately not here.)
parent_inner="$(git -C "$ROOT" ls-tree "$PARENT_TAG" unyt | awk '{print $3}')"
current_inner="$(git -C "$ROOT/unyt" rev-parse HEAD)"
[ -n "$parent_inner" ] || fail "could not read the unyt submodule pointer at $PARENT_TAG (is the outer checkout fetch-depth 0?)"
git -C "$ROOT/unyt" cat-file -e "${parent_inner}^{commit}" 2>/dev/null ||
  git -C "$ROOT/unyt" fetch --depth 1 origin "$parent_inner" 2>/dev/null ||
  fail "cannot resolve the parent inner-app commit $parent_inner — fetch it (the inner submodule needs its history)"
DNA_SOURCE=(dnas crates/rave_engine Cargo.toml Cargo.lock)
if ! git -C "$ROOT/unyt" diff --quiet "$parent_inner" "$current_inner" -- "${DNA_SOURCE[@]}"; then
  {
    echo "DNA source changed between $PARENT_TAG and $TAG — a change under the DNA build inputs"
    echo "(${DNA_SOURCE[*]}) requires a NEW LINEAGE (a vM.m+1.0 migration release), not a UI patch."
    echo "Offending files:"
    git -C "$ROOT/unyt" diff --stat "$parent_inner" "$current_inner" -- "${DNA_SOURCE[@]}"
  } >&2
  exit 1
fi

# 4. Place the inherited artifacts + repack ONLY the UI. hc web-app pack consumes the inherited
#    ./unyt.happ (never repacks the DNA) and the freshly built ../ui/white-label/dist.zip.
cp "$tmp/unyt.happ" "$ROOT/unyt/workdir/unyt.happ"
[ -f "$tmp/alliance.dna" ] && cp "$tmp/alliance.dna" "$ROOT/unyt/dnas/alliance/workdir/alliance.dna"
( cd "$ROOT/unyt" && nix develop --no-update-lock-file --accept-flake-config --command bash -c \
  "yarn install --frozen-lockfile && yarn workspace white-label package && hc web-app pack workdir --recursive" )

echo "inherit: UI release $TAG built on inherited $PARENT_TAG DNA (unyt.happ sha256 $got_sha) — DNA not rebuilt."
