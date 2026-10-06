#!/usr/bin/env bash
# The scripts that choose what a release builds and where it publishes, against fixture repos and apps
# and a stand-in gh, nix and docker, and the release workflows' wiring of them. No check takes its
# expected values from this repo's own app or network, so a fork runs it unchanged. Needs jq and
# mikefarah's yq v4.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
yq --version 2>/dev/null | grep -q 'mikefarah.* v4\.' || { echo "these tests read the workflows with mikefarah's yq v4" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
# shellcheck source-path=SCRIPTDIR source=test-assert.sh
. "$here/test-assert.sh"

refused() { # <description> <error text> <command...>: refused with the error, and nothing reaches the outputs
  local what="$1" want="$2" out
  shift 2
  check "$what" refuses "$want" "$@"
  out="$("$@" 2>/dev/null)" || true
  check "$what, and it prints nothing" test -z "$out"
}
quietly() { "$@" >/dev/null 2>&1; }

# This repo's own files.
release_app() { GITHUB_REPOSITORY=example/fork bash "$here/release-app.sh" "$@"; }
unset_in() { # <file at the repo root>: each value it has not set yet, as the release names it
  jq -r --arg file "$1" 'paths(type == "string" and startswith("TO BE SET"))
    | "\($file) has not set \(map(tostring) | join(".")) yet"' "$here/../$1"
}
waiting="$(unset_in identity.json; unset_in network.json)"
if [ -z "$waiting" ]; then
  check "this repo's build takes network.json's values, and updates from this repo" test "$(release_app build-env)" = \
    "$(jq -r '.build | to_entries[] | "\(.key)=\(.value)"' "$here/../network.json"; echo UNYT_RELEASE_REPO=example/fork)"
  check "its release notes name the network and each of its values" test "$(release_app notes)" = \
    "$(printf '\n### Network: %s\n\n' "$(jq -r .name "$here/../network.json")"
      jq -r '.build | to_entries[] | "- `\(.key)`: \(.value)"' "$here/../network.json")"
else
  while IFS= read -r unset; do refused "this repo's release is refused while $unset" "$unset" release_app build-env; done \
    <<<"$waiting"
fi

check "the README checks downloads against the key identity.json pins" test \
  "$(sed -n 's/^minisign -VHm SHA256SUMS -P //p' "$here/../README.md")" = \
  "$(jq -r .plugins.updater.pubkey "$here/../identity.json" | base64 -d | sed -n 2p)"

# A repo of fixture files to break: release-app.sh reads identity.json and network.json beside scripts/.
repo="$tmp/repo"
mkdir -p "$repo/scripts"
cp "$here/release-app.sh" "$here/updater-verify.sh" "$here/updater-signing.sh" "$repo/scripts/"
key="$(printf 'untrusted comment: minisign public key\n%s\n' "$(printf 'Ed%040d' 1 | base64 -w0)" | base64 -w0)"
fixtures() { # both fixture files as good ones
  jq -n --arg key "$key" '{identifier: "co.example.app", productName: "Example App", mainBinaryName: "example-app",
    plugins: {updater: {pubkey: $key},
      "deep-link": {mobile: [{scheme: ["example-app"]}], desktop: {schemes: ["example-app"]}}}}' >"$repo/identity.json"
  jq -n '{name: "Example Net", build: {UNYT_JOINING_SERVICE_URL: "https://joining.example",
    VITE_MIGRATION_SERVICE_URL: "https://migration.example", VITE_HOT_BRIDGE_URL: "https://hot-bridge.example",
    VITE_HOT_LOCK_VAULT: "0x\("0" * 39)1", VITE_ETH_NETWORK: "sepolia"}}' >"$repo/network.json"
}
fixture() { GITHUB_REPOSITORY="${REPOSITORY-example/fork}" bash "$repo/scripts/release-app.sh" "$@"; }
edit() { jq "$2" "$repo/$1" >"$tmp/edited" && mv "$tmp/edited" "$repo/$1"; } # <file> <jq edit>
broken() { # <description> <error text> <file> <jq edit>: the fixtures, so edited, refuse a release with the error
  fixtures
  edit "$3" "$4"
  refused "$1" "$2" fixture build-env
}
fixtures
check "a fork's build takes its network's values, and updates from the fork" test "$(fixture build-env)" = \
  "$(jq -r '.build | to_entries[] | "\(.key)=\(.value)"' "$repo/network.json"; echo UNYT_RELEASE_REPO=example/fork)"
check "its release notes name its network" eval 'grep -qx "### Network: Example Net" <<<"$(fixture notes)"'
for repository in "" example 'example/.' 'example/..' "example/fork
VITE_ETH_NETWORK=mainnet"; do
  REPOSITORY="$repository" refused "a build that updates from repo '${repository//$'\n'/\\n}' is refused" \
    "GITHUB_REPOSITORY" fixture build-env
done
# jq.exe as a Windows runner's Git Bash runs it.
mkdir "$tmp/windows"
printf '#!/bin/sh\n%s "$@" | sed "s/$/\\r/"\n' "$(command -v jq)" >"$tmp/windows/jq"
chmod +x "$tmp/windows/jq"
check "a Windows build row takes the same values" \
  test "$(PATH="$tmp/windows:$PATH" fixture build-env | od -c)" = "$(fixture build-env | od -c)"

for field in identifier productName mainBinaryName plugins.updater.pubkey; do
  broken "an identity with no $field is refused" "identity.json names no .$field" identity.json "del(.$field)"
  broken "an identity with an empty $field is refused" "identity.json names no .$field" identity.json ".$field = \"\""
done
for bad in 'identifier=" "' 'identifier="example"' 'identifier="co.example/app"' 'productName=" Example"' \
  'productName="Example/App"' 'productName="Example & App"' 'mainBinaryName="../app"' 'mainBinaryName="example app"'; do
  broken "an identity whose ${bad%%=*} is ${bad#*=} is refused" "identity.json has .${bad%%=*} '" identity.json ".$bad"
