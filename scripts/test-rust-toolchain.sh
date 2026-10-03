#!/usr/bin/env bash
# check-rust-toolchain.sh against rust.yaml fixtures shaped like the app's, and the release workflow
# against the Rust it declares. Needs mikefarah yq v4 on PATH, as GitHub's Ubuntu runners carry.
set -euo pipefail

command -v yq >/dev/null || {
  echo "yq not found: these tests read the YAML with mikefarah yq v4" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# shellcheck source-path=SCRIPTDIR source=test-assert.sh
. "$here/test-assert.sh"

step() { printf '%s\n' "$1" | sed '1s/^/      - /; 2,$s/^/        /'; } # <lines of one step>
ci() { # <lint job's Rust step> <test job's Rust step>
  {
    printf 'jobs:\n  lint:\n    steps:\n      - uses: actions/checkout@v4\n'
    printf '      # - uses: dtolnay/rust-toolchain@1.0.0\n'
    step "$1"
    printf '  test:\n    steps:\n'
    step "$2"
  } >"$tmp/rust.yaml"
  echo "$tmp/rust.yaml"
}
pin() { echo "uses: dtolnay/rust-toolchain@$1"; }
with_input() { printf '%s\nwith:\n  toolchain: %s\n' "$(pin "$1")" "$2"; } # <ref> <toolchain input>
known=6c977a6ca4077a0ceb28ffbe03f59d46e9ac8772
toolchain() { bash "$here/check-rust-toolchain.sh" "$@"; }

check "both jobs on the release's Rust pass" \
  toolchain "$(ci "$(pin 1.98.1)" "$(pin 1.98.1)")" 1.98.1
check "an app on another Rust fails the release, naming both" \
  refuses "tests the app with Rust 1.95.0, but this release installs Rust 1.98.1" \
  toolchain "$(ci "$(pin 1.95.0)" "$(pin 1.95.0)")" 1.98.1
check "jobs on two Rusts fail the release, naming them" \
  refuses "pins more than one Rust (1.95.0, 1.98.1), and this release installs Rust 1.98.1" \
  toolchain "$(ci "$(pin 1.98.1)" "$(pin 1.95.0)")" 1.98.1
check "whichever job is left behind" \
  refuses "pins more than one Rust (1.95.0, 1.98.1)" \
  toolchain "$(ci "$(pin 1.95.0)" "$(pin 1.98.1)")" 1.98.1
check "an app that pins no Rust fails the release" \
  refuses "pins no Rust with dtolnay/rust-toolchain, and this release installs Rust 1.98.1" \
  toolchain "$(ci "run: rustup show" "run: rustup show")" 1.98.1
check "a pin that floats fails the release" \
  refuses "tests the app with Rust stable" \
  toolchain "$(ci "$(pin stable)" "$(pin stable)")" 1.98.1
check "a quoted pin with a trailing comment is read" \
  toolchain "$(ci "uses: \"dtolnay/rust-toolchain@1.98.1\" # not @stable" "uses: 'dtolnay/rust-toolchain@1.98.1'")" 1.98.1
check "a quoted pin on another Rust is read too" \
  refuses "pins more than one Rust (1.95.0, 1.98.1)" \
  toolchain "$(ci "$(pin 1.98.1)" "uses: 'dtolnay/rust-toolchain@1.95.0'")" 1.98.1
