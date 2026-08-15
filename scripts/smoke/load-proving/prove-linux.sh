#!/usr/bin/env bash
# Does the released Linux build put a visible first screen on screen?
#
#   prove-linux.sh <artifact.deb|artifact.AppImage> <shots-dir>
#
# The Linux half of release-smoke.yaml's phase 1 — one lane per installer
# (`opens-linux`), and a failed lane fails the release run.
#
# NOT a pristine container, unlike run-smoke.sh: the question here is whether the
# app paints, not whether it declares its dependencies, and the container adds an
# X server and a `docker cp` between us and the frame. run-smoke.sh still owns the
# dependency question and still runs in a clean image.
#
# ONLY FRAMES OF THE APP'S OWN WINDOW decide the verdict, as on the other two
# platforms. The root display is photographed too, but as context: it is mostly
# the bare Xvfb background, so its dominant colour is the background's and not
# the app's — a frame of it could only ever say "something is there".
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=proving-common.sh
. "$here/proving-common.sh"

ARTIFACT="${1:?usage: prove-linux.sh <artifact.deb|artifact.AppImage> <shots-dir>}"
SHOTS="${2:?usage: prove-linux.sh <artifact> <shots-dir>}"
LABEL="linux/$(basename "$ARTIFACT")"
prove_arm_errors "$LABEL"
[ -f "$ARTIFACT" ] || prove_answer "$LABEL" "CANNOT PROVE" "no such artifact: $ARTIFACT" 2
# Absolute: `apt-get install foo.deb` without a path separator is read as a
# package NAME, and apt then reports the artifact as an unknown package.
ARTIFACT="$(cd "$(dirname "$ARTIFACT")" && pwd)/$(basename "$ARTIFACT")"

# Short /tmp path only: lair opens a unix-domain socket under the data dir and
# unix sockets cap the path at ~108 chars. Same constraint as launch-and-assert.sh.
SANDBOX="${UNYT_PROVE_SANDBOX:-/tmp/ut-prove}"
[[ "$SANDBOX" =~ ^/tmp/[A-Za-z0-9._-]+$ ]] ||
  prove_answer "$LABEL" "CANNOT PROVE" "UNYT_PROVE_SANDBOX must be a short /tmp/<name> path (got '$SANDBOX')" 2

WORK="$(mktemp -d)"
DISPLAY_NUM=""
xvfb_pid=""
app_pid=""
app_proc=""
window_id=""
saw_window=""

# shellcheck disable=SC2317,SC2329  # invoked through the EXIT trap
cleanup() {
  [ -z "$app_pid" ] || { kill -TERM -- "-$app_pid" 2>/dev/null || true; sleep 2; kill -KILL -- "-$app_pid" 2>/dev/null || true; }
  [ -z "$xvfb_pid" ] || kill -TERM "$xvfb_pid" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

for tool in Xvfb xdotool xwininfo xdpyinfo; do
  command -v "$tool" >/dev/null ||
    prove_answer "$LABEL" "CANNOT PROVE" "$tool is not installed on this runner, so there is no way to look at a screen" 2
done

# ImageMagick 6 ships `import`, 7 renames it under `magick`. Chosen once so the
# capture path cannot differ between frames.
if command -v import >/dev/null; then
  IM_IMPORT=(import)
elif command -v magick >/dev/null; then
  IM_IMPORT=(magick import)
else
  prove_answer "$LABEL" "CANNOT PROVE" "neither 'import' nor 'magick' is installed, so nothing can be captured" 2
fi

prove_python || prove_answer "$LABEL" "CANNOT PROVE" "no python on this runner, so no frame could be analysed" 2

# ── install the way a user would ──────────────────────────────────────────────
LAUNCH=""
PROC_NAME=""
case "$ARTIFACT" in
  *.deb)
    sudo apt-get install -y "$ARTIFACT" >&2 ||
      prove_answer "$LABEL" "NOT PROVEN" "the package would not install, so there was nothing to launch" 1
    pkg="$(dpkg-deb -f "$ARTIFACT" Package)"
    # `|| true` on the whole pipeline: pipefail plus `head` closing early makes
    # SIGPIPE the assignment's status, which errexit would take as a failure.
    LAUNCH="$(dpkg -L "$pkg" | grep -E '^/usr/bin/' | head -1 || true)"
    [ -x "$LAUNCH" ] ||
      prove_answer "$LABEL" "NOT PROVEN" "$pkg installed no executable under /usr/bin, so there was nothing to launch" 1
    PROC_NAME="$(basename "$LAUNCH")"
    ;;
  *.AppImage)
    LAUNCH="$WORK/app.AppImage"
    cp "$ARTIFACT" "$LAUNCH"
    chmod +x "$LAUNCH"
    # FUSE is absent on the runners and libfuse2 is renamed on newer Ubuntu, so
    # extraction is the portable path — same reasoning as container-checks-appimage.sh.
    export APPIMAGE_EXTRACT_AND_RUN=1
    ( cd "$WORK" && "$LAUNCH" --appimage-extract >/dev/null ) ||
      prove_answer "$LABEL" "NOT PROVEN" "the AppImage would not extract, so there was nothing to launch" 1
    # The app runs as its INNER binary, so the process to watch is named by the
    # bundle rather than guessed from the .AppImage filename.
    PROC_NAME="$(grep -hm1 '^Exec=' "$WORK"/squashfs-root/*.desktop 2>/dev/null | sed 's/^Exec=//; s/[[:space:]].*//' || true)"
    [ -n "$PROC_NAME" ] ||
      prove_answer "$LABEL" "NOT PROVEN" "the AppImage's .desktop declares no Exec, so there is no process to watch" 1
    sudo apt-get install -y libwebkit2gtk-4.1-0 libgbm1 libgl1 libegl1 >&2 ||
      prove_answer "$LABEL" "CANNOT PROVE" "the AppImage's GTK baseline would not install on this runner" 2
    ;;
  *)
    prove_answer "$LABEL" "CANNOT PROVE" "unsupported artifact '$ARTIFACT' (expected .deb or .AppImage)" 2
    ;;