done
check "a product name with brackets is one this release can publish under" eval '
  fixtures && edit identity.json ".productName = \"Example [App] (Test) {1}\"" && fixture build-env >/dev/null'
for scheme in '""' '"Example-App"' '"example app"'; do
  broken "an identity whose scheme is $scheme is refused" "which is no URI scheme" identity.json \
    ".plugins[\"deep-link\"].desktop.schemes = [$scheme] | .plugins[\"deep-link\"].mobile = [{scheme: [$scheme]}]"
done
broken "an identity whose mobile scheme is not its desktop one is refused" "another mobile deep-link scheme than its desktop one" \
  identity.json '.plugins["deep-link"].mobile = [{scheme: ["other-app"]}]'
broken "an identity with two desktop schemes is refused" "names no one desktop deep-link scheme" \
  identity.json '.plugins["deep-link"].desktop.schemes += ["other"]'
for set in '.plugins["deep-link"].mobile[0].scheme += ["other"]' 'del(.plugins["deep-link"].mobile)' \
  '.plugins["deep-link"].mobile += [{scheme: ["other"]}]'; do
  broken "an identity whose deep links are $set is refused" "names no one mobile deep-link scheme" identity.json "$set"
done
for set in '.version = "9.9.9"' '.bundle = null' '.bundle.createUpdaterArtifacts = false' '.bundle.windows = null' \
  '.bundle.windows.wix.version = "1.0.0.0"'; do
  broken "an identity that sets $set is refused" "sets the version or the bundle settings the release writes" \
    identity.json "$set"
done
broken "an identity with a tab in its name is refused" "identity.json has a control character in productName" \
  identity.json '.productName = "Example\tApp"'
fixtures
edit identity.json '.bundle.icon = ["icons/example.png"]'
check "an identity with bundle settings of its own builds" quietly fixture build-env

for bad in UNYT_JOINING_SERVICE_URL=http://joining.example VITE_MIGRATION_SERVICE_URL=migration.example \
  UNYT_JOINING_SERVICE_URL='https://joining.example/ x' VITE_MIGRATION_SERVICE_URL=https://user@migration.example \
  VITE_HOT_BRIDGE_URL=https://hot-bridge.example/lock VITE_HOT_LOCK_VAULT=0x123 "VITE_HOT_LOCK_VAULT=0x$(printf '%041d' 1)" \
  VITE_HOT_LOCK_VAULT=0xE3E064e3C2EEf66cb93dA8D8114F5084E92F48D6 VITE_ETH_NETWORK=holesky \
  'VITE_HOT_BRIDGE_URL=https://hot-bridge.example/ TO BE SET' UNYT_JOINING_SERVICE_URL=https://. \
  VITE_MIGRATION_SERVICE_URL=https://migration..example VITE_HOT_BRIDGE_URL=https://- \
  UNYT_JOINING_SERVICE_URL=https://joining.example:0 "VITE_HOT_LOCK_VAULT=0x$(printf '%040d' 0)" \
  UNYT_JOINING_SERVICE_URL=https://joining.1 UNYT_JOINING_SERVICE_URL=https://joining.example-; do
  broken "a network whose ${bad%%=*} is ${bad#*=} is refused" "builds with ${bad%%=*} ${bad#*=}, which is no value it can take" \
    network.json ".build.${bad%%=*} = \"${bad#*=}\""
done
for set in '.build.FAUCET = "https://faucet.example"' 'del(.build.VITE_ETH_NETWORK)' '.build.VITE_ETH_NETWORK = 1' \
  '.chain = "x"' 'del(.name)'; do
  broken "a network whose values are $set is refused" "network.json does not hold a name and a build string" \
    network.json "$set"
done
broken "a network with no name is refused" "network.json names no network" network.json '.name = ""'
fixtures
edit network.json '.build.VITE_ETH_NETWORK = "mainnet"'
check "a network on Ethereum mainnet builds" eval 'grep -qx VITE_ETH_NETWORK=mainnet <<<"$(fixture build-env)"'
fixtures
edit network.json '.build.UNYT_JOINING_SERVICE_URL = "https://joining.xn--p1ai"'
check "a server under an internationalized top level domain builds" quietly fixture build-env
for shape in '.plugins["deep-link"].desktop.schemes = "example-app"' '.plugins = []'; do
  broken "an identity shaped as $shape is refused with a reason" "::error::identity.json" identity.json "$shape"
done
broken "a value with a line break is refused" "network.json has a control character in build.UNYT_JOINING_SERVICE_URL" \
  network.json '.build.UNYT_JOINING_SERVICE_URL = "https://joining.example\nUNYT_RELEASE_REPO=evil/repo"'
for placeholder in "TO BE SET: the bridge" "TO BE SET"; do
  broken "a network that has not set a value is refused" "network.json has not set build.VITE_HOT_BRIDGE_URL yet" \
    network.json ".build.VITE_HOT_BRIDGE_URL = \"$placeholder\""
done
broken "an identity that has not set its key is refused" "identity.json has not set plugins.updater.pubkey yet" \
  identity.json '.plugins.updater.pubkey = "TO BE SET: the key"'
fixtures
edit network.json '.build.VITE_HOT_LOCK_VAULT = "TO BE SET: the vault"'
refused "its release notes are refused too" "network.json has not set build.VITE_HOT_LOCK_VAULT yet" fixture notes
fixtures
edit network.json '.build.VITE_MIGRATION_SERVICE_URL = "https://migration.example:8443/v1/route?x=1"'
check "a server with a port and a path is a value a network can take, in a locale whose ranges are not bytes" \
  eval 'locale -a | grep -qix "en_US.utf-\?8" && LC_ALL=en_US.UTF-8 fixture build-env >/dev/null 2>&1'
