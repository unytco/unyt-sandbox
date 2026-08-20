#!/usr/bin/env bash
# UI release: inherit the lineage's unyt.happ + alliance.dna + unyt_cli byte-for-byte from the parent
# vM.m.0 release, guard the inheritance, and repack ONLY the UI into unyt.webhapp. The DNA is NEVER
# rebuilt or repacked — that is the whole point of a UI release (one lineage, one DNA, one app_id).
#
# unyt_cli is inherited for the same reason, not rebuilt: it compiles the rave_engine payload types
# and the smart_agreement_library templates INTO the binary, so a CLI and a happ only agree when they
# came from one commit. A UI release may carry a submodule pointer that has moved on past the
# lineage's DNA (see the note at step 2), so building here would ship a mismatched pair under one tag.
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
expected_cli_sha="$(jq -r '.cli_sha256' "$PIN")"
{ [ -n "$expected_cli_sha" ] && [ "$expected_cli_sha" != "null" ]; } ||
  fail "lineage.json has no cli_sha256 — prepare the pin from the published $PARENT_TAG asset first"

# 1. Inherit the lineage artifacts from the parent release. A missing parent, or a parent without one
#    of these assets, fails here — there is no fallback to rebuilding the DNA.
tmp="$(mktemp -d)"
gh release download "$PARENT_TAG" --repo "$REPO" --dir "$tmp" --pattern unyt.happ --pattern alliance.dna --pattern unyt_cli ||
  fail "could not download unyt.happ / alliance.dna / unyt_cli from parent release $PARENT_TAG (a UI release never rebuilds the DNA)"
[ -f "$tmp/unyt.happ" ] || fail "parent release $PARENT_TAG has no unyt.happ asset"
# `gh release download` succeeds if only ONE --pattern matches, so check each of the others
# explicitly — a UI release must republish them byte-identical, and both are declared artifacts.
[ -f "$tmp/alliance.dna" ] || fail "parent release $PARENT_TAG has no alliance.dna asset"
[ -f "$tmp/unyt_cli" ] || fail "parent release $PARENT_TAG has no unyt_cli asset"

# 2. Digest guard — release assets are mutable (allowUpdates), so the trusted digest is the committed
#    one. A mismatch means a mutated or wrong-tag asset.
got_sha="$(sha256sum "$tmp/unyt.happ" | awk '{print $1}')"
[ "$got_sha" = "$expected_sha" ] ||
  fail "inherited unyt.happ sha256 $got_sha != committed lineage.json $expected_sha (mutated or wrong-tag release asset)"
got_cli_sha="$(sha256sum "$tmp/unyt_cli" | awk '{print $1}')"
[ "$got_cli_sha" = "$expected_cli_sha" ] ||
  fail "inherited unyt_cli sha256 $got_cli_sha != committed lineage.json $expected_cli_sha (mutated or wrong-tag release asset)"

# No DNA-source-diff check: the digest guard above already pins the shipped unyt.happ to the parent
# vM.m.0's exact bytes, so a UI release can never ship a different DNA. A UI patch may deliberately
# ship a backward-compatible UI on the parent's DNA even after the DNA source has moved on toward the
# next migration; which kind a tag is is the operator's call (vM.m.p = UI), not CI's to re-derive.

# 3. Place the inherited artifacts + repack ONLY the UI. hc web-app pack consumes the inherited
#    ./unyt.happ (never repacks the DNA) and the freshly built ../ui/white-label/dist.zip.
#    NOT --recursive: that makes hc ignore the pre-built ./unyt.happ and rebuild the whole chain from
#    the manifests down to the zome wasm, which a UI release never compiles.
cp "$tmp/unyt.happ" "$ROOT/unyt/workdir/unyt.happ"
[ -f "$tmp/alliance.dna" ] && cp "$tmp/alliance.dna" "$ROOT/unyt/dnas/alliance/workdir/alliance.dna"
#    unyt_cli goes where a migration release's `cargo build --release` leaves it, so the workflow
#    declares one artifact path for both release kinds. A release asset carries no mode bit; restore it.
mkdir -p "$ROOT/unyt/target/release"
cp "$tmp/unyt_cli" "$ROOT/unyt/target/release/unyt_cli"
chmod 755 "$ROOT/unyt/target/release/unyt_cli"
#    `--ignore-engines` for the same reason as the White-label UI workflow: hc-spin's native helper
#    declares `engines.node >= 24` and this nix shell ships node 22, and yarn aborts the WHOLE install
#    on an engine mismatch. Without it a UI release dies here — in publish-happ, the first job — so
#    there would be no release object at all, not merely no installers.
( cd "$ROOT/unyt" && nix develop --no-update-lock-file --accept-flake-config --command bash -c \
  "yarn install --frozen-lockfile --ignore-engines && yarn workspace white-label package && hc web-app pack workdir" )

echo "inherit: UI release $TAG built on inherited $PARENT_TAG DNA (unyt.happ sha256 $got_sha, unyt_cli sha256 $got_cli_sha) — DNA not rebuilt."