check "a pin in a flow mapping is read" \
  refuses "pins more than one Rust (1.95.0, 1.98.1)" \
  toolchain "$(ci "$(pin 1.98.1)" "{ name: Rust#1, uses: dtolnay/rust-toolchain@1.95.0 }")" 1.98.1
check "as is a folded one" \
  refuses "pins more than one Rust (1.95.0, 1.98.1)" \
  toolchain "$(ci "$(pin 1.98.1)" "$(printf 'uses: >-\n  dtolnay/rust-toolchain@1.95.0')")" 1.98.1
check "and an owner in another case" \
  refuses "pins more than one Rust (1.95.0, 1.98.1)" \
  toolchain "$(ci "$(pin 1.98.1)" "uses: Dtolnay/rust-toolchain@1.95.0")" 1.98.1
check "a pin named in a script is not a step" \
  toolchain "$(ci "$(pin 1.98.1)" "run: echo dtolnay/rust-toolchain@1.95.0")" 1.98.1
check "a known commit installs its toolchain input" \
  toolchain "$(ci "$(with_input "$known" 1.98.1)" "$(pin 1.98.1)")" 1.98.1
check "and is held to it" \
  refuses "pins more than one Rust (1.95.0, 1.98.1)" \
  toolchain "$(ci "$(with_input "$known" 1.95.0)" "$(pin 1.98.1)")" 1.98.1
check "a commit this check does not know fails the release" \
  refuses "at commit eb0a44f258ec94ab9ee0f14f998f4cf332c25d3a, which this check does not know" \
  toolchain "$(ci "$(with_input eb0a44f258ec94ab9ee0f14f998f4cf332c25d3a 1.98.1)" "$(pin 1.98.1)")" 1.98.1
check "a version ref ignores a toolchain input, as the action does" \
  toolchain "$(ci "$(with_input 1.98.1 1.95.0)" "$(pin 1.98.1)")" 1.98.1
check "a channel ref installs its toolchain input" \
  refuses "tests the app with Rust 1.95.0" \
  toolchain "$(ci "$(with_input stable 1.95.0)" "$(with_input stable 1.95.0)")" 1.98.1
check "a toolchain key outside with: is not an input" \
  refuses "pins more than one Rust (1.95.0, 1.98.1)" \
  toolchain "$(ci "$(printf '%s\nenv:\n  toolchain: 1.98.1' "$(with_input master 1.95.0)")" "$(pin 1.98.1)")" 1.98.1
check "a rust.yaml that is not YAML fails the release" \
  refuses "does not read as a workflow" toolchain "$(printf 'jobs: [\n' >"$tmp/bad.yaml" && echo "$tmp/bad.yaml")" 1.98.1
check "an app with no rust.yaml fails the release" \
  refuses "$tmp/absent.yaml is missing or unreadable, and this release installs Rust 1.98.1" \
  toolchain "$tmp/absent.yaml" 1.98.1
check "a release that declares no Rust fails" \
  refuses "is RUST_TOOLCHAIN set?" toolchain "$(ci "$(pin 1.98.1)" "$(pin 1.98.1)")" ""

rel="$here/../.github/workflows/release-tauri-app.yaml"
check "the release declares its Rust as a version" \
  grep -qxE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$(yq '.env.RUST_TOOLCHAIN' "$rel")"
check "and nothing in it sets it again" \
  test "$(yq '[.jobs[] | ((.env // {}), (.steps[]? | (.env // {}))) | select(has("RUST_TOOLCHAIN"))] | length' "$rel")" = 0
another_rust() { # anything in the release that picks a Rust other than its dtolnay steps
  yq '.jobs[].steps[]?.uses // "" | select(test("(?i)toolchain") and (test("(?i)^dtolnay/rust-toolchain@") | not))' "$rel"
  grep -v '^[[:space:]]*#' "$rel" |
    grep -E 'RUST_TOOLCHAIN=|RUSTUP_TOOLCHAIN|rustup[[:space:]]+(default|override)|cargo[[:space:]]+\+|rust-toolchain\.toml' || true
}
check "or picks a Rust another way" test -z "$(another_rust)"
check "every Rust it installs is the one it declares" \
  toolchain "$rel" '${{ env.RUST_TOOLCHAIN }}'
check "on every run" \
  test "$(yq '[.jobs[].steps[]? | select((.uses // "") | test("(?i)^dtolnay/rust-toolchain@")) |
    select(has("if") or has("continue-on-error"))] | length' "$rel")" = 0

check_step='.jobs["build-happ"].steps[] | select((.run // "") | test("check-rust-toolchain"))'
check "stage 1 runs the check as it is, with nothing to skip or soften it" \
  test "$(yq "[$check_step | (keys | join(\",\")) + \" \" + .run] | join(\"|\")" "$rel")" = \
  'name,run bash scripts/check-rust-toolchain.sh unyt/.github/workflows/rust.yaml "$RUST_TOOLCHAIN"'

# One line per step of a job: install, check, build, nix (a build in the nix shell's Rust) or other.
steps() { # <job key>
  JOB="$1" yq '.jobs[strenv(JOB)].steps[] | (.uses // "") as $uses | (.run // "") as $run |
    [ ($uses | test("(?i)^dtolnay/rust-toolchain@")), ($run | test("check-rust-toolchain\.sh")),
      (($run | test("(^|[^[:alnum:]_./-])cargo\s")) or ($uses | test("(?i)^tauri-apps/tauri-action@"))),
      ($run | test("nix\s+develop")) ] | @tsv' "$rel" |
    awk -F'\t' '{ print $1 == "true" ? "install" : $2 == "true" ? "check" : $3 == "true" ? "build" : $4 == "true" ? "nix" : "other" }'
}
first() { # <job key> <kind>...: whichever of those kinds comes first in the job
  local job="$1"
  shift
  steps "$job" | awk -v kinds=" $* " 'index(kinds, " " $1 " ") { print $1; exit }'
}
check "stage 1 checks before it builds anything" test "$(first build-happ check build nix)" = check
check "stage 1 installs it before it builds unyt_cli" test "$(first build-happ install build)" = install
check "stage 2 installs it before it builds the installers" test "$(first release-tauri-app install build)" = install

report "rust toolchain"