fixtures
cat "$repo/network.json" "$repo/network.json" >"$tmp/twice.json" && mv "$tmp/twice.json" "$repo/network.json"
refused "a network.json of two documents is refused" "network.json is not one JSON document" fixture build-env
rm "$repo/network.json"
refused "a repo with no network.json is refused" "no identity.json and network.json" fixture build-env

# The identity a build merges, as tauri build --config merges it.
fixtures
mkdir -p "$tmp/app/src-tauri"
jq -n '{version: "0.0.1", productName: "Dev", identifier: "co.example.dev", mainBinaryName: "dev",
  build: {devUrl: "http://localhost:1420"}, app: {windows: [{label: "splash"}, {label: "main"}]}, bundle: {active: true},
  plugins: {updater: {pubkey: "", requireSignedVersion: true},
    "deep-link": {mobile: [{scheme: ["dev"]}], desktop: {schemes: ["dev", "dev-2"]}}}}' \
  >"$tmp/app/src-tauri/tauri.conf.json"
edit identity.json '.build.devUrl = null | .app.windows = [{label: "splash"}]'
merged() { jq -c "$1" "$tmp/merged.json"; } # <jq path>
check "identity.json merges over the app's configuration" fixture identity "$tmp/app" "$tmp/merged.json"
check "and the merged app is the identity" \
  test "$(merged '[.identifier, .productName, .mainBinaryName, .plugins["deep-link"][]]')" = \
  '["co.example.app","Example App","example-app",[{"scheme":["example-app"]}],{"schemes":["example-app"]}]'
check "the merge keeps what the identity leaves out" \
  test "$(merged '[.version, .bundle.active, .plugins.updater.requireSignedVersion]')" = '["0.0.1",true,true]'
check "the merge replaces an array whole, as tauri does" test "$(merged '.app.windows | length')" = 1
check "the merge drops what the identity sets to null, as tauri does" test "$(merged '.build | has("devUrl")')" = false
signs() { bash "$repo/scripts/updater-signing.sh" "$tmp/merged.json"; }
check "the merged app signs with the key the identity pins" test "$(signs)" = "pubkey=$key"
edit identity.json '.plugins.updater.pubkey = "TO BE SET: the key"'
check "an identity that has not set its key still merges, and its release does not sign" \
  eval 'fixture identity "$tmp/app" "$tmp/merged.json" && ! signs >/dev/null 2>&1'
check "an identity with no app checked out is refused" refuses "is the app checked out?" \
  fixture identity "$tmp/absent" "$tmp/merged.json"

# set-app-version.sh and check-version-contract.sh write and read the app beside them.
versioned="$tmp/versioned"
mkdir -p "$versioned/scripts" "$versioned/unyt/src-tauri"
cp "$here/set-app-version.sh" "$here/check-version-contract.sh" "$here/updater-verify.sh" "$versioned/scripts/"
app_tree() { # [crlf]: an app at version 0.108.0 whose workspace is 0.108.0 too
  printf '[workspace]\nmembers = ["src-tauri", "crates/cli"]\n\n[workspace.package]\nversion = "0.108.0"\n' \
    >"$versioned/unyt/Cargo.toml"
  printf '[dependencies.serde]\nversion = "1"\n\n[package]\nname = "unyt-app"\nversion = "0.108.0"\n' \
    >"$versioned/unyt/src-tauri/Cargo.toml"
  printf '%s\n' '# generated' 'version = 4' '' '[[package]]' 'name = "unyt-app-macros"' 'version = "0.108.0"' '' \
    '[[package]]' 'name = "unyt-app"' 'version = "0.108.0"' 'dependencies = [' ' "serde",' ']' '' \
    '[[package]]' 'name = "unyt_cli"' 'version = "0.108.0"' >"$versioned/unyt/Cargo.lock"
  printf '{"version": "0.108.0", "productName": "Unyt"}\n' >"$versioned/unyt/src-tauri/tauri.conf.json"
  [ "${1:-}" != crlf ] || sed -i 's/$/\r/' "$versioned/unyt/Cargo.lock" "$versioned/unyt/src-tauri/Cargo.toml"
  rm -rf "$tmp/unyt.before"
  cp -r "$versioned/unyt" "$tmp/unyt.before"
}
set_version() { bash "$versioned/scripts/set-app-version.sh" "$@"; }
contract() { bash "$versioned/scripts/check-version-contract.sh" "$@"; }
changed() { diff "$tmp/unyt.before/$1" "$versioned/unyt/$1" | grep '^[<>]' | tr -d '\r' | tr '\n' '|'; } # <file>
app_tree
check "the version contract refuses an app the release has not written its version into" \
  refuses "tag v0.110.0 (release version 0.110.0) disagrees with src-tauri Cargo.toml version 0.108.0" contract v0.110.0
check "a release writes its tag's version into the app" set_version v0.110.0-dev.3
check "and the version contract holds" test "$(contract v0.110.0-dev.3)" = 0.110.0-dev.3
check "it writes tauri.conf.json's version" test "$(jq -r .version "$versioned/unyt/src-tauri/tauri.conf.json")" = 0.110.0-dev.3
check "it writes the app package's version, and nothing else of Cargo.toml" \
  test "$(changed src-tauri/Cargo.toml)" = '< version = "0.108.0"|> version = "0.110.0-dev.3"|'
check "it writes the app package's Cargo.lock entry, and no other" \
  test "$(changed Cargo.lock)" = '< version = "0.108.0"|> version = "0.110.0-dev.3"|'
