#!/usr/bin/env bash
# The negative control, the watch loop and the verdict, shared by prove-linux.sh
# and prove-macos.sh. Sourced, never run.
#
# TEMPORARY — scaffolding for .github/workflows/zz-TEMPORARY-load-proving.yaml.
# Deleting that workflow and this directory leaves the repo as it was.
#
# THE VERDICT IS TWO INDEPENDENT FACTS, and PROVEN needs both:
#   A. the app got as far as a screen — its log reaches LairAwaitingPassword or a
#      healthy backend state, and never a failure state.
#   B. the platform's EVIDENCE that it is on screen. On Linux and Windows that is
#      a photograph of the app's own window, dominated by a colour the app
#      declares with content drawn on it. macOS cannot photograph anything a
#      runner would believe, so it replaces the evidence with the window list and
#      says plainly that it proves less — see prove-macos.sh.
#
# Before either, the capture path itself is tested: a frame is taken BEFORE the
# app is launched, and it must not pass for the app. A capture that photographs
# the desktop when the app does not exist would photograph the desktop when it
# does, and every verdict after that would be void — that is UNTRUSTED, and it is
# the most useful thing a first run can tell us.
#
# WHAT THE CONTROL CANNOT COVER, since a window-scoped capture has no window to
# aim at before launch: it photographs the screen, while the verdict frames
# photograph the app's window. It answers "is this runner's screen mistakable for
# the app", not "is this window capture aimed properly" — Windows narrows that
# gap by taking a second control at the splash's own footprint.
#
# Anything that stops us LOOKING is never a pass: CANNOT PROVE (we could not
# capture) and UNTRUSTED (we could, but not the app) are both red, and both say
# which. This whole exercise exists because checks were going green without
# testing what they claimed.
#
# Platform scripts provide: prove_logs · prove_alive · prove_capture <slug> ·
# prove_control <path>, and may override prove_seek_evidence.

prove_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../common.sh
. "$prove_here/../common.sh"

PROVE_ANALYSER="$prove_here/screenshot-stats.py"

# The state that means "the keystore password prompt is what the user is looking
# at" — the app's Debug spelling, `LairAwaitingPassword { is_initial_setup: true }`
# (unyt/src-tauri/src/runtime/status.rs). ON A COLD SANDBOX THIS IS SUCCESS, not a
# stall: the main window is only created once the conductor is up, so a fresh
# install legitimately parks here with the splash's prompt on screen.
# shellcheck disable=SC2034  # applied through the matcher below, and read by prove-windows.ps1
UNYT_RE_AWAITING_PASSWORD='Status update: .* -> LairAwaitingPassword \{'

prove_match_awaiting() { grep -qE -e "$UNYT_RE_AWAITING_PASSWORD"; }
prove_first_awaiting() { grep -oE -e "($UNYT_RE_AWAITING_PASSWORD).*" | head -1; }

# POLLED, NEVER SLEPT: WebView2 and WebKitGTK cold-start times vary several-fold
# between runs on the same runner, so any fixed wait is either a flake or a
# waste. Each frame is analysed as it is taken and the loop stops at the first
# one that is the app's.
PROVE_POLL="${PROVE_POLL:-2}"
PROVE_MAX_SHOTS="${PROVE_MAX_SHOTS:-24}"
PROVE_HARD_MAX_SHOTS="${PROVE_HARD_MAX_SHOTS:-40}"
# Long enough for a cold keystore init on a slow runner; the loop leaves as soon
# as it has its answer, so this only bounds the bad case.
PROVE_TIMEOUT="${PROVE_TIMEOUT:-240}"
# How long to keep photographing after the state is reached. The webview paints
# the prompt a moment after Rust logs the state, and 30s of 2s polls is fifteen
# chances at a render that normally lands on the first.
PROVE_POST_SECONDS="${PROVE_POST_SECONDS:-30}"

PROVE_SHOTS_VERDICT=""
PROVE_SHOTS_CONTEXT=""
PROVE_REACHED=""
PROVE_FAILED_STATE=""
PROVE_EVIDENCE=""
PROVE_SHOT_COUNT=0
PROVE_CAPTURE_FAILURES=0
PROVE_LAST_SLUG=""

