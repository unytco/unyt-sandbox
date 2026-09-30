#!/usr/bin/env bash
# Puts the pinned minisign on $GITHUB_PATH. Bumping it: verify the new tarball against jedisct1's
# minisign key before pinning its sha256.
set -euo pipefail

VERSION=0.12
SHA256=9a599b48ba6eb7b1e80f12f36b94ceca7c00b7a5173c95c3efc88d9822957e73

dir="${RUNNER_TEMP:?}/minisign"
mkdir -p "$dir"
curl -fsSL -o "$dir/minisign.tar.gz" \
  "https://github.com/jedisct1/minisign/releases/download/$VERSION/minisign-$VERSION-linux.tar.gz"
echo "$SHA256  $dir/minisign.tar.gz" | sha256sum -c -
tar xzf "$dir/minisign.tar.gz" -C "$dir" --strip-components=2 minisign-linux/x86_64/minisign
echo "$dir" >>"$GITHUB_PATH"
