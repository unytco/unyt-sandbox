#!/usr/bin/env bash
# cli-release.sh against a stand-in gh that holds a fixture repo's releases. Needs minisign on PATH
# (install-minisign.sh), the Tauri signer and jq.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck source-path=SCRIPTDIR source=test-assert.sh
. "$here/test-assert.sh"

# A stand-in gh over $GH: releases.json holds the releases, assets/<id>/ their files, and calls logs each
# release deleted or created.
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
method=GET words=() repo="" pattern="" dir="" target="" prerelease=false title="" notes="" filter=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --repo) repo="$2"; shift ;;
    --pattern) pattern="$2"; shift ;;
    --dir) dir="$2"; shift ;;
    --target) target="$2"; shift ;;
    --title) title="$2"; shift ;;
    --notes) notes="$2"; shift ;;
    --jq) filter="$2"; shift ;;
    --prerelease) prerelease=true ;;
    --paginate) ;;
    *) words+=("$1") ;;
  esac
  shift
done
set -- "${words[@]}"
releases="$GH/releases.json"
save() { jq "$@" "$releases" >"$GH/r" && mv "$GH/r" "$releases"; }
case "$1" in
  api)
    [[ "$2" == "repos/$REPO/releases"* ]] || { echo "the stand-in gh has no $2" >&2; exit 2; }
    if [ "$method" = DELETE ]; then
      save --argjson id "${2##*/}" 'map(select(.id != $id))'
      echo "delete ${2##*/}" >>"$GH/calls"
    else
      jq -r "$filter" "$releases"
    fi ;;
  release)
    [ "$repo" = "$REPO" ] || { echo "the stand-in gh holds no repo $repo" >&2; exit 2; }
    case "$2" in
      download)
        id="$(jq --arg tag "$3" '.[] | select(.tag_name == $tag) | .id' "$releases")"
        cp "$GH/assets/$id/$pattern" "$dir/" ;;
      create)
        id="$(jq 'map(.id) + [100] | max + 1' "$releases")"
        save --argjson id "$id" --arg tag "$3" --arg target "$target" --argjson prerelease "$prerelease" \
          --arg title "$title" --arg notes "$notes" '. + [{id: $id, tag_name: $tag, draft: false,
          prerelease: $prerelease, name: $title, body: $notes, target_commitish: $target}]'
        mkdir "$GH/assets/$id"
        cp "${@:4}" "$GH/assets/$id/"
        echo "create $id" >>"$GH/calls" ;;
    esac ;;
esac
EOF
chmod +x "$tmp/bin/gh"

commit=1111111111111111111111111111111111111111
printf 'the cli' >"$tmp/unyt_cli"
printf '\n### Added\n\n- a new command\n' >"$tmp/notes.md"
printf 'the 1.2.0 dna' >"$tmp/dna"
dna="$(sha256sum <"$tmp/dna" | cut -d' ' -f1)"
worlds=0 GH="" CLI=""
world() { # [<release JSON>...]: a fixture repo with those releases, and v1.2.0 and v1.2.0-dev.4 with the DNA
  worlds=$((worlds + 1))
  GH="$tmp/gh.$worlds" CLI="$tmp/cli.$worlds"
  mkdir -p "$GH/assets/1" "$GH/assets/2" "$CLI"
  : >"$GH/calls"
  jq -n --argjson more "$(jq -sc . <<<"$*")" \
    '[{id: 1, tag_name: "v1.2.0", draft: false}, {id: 2, tag_name: "v1.2.0-dev.4", draft: false}] + $more' >"$GH/releases.json"
  cp "$tmp/dna" "$GH/assets/1/alliance.dna"
  cp "$tmp/dna" "$GH/assets/2/alliance.dna"
  cp "$tmp/unyt_cli" "$tmp/notes.md" "$CLI/"
}
cli() { GITHUB_REPOSITORY=example/fork REPO=example/fork GH="$GH" PATH="$tmp/bin:$PATH" bash "$here/cli-release.sh" "$@"; }
"$here/tauri-signer/node_modules/.bin/tauri" signer generate --ci -p test -w "$tmp/release.key" >/dev/null
pubkey="$(cat "$tmp/release.key.pub")"
published() { # <cli tag> [<dna sha256>]
  TAURI_SIGNING_PRIVATE_KEY="$(cat "$tmp/release.key")" TAURI_SIGNING_PRIVATE_KEY_PASSWORD=test \
    cli publish "$1" "$commit" "${2:-$dna}" "$pubkey" "$CLI" >/dev/null
}
release_of() { # <tag> <filter>: the filter on the tag's one release
  jq -r --arg tag "$1" "[.[] | select(.tag_name == \$tag)] | if length == 1 then .[0] | $2 else \"\(length) releases\" end" \
    "$GH/releases.json"
}
fields() { release_of "$1" "[$2] | map(tostring) | join(\" \")"; } # <tag> <fields>
built() { echo "The unyt_cli of [$1](https://github.com/example/fork/releases/tag/$1), with its DNA, built from $commit."; }