# EVERY WAY OUT OF A LANE SAYS SOMETHING, mirroring prove-windows.ps1's Exit-With.
# publish-verdict.sh already reds a lane that printed nothing, but its summary can
# then only say "exited N without a verdict" — and the reason (two .app bundles,
# no python, no executable in the package) is the whole value of the run.
#
# Clears the ERR trap first: this IS the answer, so the trap below must not add a
# second one behind it.
prove_answer() { # <label> <word> <why> <code>
  trap - ERR
  printf 'VERDICT %s: %s — %s\n' "${1:?label required}" "${2:?verdict word required}" "${3:?a reason required}"
  exit "${4:?an exit code required}"
}

# The net under errexit: `ditto`, `plutil`, `dpkg-deb` and a dozen others can end
# a lane at any line, and a lane that dies wordlessly leaves publish-verdict.sh
# able to say only "exited N". Armed as soon as the label exists, and cleared by
# whichever answer gets there first.
prove_arm_errors() { # <label>
  # The label is expanded NOW (it is out of scope when the trap fires); $LINENO is
  # expanded THEN, and has to stay outside the single-quoted format string to be.
  # shellcheck disable=SC2064
  trap "printf 'VERDICT %s: CANNOT PROVE — this lane died at line %s before it could answer\\n' '${1:?label required}' \"\$LINENO\"" ERR
}

prove_init() { # <shots-root>
  PROVE_SHOTS_VERDICT="${1:?shots root required}/verdict"
  PROVE_SHOTS_CONTEXT="$1/context"
  # CLEARED, not just created: the verdict passes if ANY frame is the app's, so a
  # frame an earlier run left here would prove this artifact with the last one's
  # screenshot. A GitHub runner is fresh; a re-run on a laptop or a self-hosted
  # runner is not, and that is where this lane gets developed.
  rm -rf "$PROVE_SHOTS_VERDICT" "$PROVE_SHOTS_CONTEXT"
  mkdir -p "$PROVE_SHOTS_VERDICT" "$PROVE_SHOTS_CONTEXT"
}

# ── the negative control ──────────────────────────────────────────────────────
# Kept out of the verdict directory on purpose: it is evidence about the RUNNER,
# and a frame of the desktop must never be able to answer a question about the app.
PROVE_CONTROL_NOTE=""
# The same finding as a single word, because `advisory` throws the return code
# away and a caller still has to be able to ask. `usable` is the ONLY value in
# which a frame from this runner can decide anything; macOS reads it to choose
# between a pixel verdict and the window list.
PROVE_CONTROL_STATUS=""

# `advisory` for a platform whose verdict does not rest on pixels: the control is
# still run and still reported, but it cannot condemn a lane that never used a
# frame as evidence in the first place. macOS is that platform.
prove_control_check() { # <label> [advisory] [slug]
  local label="${1:?label required}" advisory="${2:-}" path rc=0
  # Named, because a platform may need more than one: the whole screen answers
  # "is this runner's screen mistakable for the app", and a sub-rect of it can
  # clear a bar the whole screen does not.
  path="$PROVE_SHOTS_CONTEXT/${3:-00-control-before-launch}.png"
  PROVE_CONTROL_STATUS="uncapturable"
  if ! prove_control "$path"; then
    PROVE_CONTROL_NOTE="nothing could be captured at all"
    [ -n "$advisory" ] && return 0
    echo "::error::the capture path produced nothing at all before launch" >&2
    printf 'VERDICT %s: CANNOT PROVE — nothing could be captured on this runner even before the app was started\n' "$label"
    return 2
  fi
  "$PROVE_PYTHON" "$PROVE_ANALYSER" --control "$path" >&2 || rc=$?
  case "$rc" in
    0)
      PROVE_CONTROL_STATUS="usable"
      PROVE_CONTROL_NOTE="a pre-launch frame does not pass for the app"
      echo "OK: $PROVE_CONTROL_NOTE, so a later one that does means the app" >&2
      return 0 ;;
    5)
      PROVE_CONTROL_STATUS="passes-for-app"
      PROVE_CONTROL_NOTE="A PRE-LAUNCH FRAME ALREADY PASSES FOR THE APP — no frame from this runner is evidence"
      if [ -n "$advisory" ]; then
        echo "::warning title=Capture on this runner cannot be trusted::$PROVE_CONTROL_NOTE" >&2
        return 0
      fi
      echo "::error title=The capture path cannot be trusted::a frame taken BEFORE the app was launched already passes for the app" >&2
      echo "  Every verdict this job could go on to produce would be about whatever that frame photographed," >&2
      echo "  not about the artifact. Nothing here is evidence until the capture is aimed properly." >&2
      printf 'VERDICT %s: UNTRUSTED — a frame captured before the app was even launched already scores as the app, so this capture path cannot answer the question\n' "$label"
      return 3 ;;
    4)
      PROVE_CONTROL_STATUS="unreadable"
      PROVE_CONTROL_NOTE="the pre-launch frame could not be read as an image"
      [ -n "$advisory" ] && return 0
      printf 'VERDICT %s: CANNOT PROVE — the pre-launch frame could not be read, so the capture path is unusable\n' "$label"
      return 2 ;;
    *)
      # shellcheck disable=SC2034  # read by prove-macos.sh, which sources this
      PROVE_CONTROL_STATUS="analyser-failed"
      PROVE_CONTROL_NOTE="the frame analyser failed on the control frame (exit $rc)"
      [ -n "$advisory" ] && return 0
      printf 'VERDICT %s: CANNOT PROVE — %s\n' "$label" "$PROVE_CONTROL_NOTE"
      return 2 ;;
  esac
}

