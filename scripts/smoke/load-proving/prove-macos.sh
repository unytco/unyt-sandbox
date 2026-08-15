#!/usr/bin/env bash
# Does the released macOS build launch and put a window on screen?
#
#   prove-macos.sh <artifact.dmg> <shots-dir>
#
# TEMPORARY — scaffolding for .github/workflows/zz-TEMPORARY-load-proving.yaml.
#
# THIS LANE PROVES LESS THAN THE OTHER TWO, AND SAYS SO. Linux and Windows gate
# on a photograph of the app's own window. macOS cannot: since Catalina, reading
# screen pixels needs the TCC "Screen Recording" grant, a GitHub-hosted runner
# has never had it and cannot be given it, and without it `screencapture` does
# not fail — it returns the desktop with every application window omitted. A
# wallpaper is a rich gradient, so a not-blank threshold scores it as a painted
# app. Any pixel verdict from this runner would be a lie either way it fell.
#
# So the gate here is the WINDOW LIST, which is only partly redacted: the title
# is withheld without the grant, the owner pid, the layer and the bounds are not.
# What that proves: the app launched, reached a state a user could act on, and
# put a real on-screen window up at a real size. WHAT IT DOES NOT PROVE: that
# the webview painted anything into that window.
#
# Frames are still captured and still uploaded — as evidence about the runner,
# never as the verdict. See mac-window-info.swift.
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
echo "screen recording: ${grant:-unknown} (this decides only whether the FRAMES are worth anything;" >&2
echo "  the verdict below is the window list either way)" >&2

# ── the negative control ──────────────────────────────────────────────────────
# EVIDENCE, NOT A GATE, and the difference is the point: nothing on this platform
# is decided on pixels, so a control frame that passes for the app says the
# capture path is untrustworthy WITHOUT changing whether the app is proven.
prove_control() { # <path>
  screencapture -x "$1" 2>/dev/null && [ -s "$1" ]
}
prove_control_check "$LABEL" advisory || true
echo "control: $PROVE_CONTROL_NOTE" >&2

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

# Frames are context on this platform, so they are written where the verdict
# cannot read them.
prove_capture() { # <slug>
  screencapture -x "$PROVE_SHOTS_CONTEXT/$1-screen.png" 2>/dev/null && [ -s "$PROVE_SHOTS_CONTEXT/$1-screen.png" ]
}

# THE GATE ON THIS PLATFORM, replacing the photograph the other two use: the
# largest layer-0 window the app owns that is big enough to be a window a user
# sees. A frame is taken alongside it, for the record and never for the verdict.
prove_seek_evidence() { # <slug> [force]
  local found
  prove_shoot "$@" || true
  found="$(window_info "$app_pid" 2>/dev/null |
    awk -v minw="$MIN_WINDOW_W" -v minh="$MIN_WINDOW_H" '
      /^WINDOW / && $5 >= minw && $6 >= minh {
        area = $5 * $6
        if (area > best) { best = area; line = $0 }
      }
      END { if (line != "") print line }' || true)"
  [ -n "$found" ] || return 1
  echo "OK: the app owns an on-screen window — $found" >&2
  PROVE_EVIDENCE="$found"
  return 0
}

# A whole-screen retina PNG per poll would be tens of megabytes of artifact for
# frames that decide nothing here. Both ceilings, because the forced shots after
# the state is reached bypass the first one.
PROVE_MAX_SHOTS=6
PROVE_HARD_MAX_SHOTS=8

# The shared watch: same failure, exit and timeout handling as the other lanes,
# with the evidence swapped out above.
prove_watch || true

echo "--- app stdout/stderr (tail) ---" >&2
tail -40 "$stdout_log" >&2 2>/dev/null || true
echo "--- the window list as it stands now ---" >&2
window_info "$app_pid" >&2 || true
# compgen, not `find -quit`: BSD find is not GNU find, and a glob that matched
# nothing would otherwise be handed to the analyser as a filename.
if compgen -G "$PROVE_SHOTS_CONTEXT/*.png" >/dev/null; then
  echo "--- what those frames contain (CONTEXT ONLY on this platform) ---" >&2
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

if [ -z "$PROVE_EVIDENCE" ]; then
  prove_answer "$LABEL" "NOT PROVEN" \
    "$state_note, and it never put an on-screen window of at least ${MIN_WINDOW_W}x${MIN_WINDOW_H} up (webview paint is not verified on macOS either way — see the header of prove-macos.sh)" 1
fi

read -r _ _ _ _ win_w win_h _ <<<"$PROVE_EVIDENCE"
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
  prove_answer "$LABEL" "NOT PROVEN" "$state_note, though it did put a $size_note window on screen" 1
fi
# WINDOW-ONLY, never PROVEN: publish-verdict.sh passes this lane green and says
# in the same breath that no pixel was checked. The two must not share a word —
# the Checks list is where this gets read, and there they would look identical.
# The control's finding rides along, because the frames this lane uploads are
# where a reader would otherwise go looking for the paint it did not verify.
printf 'VERDICT %s: WINDOW-ONLY — %s and put a %s window on screen; macOS cannot photograph it on a runner (control: %s), so whether the webview painted into that window is NOT verified here\n' \
  "$LABEL" "$state_note" "$size_note" "$PROVE_CONTROL_NOTE"
exit 0
