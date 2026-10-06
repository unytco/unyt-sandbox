#!/usr/bin/env bash
# The key a release run signs its updates and SHA256SUMS with, as a $GITHUB_OUTPUT line:
#   signing-key.sh <tag>      prints  key=release    for vMAJOR.MINOR.PATCH
#                                     key=throwaway  for any other tag, such as vMAJOR.MINOR.PATCH-dev.N
set -euo pipefail

TAG="${1:?usage: signing-key.sh <tag>}"
n='(0|[1-9][0-9]*)'
if [[ "$TAG" =~ ^v$n\.$n\.$n$ ]]; then echo "key=release"; else echo "key=throwaway"; fi
