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

# 3. Source-diff guard — the DNA source must be identical to the parent tag; a zome change that would
#    silently not ship requires a NEW lineage (a vM.m+1.0 migration release), not a UI patch. Compare
#    the two pinned inner-app commits' dnas/ trees — NOT the submodule pointer, which changes on every
#    UI release.
parent_inner="$(git -C "$ROOT" ls-tree "$PARENT_TAG" unyt | awk '{print $3}')"
current_inner="$(git -C "$ROOT/unyt" rev-parse HEAD)"
[ -n "$parent_inner" ] || fail "could not read the unyt submodule pointer at $PARENT_TAG (is the outer checkout fetch-depth 0?)"
git -C "$ROOT/unyt" cat-file -e "${parent_inner}^{commit}" 2>/dev/null ||
  git -C "$ROOT/unyt" fetch --depth 1 origin "$parent_inner" 2>/dev/null ||
  fail "cannot resolve the parent inner-app commit $parent_inner — fetch it (the inner submodule needs its history)"
if ! git -C "$ROOT/unyt" diff --quiet "$parent_inner" "$current_inner" -- dnas/; then
  {
    echo "DNA source changed between $PARENT_TAG and $TAG — a change under dnas/ requires a NEW LINEAGE"
    echo "(a vM.m+1.0 migration release), not a UI patch. Offending files:"
    git -C "$ROOT/unyt" diff --stat "$parent_inner" "$current_inner" -- dnas/
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
