#!/usr/bin/env bash
# Does the released macOS build launch and put a window on screen?
#
#   prove-macos.sh <artifact.dmg> <shots-dir>
#
# The macOS half of release-smoke.yaml's phase 1 (`opens-macos`), one lane per
# architecture. It runs on the pinned macos-15 / macos-15-intel images the
# inventory names — the capture rules below are what that pinning protects.
#
# TWO MODES, AND THE LOG SAYS WHICH ONE THIS RUN CONCLUDED IN.
#
#   PROVEN       a window-scoped capture of the app's own window is the app's own
#                screen, judged by the same analyser as Linux and Windows.
#   WINDOW-ONLY  anything else. The gate is then the WINDOW LIST, which is only
#                partly redacted: kCGWindowName is withheld from a process
#                without the TCC "Screen Recording" grant, the owner pid, the
#                layer and the bounds are not. That proves the app launched,
#                reached a state a user could act on, and put a real on-screen
#                window up at a real size — and NOT that the webview painted
#                anything into it.
#
# WHY BOTH, when the grant is what a runner is not supposed to have: without it
# `screencapture` does not fail, it returns the desktop with every application
# window omitted — and a wallpaper is a rich gradient that a not-blank threshold
# scores as a painted app. But the first run of this lane read a window TITLE,
# which is the one field that grant governs, so on macos-15 the grant is there
# (the pinning, rather than macos-latest, is the likeliest reason). So the lane
# measures whether it has the grant, tries, and drops to the window list on
# anything short of the app's own screen.
#
# The fallback is the whole point: this lane is never red for a reason that used
# to be green, and never PROVEN off a frame that is not the app's own window.
# The negative control and the window-server survey run either way — they are the
# evidence for which mode we ended up in. See mac-window-info.swift.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=proving-common.sh
. "$here/proving-common.sh"

DMG="${1:?usage: prove-macos.sh <artifact.dmg> <shots-dir>}"
SHOTS="${2:?usage: prove-macos.sh <artifact.dmg> <shots-dir>}"
LABEL="macos/$(basename "$DMG")"
prove_arm_errors "$LABEL"
[ -f "$DMG" ] || prove_answer "$LABEL" "CANNOT PROVE" "no such artifact: $DMG" 2

# A window this size is the app's, not a toolkit helper or an offscreen shim.
# The splash is declared 800x800 in unyt/src-tauri/tauri.conf.json; the floor is
# well under it because a full boot replaces the splash with the main window,
# which is a different size and still a window the app put on screen.
MIN_WINDOW_W=400
MIN_WINDOW_H=300
DECLARED_W=800
DECLARED_H=800

# A SHORT home, not mktemp's: lair binds a unix-domain socket under
# ~/Library/Application Support/<bundle id>/<version>/holochain, and a
# /var/folders/... temp root spends most of the 108-character socket limit
# before the app has added a byte.
FAKE_HOME="${UNYT_PROVE_HOME:-/tmp/ut-prove}"
[[ "$FAKE_HOME" =~ ^/tmp/[A-Za-z0-9._-]+$ ]] ||
  prove_answer "$LABEL" "CANNOT PROVE" "UNYT_PROVE_HOME must be a short /tmp/<name> path (got '$FAKE_HOME')" 2
# How long `hdiutil attach` may take before it is treated as stuck — a disk image
# carrying a licence agreement waits for a keypress, which would otherwise hang
# the job until the runner's own six-hour timeout.
ATTACH_TIMEOUT="${UNYT_HDIUTIL_TIMEOUT:-120}"

WORK="$(mktemp -d)"
MOUNT=""
app_pid=""