esac
echo "launching $LAUNCH (process '$PROC_NAME')" >&2

# ── a display of our own ──────────────────────────────────────────────────────
# Explicit Xvfb rather than xvfb-run: the capture has to address the SAME display
# the app was given, and xvfb-run picks one it never tells the caller about.
# 1400x1050 leaves room around the 800x800 splash, so the window is never clipped.
for candidate in $(seq 99 120); do
  [ -e "/tmp/.X${candidate}-lock" ] && continue
  Xvfb ":$candidate" -screen 0 1400x1050x24 -nolisten tcp >"$WORK/xvfb.log" 2>&1 &
  xvfb_pid=$!
  for _ in $(seq 1 20); do
    if xdpyinfo -display ":$candidate" >/dev/null 2>&1; then DISPLAY_NUM="$candidate"; break; fi
    kill -0 "$xvfb_pid" 2>/dev/null || break
    sleep 1
  done
  [ -n "$DISPLAY_NUM" ] && break
  kill -TERM "$xvfb_pid" 2>/dev/null || true
  xvfb_pid=""
done
if [ -z "$DISPLAY_NUM" ]; then
  echo "::error::no Xvfb display came up, so there is no screen to look at:" >&2
  sed 's/^/  /' "$WORK/xvfb.log" >&2 || true
  prove_answer "$LABEL" "CANNOT PROVE" "no X display could be started on this runner" 2
fi
export DISPLAY=":$DISPLAY_NUM"
echo "  display $DISPLAY (1400x1050)" >&2

# ── the negative control, before anything is launched ─────────────────────────
prove_init "$SHOTS"
prove_control() { # <path>
  "${IM_IMPORT[@]}" -display "$DISPLAY" -window root "$1" 2>/dev/null
}
control_rc=0
prove_control_check "$LABEL" || control_rc=$?
[ "$control_rc" -eq 0 ] || exit "$control_rc"

# ── the sandbox ───────────────────────────────────────────────────────────────
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"/{data,cache,config,state}
stdout_log="$SANDBOX/app-stdout.log"
: >"$stdout_log"

export XDG_DATA_HOME="$SANDBOX/data"
export XDG_CACHE_HOME="$SANDBOX/cache"
export XDG_CONFIG_HOME="$SANDBOX/config"
export XDG_STATE_HOME="$SANDBOX/state"
# Without this the single-instance plugin is installed and a second launch would
# focus the first window instead of starting.
export AGENT_ID="${AGENT_ID:-prove}"
export RUST_LOG="${RUST_LOG:-info}"
# Headless WebKitGTK: with no GPU the DMABUF/GBM/EGL path fails and the webview
# dies mid-boot, which would be indistinguishable from a real failure.
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export LIBGL_ALWAYS_SOFTWARE=1
export GDK_BACKEND=x11
# DELIBERATELY NOT SET: UNYT_BYPASS_PASSWORD. Parking at LairAwaitingPassword with
# the prompt on screen is exactly what this proves, and the bypass was observed
# locally not to advance the app anyway.

