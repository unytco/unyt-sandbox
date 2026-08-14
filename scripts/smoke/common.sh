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

# The POSITIVE counterpart, logged on the cold path
# (identity.rs: `latest_prior_holochain_dir` finds nothing). Required alongside
# the absence above, because "the carry line is absent" is also satisfied by a
# boot that never reached the identity check at all — an absence-only assertion
# cannot tell "clean install" from "never ran".
# shellcheck disable=SC2034  # read by the scripts that source this file
UNYT_RE_FRESH_IDENTITY='identity: no prior data-root identity; using a fresh identity'

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
# Fails CLOSED on a bad path: an unreadable or missing probe is a broken check,
# not evidence that the artifact predates the breadcrumb, and the two must not be
# indistinguishable. Returns 2 for "cannot tell", which the caller treats as an
# error rather than a skip.
smoke_supports_ui_ready() {
  local probe="${1:?binary path required}"
  [ -f "$probe" ] && [ -r "$probe" ] || return 2
  grep -qaF -e "$UNYT_RE_UI_READY" "$probe"
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
smoke_match_fresh()        { grep -qF -e "$UNYT_RE_FRESH_IDENTITY"; }
smoke_match_failed()       { grep -qE -e "$UNYT_RE_FAILED"; }
smoke_first_failures()     { grep -oE -e "($UNYT_RE_FAILED).*" | head -3; }
smoke_count_disconnects()  { grep -cE -e "$UNYT_RE_DISCONNECTED" || true; }

# ── dependency comparison ────────────────────────────────────────────────────
# Compare a COMPUTED dependency list against what the package DECLARES, and emit
# one finding per line: `MISSING <dep>`, `UNCONSTRAINED <dep>`, or
# `TOOLOW <dep> declared <constraint>`.
#
# Args: <declared-file> <computed-file> [provides-file]
#   declared/computed: one `name (op ver)` per line.
#   provides: optional, one `<package> <provides-name>...` per line — the names a
#   computed package declares `Provides:`. Ubuntu's time_t transition renamed
#   libgtk-3-0 -> libgtk-3-0t64 and libglib2.0-0 -> libglib2.0-0t64 on 24.04+ and
#   debian:13, and dpkg-shlibdeps resolves to whatever the CURRENT image calls
#   them — so a single hand-written declared list can never name both. The t64
#   packages declare `Provides:` the old names (verified on 24.04, debian:13 and
#   26.04, versioned), and a versioned dependency against a versioned Provides
#   resolves, so declaring the non-t64 name installs correctly on all four
#   images. This file's job is to agree with that reality: without the map the
#   gate reports a correctly-installing package as MISSING, and a gate that goes
#   red on a correct package is the one nobody reads.
#
# Lives here, and takes files rather than doing its own extraction, so
# test-oracle.sh drives the REAL comparison against fixtures — the same reason
# the matchers live here. Both bugs this replaced were invisible to reading:
#   - package names were interpolated into an ERE, where `c++` is a quantifier,
#     so a correctly-declared `libstdc++6` was reported MISSING. Parsing is now
#     pure string splitting, with no pattern anywhere.
#   - only a BARE declaration counted as under-declared, so declaring
#     `libc6 (>= 2.17)` against a computed `(>= 2.34)` passed — leaving exactly
#     the too-old-glibc install this gate exists to prevent. The declared floor
#     must now COVER the computed one.
# Split `>= 2.34`, `>=2.34` or `>>2.33` into "<op> <version>". Leading run of
# relation characters is the operator, the rest is the version — a space is
# optional in a hand-written list, and taking the LAST space-separated token
# instead (the old approach) silently turned `>=2.34` into the "version" `>=2.34`,
# which dpkg then accepted against anything.
smoke_split_constraint() {
  local c="${1:-}" op ver
  c="${c#"${c%%[![:space:]]*}"}"; c="${c%"${c##*[![:space:]]}"}"
  op="${c%%[!<>=]*}"
  ver="${c#"$op"}"
  ver="${ver#"${ver%%[![:space:]]*}"}"; ver="${ver%"${ver##*[![:space:]]}"}"
  printf '%s %s\n' "$op" "$ver"
}

# Compare a COMPUTED dependency list against what the package DECLARES, and emit
# one finding per line: `MISSING`, `UNCONSTRAINED`, `NOFLOOR`, `BADVERSION`,
# `UNPARSEABLE` or `TOOLOW`, each followed by the dependency.
#
# Args: <declared-file> <computed-file> [provides-file]
#   declared/computed: one `name (op ver)` per line.
#   provides: optional, one `<package> <provides-name>...` per line — the names a
#   computed package declares `Provides:`. Ubuntu's time_t transition renamed
#   libgtk-3-0 -> libgtk-3-0t64 and libglib2.0-0 -> libglib2.0-0t64 on 24.04+ and
#   debian:13, and dpkg-shlibdeps resolves to whatever the CURRENT image calls
#   them — so a single hand-written declared list can never name both. The t64
#   packages declare `Provides:` the old names (verified on 24.04, debian:13 and
#   26.04, versioned), and a versioned dependency against a versioned Provides
#   resolves, so declaring the non-t64 name installs correctly on all four
#   images. This file's job is to agree with that reality: without the map the
#   gate reports a correctly-installing package as MISSING, and a gate that goes
#   red on a correct package is the one nobody reads.
#
# Lives here, and takes files rather than doing its own extraction, so
# test-oracle.sh drives the REAL comparison against fixtures — the same reason
# the matchers live here. Every bug fixed in this function was a way for the gate
# to accept a declaration providing no usable floor, which is the one property it
# exists to enforce, and none was visible by reading:
#   - package names interpolated into an ERE, where `c++` is a quantifier, so a
#     correctly-declared `libstdc++6` was reported MISSING;
#   - only a BARE declaration counted, so `libc6 (>= 2.17)` against a computed
#     `(>= 2.34)` passed;
#   - the operator was discarded, so `libc6 (<= 2.40)` — an UPPER bound, no floor
#     at all — passed;
#   - `dpkg --compare-versions` returns 0 for a malformed version, so the
#     plausible hand-written `libc6 (>=2.34)` (no space) made ANY value pass.
# The declared list is hand-maintained in tauri.conf.json and this gate's premise
# is that it is wrong, so nothing here may assume it is well-formed.
smoke_depends_gaps() {
  local declared_file="${1:?declared file required}" computed_file="${2:?computed file required}"
  local provides_file="${3:-}"
  local dep name constraint cline cname cconstraint found op ver dop dver alias pline aliases matched
  while read -r dep; do
    [ -n "$dep" ] || continue
    name="${dep%% *}"; name="${name%%:*}"   # strip any :arch qualifier
    constraint=""
    case "$dep" in *\(*\)) constraint="${dep#*\(}"; constraint="${constraint%%\)*}" ;; esac
    # A computed entry that carries "(" but no parseable constraint (e.g. an
    # alternation `libfoo (>= 9) | libbar`) must not silently skip the floor check.
    if [ -z "$constraint" ] && case "$dep" in *\(*) true ;; *) false ;; esac; then
      printf 'UNPARSEABLE %s\n' "$dep"; continue
    fi

    # The declared list may legitimately name something this package PROVIDES
    # rather than the package itself; collect those aliases so the lookup below
    # accepts either.
    aliases="$name"
    if [ -n "$provides_file" ] && [ -f "$provides_file" ]; then
      while read -r pline; do
        [ -n "$pline" ] || continue
        [ "${pline%% *}" = "$name" ] || continue
        aliases="$aliases ${pline#* }"
        break
      done <"$provides_file"
    fi

    found=""
    while read -r cline; do
      [ -n "$cline" ] || continue
      cname="${cline%% *}"; cname="${cname%%:*}"
      matched=""
      for alias in $aliases; do [ "$cname" = "$alias" ] && { matched=1; break; }; done
      [ -n "$matched" ] || continue
      found="$cline"
      cconstraint=""
      case "$cline" in *\(*\)) cconstraint="${cline#*\(}"; cconstraint="${cconstraint%%\)*}" ;; esac
      break
    done <"$declared_file"

    if [ -z "$found" ]; then
      printf 'MISSING %s\n' "$dep"
    elif [ -n "$constraint" ] && [ -z "$cconstraint" ]; then
      printf 'UNCONSTRAINED %s\n' "$dep"
    elif [ -n "$constraint" ]; then
      read -r op ver <<<"$(smoke_split_constraint "$constraint")"
      read -r dop dver <<<"$(smoke_split_constraint "$cconstraint")"
      if [ "$dop" != ">=" ] && [ "$dop" != ">>" ]; then
        # An upper bound or an equality pins nothing below itself: `libc6 (<= 2.40)`
        # still permits installing on glibc 2.17.
        printf 'NOFLOOR %s declared (%s) — not a lower bound\n' "$dep" "$cconstraint"
      elif [ -z "$dver" ] || ! dpkg --validate-version "$dver" 2>/dev/null; then
        # dpkg --compare-versions returns 0 for a malformed version, so an
        # unvalidated one would make every comparison pass.
        printf 'BADVERSION %s declared (%s)\n' "$dep" "$cconstraint"
      elif ! dpkg --compare-versions "$dver" ge "$ver" 2>/dev/null; then
        printf 'TOOLOW %s declared (%s)\n' "$dep" "$cconstraint"
      fi
    fi
  done <"$computed_file"
}