check "a CLI tag names its version" test "$(cli tag cli-v1.2.0-dev.4.3)" = $'tag=cli-v1.2.0-dev.4.3\nversion=1.2.0-dev.4.3'
for tag in v1.2.0 cli-v1.2.0 cli-v1.2.3.0 cli-v1.2.0.01 cli-v1.2.0-rc.1.0; do
  check "\"$tag\" is no CLI tag" refuses "tag $tag is not cli-vMAJOR.MINOR.0.N" cli tag "$tag"
done

printf '#!/bin/sh\necho "unyt_cli 1.2.0.3"\n' >"$tmp/bin/unyt_cli"
chmod +x "$tmp/bin/unyt_cli"
check "a unyt_cli that prints the release's version passes" cli version "$tmp/bin/unyt_cli" 1.2.0.3
check "one that prints another fails" refuses "prints 'unyt_cli 1.2.0.3', not 'unyt_cli 1.2.0.4'" \
  cli version "$tmp/bin/unyt_cli" 1.2.0.4

changelog="$tmp/CHANGELOG.md"
printf '%s\n' '# Changelog' '' '## [Unreleased]' '' '- next' '' '## [1.2.0.10] - 2026-10-20' '' '- tenth' '' \
  '## [1.2.0.1]' '' '### Added' '' '- first' '' '## [1.2.0.0]' '' '- zeroth' >"$changelog"
check "the notes are the changelog's section for the tag's version" \
  test "$(cli notes cli-v1.2.0.1 "$changelog")" = $'\n### Added\n\n- first'
check "a version with no section has no notes, and warns" \
  eval '[ -z "$(cli notes cli-v1.2.0.2 "$changelog" 2>"$tmp/warned")" ] &&
    grep -qxF "::warning::$changelog has no section [1.2.0.2], so the release notes name only the build" "$tmp/warned"'

world
check "a CLI built with another DNA than its app release carries publishes nothing" eval \
  'refuses "this unyt_cli was built with another DNA than v1.2.0 carries" published cli-v1.2.0.0 "$(printf "%064d" 0)" &&
    [ ! -s "$GH/calls" ]'

world
check "a CLI release with its app release's DNA publishes" published cli-v1.2.0.0
check "at the build's commit, as a pre-release" \
  test "$(fields cli-v1.2.0.0 '.draft, .prerelease, .target_commitish')" = "false true $commit"
check "its notes are its changelog's, then the build's" \
  test "$(release_of cli-v1.2.0.0 .body)" = $'\n### Added\n\n- a new command\n\n'"$(built v1.2.0)"
carries() { # <assets dir>: unyt_cli, and SHA256SUMS that checks it, signed for the release key
  test "$(ls "$1" | tr '\n' ' ')" = "SHA256SUMS SHA256SUMS.minisig unyt_cli " && cmp -s "$1/unyt_cli" "$tmp/unyt_cli" &&
    (cd "$1" && sha256sum --check --strict --quiet SHA256SUMS) &&
    minisign -Vqm "$1/SHA256SUMS" -P "$(base64 -d <<<"$pubkey" | sed -n 2p)"
}
check "it carries unyt_cli and SHA256SUMS signed for the release key" carries "$GH/assets/$(release_of cli-v1.2.0.0 .id)"

world '{"id": 50, "tag_name": "cli-v1.2.0.0", "draft": true}'
check "a draft of the tag is deleted, and the release published in its place" eval \
  'published cli-v1.2.0.0 && test "$(tr "\n" " " <"$GH/calls")/$(release_of cli-v1.2.0.0 .id)" = "delete 50 create 101 /101"'

world '{"id": 50, "tag_name": "cli-v1.2.0.0", "draft": false}'
check "a tag already released is never released again" \
  eval 'refuses "cli-v1.2.0.0 is already released: tag the next N" published cli-v1.2.0.0 && [ ! -s "$GH/calls" ]'

world
: >"$CLI/notes.md"
check "a pre-release app's CLI release, with no notes of its own, has notes that name only the build" \
  eval 'published cli-v1.2.0-dev.4.0 && test "$(release_of cli-v1.2.0-dev.4.0 .body)" = "$(built v1.2.0-dev.4)"'

report "CLI release scripts"
