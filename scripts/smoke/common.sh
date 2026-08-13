#!/usr/bin/env bash
# Shared constants for the release install-smoke. Sourced, never run.
#
# One home for the facts that must match the app: change the bundle identifier or
# a runtime-status variant in `unyt/` and this file changes with it.

# The Tauri bundle identifier (unyt/src-tauri/tauri.conf.json). Tauri keys
# app_log_dir()/app_data_dir() on it, so the app's logs land under
# $XDG_DATA_HOME/<id>/logs. The AGENT_ID suffix the app applies to its app_dirs2
# CONDUCTOR dir never reaches this one.
UNYT_BUNDLE_ID="co.unyt.unyt.sandbox"

# The glibc of the OLDEST distro we support (Ubuntu 22.04 ships 2.35) — i.e. the
# highest version a shipped binary is allowed to require. Named for what it is:
# the floor of the support range, which is the ceiling on what we may import.
# A binary needing more installs fine and then dies at exec on a supported target.
# shellcheck disable=SC2034  # read by the scripts that source this file
UNYT_OLDEST_GLIBC="2.35"

# ── The health oracle ─────────────────────────────────────────────────────────
# Statuses as the app's own log writes them (unyt/src-tauri/src/runtime/status.rs
# — `Status update: {from} -> {to}`), plus the webview breadcrumb.
#
# HEALTHY is a SET, and every member is a genuine, correct first-run outcome for a
# shipped build on a clean machine. Do not "simplify" it to one:
#   HcAuthRequired       production path: conductor up, agent key minted, the
#                        auth server reachable and answering for an unregistered
#                        key. A release build compiles a joining URL into
#                        `consts`, and `joining_service_url()` treats an empty
#                        env value as UNSET, so this is what a clean machine with
#                        network access actually reaches.
#   NetworkSetupRequired auth server unreachable -> the app fails OPEN
#                        (HcAuthStatus::Failed -> warn -> LairReady), or the
#                        build genuinely has no joining service.
#   JoiningRequired      membrane-proof path.
#   Ready                already-provisioned install.
# Accepting all four is what lets this run with or without network access to
# joining.unyt.dev, without tampering with the machine to force one branch.
#
# UiReady is deliberately NOT one of them. It is the only signal that proves the
# WEBVIEW painted — every state above is emitted from Rust during boot and would
# still appear if the UI bundle never loaded — so as an alternative it gated
# nothing and a black-window release passed. It is asserted separately, and
# REQUIRED, whenever the artifact under test carries the breadcrumb.
#
# NOTE ON SHAPE: these match Rust's Debug output, which differs per variant kind
# — a struct variant prints `Name { field: … }`, a tuple variant `Name(…)`, and a
# unit variant just `Name`. Matching them uniformly is how a state silently stops
# being detected, so each group below is anchored to its own shape.
#
# ANCHORED to `Status update:`. The oracle greps the MERGED log — the app's own
# lines plus holochain, kitsune2 and lair at RUST_LOG=info — where "-> Ready" and
# the like occur in unrelated subsystem output. Unanchored, any of those declared
# the app healthy.
# shellcheck disable=SC2034  # read by the scripts that source this file
UNYT_RE_BACKEND_READY='Status update: .* -> (HcAuthRequired|NetworkSetupRequired|JoiningRequired) \{ agent_key: "uhCAk|Status update: .* -> Ready\b'

# Terminal failures. `ConductorDisconnected` is deliberately NOT here — it is the
# transient first step of the heartbeat's reconnect backoff (5s -> 60s;
# unyt/src-tauri/src/utils/holochain.rs) and only becomes `ConductorCrashed`
# after ~5 minutes of consecutive failures.
# shellcheck disable=SC2034  # read by the scripts that source this file
UNYT_RE_FAILED='panicked at|Status update: .* -> (ConductorError|AppInstallationError|Error)\(|Status update: .* -> (ConductorCrashed|HcAuthFailed|LairInvalidPassword|NetworkUnreachable)\b'