check "and leaves the workspace version, which the zomes build with" diff "$tmp/unyt.before/Cargo.toml" "$versioned/unyt/Cargo.toml"
app_tree crlf
check "a Windows checkout's Cargo files are written too" eval 'set_version v0.1.0 && test "$(contract v0.1.0)" = 0.1.0'
crlf() { ! grep -qv $'\r$' "$versioned/unyt/$1"; } # <file>: every line ends in a carriage return
check "and keep their line endings" eval 'crlf Cargo.lock && crlf src-tauri/Cargo.toml'
app_tree
sed -i 's/^name = "unyt-app"$/name = "renamed"/' "$versioned/unyt/Cargo.lock"
check "an app whose Cargo.lock has no entry for its package is refused" refuses "has no one entry for unyt-app" set_version v0.1.0
app_tree
sed -i '0,/^version = "0.108.0"$/!{/^name = "unyt-app"$/{n;s/.*/version = "0.107.0"/}}' "$versioned/unyt/Cargo.lock"
check "the version contract refuses a Cargo.lock that disagrees" refuses "Cargo.lock has 0.107.0 version for the app package" \
  contract v0.108.0
app_tree
sed -i 's/^name = "unyt-app"$/name = "renamed"/' "$versioned/unyt/Cargo.lock"
check "the version contract refuses a Cargo.lock with no entry for the app" refuses "Cargo.lock has no version for the app package" \
  contract v0.108.0
for tag in 0.1.0 v0.1 v01.1.0 v0.1.0-rc.1 v0.1.0-dev.x v0.1.0-dev.01 'v0.1.0"; rm -rf /'; do
  app_tree
  check "tag $tag names no version, and nothing is written" \
    eval 'refuses "is not vMAJOR.MINOR.PATCH" set_version "$tag" && diff -r "$tmp/unyt.before" "$versioned/unyt"'
done
app_tree
chmod a-w "$versioned/unyt/Cargo.lock"
check "a Cargo.lock the release cannot write is refused" eval '[[ "$(set_version v0.1.0 2>&1)" == *"cannot write "*/Cargo.lock ]]'
chmod u+w "$versioned/unyt/Cargo.lock"

# A stand-in gh: `api <path> [--jq <filter>]` answers from <fixture>/api/<path>.json through the filter,
# and with --paginate from <fixture>/api/<path>.2.json too,
# `api -H Accept: application/octet-stream <path>` with <fixture>/api/<path> as it is, and
# `release download <tag>` serves <fixture>/releases/<owner>/<name>/<tag>/. nix notes that it ran.
gh_root="$tmp/gh"
mkdir -p "$tmp/bin" "$gh_root/api"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = api ]; then
  shift
  path="" filter=. raw="" pages=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --jq) filter="$2"; shift ;;
      -H) raw=1; shift ;;
      --paginate) pages=1 ;;
      *) path="${1%%\?*}" ;;
    esac
    shift
  done
  if [ -n "$raw" ]; then cat "$GH_ROOT/api/$path"; exit; fi
  [ -f "$GH_ROOT/api/$path.json" ] || { echo "Not Found (HTTP 404)" >&2; exit 1; }
  jq -r "$filter" "$GH_ROOT/api/$path.json"
  [ -z "$pages" ] || [ ! -f "$GH_ROOT/api/$path.2.json" ] || jq -r "$filter" "$GH_ROOT/api/$path.2.json"
  exit
fi
[ "$1 $2" = "release download" ] || exit 2
tag="$3" repo="" dir=""
shift 3
while [ "$#" -gt 0 ]; do
  case "$1" in --repo) repo="$2" ;; --dir) dir="$2" ;; esac
  shift
