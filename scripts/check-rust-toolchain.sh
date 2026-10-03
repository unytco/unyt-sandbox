#!/usr/bin/env bash
# Fails unless every dtolnay/rust-toolchain step in a workflow installs the one Rust given:
#   check-rust-toolchain.sh <workflow.yaml> <toolchain>
# A job that picks its Rust another way, such as rustup, RUSTUP_TOOLCHAIN or a nix shell, is not seen.
# Reads the YAML with mikefarah yq v4, which GitHub's Ubuntu runners carry.
set -euo pipefail

# Commits of dtolnay/rust-toolchain whose action.yml installs its toolchain input. A commit on a
# version branch ignores that input, so a commit not listed here fails until its action.yml is read.
reads_input=" 6c977a6ca4077a0ceb28ffbe03f59d46e9ac8772 "

fail() {
  echo "::error::$*" >&2
  exit 1
}

[ $# -eq 2 ] || fail "usage: check-rust-toolchain.sh <workflow.yaml> <toolchain>"
CI="$1"
WANT="$2"
[ -n "$WANT" ] || fail "no Rust to hold $CI to: is RUST_TOOLCHAIN set?"
{ [ -f "$CI" ] && [ -r "$CI" ]; } ||
  fail "$CI is missing or unreadable, and this release installs Rust $WANT: is the unyt submodule checked out?"
[[ "$(yq --version 2>&1 || true)" == *mikefarah/yq*" version v4."* ]] || fail "this check needs mikefarah yq v4 on PATH"

steps="$(yq '.jobs[].steps[]? | select((.uses // "") | test("(?i)^dtolnay/rust-toolchain@")) |
  [(.uses | sub("^[^@]*@", "")), ((.with.toolchain // "") | tostring)] | @tsv' "$CI")" ||
  fail "$CI does not read as a workflow, and this release installs Rust $WANT"

# A version ref is a branch with the version built in, which takes no toolchain input.
pins=""
while IFS=$'\t' read -r ref input; do
  [ -n "$ref" ] || continue
  if [[ "$ref" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    pins+="$ref"$'\n'
  elif [[ "$ref" =~ ^[0-9a-f]{40}$ && "$reads_input" != *" $ref "* ]]; then
    fail "$CI installs dtolnay/rust-toolchain at commit $ref, which this check does not know, and this release installs Rust $WANT"
  else
    pins+="${input:-$ref}"$'\n'
  fi
done <<<"$steps"
pins="$(sort -u <<<"${pins%$'\n'}")"

[ -n "$pins" ] || fail "$CI pins no Rust with dtolnay/rust-toolchain, and this release installs Rust $WANT"
[[ "$pins" != *$'\n'* ]] ||
  fail "$CI pins more than one Rust (${pins//$'\n'/, }), and this release installs Rust $WANT"
[ "$pins" = "$WANT" ] ||
  fail "$CI tests the app with Rust $pins, but this release installs Rust $WANT"
echo "Rust $WANT, as $CI pins"