# MAY A FRAME FROM THIS RUNNER DECIDE ANYTHING? Two independent halves, and a
# lane needs both: <capable> is the platform's own answer to "would a capture
# return the app's own window at all" (on macOS, whether it has the TCC grant),
# and the control statuses are this run's answer to "would this runner's screen
# pass for the app even if it did". A single no anywhere is a no.
#
# Only a platform with a SECOND way to answer calls this — macOS, which falls
# back to the window list. Linux and Windows have no fallback, so for them a
# control that cannot be trusted reds the lane outright rather than dropping it
# into a lesser verdict.
# The word a platform's probe reported, as the yes/no that predicate takes. Two
# lines with one home, because inverting them arms a pixel verdict on exactly the
# runner that must not have one.
prove_capable_word() { # <grant-word>
  if [ "${1:-}" = granted ]; then echo yes; else echo no; fi
}

prove_pixels_may_decide() { # <capable:yes|no> <control-status>...
  local capable="${1:?capable yes/no required}" status
  shift
  [ "$capable" = yes ] || return 1
  # No statuses at all is a no: it means no control was taken, and an untested
  # capture path is exactly what this whole exercise refuses to trust.
  [ "$#" -gt 0 ] || return 1
  for status in "$@"; do
    [ "$status" = usable ] || return 1
  done
  return 0
}

# ── frames ────────────────────────────────────────────────────────────────────
# Capture failures are counted rather than fatal: a run that could not photograph
# frame 3 still has frames 1 and 2, and the count is reported so a lane that
# never managed one cannot read as blank.
prove_shoot() { # <slug> [force]
  PROVE_LAST_SLUG=""
  # `force` skips the ordinary budget, not the hard ceiling: the frames from the
  # moment the state is reached are the ones worth having, but a run that
  # photographed forever would upload an artifact nobody opens.
  [ "$PROVE_SHOT_COUNT" -lt "$PROVE_HARD_MAX_SHOTS" ] || return 1
  if [ "$PROVE_SHOT_COUNT" -ge "$PROVE_MAX_SHOTS" ] && [ -z "${2:-}" ]; then return 1; fi
  PROVE_SHOT_COUNT=$((PROVE_SHOT_COUNT + 1))
  local slug
  slug="$(printf '%02d-%s' "$PROVE_SHOT_COUNT" "$1")"
  if prove_capture "$slug"; then
    PROVE_LAST_SLUG="$slug"
    return 0
  fi
  PROVE_CAPTURE_FAILURES=$((PROVE_CAPTURE_FAILURES + 1))
  return 1
}

# Analysed as it is taken, so the loop can stop the moment it has its answer
# rather than photographing a boot it has already proved.
prove_shoot_and_assess() { # <slug> [force]
  prove_shoot "$@" || return 1
  local out rc=0
  out="$("$PROVE_PYTHON" "$PROVE_ANALYSER" "$PROVE_SHOTS_VERDICT/$PROVE_LAST_SLUG"*.png 2>&1)" || rc=$?
  printf '  %s\n' "$out" >&2
  [ "$rc" -eq 0 ] || return 1
  PROVE_EVIDENCE="frame $PROVE_LAST_SLUG"
  return 0
}

