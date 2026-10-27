#!/usr/bin/env bash
# The CLI release cli-vX.Y.0.N, build N of unyt_cli for the app release vX.Y.0, or cli-vX.Y.0-dev.M.N for
# the pre-release vX.Y.0-dev.M:
#   cli-release.sh tag <cli tag>                  the tag and its version, as $GITHUB_OUTPUT lines
#   cli-release.sh version <unyt_cli> <version>   fails unless that binary prints the version
#   cli-release.sh notes <cli tag> <changelog>    the changelog's section for the tag's version
#   cli-release.sh publish <cli tag> <commit> <dna sha256> <cli dir>
# publish fails unless the app release carries an alliance.dna with <dna sha256>, the DNA the CLI was
# built with, and fails when the tag is already released. It deletes the tag's drafts, then publishes
# <cli dir>/unyt_cli alone as a pre-release, with <cli dir>/notes.md as its notes, at <commit>.
# Env for publish: GITHUB_REPOSITORY and GH_TOKEN.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

parse() { # <cli tag>: sets $version and $app_tag
  local n='(0|[1-9][0-9]*)'
  [[ "$1" =~ ^cli-v($n\.$n\.0(-dev\.$n)?)\.$n$ ]] ||
    fail "tag $1 is not cli-vMAJOR.MINOR.0.N or cli-vMAJOR.MINOR.0-dev.M.N"
  app_tag="v${BASH_REMATCH[1]}"
  version="${1#cli-v}"
}

case "${1:-}" in
  tag)
    parse "${2:?usage: cli-release.sh tag <cli tag>}"
    printf 'tag=%s\nversion=%s\n' "$2" "$version"
    ;;
  version)
    usage="usage: cli-release.sh version <unyt_cli> <version>"
    printed="$("${2:?$usage}" --version)"
    [ "$printed" = "unyt_cli ${3:?$usage}" ] || fail "$2 prints '$printed', not 'unyt_cli $3'"
    ;;
  notes)
    usage="usage: cli-release.sh notes <cli tag> <changelog>"
    parse "${2:?$usage}"
    notes="$(awk -v head="## [$version]" 'index($0, head) == 1 { p = 1; next } p && /^## \[/ { exit } p { print }' \
      "${3:?$usage}")"
    [ -n "$notes" ] || echo "::warning::$3 has no section [$version], so the release notes name only the build" >&2
    printf '%s\n' "$notes"
    ;;
  publish)
    usage="usage: cli-release.sh publish <cli tag> <commit> <dna sha256> <cli dir>"
    TAG="${2:?$usage}" COMMIT="${3:?$usage}" DNA="${4:?$usage}" DIR="${5:?$usage}"
    REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must name the repo the CLI releases from}"
    parse "$TAG"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    gh release download "$app_tag" --repo "$REPO" --pattern alliance.dna --dir "$tmp"
    [ "$(sha256 "$tmp/alliance.dna")" = "$DNA" ] || fail "this unyt_cli was built with another DNA than $app_tag carries"

    releases="$(gh api --paginate "repos/$REPO/releases?per_page=100" \
      --jq ".[] | select(.tag_name == \"$TAG\") | \"\(.id) \(.draft)\"")"
    ! grep -q ' false$' <<<"$releases" || fail "$TAG is already released: tag the next N"

    notes="The unyt_cli of [$app_tag](https://github.com/$REPO/releases/tag/$app_tag), with its DNA, built from $COMMIT."
    changes="$(cat "$DIR/notes.md")"
    [ -z "$changes" ] || notes="$changes"$'\n\n'"$notes"
    for id in $(cut -d' ' -f1 <<<"$releases"); do
      gh api -X DELETE "repos/$REPO/releases/$id" >/dev/null
    done
    # A pre-release, because GitHub can make a full release Latest despite make_latest false (cli/cli#10695).
    gh release create "$TAG" --repo "$REPO" --target "$COMMIT" --prerelease --title "unyt_cli $version" \
      --notes "$notes" "$DIR/unyt_cli"
    ;;
  *) fail "usage: cli-release.sh tag | version | notes | publish <arguments>" ;;
esac