# ── the check runner ─────────────────────────────────────────────────────────
# The shape both container drivers present: a registry of checks, ONE definition
# of the sequence, and a `--only <id>` mode that runs exactly one of them,
# resuming from a state directory an earlier invocation left behind. release-
# smoke.yaml drives that mode so each check is its own CI step.
#
# It lives here, driven by test-oracle.sh, for the same reason the matchers do:
# every bug in this suite has been in the invocation rather than the logic, and a
# copy of this dispatcher in each driver would be two places for the next one to
# hide. A driver sets UNYT_SMOKE_CHECKS (`id|display name|function`, IN RUN
# ORDER) and UNYT_SMOKE_GATE (the id nothing downstream works without), then
# calls smoke_dispatch.
#
# shellcheck disable=SC2034  # read by the scripts that source this file
smoke_results=()

smoke_check_field() { # <id> <2=name|3=function>
  local entry rest
  for entry in "${UNYT_SMOKE_CHECKS[@]}"; do
    [ "${entry%%|*}" = "$1" ] || continue
    rest="${entry#*|}"
    case "$2" in
      2) printf '%s\n' "${rest%%|*}" ;;
      3) printf '%s\n' "${rest#*|}" ;;
    esac
    return 0
  done
  return 1
}
smoke_check_name() { smoke_check_field "$1" 2; }
smoke_check_fn()   { smoke_check_field "$1" 3; }