# shellcheck disable=SC2317,SC2329  # invoked through the EXIT trap
cleanup() {
  [ -z "$app_pid" ] || { kill -TERM "$app_pid" 2>/dev/null || true; sleep 2; kill -KILL "$app_pid" 2>/dev/null || true; }
  [ -z "$MOUNT" ] || hdiutil detach -quiet "$MOUNT" 2>/dev/null || hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

prove_python || prove_answer "$LABEL" "CANNOT PROVE" "no python on this runner, so no frame could be read" 2
prove_init "$SHOTS"

# ── is there a screen at all? ─────────────────────────────────────────────────
# ASKED FIRST, and loudly: a runner with no Aqua session cannot show a GUI app
# anything, and the window list would be empty for a reason that has nothing to
# do with the artifact. Reporting that as a failed app would be a lie; skipping
# it silently would be worse.
session="$(launchctl managername 2>/dev/null || true)"
echo "launchctl managername: ${session:-<none>}" >&2
if [ "$session" != "Aqua" ]; then
  echo "::error title=No window server on this runner::the launchd session is '${session:-unknown}', not Aqua" >&2
  prove_answer "$LABEL" "CANNOT PROVE" "this runner has no Aqua (GUI) session, so no application can put a window on a screen here" 2
fi

if ! command -v swiftc >/dev/null; then
  prove_answer "$LABEL" "CANNOT PROVE" "swiftc is not on PATH, so the window probe could not be built and nothing could be asked of the window server" 2
fi
# Compiled once rather than run through `swift` per poll: interpreting it each
# time would add most of a minute across a run. Copied to main.swift first,
# because swiftc only accepts top-level statements in a file by that name.
cp "$here/mac-window-info.swift" "$WORK/main.swift"
if ! swiftc -O -o "$WORK/window-info" "$WORK/main.swift" >&2; then
  prove_answer "$LABEL" "CANNOT PROVE" "the window probe would not compile on this runner, so nothing could be asked of the window server" 2
fi

window_info() { "$WORK/window-info" "${1:-0}"; }

# ── can the window list answer at all? ────────────────────────────────────────
# ASKED BEFORE ANYTHING IS INSTALLED, because the whole macOS approach rests on
# the owner pid and the bounds surviving the redaction — and that is the least
# certain claim in it. The survey is printed either way; the first run of this
# lane is partly an experiment, and "we learned it does not work here" is a
# result, not a failure to report.
probe_rc=0
probe_out="$(window_info 0)" || probe_rc=$?
printf '%s\n' "$probe_out" >&2
# Exhaustive on purpose: 0 and 1 are both "the list answered" (pid 0 owns
# nothing), and every other code has to be named rather than fallen through.
case "$probe_rc" in
  0 | 1) ;;
  3)
    prove_answer "$LABEL" "CANNOT PROVE" "the window server returned no window list at all" 2 ;;
  5)
    echo "::error title=The macOS window list is not evidence::the owner pid or the bounds are redacted across the whole list" >&2
    prove_answer "$LABEL" "UNTRUSTED" "the window list carries no usable owner pid or bounds on this macOS, so it cannot say whether the app put a window on screen and no verdict from this runner would mean anything" 3 ;;
  *)
    prove_answer "$LABEL" "CANNOT PROVE" "the window probe exited $probe_rc, which it is not supposed to be able to do" 2 ;;
esac
grant="$(printf '%s' "$probe_out" | sed -n 's/^GRANT  screen-recording=//p')"
# Read from whether the list carries titles at all, and only PROVISIONAL here:
# every window in it belongs to somebody else at this point, and the reading that
# decides anything is taken again once the app has a window of its own.
echo "screen recording (before launch): ${grant:-unknown}" >&2

# ── the negative control ──────────────────────────────────────────────────────
# ADVISORY, NEVER A GATE: this lane has a verdict that does not rest on pixels, so
# a control frame that passes for the app must not be able to red it. What it
# does instead is decide whether pixels may be believed at all — see the mode
# below. TWO of them, for the same reason prove-windows.ps1 takes two: the whole
# screen answers "is this runner's screen mistakable for the app", but the frame
# that would decide is one window's worth of it, and a sub-rect can clear a bar
# the whole screen does not. The rect is anchored at the top-left because that is
# where the menu bar is, and a strip of chrome over a desktop is exactly the
# frame these thresholds were tightened to reject.
prove_control() { # <path>
  screencapture -x "$1" 2>/dev/null && [ -s "$1" ]
}
prove_control_check "$LABEL" advisory 00-control-screen || true
screen_control_status="$PROVE_CONTROL_STATUS"
screen_control_note="$PROVE_CONTROL_NOTE"
prove_control() { # <path>
  screencapture -x "-R0,0,$DECLARED_W,$DECLARED_H" "$1" 2>/dev/null && [ -s "$1" ]
}
prove_control_check "$LABEL" advisory 00-control-window-rect || true
rect_control_status="$PROVE_CONTROL_STATUS"
echo "control (whole screen): $screen_control_note" >&2
echo "control (a ${DECLARED_W}x${DECLARED_H} rect of it): $PROVE_CONTROL_NOTE" >&2
CONTROL_NOTE="$screen_control_note; a ${DECLARED_W}x${DECLARED_H} rect of it, $PROVE_CONTROL_NOTE"