# WHAT COUNTS AS EVIDENCE THAT THE APP IS ON SCREEN — the one thing that differs
# between platforms, so it is the one thing a platform overrides. A photograph of
# the window is the default; macOS cannot photograph anything a runner would
# believe, so it replaces this with the window list. Sets PROVE_EVIDENCE and
# returns 0 once it has it.
prove_seek_evidence() { prove_shoot_and_assess "$@"; }

# A BOUNDED SECOND PHASE, for a lane that has its window and now wants the paint.
# The watch below stops at the first evidence its platform accepts, and on macOS
# that is the window list — so photographing the window is something that happens
# AFTER it rather than during it, and it can only ever upgrade a verdict the lane
# has already earned. Drives prove_capture, so the platform still decides what a
# frame is; sets PROVE_EVIDENCE and returns 0 at the first frame that is the
# app's own screen, 1 when the budget runs out having seen none.
prove_seek_paint() { # <slug-prefix> <seconds>
  local prefix="${1:?slug prefix required}" budget="${2:?a budget in seconds required}" started now taken
  started="$(date +%s)"
  while :; do
    now="$(date +%s)"
    taken="$PROVE_SHOT_COUNT"
    prove_shoot_and_assess "$prefix-t$((now - started))s" force && return 0
    # TWO BUDGETS, and the frame ceiling has to be able to end this too: past it
    # prove_shoot refuses before it captures anything, so every further poll
    # would sleep against a clock with nothing left to photograph — and the
    # caller would read those non-attempts as frames that were not a screen.
    [ "$PROVE_SHOT_COUNT" -gt "$taken" ] || return 1
    [ "$(date +%s)" -lt $((started + budget)) ] || return 1
    sleep "$PROVE_POLL"
  done
}

# ── the watch ─────────────────────────────────────────────────────────────────
prove_watch() {
  local started now logs reached_at=0
  started="$(date +%s)"
  while :; do
    now="$(date +%s)"
    logs="$(prove_logs)"

    if [ -z "$PROVE_FAILED_STATE" ] && printf '%s' "$logs" | smoke_match_failed; then
      PROVE_FAILED_STATE="$(printf '%s' "$logs" | smoke_first_failures | head -1)"
      echo "::error::the app reached a FAILURE state: $PROVE_FAILED_STATE" >&2
      prove_seek_evidence "t$((now - started))s-failed" force || true
      return 1
    fi

    if [ -z "$PROVE_REACHED" ]; then
      if printf '%s' "$logs" | smoke_match_backend_ready; then
        PROVE_REACHED="$(printf '%s' "$logs" | smoke_first_backend_ready)"
      elif printf '%s' "$logs" | prove_match_awaiting; then
        PROVE_REACHED="$(printf '%s' "$logs" | prove_first_awaiting)"
      fi
      if [ -n "$PROVE_REACHED" ]; then
        reached_at="$now"
        echo "OK: the app reached -> $PROVE_REACHED" >&2
      fi
    fi

    # Forced once the state is reached: the frames from the window in which the
    # prompt is actually on screen are the ones worth the budget.
    if [ -z "$PROVE_EVIDENCE" ]; then
      if [ -n "$PROVE_REACHED" ]; then
        prove_seek_evidence "t$((now - started))s" force || true
      else
        prove_seek_evidence "t$((now - started))s" || true
      fi
    fi

    # An `if`, not an `&&` chain: the chain's status is the LOOP's when the
    # condition is false, so a caller that ever ran this without `|| true` would
    # be killed by errexit at the first poll.
    if [ -n "$PROVE_REACHED" ] && [ -n "$PROVE_EVIDENCE" ]; then return 0; fi
    if [ -n "$PROVE_REACHED" ] && [ $(( $(date +%s) - reached_at )) -ge "$PROVE_POST_SECONDS" ]; then
      echo "::error::${PROVE_POST_SECONDS}s after the app reached its state, nothing shows the app on screen" >&2
      return 1
    fi

    if ! prove_alive; then
      echo "::error::the app process exited before reaching any state a user could see" >&2
      prove_seek_evidence "t$((now - started))s-exited" force || true
      return 1
    fi
    if [ "$(date +%s)" -ge $((started + PROVE_TIMEOUT)) ]; then
      echo "::error::no LairAwaitingPassword and no healthy state within ${PROVE_TIMEOUT}s" >&2
      prove_seek_evidence "t$(( $(date +%s) - started ))s-timeout" force || true
      return 1
    fi
    sleep "$PROVE_POLL"
  done
}