done
[ -d "$GH_ROOT/releases/$repo/$tag" ] || { echo "release not found" >&2; exit 1; }
cp "$GH_ROOT/releases/$repo/$tag"/* "$dir/"
EOF
printf '#!/bin/sh\ntouch "$NIX_CALLED"\n' >"$tmp/bin/nix"
chmod +x "$tmp/bin/gh" "$tmp/bin/nix"
stubbed() { PATH="$tmp/bin:$PATH" GH_ROOT="$gh_root" NIX_CALLED="$tmp/nix.called" "$@"; }
answers() { mkdir -p "$(dirname "$gh_root/api/$1")" && cat >"$gh_root/api/$1"; } # <path>: gh api answers with stdin

policies() { jq -n '$ARGS.positional as $p | {branch_policies: [range(0; $p | length; 2) | {type: $p[.], name: $p[. + 1]}]}' --args "$@"; }
environment() { # <name> <protection rule types> <custom branch policies> [<type> <policy>]...: a fixture environment
  # whose reviewer rule takes REVIEWERS reviewers (1), PREVENT_SELF_REVIEW (true) and CAN_ADMINS_BYPASS (false)
  local name="$1" rules="$2" custom="$3"
  shift 3
  jq -n --arg rules "$rules" --argjson custom "$custom" --argjson reviewers "${REVIEWERS:-1}" \
    --argjson own "${PREVENT_SELF_REVIEW:-true}" --argjson bypass "${CAN_ADMINS_BYPASS:-false}" '{can_admins_bypass: $bypass,
    protection_rules: [$rules | splits(",") | select(. != "") | {type: .} | if .type == "required_reviewers"
      then . + {prevent_self_review: $own, reviewers: [range($reviewers) | {type: "User"}]} else . end],
    deployment_branch_policy: (if $custom == null then null else {protected_branches: false, custom_branch_policies: $custom} end)}' |
    answers "repos/example/fork/environments/$name.json"
  policies "$@" | answers "repos/example/fork/environments/$name/deployment-branch-policies.json"
}
environment release required_reviewers,branch_policy true tag 'v*'
environment several required_reviewers,branch_policy true tag 'beta-*' tag 'v[0-9]*'
environment unreviewed branch_policy true tag 'v*'
environment any-ref required_reviewers null
environment protected-branches required_reviewers false
environment branch-too required_reviewers,branch_policy true tag 'v*' branch main
environment untyped required_reviewers,branch_policy true tag 'v*' null main
environment other-tags required_reviewers,branch_policy true tag 'release-*'
environment no-policies required_reviewers,branch_policy true
environment branch-on-page-2 required_reviewers,branch_policy true tag 'v*'
policies branch main | answers repos/example/fork/environments/branch-on-page-2/deployment-branch-policies.2.json
REVIEWERS=0 environment nobody required_reviewers,branch_policy true tag 'v*'
PREVENT_SELF_REVIEW=false environment self-review required_reviewers,branch_policy true tag 'v*'
CAN_ADMINS_BYPASS=true environment bypass required_reviewers,branch_policy true tag 'v*'
release_environment() { GITHUB_REPOSITORY=example/fork stubbed bash "$here/check-release-environment.sh" "$@"; }
check "an environment with a reviewer that admits the tag by a tag policy holds" release_environment release v0.110.0
check "one that admits it among other tags holds" release_environment several v0.110.0-dev.1
for name in unreviewed nobody; do
  check "an environment with no reviewer ($name) is refused" \
    refuses "environment $name has no required reviewers" release_environment "$name" v0.110.0
done
check "an environment whose tagger may approve their own release is refused" \
  refuses "environment self-review lets whoever pushed the tag approve its own signing" release_environment self-review v0.110.0
check "an environment an admin may push past is refused" \
  refuses "environment bypass lets an admin skip its reviewers" release_environment bypass v0.110.0
check "an environment that admits a branch on a later page of its policies is refused" \
  refuses "environment branch-on-page-2 admits the branch main" release_environment branch-on-page-2 v0.110.0
for name in any-ref protected-branches; do
  check "an environment that admits refs other than tags ($name) is refused" \
    refuses "environment $name admits other refs than its tags" release_environment "$name" v0.110.0
done
check "an environment that admits a branch beside its tags is refused" \
  refuses "environment branch-too admits the branch main" release_environment branch-too v0.110.0
check "an environment with a policy of no type is refused" \
  refuses "environment untyped admits the null main" release_environment untyped v0.110.0
for name in other-tags no-policies; do
  check "an environment that admits no such tag ($name) is refused" \
    refuses "environment $name admits no tag v0.110.0" release_environment "$name" v0.110.0
done
check "an environment that does not exist is refused, not created" \
  refuses "example/fork has no environment absent" release_environment absent v0.110.0

# release-kind.sh and inherit-ui-release.sh read lineage/<owner>/<name>.json, and inherit-ui-release.sh
# writes into unyt/, all under the repo root, so they run from a copy with its own pins and app.
pins="$tmp/pins"
mkdir -p "$pins/scripts" "$pins/unyt/workdir" "$pins/unyt/dnas/alliance/workdir"
cp "$here/release-kind.sh" "$here/inherit-ui-release.sh" "$pins/scripts/"
parent="$gh_root/releases/example/fork/v0.1.0"
mkdir -p "$parent"
printf 'the 0.1 happ' >"$parent/unyt.happ"
printf 'the 0.1 dna' >"$parent/alliance.dna"
printf 'the 0.1 cli' >"$parent/unyt_cli"
sum() { sha256sum <"$parent/$1" | cut -d' ' -f1; }
mkdir -p "$pins/lineage/example"
jq -n --arg h "$(sum unyt.happ)" --arg d "$(sum alliance.dna)" --arg c "$(sum unyt_cli)" \
  '{lineage: "0.1", parent_tag: "v0.1.0", happ_sha256: $h, dna_sha256: $d, cli_sha256: $c}' >"$pins/lineage/example/fork.json"
kind() { GITHUB_REPOSITORY="$1" bash "$pins/scripts/release-kind.sh" "$2"; } # <repo> <tag>
for tag in v0.2.0 v0.2.0-dev.1; do
  check "$tag is a migration release, whatever the repo pins" test "$(kind example/none "$tag")" = kind=migration
done
check "a UI release takes the pin of the repo it runs in" test "$(kind example/fork v0.1.3)" = "$(printf 'kind=ui\nparent_tag=v0.1.0')"
check "a UI release in a repo that pins nothing is refused" refuses "needs a committed lineage/example/other.json" \
  kind example/other v0.1.3
check "a UI release on another lineage than the repo pins is refused" refuses "pins lineage '0.1', but tag v0.2.1" \
  kind example/fork v0.2.1
for pin in "$here"/../lineage/*/*.json; do
  repository="${pin#"$here"/../lineage/}" repository="${repository%.json}"
  check "the pin of $repository resolves its lineage's UI releases" test "$(GITHUB_REPOSITORY="$repository" \
    bash "$here/release-kind.sh" "v$(jq -r .lineage "$pin").1" | sed -n 2p)" = "parent_tag=$(jq -r .parent_tag "$pin")"
done
inherit() { # <repo>
  rm -f "$tmp/nix.called" "$pins/unyt/workdir/unyt.happ"
  GITHUB_REPOSITORY="$1" stubbed bash "$pins/scripts/inherit-ui-release.sh" v0.1.1 v0.1.0
}
inherited() {
  inherit example/fork >/dev/null 2>&1 &&
    cmp -s "$parent/unyt.happ" "$pins/unyt/workdir/unyt.happ" &&
    cmp -s "$parent/unyt_cli" "$pins/unyt/target/release/unyt_cli" &&
    cmp -s "$parent/alliance.dna" "$pins/unyt/dnas/alliance/workdir/alliance.dna" && [ -e "$tmp/nix.called" ]
}
check "a UI release inherits its parent's DNA and CLI from this repo's releases, and packs the UI" inherited
mkdir -p "$pins/lineage/example" && cp "$pins/lineage/example/fork.json" "$pins/lineage/example/other.json"
check "a UI release whose parent is not on this repo's releases inherits nothing" \
  eval 'refuses "could not download" inherit example/other && [ ! -e "$tmp/nix.called" ]'
check "a UI release of a repo that pins nothing inherits nothing" refuses "missing lineage/example/none.json" inherit example/none
check "a UI release knows no repo but the one it runs in" refuses "GITHUB_REPOSITORY must name" inherit ""