set -m   # own process group per background job, so cleanup can signal the tree
"$LAUNCH" >"$stdout_log" 2>&1 &
app_pid=$!
set +m

# Track the APP, not the launcher. pgrep matches on the first 15 characters.
for _ in $(seq 1 30); do
  app_proc="$(pgrep -g "$app_pid" -x "${PROC_NAME:0:15}" 2>/dev/null | head -1 || true)"
  [ -n "$app_proc" ] && break
  kill -0 "$app_pid" 2>/dev/null || break
  sleep 1
done
if [ -z "$app_proc" ]; then
  echo "::error::no '$PROC_NAME' process appeared within 30s — the app never started:" >&2
  tail -40 "$stdout_log" >&2 || true
  prove_answer "$LABEL" "NOT PROVEN" "no '$PROC_NAME' process appeared within 30s — the app never started" 1
fi
echo "  app pid $app_proc (launcher $app_pid)" >&2

# ── find its window ───────────────────────────────────────────────────────────
# Exit 1 is "no window", which is an answer about the app. ANYTHING ELSE is the
# probe itself failing — a missing script, a broken xwininfo — and reporting that
# as "the app mapped no window" would blame the artifact for our tooling.
find_window() {
  local out rc=0
  out="$(bash "$here/x-largest-window.sh" "$app_proc" 2>"$WORK/xwin.err")" || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "::error::the window probe exited $rc — this says nothing about the app:" >&2
    sed 's/^/  /' "$WORK/xwin.err" >&2 || true
  else
    sed 's/^/  /' "$WORK/xwin.err" >&2 || true
  fi
  printf '%s' "$out"
}

# Set here and in prove_capture, never inside find_window: that runs in a command
# substitution, and a subshell's assignment dies with it.
for _ in $(seq 1 30); do
  window_id="$(find_window)"
  [ -n "$window_id" ] && { saw_window=1; break; }
  kill -0 "$app_proc" 2>/dev/null || break
  sleep 1
done
if [ -n "$window_id" ]; then
  echo "  window $window_id — $(xdotool getwindowgeometry "$window_id" 2>/dev/null | tr '\n' ' ')" >&2
else
  echo "::warning::the app has mapped no visible X window yet" >&2
  xwininfo -root -tree >&2 2>/dev/null || true
fi

# ── the callbacks proving-common.sh drives ────────────────────────────────────
prove_logs() { smoke_all_logs "$SANDBOX"; }
prove_alive() { kill -0 "$app_proc" 2>/dev/null; }

prove_capture() { # <slug>
  local slug="$1"
  # The whole display as context, whatever else happens: when the window frame
  # comes back wrong it is what tells a human whether anything was there at all.
  "${IM_IMPORT[@]}" -display "$DISPLAY" -window root "$PROVE_SHOTS_CONTEXT/$slug-root.png" 2>/dev/null || true
  # Re-found each time: the window does not exist until the app maps it, and a
  # full boot replaces the splash with the main window later on.
  window_id="$(find_window)"
  [ -n "$window_id" ] || return 1
  # EVER, not currently: a window that appeared and then went away is a different
  # finding from one that never existed, and the verdict below tells them apart.
  saw_window=1
  "${IM_IMPORT[@]}" -display "$DISPLAY" -window "$window_id" "$PROVE_SHOTS_VERDICT/$slug-window.png" 2>/dev/null
}

# The verdict reads the STATE the watch reached, not its return code: a run that
# never got there still has frames, and they are still worth analysing.
prove_watch || true

echo "--- app stdout/stderr (tail) ---" >&2
tail -40 "$stdout_log" >&2 2>/dev/null || true

# "The app showed no window" is about the artifact; it is not the same finding as
# a capture that failed, so it is reported as itself.
if [ -z "$saw_window" ] && [ "$PROVE_SHOT_COUNT" -gt 0 ]; then
  xwininfo -root -tree >&2 2>/dev/null || true
  prove_answer "$LABEL" "NOT PROVEN" "the app ran but mapped no visible window, so there was no first screen to photograph" 1
fi

verdict_rc=0
prove_verdict "$LABEL" || verdict_rc=$?
exit "$verdict_rc"
