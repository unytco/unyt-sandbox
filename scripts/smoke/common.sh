#!/usr/bin/env bash
# Shared constants for the release install-smoke. Sourced, never run.

# From unyt/src-tauri/tauri.conf.json. Tauri keys app_log_dir() on it, so logs
# land under $XDG_DATA_HOME/<id>/logs — no AGENT_ID suffix on this one.
UNYT_BUNDLE_ID="co.unyt.unyt.sandbox"

# The glibc of the OLDEST distro we support (Ubuntu 22.04 ships 2.35) — i.e. the
# highest version a shipped binary is allowed to require. Named for what it is:
# the floor of the support range, which is the ceiling on what we may import.
# shellcheck disable=SC2034  # read by the scripts that source this file
UNYT_OLDEST_GLIBC="2.35"

# ── The health oracle ─────────────────────────────────────────────────────────
# Statuses as the app's own log writes them (unyt/src-tauri/src/runtime/status.rs
# — `Status update: {from} -> {to}`), plus the webview breadcrumb.
# HEALTHY IS A SET ON PURPOSE — all four are genuine first-run outcomes, which is
# what lets this run with or without network access. Do not simplify it to one.
# shellcheck disable=SC2034  # read by the scripts that source this file
UNYT_RE_BACKEND_READY='Status update: .* -> (HcAuthRequired|NetworkSetupRequired|JoiningRequired) \{ agent_key: "uhCAk|Status update: .* -> Ready\b'

# `ConductorDisconnected` is deliberately NOT here: it is the transient first
# step of the reconnect backoff, and becomes `ConductorCrashed` after ~5 min.
# shellcheck disable=SC2034  # read by the scripts that source this file
UNYT_RE_FAILED='panicked at|Status update: .* -> (ConductorError|AppInstallationError|Error)\(|Status update: .* -> (ConductorCrashed|HcAuthFailed|LairInvalidPassword|NetworkUnreachable)\b'

# Watched separately, with a bounded tolerance rather than an open-ended wait: a
# conductor that keeps dropping is a wedged app even though no single drop is fatal.
# shellcheck disable=SC2034  # read by the scripts that source this file
UNYT_RE_DISCONNECTED='Status update: .* -> ConductorDisconnected'

# On a cold install there is no prior lair, so this MUST NOT appear — its
# presence means a warm start over leaked state.
# shellcheck disable=SC2034  # read by the scripts that source this file
UNYT_RE_CARRIED_IDENTITY='identity: agent identity carried forward'

# The POSITIVE counterpart, required alongside the absence above: an
# absence-only assertion cannot tell "clean install" from "never ran".
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
smoke_supports_ui_ready() {
  local probe="${1:?binary path required}"
  [ -f "$probe" ] && [ -r "$probe" ] || return 2
  grep -qaF -e "$UNYT_RE_UI_READY" "$probe"
}

# ── the matchers ─────────────────────────────────────────────────────────────
# The ONLY place these patterns are applied, so the regression test drives the
# real call sites — every oracle bug so far has been in the invocation, not the
# pattern (a leading "-" read as grep options; an unanchored alternation matching
# another subsystem's line). The `(...)` before `.*` is load-bearing: `A|B.*`
# binds `.*` to B alone and truncates a match on any earlier alternative.
smoke_match_backend_ready(){ grep -qE -e "$UNYT_RE_BACKEND_READY"; }
smoke_first_backend_ready(){ grep -oE -e "($UNYT_RE_BACKEND_READY).*" | head -1; }
smoke_match_ui_ready()     { grep -qF -e "$UNYT_RE_UI_READY"; }
smoke_match_carried()      { grep -qF -e "$UNYT_RE_CARRIED_IDENTITY"; }
smoke_match_fresh()        { grep -qF -e "$UNYT_RE_FRESH_IDENTITY"; }
smoke_match_failed()       { grep -qE -e "$UNYT_RE_FAILED"; }
smoke_first_failures()     { grep -oE -e "($UNYT_RE_FAILED).*" | head -3; }
smoke_count_disconnects()  { grep -cE -e "$UNYT_RE_DISCONNECTED" || true; }

# ── dependency comparison ────────────────────────────────────────────────────
# Computed vs DECLARED: one finding per line, MISSING/UNCONSTRAINED/TOOLOW.
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
# One definition of the sequence, plus a `--only <id>` mode resuming from a state
# directory — which is how each check becomes its own CI step.
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

# `<id><TAB><display name>`, in run order. release-smoke.yaml's guard reads this
# to prove every declared check reported.
smoke_print_checks() {
  local entry rest
  for entry in "${UNYT_SMOKE_CHECKS[@]}"; do
    rest="${entry#*|}"
    printf '%s\t%s\n' "${entry%%|*}" "${rest%%|*}"
  done
}

# ── state between checks ──────────────────────────────────────────────────────
# A CI step is a separate process, so check 1's findings must outlive it.
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
# The order is load-bearing and `--only` is how it could stop being honoured, so
# it is enforced: every earlier check must have RUN, and the gate must have
# PASSED. Ran, not passed, for the rest — one red check may not silence the next.
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
  if ! smoke_state_set "$(smoke_state_var "$id")" 1; then
    echo "::error::could not record that '$name' ran in $(smoke_state_file) — the checks after" >&2
    echo "  it would be refused as though it had never happened." >&2
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then smoke_results+=("$name|pass"); else smoke_results+=("$name|FAIL"); fi
  return "$rc"
}

# Rows on stdout, narration on stderr. Also to UNYT_SMOKE_RESULTS: a row that
# only ever existed on a pipe dies with the container.
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