# ── install the way a user would ──────────────────────────────────────────────
attach_log="$WORK/hdiutil-attach.log"
hdiutil attach -nobrowse -readonly -noverify -noautoopen \
  -mountpoint "$WORK/mnt" "$DMG" >"$attach_log" 2>&1 </dev/null &
hd_pid=$!
hd_deadline=$(( $(date +%s) + ATTACH_TIMEOUT ))
hd_rc=0
while kill -0 "$hd_pid" 2>/dev/null; do
  if [ "$(date +%s)" -ge "$hd_deadline" ]; then
    kill -KILL "$hd_pid" 2>/dev/null || true
    hd_rc=124
    break
  fi
  sleep 1
done
[ "$hd_rc" -ne 0 ] || { wait "$hd_pid" || hd_rc=$?; }
if [ "$hd_rc" -ne 0 ]; then
  echo "::error::hdiutil could not mount $(basename "$DMG") (exit $hd_rc):" >&2
  sed 's/^/  /' "$attach_log" >&2 || true
  prove_answer "$LABEL" "NOT PROVEN" "the disk image would not mount, so nothing could be installed" 1
fi
MOUNT="$WORK/mnt"

app_count="$(find "$MOUNT" -maxdepth 1 -name '*.app' -print | grep -c . || true)"
app_src="$(find "$MOUNT" -maxdepth 1 -name '*.app' -print | sort | head -1 || true)"
if [ "$app_count" != "1" ]; then
  prove_answer "$LABEL" "CANNOT PROVE" "the disk image contains $app_count .app bundles — refusing to pick one at random" 2
