#!/usr/bin/env bash
# Fails unless no job that builds the app holds a credential that can change a release, and prints
# each job it judged to build, as `<workflow> <job>`:
#   check-build-credentials.sh <workflow>...
# A job builds when it checks out the app or runs a build tool. Build code can read every secret and
# token its job holds, so such a job declares its own permissions, none of them write, and reads only
# the secrets the build needs.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

[ "$#" -gt 0 ] || fail "usage: check-build-credentials.sh <workflow>..."
build_secrets=(UNYT_DEPLOY_KEY APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_DEV_IDENTITY
  APPLE_ID_EMAIL APPLE_ID_PASSWORD APPLE_TEAM_ID)

judged="$(for workflow; do
  awk -v file="$(basename "$workflow")" -v allowed=" ${build_secrets[*]} " '
    function held(text, where,   rest, name, said) {
      rest = text
      while (match(rest, /secrets\.[A-Za-z0-9_]+/)) {
        name = substr(rest, RSTART + 8, RLENGTH - 8)
        if (index(allowed, " " name " ") == 0 && !(name in said)) {
          said[name]
          bad = bad "; " where " holds secrets." name
        }
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
    function judge() {
      if (job == "" || body !~ builds) return
      print "build " file " " job
      bad = ""
      held(top, "its workflow")
      held(body, "it")
      if (body !~ /\n    permissions:/) bad = bad "; it declares no permissions of its own"
      if (body ~ /\n    permissions:[^\n]*write|\n      [a-z-]+:[[:space:]]*write[[:space:]]*\n/)
        bad = bad "; its token can write"
      if (bad != "") print "bad " file " " job ": " substr(bad, 3)
    }
    BEGIN {
      builds = "checkout-app|submodules:|UNYT_DEPLOY_KEY|tauri-apps/tauri-action|nix develop|make package|cargo build|yarn install|inherit-ui-release[.]sh"
    }
    { line = $0; sub(/(^|[[:space:]])#.*$/, "", line) }
    /^jobs:/ { in_jobs = 1; next }
    !in_jobs { top = top line "\n"; next }
    line ~ /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      judge()
      job = line
      gsub(/[ :]/, "", job)
      body = "\n"
      next
    }
    { body = body line "\n" }
    END { judge() }
  ' "$workflow"
done)"

bad="$(sed -n 's/^bad //p' <<<"$judged")"
[ -z "$bad" ] || fail "a job that builds the app holds a credential that can change a release: ${bad//$'\n'/ | }"
sed -n 's/^build //p' <<<"$judged"
