#!/usr/bin/env bash
# Fails when a workflow lets code that builds the app reach a credential that can change a release:
#   check-build-credentials.sh <workflow>...
# Build code can read every secret and token its job holds. So every job but the named credential
# holders below reads no secret beyond the build's and no holder's outputs, and has permissions
# declared, none of them write; and a credential holder runs no build. YAML that parsers may read
# differently, such as an anchor, fails it. Needs mikefarah's yq v4 and jq.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

[ "$#" -gt 0 ] || fail "usage: check-build-credentials.sh <workflow>..."
yq --version 2>/dev/null | grep -q 'mikefarah.* v4\.' || fail "this check needs mikefarah's yq v4 on PATH"
build_secrets='["unyt_deploy_key", "apple_certificate", "apple_certificate_password", "apple_dev_identity",
  "apple_id_email", "apple_id_password", "apple_team_id"]'
# The smoke's jobs read the draft release with GIT_PAT and run the installers on it.
credential_holders() { # <workflow file name>
  case "$1" in
    release-tauri-app.yaml) echo '["publish-happ", "publish-builds", "updater-manifests", "smoke-test"]' ;;
    release-smoke.yaml) echo '["inventory", "opens-linux", "opens-macos", "opens-windows", "static-linux",
      "static-macos", "static-windows"]' ;;
    *) echo '[]' ;;
  esac
}

judge='
  def secrets_read: # every read of the secrets context beyond the build secrets
    ascii_downcase
    | gsub("secrets\\.(?<n>[a-z0-9_]+)"; if (.n | IN($allowed[])) then "" else "secrets." + .n + " " end)
    | [scan("secrets\\.[a-z0-9_]+")] + (if gsub("secrets\\.[a-z0-9_]+"; "") | test("secrets") then ["the secrets context"] else [] end)
    | unique;
  def read_only: . == "read-all" or . == {} or (type == "object" and all(.[]; IN("read", "none")));
  def builds:
    tojson | ascii_downcase | gsub("\\\\[ntr]"; " ") | gsub("\\s+"; " ")
    | gsub("npm ci --prefix scripts/tauri-signer --ignore-scripts --no-audit --no-fund"; "")
    | test("checkout-app|unyt_deploy_key|\"repository\"|ssh-key|submodule|tauri-apps/tauri-action|tauri build|nix (develop|build)|\\bmake\\b|cargo|yarn|npx |npm |actions/cache");
  (.permissions // null) as $top_permissions
  | ($jobs - $holders) as $others
  | (del(.jobs, .on) | tojson | secrets_read) as $top
  | (if $top != [] then "the workflow, and so every job, reads \($top | join(" "))" else empty end),
    (if (.jobs | type) != "object" then "it has no jobs this check can read" else empty end),
    (.jobs // {} | to_entries[] | .key as $job | .value as $j
      | if $job | IN($holders[]) then
          (if $j | builds then "\($job) holds a credential that can change a release, and builds the app" else empty end)
        else
          ($j | tojson | secrets_read | if . != [] then "\($job) reads \(join(" "))" else empty end),
          ($j | del(.needs) | tojson | ascii_downcase
            | gsub("needs\\s*\\.\\s*(?<n>[a-z0-9_-]+)"; if (.n | IN($others[])) then "" else "needs." + .n + " " end)
            | if test("needs") then "\($job) reads what a credential holder hands on" else empty end),
          (if $j | has("permissions") then $j.permissions else $top_permissions end
            | if . == null then "\($job) takes the repository default permissions"
              elif read_only | not then "\($job) holds a token that can write"
              else empty end)
        end),
    ($holders[] | select(. as $h | $jobs | index($h) | not)
      | "it names \(.) as a credential holder, but has no such job")
'

bad=""
for workflow; do
  name="$(basename "$workflow")"
  odd="$(yq '[.. | select(tag == "!!map") | keys[] | select(tag == "!!merge")] | length' "$workflow" 2>/dev/null)" ||
    fail "could not read $workflow"
  [ "$odd" = 0 ] || bad="$bad$name: it uses a YAML merge key, which this check cannot follow"$'\n'
  odd="$(yq '[.. | select(anchor != "")] | length' "$workflow")"
  [ "$odd" = 0 ] || bad="$bad$name: it uses a YAML anchor, which parsers resolve differently"$'\n'
  odd="$(yq '[.. | select(tag == "!!map") | select((keys | length) != (keys | unique | length))] | length' "$workflow")"
  [ "$odd" = 0 ] || bad="$bad$name: it names a key twice"$'\n'
  odd="$(yq 'explode(.) | [.. | tag | select(test("^!!(map|seq|str|int|bool|null|float)$") | not)] | unique | join(" ")' \
    "$workflow" 2>/dev/null)"
  [ -z "$odd" ] || bad="$bad$name: it uses the YAML tags $odd"$'\n'
  json="$(yq -o=json 'explode(.)' "$workflow" 2>/dev/null)" || fail "could not read $workflow"
  found="$(jq -r --argjson allowed "$build_secrets" --argjson holders "$(credential_holders "$name")" \
    '(.jobs // {} | keys) as $jobs | '"$judge" <<<"$json")" || fail "could not judge $workflow"
  bad="$bad$(sed "/^$/d; s/^/$name: /" <<<"$found")"$'\n'
done
bad="$(sed '/^$/d' <<<"$bad")"
[ -z "$bad" ] || fail "code that builds the app can reach a credential that can change a release: ${bad//$'\n'/ | }"