# The probe, against a fixture app tree: ready, waiting, then broken.
probe_app="$tmp/probe-app"
mkdir -p "$probe_app/src-tauri/src" "$probe_app/ui/white-label"
cp "$tmp/app/src-tauri/tauri.conf.json" "$probe_app/src-tauri/"
cp "$here/fixtures/updater.rs" "$probe_app/src-tauri/src/"
printf '[package]\nname = "unyt-app"\nversion = "0.0.1"\n' >"$probe_app/src-tauri/Cargo.toml"
printf '[[package]]\nname = "unyt-app"\nversion = "0.0.1"\n' >"$probe_app/Cargo.lock"
reads_all() { # every value the release builds the fixture app with
  printf 'env("UNYT_JOINING_SERVICE_URL"); env("UNYT_RELEASE_REPO");\n' >"$probe_app/src-tauri/build.rs"
  printf 'env.VITE_%s;\n' MIGRATION_SERVICE_URL HOT_BRIDGE_URL HOT_LOCK_VAULT ETH_NETWORK >"$probe_app/ui/white-label/vite.config.js"
}
reads_all
cp "$here/release-probe.sh" "$here/set-app-version.sh" "$here/check-version-contract.sh" "$here/updater-asset-names.sh" \
  "$repo/scripts/"
mkdir -p "$probe_app/scripts" "$probe_app/dnas/alliance" "$probe_app/.github/workflows" "$repo/.github/workflows"
cp "$here/check-dna-pin.sh" "$repo/scripts/"
touch "$probe_app/scripts/check-dna-hashes.sh" "$probe_app/dnas/alliance/build-hashes"
rust_ci() { # <toolchain>: an app CI and a release workflow on that Rust
  printf 'jobs:\n  t:\n    steps:\n      - uses: dtolnay/rust-toolchain@6c977a6ca4077a0ceb28ffbe03f59d46e9ac8772\n        with:\n          toolchain: %s\n' \
    "$1" >"$probe_app/.github/workflows/rust.yaml"
}
printf 'env:\n  RUST_TOOLCHAIN: 1.2.3\n' >"$repo/.github/workflows/release-tauri-app.yaml"
rust_ci 1.2.3
cp "$here/check-rust-toolchain.sh" "$repo/scripts/"
probe() { env -u GITHUB_REPOSITORY bash "$repo/scripts/release-probe.sh" "$probe_app"; }
probe_says() { # <exit status> <line pattern>: the probe exits so, and prints a line matching the pattern
  local out rc=0
  out="$(probe 2>&1)" || rc=$?
  [ "$rc" -eq "$1" ] && grep -qE "$2" <<<"$out"
}
fixtures
check "the probe passes an app tree the release takes" quietly probe
check "and says the release signs" probe_says 0 '^ok +signing'
edit identity.json '.plugins.updater.pubkey = "TO BE SET: the key"'
check "the probe waits on a value the files have not set" \
  probe_says 0 '^waits +release +identity.json has not set plugins.updater.pubkey'
edit network.json '.build.VITE_MIGRATION_SERVICE_URL = "http://migration.example"'
check "the probe fails a release refused for more than what it has not set" probe_says 1 '^FAIL +release'
fixtures
edit identity.json '.plugins.updater.pubkey = "no key"'
check "the probe fails a release that would not sign" probe_says 1 '^FAIL +signing'
fixtures
sed -i 's/env.VITE_HOT_LOCK_VAULT;//; s/env.VITE_ETH_NETWORK;//' "$probe_app/ui/white-label/vite.config.js"
check "the probe fails an app tree that reads not every value its release builds it with" \
  probe_says 1 'reads no VITE_ETH_NETWORK, VITE_HOT_LOCK_VAULT, so'
reads_all
sed -i 's/env("UNYT_RELEASE_REPO");//' "$probe_app/src-tauri/build.rs"
check "the probe fails an app tree that does not read the repo it updates from" \
  probe_says 1 'the app in .* reads no UNYT_RELEASE_REPO, so'
reads_all
rm "$probe_app/dnas/alliance/build-hashes"
check "the probe fails an app tree a migration release cannot hold to its DNA hashes" \
  probe_says 1 'the pinned app has no dnas/alliance/build-hashes'
touch "$probe_app/dnas/alliance/build-hashes"
rust_ci 1.2.4
check "the probe fails an app tree whose CI builds with another Rust" probe_says 1 '^FAIL +rust'
rust_ci 1.2.3
sed -i 's/release_product(&app.package_info().name)/app.package_info().name.clone()/' "$probe_app/src-tauri/src/updater.rs"
check "the probe fails an app tree that looks its updates up under another name than the release's" \
  probe_says 1 '^FAIL +assets'
cp "$here/fixtures/updater.rs" "$probe_app/src-tauri/src/"
mv "$repo/scripts/release-app.sh" "$repo/scripts/release-app.real.sh"
printf '#!/usr/bin/env bash\n[ "$1" != build-env ] || exit 1\nexec bash "${0%%.sh}.real.sh" "$@"\n' >"$repo/scripts/release-app.sh"
check "the probe fails a release refused without a reason" probe_says 1 '^FAIL +release'
mv "$repo/scripts/release-app.real.sh" "$repo/scripts/release-app.sh"
rm "$probe_app/Cargo.lock"
check "the probe fails an app tree the release cannot write its version into" probe_says 1 '^FAIL +version'

# The smoke reads the repo and the app it was told, or this one's.
printf '{"assets": [{"id": 71, "name": "unyt_0.1.0_Example.App_default-arc_amd64_linux.deb", "size": 9}]}' |
  answers repos/example/fork/releases/7.json
printf 'the build' | answers repos/example/fork/releases/assets/71
smoke() { GITHUB_REPOSITORY=example/fork stubbed bash "$here/smoke/$1" "${@:2}" 2>/dev/null; } # <script> <arg>...
check "the smoke downloads an installer from this repo's releases" \
  eval 'test "$(cat "$(smoke download-release-asset.sh 7 _default-arc_amd64_linux.deb "$tmp/downloads")")" = "the build"'
