#!/usr/bin/env bash
# The app this repo releases, as identity.json and network.json at its root name it:
#   release-app.sh identity <app-dir> <merged-out>  writes <app-dir>'s Tauri configuration with
#                                                   identity.json merged over it, as
#                                                   `tauri build --config` merges it
#   release-app.sh build-env                        the values its build reads, as $GITHUB_ENV lines
#   release-app.sh reads <app-dir>                  fails unless <app-dir> reads each of those values
#   release-app.sh notes                            its network, as release notes
# Each refuses a file that is malformed. build-env and notes also refuse a value the files have not set
# yet. Env: GITHUB_REPOSITORY, the repo the app updates from (build-env).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"
IDENTITY="$here/../identity.json"
NETWORK="$here/../network.json"
# A bracket range in a pattern is a range of bytes only in the C locale.
export LC_ALL=C
# On Windows, jq ends its lines with a carriage return.
jq() { command jq "$@" | tr -d '\r'; }
# Tauri merges --config as a JSON merge patch (RFC 7396).
merge='def merge_patch($patch):
  if ($patch | type) == "object" then
    reduce ($patch | to_entries[]) as $e (if type == "object" then . else {} end;
      if $e.value == null then del(.[$e.key]) else .[$e.key] |= merge_patch($e.value) end)
  else $patch end;'
origin='https://([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}(:[1-9][0-9]{0,4})?'
url_re="^$origin(/[!-~]*)?\$"
origin_re="^$origin/?\$"
values='["UNYT_JOINING_SERVICE_URL","VITE_ETH_NETWORK","VITE_HOT_BRIDGE_URL","VITE_HOT_LOCK_VAULT","VITE_MIGRATION_SERVICE_URL"]'

problems=()
report() {
  [ "${#problems[@]}" -eq 0 ] && return 0
  printf '::error::%s\n' "${problems[@]}" >&2
  exit 1
}

controls() { # <file>: queues each string in it that holds a control character
  local path
  while IFS= read -r path; do problems+=("$(basename "$1") has a control character in $path"); done < <(
    jq -r 'paths(type == "string" and (explode | any(. < 32 or . == 127))) | map(tostring) | join(".")' "$1")
}

formed() { # <jq path> <regex> <what it is not>: queues identity.json's value at the path unless it matches
  local value
  value="$(jq -r "$1 | strings" "$IDENTITY")"
  [[ "$value" == "TO BE SET"* || "$value" =~ $2 ]] || problems+=("identity.json has $1 '$value', which is no $3")
}

check_identity() {
  local field
  controls "$IDENTITY"
  for field in .identifier .productName .mainBinaryName .plugins.updater.pubkey; do
    jq -e "$field | type == \"string\" and length > 0" "$IDENTITY" >/dev/null ||
      problems+=("identity.json names no $field")
  done
  formed .identifier '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' "reverse domain name"
  # The characters a release asset name keeps, or release_product renames.
  formed .productName '^[A-Za-z0-9][]A-Za-z0-9 ._()[{}-]*$' "name this release can publish assets under"
  formed .mainBinaryName '^[A-Za-z0-9][A-Za-z0-9._-]*$' "file name"
  formed '.plugins["deep-link"].desktop.schemes[0]' '^[a-z][a-z0-9+.-]*$' "URI scheme"
  jq -e '.plugins["deep-link"] | .desktop.schemes == .mobile[0].scheme' "$IDENTITY" >/dev/null ||
    problems+=("identity.json names another mobile deep-link scheme than its desktop one")
  jq -e '.plugins["deep-link"].desktop.schemes | type == "array" and length == 1 and (.[0] | type == "string")' \
    "$IDENTITY" >/dev/null || problems+=("identity.json names no one desktop deep-link scheme")
  jq -e '.plugins["deep-link"].mobile | type == "array" and length == 1
    and (.[0].scheme | type == "array" and length == 1 and (.[0] | type == "string"))' \
    "$IDENTITY" >/dev/null || problems+=("identity.json names no one mobile deep-link scheme")
  # The release writes these into the app's tauri.conf.json, and identity.json merges over it.
  [ "$(jq -c -n "$merge"' $written | merge_patch($identity[0]) | [.version, .bundle.createUpdaterArtifacts, .bundle.windows.wix.version]' \
    --argjson written '{"version": "0.0.0", "bundle": {"createUpdaterArtifacts": true, "windows": {"wix": {"version": "0.0.0.0"}}}}' \
    --slurpfile identity "$IDENTITY")" = '["0.0.0",true,"0.0.0.0"]' ] ||
    problems+=("identity.json sets the version or the bundle settings the release writes")
}