# ── the verdict ───────────────────────────────────────────────────────────────
# THE ONE PLACE IT IS DECIDED, so all three platforms answer the same question
# the same way. 0 proven · 1 not proven · 2 cannot prove · 3 untrusted.
prove_verdict() { # <label>
  trap - ERR
  local label="${1:?label required}" rc=0 analysis shot count=0
  local -a shots=()
  # Counted rather than measured with ${#shots[@]}: on bash 3.2, which is what
  # /bin/bash is on a macOS runner, expanding an EMPTY array under `set -u` is an
  # unbound-variable error and this function would die instead of answering.
  while IFS= read -r shot; do
    shots+=("$shot")
    count=$((count + 1))
  done < <(find "$PROVE_SHOTS_VERDICT" -name '*.png' | sort)

  if [ "$count" -eq 0 ]; then
    printf 'VERDICT %s: CANNOT PROVE — not one frame of the app window was captured (%d capture attempt(s) failed)\n' \
      "$label" "$PROVE_CAPTURE_FAILURES"
    return 2
  fi

  analysis="$("$PROVE_PYTHON" "$PROVE_ANALYSER" "${shots[@]}" 2>&1)" || rc=$?
  printf '%s\n' "$analysis" >&2

  if [ "$rc" -eq 4 ]; then
    printf 'VERDICT %s: CANNOT PROVE — %d frame(s) were written but none could be read as an image\n' \
      "$label" "$PROVE_SHOT_COUNT"
    return 2
  fi
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    printf 'VERDICT %s: CANNOT PROVE — the frame analyser itself failed (exit %d)\n' "$label" "$rc"
    return 2
  fi

  # Both halves, always named: a run that painted a screen while the backend
  # failed, and one that booted cleanly behind a blank window, are different bugs
  # and the line has to say which happened.
  local screen_note state_note
  if [ "$rc" -eq 0 ]; then
    screen_note="a frame of its window is the app's own screen ($(printf '%s' "$analysis" | grep -m1 '^PAINTED' | sed 's/^PAINTED *//'))"
  elif printf '%s' "$analysis" | grep -q '^FOREIGN'; then
    screen_note="every frame of its window shows something that is not the app ($(printf '%s' "$analysis" | grep -m1 '^FOREIGN' | sed 's/^FOREIGN *//'))"
  else
    # NOT "a flat fill": FLAT covers three frames that are not flat at all — a
    # blank window with a strip of chrome on it, and a greyscale or palette
    # capture, which cannot hold the colours of a render whatever it depicts.
    # The detail says which bar was missed; this line must not name a cause.
    screen_note="no frame of its window carries enough to be a screen ($(printf '%s' "$analysis" | grep -m1 '^FLAT' | sed 's/^FLAT *//'))"
  fi
  if [ -n "$PROVE_FAILED_STATE" ]; then
    state_note="the app reached a failure state ($PROVE_FAILED_STATE)"
  elif [ -n "$PROVE_REACHED" ]; then
    state_note="the app reached $PROVE_REACHED"
  else
    state_note="the app never reached LairAwaitingPassword or a healthy state"
  fi

  if [ "$rc" -eq 0 ] && [ -z "$PROVE_FAILED_STATE" ] && [ -n "$PROVE_REACHED" ]; then
    printf 'VERDICT %s: PROVEN — %s, and %s\n' "$label" "$state_note" "$screen_note"
    return 0
  fi
  printf 'VERDICT %s: NOT PROVEN — %s, and %s\n' "$label" "$state_note" "$screen_note"
  return 1
}

# Whichever spelling this runner has. Named rather than assumed: `python3` is
# absent on the Windows images and `python` on some Linux ones.
PROVE_PYTHON=""
prove_python() {
  local candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then PROVE_PYTHON="$candidate"; return 0; fi
  done
  echo "::error::no python3 on PATH, so no frame can be analysed" >&2
  return 1
}