check "the smoke lists the installers of this repo's releases" eval 'smoke release-inventory.sh 7 | grep -qx deb=true'
check "the smoke downloads from no repo it was not told" refuses "must name the release repo" \
  env -u UNYT_SMOKE_REPO -u GITHUB_REPOSITORY bash "$here/smoke/download-release-asset.sh" 1 _x.deb "$tmp/downloads"
check "the smoke lists the installers of no repo it was not told" refuses "must name the release repo" \
  env -u UNYT_SMOKE_REPO -u GITHUB_REPOSITORY -u UNYT_SMOKE_ASSETS -u UNYT_SMOKE_FROM bash "$here/smoke/release-inventory.sh" 1
for named in "-u UNYT_BUNDLE_ID" "UNYT_BUNDLE_ID="; do
  # shellcheck disable=SC2086 # an env option, or an assignment
  check "the smoke launches no app it was not told the identifier of ($named)" refuses "UNYT_BUNDLE_ID is unset" \
    env $named UNYT_SMOKE_SANDBOX="$tmp/launch" bash "$here/smoke/launch-and-assert.sh" "$(type -P true)"
done
# A stand-in docker: notes each call, and answers that its container is running.
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_CALLS"
[ "$1" != inspect ] || echo true
EOF
chmod +x "$tmp/bin/docker"
lane="$tmp/smoke-state/lane"
mkdir -p "$lane"
printf '%s' "$lane" >"$tmp/smoke-state/current"
printf 'ubuntu:22.04' >"$lane/image"
printf 'container-checks.sh' >"$lane/driver"
printf '%s' "$tmp/x.deb" >"$lane/artifact"
printf 'cid' >"$lane/cid"
launch_check() { # [<UNYT_BUNDLE_ID>]: the docker exec that runs the launch check
  rm -f "$tmp/docker.calls"
  env ${1+UNYT_BUNDLE_ID="$1"} UNYT_SMOKE_STATE="$tmp/smoke-state" DOCKER_CALLS="$tmp/docker.calls" PATH="$tmp/bin:$PATH" \
    bash "$here/smoke/run-smoke.sh" --exec launch >/dev/null 2>&1 || true
  grep -m1 '^exec .* --only launch ' "$tmp/docker.calls"
}
check "the smoke's container launches the app identity.json names" \
  eval 'launch_check "" | grep -qF -- "-e UNYT_BUNDLE_ID=$(jq -r .identifier "$here/../identity.json") "'
check "or the one it was told" eval 'launch_check co.example.told | grep -qF -- "-e UNYT_BUNDLE_ID=co.example.told "'
mkdir -p "$tmp/unnamed/scripts"
cp -r "$here/smoke" "$tmp/unnamed/scripts/"
printf '{}' >"$tmp/unnamed/identity.json"
unnamed_launch() {
  rm -f "$tmp/docker.calls"
  env -u UNYT_BUNDLE_ID UNYT_SMOKE_STATE="$tmp/smoke-state" DOCKER_CALLS="$tmp/docker.calls" PATH="$tmp/bin:$PATH" \
    bash "$tmp/unnamed/scripts/smoke/run-smoke.sh" --exec launch
}
mkdir "$tmp/no-jq"
for dir in ${PATH//:/ }; do
  for tool in "$dir"/*; do
    name="${tool##*/}"
    [ "$name" = jq ] || [ ! -x "$tool" ] || [ -L "$tmp/no-jq/$name" ] || ln -s "$tool" "$tmp/no-jq/$name"
  done
done
ln -sf "$tmp/bin/docker" "$tmp/no-jq/docker"
no_jq_launch() {
  rm -f "$tmp/docker.calls"
  env -u UNYT_BUNDLE_ID UNYT_SMOKE_STATE="$tmp/smoke-state" DOCKER_CALLS="$tmp/docker.calls" PATH="$tmp/no-jq" \
    bash "$here/smoke/run-smoke.sh" --exec launch
}
check "the smoke says so when it needs jq to read the app's identifier" eval '
  refuses "reading identity.json'"'"'s identifier needs jq" no_jq_launch && ! grep -q "^exec .* --only launch " "$tmp/docker.calls"'
check "the smoke runs no check when identity.json names no app" eval '
  refuses "identity.json names no identifier" unnamed_launch && ! grep -q "^exec .* --only launch " "$tmp/docker.calls"'

# The release workflow's wiring.
wf="$(yq -o=json "$here/../.github/workflows/release-tauri-app.yaml")"
wired() { jq -e "$@" <<<"$wf" >/dev/null; } # [<jq options>] <condition on the workflow>
check "a tag v<version> triggers a release, and nothing else does" wired '
  .on == {push: {tags: ["v[0-9]+.[0-9]+.[0-9]+", "v[0-9]+.[0-9]+.[0-9]+-dev.*"]}}'
