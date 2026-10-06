#!/usr/bin/env bash
# The release KIND a tag names, and for a UI release its lineage pin:
#
#   vM.m.0        → "migration"  a new DNA lineage begins; the DNA is built from source.
#   vM.m.p (p>0)  → "ui"         the lineage continues; the DNA is inherited from vM.m.0 verbatim.
#
# The kind is derived from the tag alone (no flag, no branch convention). For a UI release this also
# asserts this repo's lineage/<owner>/<name>.json pins THIS tag's lineage and echoes its parent tag.
# Output is `key=value` lines meant for `>> "$GITHUB_OUTPUT"`:
#   kind=migration|ui
#   parent_tag=vM.m.0        (ui only)
#
# Usage:  release-kind.sh <git-tag>      e.g.  v0.94.0  (migration)  or  v0.94.1  (ui)
# Env: GITHUB_REPOSITORY, the repo whose pin a UI release takes.
set -euo pipefail

TAG="${1:?usage: release-kind.sh <git-tag>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "release-kind: $*" >&2; exit 1; }

# vMAJOR.MINOR.PATCH, ignoring any -dev.* suffix (a dev build of a .0 is still a migration build).
core="${TAG#v}"; core="${core%%-*}"
IFS=. read -r major minor patch <<<"$core"
[[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]] ||
  fail "tag $TAG is not vMAJOR.MINOR.PATCH"
lineage="$major.$minor"

if [ "$patch" -eq 0 ]; then
  echo "kind=migration"
  exit 0
fi

PIN="$ROOT/lineage/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must name the repo whose pin a UI release takes}.json"
[ -f "$PIN" ] || fail "UI release $TAG needs a committed lineage/$GITHUB_REPOSITORY.json"
pin_lineage="$(jq -r '.lineage' "$PIN")"
parent_tag="$(jq -r '.parent_tag' "$PIN")"
[ "$pin_lineage" = "$lineage" ] ||
  fail "lineage/$GITHUB_REPOSITORY.json pins lineage '$pin_lineage', but tag $TAG is on lineage '$lineage': update the pin before cutting a UI release on a new lineage"
[ "$parent_tag" = "v$major.$minor.0" ] ||
  fail "lineage/$GITHUB_REPOSITORY.json parent_tag '$parent_tag' should be v$major.$minor.0 for tag $TAG"

echo "kind=ui"
echo "parent_tag=$parent_tag"
