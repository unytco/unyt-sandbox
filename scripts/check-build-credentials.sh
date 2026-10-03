#!/usr/bin/env bash
# Fails when a workflow lets code that builds the app reach a credential that can change a release:
#   check-build-credentials.sh <workflow>...
# Build code can read every secret and token its job holds. So every job but the named credential
# holders below reads no secret beyond the build's and has permissions declared, none of them write,
# and a credential holder runs no build. Anything this cannot read, such as a YAML anchor, fails it.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

[ "$#" -gt 0 ] || fail "usage: check-build-credentials.sh <workflow>..."
build_secrets="unyt_deploy_key apple_certificate apple_certificate_password apple_dev_identity
apple_id_email apple_id_password apple_team_id"
# The smoke's jobs read the draft release with GIT_PAT and run the installers on it.
credential_holders() { # <workflow file name>
  case "$1" in
    release-tauri-app.yaml) echo "publish-happ publish-builds updater-manifests smoke-test" ;;
    release-smoke.yaml) echo "inventory opens-linux opens-macos opens-windows static-linux static-macos static-windows" ;;
  esac
}

bad=""
for workflow; do
  name="$(basename "$workflow")"
  found="$(awk -v allowed=" ${build_secrets//$'\n'/ } " -v holders=" $(credential_holders "$name") " -v sq="'" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function strip(s) { sub(/(^|[[:space:]])#.*$/, "", s); gsub(/"/, "", s); gsub(sq, "", s); return s }
    function reads(text,   t, name, out) { # every read of the secrets context beyond the build secrets
      t = tolower(text)
      while (match(t, /secrets\.[a-z0-9_]+/)) {
        name = substr(t, RSTART + 8, RLENGTH - 8)
        if (index(allowed, " " name " ") == 0 && index(out " ", " secrets." name " ") == 0) out = out " secrets." name
        t = substr(t, 1, RSTART - 1) substr(t, RSTART + RLENGTH)
      }
      if (index(t, "secrets")) out = out " the secrets context"
      return out
    }
    function expressions(text,   from, to, out) {
      while ((from = index(text, "${{")) > 0) {
        to = index(substr(text, from), "}}")
        if (to == 0) to = length(text) - from + 1
        out = out substr(text, from, to + 1) "\n"
        text = substr(text, from + to + 1)
      }
      return out
    }
    function said(what) { print "bad " what }
    { raw = $0; line = strip($0) }
    line ~ /(^|[:-])[[:space:]]+[&*][A-Za-z0-9_]|^[[:space:]]*[&*][A-Za-z0-9_]|<<:/ {
      said("line " NR " uses a YAML anchor, which this check cannot follow")
    }
    line ~ /^[^ ]/ {
      in_jobs = line ~ /^jobs:/
      if (in_jobs && line !~ /^jobs:[[:space:]]*$/) said("its jobs are in a form this check cannot read")
      in_top_perms = line ~ /^permissions:/
      if (in_top_perms) { top_perms = 1; if (line ~ /write/) top_write = 1 }
      if (!in_jobs) top = top raw "\n"
      job_indent = -1
      next
    }
    !in_jobs {
      if (in_top_perms && line ~ /write/) top_write = 1
      top = top raw "\n"
      next
    }
    line ~ /^[[:space:]]*$/ { if (n) body[n] = body[n] raw "\n"; next }
    job_indent < 0 { job_indent = indent(line) }
    indent(line) == job_indent {
      if (line !~ /^ *[A-Za-z0-9_-]+:[[:space:]]*$/) said("line " NR " is a job in a form this check cannot read")
      job[++n] = line
      gsub(/[ :]/, "", job[n])
      key_indent[n] = -1
      in_perms = 0
      next
    }
    {
      body[n] = body[n] raw "\n"
      if (key_indent[n] < 0) key_indent[n] = indent(line)
      if (in_perms && indent(line) > key_indent[n]) { if (line ~ /write/) writes[n] = 1; next }
      in_perms = 0
      if (indent(line) == key_indent[n] && line ~ /^ *permissions:/) {
        perms[n] = 1
        in_perms = 1
        if (line ~ /write/) writes[n] = 1
      }
    }
    END {
      leak = reads(expressions(top))
      if (leak != "") said("the workflow, and so every job, reads" leak)
      if (index(top, "jobs:") && n == 0) said("it has jobs this check cannot read")
      for (i = 1; i <= n; i++) {
        if (index(holders, " " job[i] " ")) {
          held[job[i]] = 1
          if (tolower(body[i]) ~ /checkout-app|unyt_deploy_key|submodules:|submodule update|tauri-apps\/tauri-action|tauri build|nix develop|make package|cargo build|yarn|npx /)
            said(job[i] " holds a credential that can change a release, and builds the app")
          continue
        }
        leak = reads(body[i])
        if (leak != "") said(job[i] " reads" leak)
        if (!perms[i] && !top_perms) said(job[i] " takes the repository default permissions")
        else if (perms[i] ? writes[i] : top_write) said(job[i] " holds a token that can write")
      }
      split(holders, names, " ")
      for (h in names) if (!(names[h] in held)) said("it names " names[h] " as a credential holder, but has no such job")
    }
  ' "$workflow")" || fail "could not read $workflow"
  bad="$bad$(sed -n "s/^bad /$name: /p" <<<"$found")"$'\n'
done
bad="$(sed '/^$/d' <<<"$bad")"
[ -z "$bad" ] || fail "code that builds the app can reach a credential that can change a release: ${bad//$'\n'/ | }"