pinned_app='bash scripts/set-app-version.sh "$TAG"'
check "stage 1 makes the pinned app the tag's version and identity.json's app before it builds anything" \
  wired --arg first "$pinned_app" '
  .jobs["build-happ"].steps | (map(.run // "" | startswith($first)) | index(true)) as $at
  | $at != null and ([.[:$at][] | .run // "" | test("make|cargo|yarn|nix develop")] | any | not)
  and .[$at].run == "\($first)\nbash scripts/release-app.sh identity unyt tauri.merged.json\nbash scripts/release-app.sh build-env >>\"$GITHUB_ENV\"\nbash scripts/release-app.sh reads unyt\n"
  and .[$at].env == {TAG: "${{ github.ref_name }}"}'
check "every build row does too, and holds the version contract, before it installs anything" wired --arg first "$pinned_app" '
  .jobs["release-tauri-app"].steps | (map(.run // "" | startswith($first)) | index(true)) as $at
  | (map(.name // "") | index("Install and prepare")) as $install
  | (map(.name // "") | index("Install jq on Windows")) as $jq
  | $at != null and $jq != null and $install != null and $jq < $at and $at < $install
  and .[$at].run == "\($first)\nbash scripts/check-version-contract.sh \"$TAG\"\nbash scripts/release-app.sh identity unyt tauri.merged.json\nbash scripts/release-app.sh build-env >>\"$GITHUB_ENV\"\n"
  and .[$at].env == {TAG: "${{ github.ref_name }}"} and .[$at].shell == "bash"'
check "every build row merges identity.json over the app" wired '
  .jobs["release-tauri-app"].steps[] | select(.id == "build").with.args == "${{ matrix.config.args }} --config ../identity.json"'
check "the product, the update key and the build records come from the merged configuration" wired '
  (.jobs["build-happ"].steps[] | select(.id == "product").run | test("jq -er .productName tauri.merged.json"))
  and (.jobs["build-happ"].steps[] | select(.id == "updater").run
    == "bash scripts/updater-signing.sh tauri.merged.json >> \"$GITHUB_OUTPUT\"")
  and any(.jobs["release-tauri-app"].steps[]; .run // "" | test("updater-provenance.sh tauri.merged.json "))
  and ([.. | strings | select(test("src-tauri/tauri.conf.json"))] - [.. | strings | select(test("wix.version|createUpdaterArtifacts"))]
    | length == 0)'
check "the release names each updater asset as the app does for its product" wired '
  .jobs["build-happ"].steps[] | select(.run // "" | startswith("bash scripts/updater-asset-names.sh"))
  | .run == "bash scripts/updater-asset-names.sh unyt/src-tauri/src/updater.rs \"$PRODUCT\""
    and .env == {PRODUCT: "${{ steps.product.outputs.name }}"}'
check "no build value comes from anywhere but network.json" \
  wired --argjson names "$(jq -c '.build | keys + ["UNYT_RELEASE_REPO"]' "$here/../network.json")" '
  [.. | objects | select(has("env")) | .env | keys[] | select(IN($names[]))] | length == 0'
check "the release takes no input, so a run builds nothing but what the tag's commit holds" \
  wired '[.. | strings | select(test("inputs\\."))] | length == 0'
check "the release says so when the app's changelog has nothing for the tag" wired '
  any(.jobs["build-happ"].steps[]; .run // "" | test("\\[ -s release_notes.txt \\] \\|\\|\n *echo \"::warning::"))'
check "the release notes name the network" wired '
  any(.jobs["build-happ"].steps[]; .run == "bash scripts/release-app.sh notes >> release_notes.txt\ncat release_notes.txt\n")'
check "every step that names the release names the pushed tag" wired '
  [.jobs[].steps[]?.env.TAG // empty] as $tags | ($tags | length) > 5 and all($tags[]; . == "${{ github.ref_name }}")
  and (.jobs["publish-happ"].steps[] | select(.id == "create-release").with.tag) == "${{ github.ref_name }}"'
check "every release command is on this repo" wired '
  [.. | strings | scan("gh release [a-z]+[^\n]*")] as $calls
  | ($calls | length) > 0 and all($calls[]; test("--repo \"\\$GITHUB_REPOSITORY\""))'
check "the release environment is checked, by a job that runs no app code, before stage 1 builds" wired '
  .jobs["release-environment"] | .permissions == {contents: "read", actions: "read"} and (.needs == null)
  and (.steps[0].uses | test("^actions/checkout@[0-9a-f]{40}$"))
  and [.steps[1:][] | .uses // .run] == ["bash scripts/check-release-environment.sh release \"$TAG\""]
  and .steps[1].env == {GH_TOKEN: "${{ github.token }}", TAG: "${{ github.ref_name }}"}'
check "and stage 1 waits for it" wired '.jobs["build-happ"].needs == "release-environment"'
check "the release key is a secret of that environment, and only the signing job holds it" wired '
  .jobs["updater-manifests"].environment == "release"
  and ([.jobs | to_entries[] | select(.value | tojson | test("secrets\\.TAURI_SIGNING")) | .key] == ["updater-manifests"])'
check "no step splices an expression into its script" wired '[.jobs[].steps[]?.run // empty | select(test("\\$\\{\\{"))] == []'
own_names() { # <repo root>: what names that repo, its app or its network, one per line
  printf '%s\n' unytco/unyt-sandbox co.unyt. ${GITHUB_REPOSITORY:+"$GITHUB_REPOSITORY"}
  jq -r '(.identifier // empty), (.build // {} | del(.VITE_ETH_NETWORK) | .[])
    | strings | select(startswith("TO BE SET") | not)' "$1/identity.json" "$1/network.json"
}
fixtures
edit network.json '.build.VITE_HOT_BRIDGE_URL = "TO BE SET"'
check "a value not set yet names nothing" eval '! own_names "$repo" | grep -qF "TO BE SET"'
check "a value set names itself" eval 'own_names "$repo" | grep -qxF https://joining.example'
naming() { # each workflow, release script and pin that holds one of this repo's names
  own_names "$here/.." | grep -rlF -f - --include="*.y*ml" --include="*.sh" --include="*.py" --include="*.ps1" \
    --include="*.json" "$here/../.github" "$here" "$here/../lineage" | grep -vE "/test[-_]" || true
}
check "no workflow or release script names this repo, its app or its network, so a fork releases into itself" \
  test -z "$(naming)"
probe_wf="$(yq -o=json "$here/../.github/workflows/release-probe.yaml")"
probe_wired() { jq -e "$1" <<<"$probe_wf" >/dev/null; } # <condition on the probe workflow>
check "every pull request probes the pinned app as the release takes it" probe_wired '
  (.on | has("pull_request")) and (.jobs.probe.steps[0].uses | test("^actions/checkout@[0-9a-f]{40}$"))
  and [.jobs.probe.steps[1:][] | .uses // .run] == ["./.github/actions/checkout-app", "bash scripts/release-probe.sh unyt"]'

report "release app scripts"