fi
# /Applications, where a user drags it: bundle identity, signature evaluation and
# the app's own idea of where it lives all depend on the path it runs from.
APP="/Applications/$(basename "$app_src")"
case "$APP" in
  /Applications/*.app) ;;
  *) prove_answer "$LABEL" "CANNOT PROVE" "refusing to install to '$APP'" 2 ;;
esac
rm -rf "$APP"
# ditto, not cp -R: it preserves the xattrs and symlinks the signature covers.
ditto "$app_src" "$APP" >&2
hdiutil detach -quiet "$MOUNT" >&2 || hdiutil detach -quiet -force "$MOUNT" >&2 || true
MOUNT=""

EXEC_NAME="$(plutil -extract CFBundleExecutable raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$EXEC_NAME" ] && [ -x "$APP/Contents/MacOS/$EXEC_NAME" ] ||
  prove_answer "$LABEL" "NOT PROVEN" "the installed bundle has no Contents/MacOS/<CFBundleExecutable> — got '${EXEC_NAME:-<no Info.plist>}'" 1

# ── the sandbox ───────────────────────────────────────────────────────────────
# HOME is the whole redirection: tauri's app_data_dir / app_log_dir and app_dirs2
# all resolve through it on macOS, so a fake HOME moves every path the app
# writes. AGENT_ID is deliberately NOT set — it lengthens the data root, and the
# socket path above has no room to spare on a runner that has never run this app.
rm -rf "$FAKE_HOME"
mkdir -p "$FAKE_HOME"
export HOME="$FAKE_HOME"
export RUST_LOG="${RUST_LOG:-info}"
stdout_log="$WORK/app-stdout.log"
: >"$stdout_log"

# The binary directly, not `open`: `open` hands the launch to launchd, which
# gives the app launchd's environment and drops HOME, RUST_LOG and the sandbox
# with it. A bundled binary run this way still gets a window-server connection.
"$APP/Contents/MacOS/$EXEC_NAME" >"$stdout_log" 2>&1 &
app_pid=$!
echo "launched $APP/Contents/MacOS/$EXEC_NAME (pid $app_pid, HOME=$HOME)" >&2

# ── the callbacks proving-common.sh drives ────────────────────────────────────
# Tauri's app_log_dir is ~/Library/Logs/<id> on macOS; the Application Support
# path is read too, so a change in tauri's resolution shows up as a log we still
# find rather than as a silent "no state reached".
prove_logs() {
  cat "$stdout_log" \
    "$HOME/Library/Logs/$UNYT_BUNDLE_ID"/unyt.v*.log.* \
    "$HOME/Library/Application Support/$UNYT_BUNDLE_ID/logs"/unyt.v*.log.* 2>/dev/null || true
}
prove_alive() { kill -0 "$app_pid" 2>/dev/null; }

# A WHOLE-SCREEN frame is context on this platform whatever the mode: without the
# grant it is the desktop with the app omitted, and with it the app is one window
# on a desktop rather than the thing being judged. It is written where the verdict
# cannot read it.
prove_capture() { # <slug>
  screencapture -x "$PROVE_SHOTS_CONTEXT/$1-screen.png" 2>/dev/null && [ -s "$PROVE_SHOTS_CONTEXT/$1-screen.png" ]
}

# The largest layer-0 window the app owns that is big enough to be a window a
# user sees. Re-asked every time it is needed: a full boot replaces the splash
# with the main window, which is a different window with a different id.
mac_window_line() {
  window_info "$app_pid" 2>/dev/null |
    awk -v minw="$MIN_WINDOW_W" -v minh="$MIN_WINDOW_H" '
      /^WINDOW / && $5 >= minw && $6 >= minh {
        area = $5 * $6
        if (area > best) { best = area; line = $0 }
      }
      END { if (line != "") print line }' || true
}

# THE GATE THIS LANE HAS ALWAYS USED, and still its floor: the window list. Held
# in its own variable as well, because the pixel phase below sets PROVE_EVIDENCE
# to a frame and the fallback verdict still has to be able to read the window.
MAC_WINDOW_LINE=""
prove_seek_evidence() { # <slug> [force]
  local found
  prove_shoot "$@" || true
  found="$(mac_window_line)"
  [ -n "$found" ] || return 1
  echo "OK: the app owns an on-screen window — $found" >&2
  MAC_WINDOW_LINE="$found"
  PROVE_EVIDENCE="$found"
  return 0
}

# WINDOW-SCOPED, and that is what makes it evidence: `-l <windowid>` asks the
# window server for that window's own content, so what comes back is the app
# whatever is in front of it — the same reasoning as PrintWindow on Windows, and
# unlike a whole-screen frame it cannot be a picture of the desktop. `-o` drops
# the drop shadow, which would otherwise pad the frame with desktop pixels.
#
# Without the Screen Recording grant this returns the desktop instead, which is
# why pixel mode is off in that case — and why a frame that got here is still
# judged by the analyser rather than trusted for having been captured.
prove_capture_window() { # <slug>
  local out="$PROVE_SHOTS_VERDICT/$1-window.png" line id
  line="$(mac_window_line)"
  id="$(printf '%s' "$line" | awk '{print $2}')"
  [ -n "$id" ] || return 1
  screencapture -x -o -l "$id" "$out" 2>>"$WORK/screencapture.err" && [ -s "$out" ] || return 1
  # The window that was PHOTOGRAPHED, so the verdict's size describes the frame
  # rather than whatever the watch last saw: the splash is replaced by the main
  # window mid-run, and the two are different sizes.
  MAC_WINDOW_LINE="$line"
}

# A whole-screen retina PNG per poll would be tens of megabytes of artifact for
# frames that decide nothing here. Both ceilings, because the forced shots after
# the state is reached bypass the first one.
PROVE_MAX_SHOTS=6
PROVE_HARD_MAX_SHOTS=8

# The shared watch: same failure, exit and timeout handling as the other lanes,
# with the evidence swapped out above.
prove_watch || true

# ── and now the pixels, if they are allowed to mean anything ──────────────────
# AFTER the watch, never inside it: the watch's job is unchanged, so this phase
# can only add a verdict to one the lane has already earned. It runs only when
# the app got as far as a window — with nothing on screen there is nothing to
# photograph — and its own budget on top of the shot ceilings above, which the
# whole-screen frames have usually spent by now.
#
# THE GRANT IS RE-READ HERE, over a list that now contains the app's own window.
# What it measures is titles ANYWHERE in the list, not on our window (see
# mac-window-info.swift): the probe is a command-line tool that owns no windows,
# so every entry in that list belongs to another process, and a title on any of
# them is a cross-process read of the one field this grant governs. Re-read
# because a desktop with nothing titled on it answers "not-granted" for want of
# anything to read, and the app's own window is one more thing to read.
grant_now="$(window_info "$app_pid" 2>/dev/null | sed -n 's/^GRANT  screen-recording=//p' || true)"
[ -n "$grant_now" ] || grant_now="$grant"

# The arming itself is prove_pixels_may_decide's, so that the condition a false
# PROVEN would have to get past is one the test suite drives; the branches below
# only name which half said no.
capable="$(prove_capable_word "$grant_now")"
PIXEL_MODE=""
if prove_pixels_may_decide "$capable" "$screen_control_status" "$rect_control_status"; then
  PIXEL_MODE=1
  PIXEL_WHY="the window list carries titles, so this process has Screen Recording, and neither pre-launch frame passes for the app"
elif [ "$capable" != yes ]; then
  PIXEL_WHY="the window list carries no titles, so this process does not have Screen Recording and a capture would return the desktop rather than the app's own window"
else
  PIXEL_WHY="a pre-launch control frame cannot be trusted ($CONTROL_NOTE)"
fi
# What the fallback verdict says about the pixels. It starts as the reason the
# lane never tried, and the attempt below replaces it with what happened — the
# two are different findings and the verdict line must not blur them.
PIXEL_OUTCOME="$PIXEL_WHY"
if [ -n "$PIXEL_MODE" ]; then
  echo "pixel mode: ON — $PIXEL_WHY" >&2
  echo "  a frame of the app's own window that is its own screen makes this PROVEN; anything else is WINDOW-ONLY" >&2
else
  echo "pixel mode: OFF — $PIXEL_WHY" >&2
  echo "  the verdict is the window list, and webview paint is not verified here" >&2
fi

PIXEL_SECONDS="${UNYT_PROVE_PIXEL_SECONDS:-30}"
PAINTED_FRAME=""
# THE STATE HALF IS A PRECONDITION, not something the pixels could rescue: a run
# that failed or never reached a state is NOT PROVEN below whatever a frame
# shows, so photographing it would spend the budget to produce a warning about
# paint on a lane whose finding is the backend.
if [ -n "$PIXEL_MODE" ] && [ -n "$MAC_WINDOW_LINE" ] &&
  [ -z "$PROVE_FAILED_STATE" ] && [ -n "$PROVE_REACHED" ]; then
  echo "--- photographing the app's own window (${PIXEL_SECONDS}s budget) ---" >&2
  PROVE_MAX_SHOTS=$((PROVE_SHOT_COUNT + 16))
  PROVE_HARD_MAX_SHOTS=$PROVE_MAX_SHOTS
  pixel_frames_before="$(find "$PROVE_SHOTS_VERDICT" -name '*.png' | grep -c . || true)"
  pixel_failures_before="$PROVE_CAPTURE_FAILURES"
  prove_capture() { prove_capture_window "$@"; }
  if prove_seek_paint pixel "$PIXEL_SECONDS"; then
    PAINTED_FRAME="$PROVE_EVIDENCE"
    echo "OK: a window-scoped capture is the app's own screen ($PAINTED_FRAME)" >&2
  else
    # WHICH OF THE TWO IT WAS, because they are opposite findings: frames that
    # are not a screen say something about the build, and no frames at all say
    # the capture path could not photograph a window that was demonstrably
    # there. The lane must never report the second as the first.
    pixel_frames="$(find "$PROVE_SHOTS_VERDICT" -name '*.png' | grep -c . || true)"
    pixel_frames=$((pixel_frames - pixel_frames_before))
    if [ "$pixel_frames" -gt 0 ]; then
      # STOPS SHORT OF BLAMING THE BUILD on purpose: titles in the window list
      # say this process has the grant, not that a window capture returns the
      # window — a macOS that redacts one and not the other would hand back the
      # desktop here, and the frames in the artifact are how a reader tells the
      # two apart.
      PIXEL_OUTCOME="$pixel_frames frames of that window were captured and none is the app's own screen — either the webview drew nothing, or this runner handed back the desktop instead of the window"
      echo "::warning title=macOS photographed the window and it is not a screen::$PIXEL_OUTCOME (the frames are in the artifact)" >&2
    else
      PIXEL_OUTCOME="not one window-scoped capture succeeded, so nothing was photographed to judge ($((PROVE_CAPTURE_FAILURES - pixel_failures_before)) failed attempt(s))"
      echo "::warning title=macOS could not photograph the window at all::$PIXEL_OUTCOME — this lane falls back to the window list" >&2
    fi
    if [ -s "$WORK/screencapture.err" ]; then
      sed 's/^/  screencapture: /' "$WORK/screencapture.err" >&2 || true
    fi
  fi
fi

echo "--- app stdout/stderr (tail) ---" >&2
tail -40 "$stdout_log" >&2 2>/dev/null || true
echo "--- the window list as it stands now ---" >&2
window_info "$app_pid" >&2 || true
# compgen, not `find -quit`: BSD find is not GNU find, and a glob that matched
# nothing would otherwise be handed to the analyser as a filename.
if compgen -G "$PROVE_SHOTS_VERDICT/*.png" >/dev/null; then
  echo "--- what the window-scoped frames contain (these decide the verdict) ---" >&2
  "$PROVE_PYTHON" "$PROVE_ANALYSER" "$PROVE_SHOTS_VERDICT"/*.png >&2 || true
fi
if compgen -G "$PROVE_SHOTS_CONTEXT/*.png" >/dev/null; then
  echo "--- what the whole-screen frames contain (CONTEXT, never the verdict) ---" >&2
  "$PROVE_PYTHON" "$PROVE_ANALYSER" "$PROVE_SHOTS_CONTEXT"/*.png >&2 || true
fi

# ── the verdict ───────────────────────────────────────────────────────────────
# Both halves named, always: a window with no state and a state with no window
# are different bugs.
if [ -n "$PROVE_FAILED_STATE" ]; then
  state_note="the app reached a failure state ($PROVE_FAILED_STATE)"
elif [ -n "$PROVE_REACHED" ]; then
  state_note="the app reached $PROVE_REACHED"
else
  state_note="the app never reached LairAwaitingPassword or a healthy state"
fi

if [ -z "$MAC_WINDOW_LINE" ]; then
  prove_answer "$LABEL" "NOT PROVEN" \
    "$state_note, and it never put an on-screen window of at least ${MIN_WINDOW_W}x${MIN_WINDOW_H} up, so there was nothing to photograph either" 1
fi

read -r _ _ _ _ win_w win_h _ <<<"$MAC_WINDOW_LINE"
size_note="${win_w}x${win_h}"
if [ "$win_w" -lt $((DECLARED_W * 3 / 4)) ] || [ "$win_w" -gt $((DECLARED_W * 5 / 4)) ] ||
   [ "$win_h" -lt $((DECLARED_H * 3 / 4)) ] || [ "$win_h" -gt $((DECLARED_H * 5 / 4)) ]; then
  # Not fatal: a full boot replaces the splash with the main window, which is a
  # different size and still a window the app put on screen. Loud, because the
  # other reason to see it is that this is somebody else's window.
  echo "::warning title=Not the splash's declared size::the window is ${size_note}, and the splash declares ${DECLARED_W}x${DECLARED_H}" >&2
  size_note="$size_note, not the ${DECLARED_W}x${DECLARED_H} the splash declares"
fi

if [ -n "$PROVE_FAILED_STATE" ] || [ -z "$PROVE_REACHED" ]; then
  # Ahead of the pixel result on purpose, exactly as prove_verdict does it on the
  # other two platforms: a painted screen with a failed backend behind it is not
  # a pass, it is a different bug.
  prove_answer "$LABEL" "NOT PROVEN" "$state_note, though it did put a $size_note window on screen" 1
fi

# PROVEN ONLY OFF A FRAME OF THE APP'S OWN WINDOW, judged by the same analyser
# and the same thresholds as Linux and Windows. Nothing else this lane collected
# can earn this word.
if [ -n "$PAINTED_FRAME" ]; then
  prove_answer "$LABEL" "PROVEN" \
    "$state_note, put a $size_note window on screen, and a window-scoped capture of it is the app's own screen ($PAINTED_FRAME)" 0
fi

# WINDOW-ONLY, never PROVEN: publish-verdict.sh passes this lane green and says
# in the same breath that no pixel was checked. The two must not share a word —
# the Checks list is where this gets read, and there they would look identical.
# WHY the pixels did not decide rides along, because "nothing could be
# photographed" and "frames were taken and none is a screen" send a reader to
# opposite places, and only the second is worth opening the artifact for.
printf 'VERDICT %s: WINDOW-ONLY — %s and put a %s window on screen; no photograph of that window says it is a screen the app painted (%s), so what the webview drew into it is NOT verified here\n' \
  "$LABEL" "$state_note" "$size_note" "$PIXEL_OUTCOME"
exit 0