# Watched separately, with a bounded tolerance rather than an open-ended wait: a
# conductor that keeps dropping is a wedged app even though no single drop is fatal.
# shellcheck disable=SC2034  # read by the scripts that source this file
UNYT_RE_DISCONNECTED='Status update: .* -> ConductorDisconnected'

# A prior version's identity being carried into this one
# (unyt/src-tauri/src/runtime/boot/identity.rs). On a cold install there is no
# prior lair to carry, so this line MUST NOT appear — its presence means the run
# is a warm start over leaked state and is not testing what users hit.
#
# NOTE: `has_existing_key: true` is NOT evidence of leakage and must not be
# asserted false. On an authenticated build (any release), hc-auth mints an agent
# key during boot and `resolve_agent_key` then REUSES it, so `reused` — and hence
# `has_existing_key` — is legitimately true on a first install
# (unyt/src-tauri/src/joining/mod.rs first_run_has_existing_key = reused ||
# carried_forward). The carried-forward half is the one that indicates leakage.
# shellcheck disable=SC2034  # read by the scripts that source this file
UNYT_RE_CARRIED_IDENTITY='identity: agent identity carried forward'

# The webview breadcrumb (unyt/src-tauri/src/runtime/events.rs `ui_ready`),
# emitted from the frontend's first mount. Required whenever the artifact carries
# it — see smoke_supports_ui_ready.
# shellcheck disable=SC2034  # read by the scripts that source this file
UNYT_RE_UI_READY='UI ready: webview mounted the root element'

# Does THIS artifact know how to emit the breadcrumb? The log message is a string
# literal compiled into the binary, so its presence is the artifact's own answer —
# no version parsing, and nothing to keep in sync with a release schedule.
# Artifacts predating the breadcrumb (v0.100.0 and earlier) stay smokeable; newer
# ones cannot quietly lose their only webview proof.
smoke_supports_ui_ready() {
  grep -qaF "$UNYT_RE_UI_READY" "${1:?binary path required}" 2>/dev/null
}

# ── the matchers ─────────────────────────────────────────────────────────────
# The ONLY place these patterns are applied. Both launch-and-assert.sh and
# test-oracle.sh go through these functions, so the regression test exercises the
# real call sites rather than a copy of them — which is the whole point, since
# every oracle bug so far has been in the invocation, not the pattern:
#   - a pattern starting with "-" parsed as grep OPTIONS (needs -e)
#   - an alternation matched against the merged log, so an unrelated subsystem
#     line satisfied it (needs the `Status update:` anchor)
# All read the log on stdin.
# The `(...)` around the pattern before appending `.*` is load-bearing: `A|B.*`
# binds the `.*` to B alone, so a match on any earlier alternative was reported
# truncated at the alternative's own end.
smoke_match_backend_ready(){ grep -qE -e "$UNYT_RE_BACKEND_READY"; }
smoke_first_backend_ready(){ grep -oE -e "($UNYT_RE_BACKEND_READY).*" | head -1; }
smoke_match_ui_ready()     { grep -qF -e "$UNYT_RE_UI_READY"; }
smoke_match_carried()      { grep -qF -e "$UNYT_RE_CARRIED_IDENTITY"; }
smoke_match_failed()       { grep -qE -e "$UNYT_RE_FAILED"; }
smoke_first_failures()     { grep -oE -e "($UNYT_RE_FAILED).*" | head -3; }
smoke_count_disconnects()  { grep -cE -e "$UNYT_RE_DISCONNECTED" || true; }

# The app's rolling log dir inside a smoke sandbox ($1 = sandbox root; the smoke
# scripts point XDG_DATA_HOME at <sandbox>/data). Files are named
# unyt.v<major>.<minor>.log.YYYY-MM-DD.
smoke_log_dir() { printf '%s/data/%s/logs\n' "${1:?sandbox root required}" "$UNYT_BUNDLE_ID"; }

# Concatenate every log sink the app writes, for grepping. Both matter: the file
# is durable, stdout catches a crash that happens before the log dir exists.
smoke_all_logs() {
  local sandbox="${1:?sandbox root required}"
  cat "$sandbox/app-stdout.log" "$(smoke_log_dir "$sandbox")"/unyt.v*.log.* 2>/dev/null || true
}