check_network() {
  local name value
  controls "$NETWORK"
  jq -e '.name | type == "string" and length > 0' "$NETWORK" >/dev/null || problems+=("network.json names no network")
  jq -e --argjson values "$values" 'keys == ["build", "name"] and (.build | keys == $values and all(.[]; type == "string"))' \
    "$NETWORK" >/dev/null || problems+=("network.json does not hold a name and a build string for each of $values")
  while IFS=$'\t' read -r name value; do
    [[ "$value" != "TO BE SET"* ]] || continue
    case "$name $value" in
      VITE_ETH_NETWORK\ sepolia | VITE_ETH_NETWORK\ mainnet) continue ;;
      VITE_HOT_LOCK_VAULT\ *) [[ "$value" =~ ^0x[0-9a-f]{40}$ && "$value" =~ [1-9a-f] ]] && continue ;;
      VITE_HOT_BRIDGE_URL\ *) [[ "$value" =~ $origin_re ]] && continue ;;
      UNYT_JOINING_SERVICE_URL\ * | VITE_MIGRATION_SERVICE_URL\ *) [[ "$value" =~ $url_re ]] && continue ;;
    esac
    problems+=("network.json builds with $name $value, which is no value it can take")
  done < <(jq -r '.build | objects | to_entries[] | [.key, (.value | tostring)] | @tsv' "$NETWORK")
}

checked() { # the files are well formed
  local file
  [ -f "$IDENTITY" ] && [ -f "$NETWORK" ] || fail "this repo has no identity.json and network.json at its root"
  for file in "$IDENTITY" "$NETWORK"; do
    [ "$(jq -s length "$file")" = 1 ] || fail "$(basename "$file") is not one JSON document"
  done
  check_identity
  check_network
  report
}

set_values() { # refuses a value the files have not set yet
  local file path value
  for file in "$IDENTITY" "$NETWORK"; do
    while IFS=$'\t' read -r path value; do
      problems+=("$(basename "$file") has not set $path yet: $value")
    done < <(jq -r 'paths(type == "string" and startswith("TO BE SET")) as $p
      | [($p | map(tostring) | join(".")), getpath($p)] | @tsv' "$file")
  done
  report
}

case "${1:-}" in
  identity)
    usage="usage: release-app.sh identity <app-dir> <merged-out>"
    APP="${2:?$usage}" OUT="${3:?$usage}"
    checked
    [ -f "$APP/src-tauri/tauri.conf.json" ] || fail "no $APP/src-tauri/tauri.conf.json: is the app checked out?"
    jq "$merge"' merge_patch($identity[0])' --slurpfile identity "$IDENTITY" "$APP/src-tauri/tauri.conf.json" >"$OUT"
    ;;
  build-env)
    REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must name the repo the app updates from}"
    [[ "$REPO" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ && "${REPO#*/}" != . && "${REPO#*/}" != .. ]] ||
      fail "GITHUB_REPOSITORY is $REPO, not a GitHub owner/name"
    checked
    set_values
    jq -r '.build | to_entries[] | "\(.key)=\(.value)"' "$NETWORK"
    echo "UNYT_RELEASE_REPO=$REPO"
    ;;
  reads)
    APP="${2:?usage: release-app.sh reads <app-dir>}"
    checked
    unread=""
    # A name the app's Rust and UI source never mention is a value its build never reads. A mention does
    # not prove it is read.
    for name in $(jq -r '.build | keys[]' "$NETWORK") UNYT_RELEASE_REPO; do
      grep -rqwF "$name" "$APP"/src-tauri/build.rs "$APP"/src-tauri/build "$APP"/src-tauri/src \
        "$APP"/ui/*/vite.config.* "$APP"/ui/*/src 2>/dev/null || unread="${unread:+$unread, }$name"
    done
    [ -z "$unread" ] || fail "the app in $APP reads no $unread, so its build would not take this release's value"
    ;;
  notes)
    checked
    set_values
    echo
    echo "### Network: $(jq -r .name "$NETWORK")"
    echo
    jq -r '.build | to_entries[] | "- `\(.key)`: \(.value)"' "$NETWORK"
    ;;
  *) fail "usage: release-app.sh identity <app-dir> <merged-out> | build-env | reads <app-dir> | notes" ;;
esac