# `<id><TAB><display name>`, in run order. The single source of truth for what
# the sequence contains: release-smoke.yaml's guard reads it to prove every
# declared check reported, so a step nobody wired up is a red run rather than a
# check that quietly stopped existing.
smoke_print_checks() {
  local entry rest
  for entry in "${UNYT_SMOKE_CHECKS[@]}"; do
    rest="${entry#*|}"
    printf '%s\t%s\n' "${entry%%|*}" "${rest%%|*}"
  done
}

# ── state between checks ──────────────────────────────────────────────────────
# A GitHub Actions step is a separate process, so what check 1 learned — the
# package name, the installed binary, whether it got that far at all — has to
# outlive it. Inside the container that is just a file in /tmp.
#
# READ BACK BY SOURCING, EVEN WITHIN ONE PROCESS. The whole-run path re-loads
# between checks rather than keeping the values in scope, so it exercises the
# same file the split path depends on; a value a check forgot to record fails
# locally instead of only in CI.
#
# AND THE FILE IS THE ONLY SOURCE, which is why loading UNSETS first. Sourcing
# alone cannot remove a variable that is no longer in the file, so a GATE_OK
# left over from an earlier artifact's run would outlive the reset and let every
# downstream check report on an install that is not there. A driver declares
# UNYT_SMOKE_STATE_VARS and smoke_state_set refuses anything else, so a fifth
# value cannot be added without joining the list that gets cleared.
smoke_state_dir()   { printf '%s\n' "${UNYT_SMOKE_STATE:-/tmp/unyt-smoke-state}"; }
smoke_state_file()  { printf '%s/state.env\n' "$(smoke_state_dir)"; }
smoke_state_reset() { mkdir -p "$(smoke_state_dir)" && : >"$(smoke_state_file)"; }
smoke_state_set() {
  local name entry found=""
  for name in "${UNYT_SMOKE_STATE_VARS[@]}"; do
    [ "$name" = "$1" ] && { found=1; break; }
  done
  for entry in "${UNYT_SMOKE_CHECKS[@]}"; do
    [ -z "$found" ] || break
    [ "$(smoke_state_var "${entry%%|*}")" = "$1" ] && found=1
  done
  if [ -z "$found" ]; then
    echo "::error::'$1' is not in UNYT_SMOKE_STATE_VARS, so loading would not clear it" >&2
    return 1
  fi
  mkdir -p "$(smoke_state_dir)"
  printf '%s=%q\n' "$1" "$2" >>"$(smoke_state_file)"
}
smoke_state_load() {
  local f v entry
  for v in "${UNYT_SMOKE_STATE_VARS[@]}"; do unset "$v"; done
  for entry in "${UNYT_SMOKE_CHECKS[@]}"; do unset "$(smoke_state_var "${entry%%|*}")"; done
  f="$(smoke_state_file)"
  # shellcheck disable=SC1090  # a file this script wrote, named at runtime
  [ -f "$f" ] && . "$f"
  return 0
}
# `binary-compat` is not a legal shell variable name.
smoke_state_var()   { printf 'RAN_%s\n' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"; }

# ── the order guard ───────────────────────────────────────────────────────────
# THE ORDER IS LOAD-BEARING (see container-checks.sh), and running one check per
# invocation is exactly how it could stop being honoured — nothing about
# `--only depends` says the pristine install has already happened. So the
# sequence is enforced rather than assumed: a check refuses unless every check
# before it has RUN, and unless the gate check PASSED.
#
# Ran, not passed, for the predecessors: two independent checks must both report
# in CI, so one going red may not silence the next. The gate is the exception —
# with no install there is nothing downstream to look at.
smoke_order_ok() { # <id>
  local id="$1" entry eid var missing=""
  for entry in "${UNYT_SMOKE_CHECKS[@]}"; do
    eid="${entry%%|*}"
    [ "$eid" = "$id" ] && break
    var="$(smoke_state_var "$eid")"
    [ -n "${!var:-}" ] || missing="${missing:+$missing, }$(smoke_check_name "$eid")"
  done
  if [ -n "$missing" ]; then
    echo "::error::this check has to run after: $missing" >&2
    echo "  Running a later check first installs tooling of its own, and any of it could satisfy" >&2
    echo "  a dependency the package failed to declare — turning the exact bug this suite exists" >&2
    echo "  to find into a pass." >&2
    return 1
  fi
  if [ "$id" != "$UNYT_SMOKE_GATE" ] && [ -z "${GATE_OK:-}" ]; then
    echo "::error::the '$(smoke_check_name "$UNYT_SMOKE_GATE")' check did not pass, so there is" >&2
    echo "  nothing here to check. This row is that failure, not a second one." >&2
    return 1
  fi
  return 0
}

# THE ONE PLACE A CHECK IS INVOKED, so `--only` and the whole run cannot drift
# into treating the same check differently.
smoke_run_one() { # <id>
  local id="$1" name fn rc=0
  name="$(smoke_check_name "$id")" || { echo "::error::no such check: $id" >&2; return 2; }
  fn="$(smoke_check_fn "$id")"
  # The first check starts a fresh run. Both Linux bundles are smoked in the same
  # job, so a state file an earlier artifact left behind would otherwise let a
  # later check report on the wrong install.
  [ "$id" != "$UNYT_SMOKE_GATE" ] || smoke_state_reset
  echo "" >&2
  echo "===== $name =====" >&2
  smoke_order_ok "$id" && "$fn" || rc=1
  # Recorded whatever the verdict: the next check needs to know this one RAN.
  # A FAILED write fails THIS check, rather than being swallowed — the marker is
  # the whole basis of the order guarantee, and an unwritable state directory
  # would otherwise produce a pass row whose successor then blames the wrong
  # check (or, for the last check in a sequence, nothing at all).
  if ! smoke_state_set "$(smoke_state_var "$id")" 1; then
    echo "::error::could not record that '$name' ran in $(smoke_state_file) — the checks after" >&2
    echo "  it would be refused as though it had never happened." >&2
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then smoke_results+=("$name|pass"); else smoke_results+=("$name|FAIL"); fi
  return "$rc"
}

# Rows on stdout, narration on stderr, so whatever reads the log can tell a
# check's verdict from its commentary. Also appended to UNYT_SMOKE_RESULTS when
# set: run-smoke.sh reads the row back out of the container, and a row that only
# ever existed on a pipe is lost the moment the container is.
smoke_emit_rows() {
  local row
  [ "${#smoke_results[@]}" -gt 0 ] || return 0
  for row in "${smoke_results[@]}"; do
    printf '%s\n' "$row"
    [ -z "${UNYT_SMOKE_RESULTS:-}" ] || printf '%s\n' "$row" >>"$UNYT_SMOKE_RESULTS"
  done
}

# Exit 2 rather than 1 for a bad invocation: a check that went red and a check
# that was never named are different answers, and a caller that mistypes an id
# must not read as an artifact that failed.
smoke_dispatch() { # print | only <id> | all
  local entry rc=0
  case "${1:?smoke_dispatch needs a mode}" in
    print)
      smoke_print_checks
      exit 0 ;;
    only)
      smoke_state_load
      smoke_run_one "${2:?--only needs a check id}" || rc=$?
      smoke_emit_rows
      exit "$rc" ;;
    all)
      for entry in "${UNYT_SMOKE_CHECKS[@]}"; do
        smoke_state_load
        smoke_run_one "${entry%%|*}" || rc=1
      done
      echo "" >&2
      smoke_emit_rows
      exit "$rc" ;;
    *)
      echo "::error::unknown dispatch mode '$1'" >&2
      exit 2 ;;
  esac
}

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
