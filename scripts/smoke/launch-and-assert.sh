#!/usr/bin/env bash
# Launch the installed app and assert it comes up, stays up, and shuts down.
#
#   launch-and-assert.sh <installed-binary>
#
# Runs inside the container, after the .deb is installed. No WebDriver, no
# in-app hooks beyond the app's own log — the only tool added to the machine is
# Xvfb, which stands in for the user's monitor and adds nothing to the app's own
# dependency closure.
#
# Three assertions, in order:
#   1. REACHES a healthy terminal state (the set in common.sh — any one passes).
#      Fails immediately on a terminal failure state or a panic.
#   2. STAYS there. A conductor that boots and then wedges passes (1) and fails
#      here: after the terminal state, keep tailing for longer than one heartbeat
#      interval and refuse a conductor that keeps dropping.
#   3. SHUTS DOWN. SIGTERM, then require exit within a bound — a hung process
#      does not.
#
# Env: UNYT_SMOKE_SANDBOX (default /tmp/ut-smoke) · UNYT_SMOKE_TIMEOUT (default
#      240) · UNYT_SMOKE_SETTLE (default 45, must exceed the 5s first backoff)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$here/common.sh"

BIN="${1:?usage: launch-and-assert.sh <installed-binary>}"
[ -x "$BIN" ] || { echo "::error::not executable: $BIN" >&2; exit 1; }

SANDBOX="${UNYT_SMOKE_SANDBOX:-/tmp/ut-smoke}"
TIMEOUT="${UNYT_SMOKE_TIMEOUT:-240}"
SETTLE="${UNYT_SMOKE_SETTLE:-45}"
# The heartbeat's reconnect backoff starts at 5s, so a settle window shorter than
# that could not observe even one retry and the "stays up" assertion would be
# theatre.
[ "$SETTLE" -ge 15 ] || { echo "::error::UNYT_SMOKE_SETTLE must be >= 15s to span a heartbeat retry" >&2; exit 1; }

# Short /tmp path only: lair's keystore opens a unix-domain socket under the data
# dir and unix sockets cap the path at ~108 chars. Also guards the rm below.
if [[ ! "$SANDBOX" =~ ^/tmp/[A-Za-z0-9._-]+$ ]]; then
  echo "::error::UNYT_SMOKE_SANDBOX must be a short /tmp/<name> path (got '$SANDBOX')" >&2
  exit 1
fi
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"/{data,cache,config,state}
stdout_log="$SANDBOX/app-stdout.log"
: >"$stdout_log"

app_pid=""
# shellcheck disable=SC2317  # invoked through the EXIT trap
cleanup() {
  [ -n "$app_pid" ] || return 0
  kill -TERM -- "-$app_pid" 2>/dev/null || true
  sleep 2
  kill -KILL -- "-$app_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

dump_logs() {
  echo "--- app stdout/stderr (tail) ---" >&2
  tail -60 "$stdout_log" 2>/dev/null || echo "(none captured)" >&2
  echo "--- app log (tail) ---" >&2
  smoke_all_logs "$SANDBOX" | tail -60 >&2
}

# Nothing here can type into the first-run password prompt, so the keystore is
# created with an empty passphrase. That still exercises REAL keystore creation
# and a real conductor start — it skips the prompt, not the work.
export UNYT_BYPASS_PASSWORD=1
# Without this the single-instance plugin is installed and a second launch on the
# same machine would just focus the first window instead of starting.
export AGENT_ID="${AGENT_ID:-smoke}"
export XDG_DATA_HOME="$SANDBOX/data"
export XDG_CACHE_HOME="$SANDBOX/cache"
export XDG_CONFIG_HOME="$SANDBOX/config"
export XDG_STATE_HOME="$SANDBOX/state"
export RUST_LOG="${RUST_LOG:-info}"
# Headless WebKitGTK: with no GPU the DMABUF/GBM/EGL path fails and the webview
# dies mid-boot, which would be indistinguishable from a real failure.
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export LIBGL_ALWAYS_SOFTWARE=1
export GDK_BACKEND=x11
case "$BIN" in *.AppImage) export APPIMAGE_EXTRACT_AND_RUN=1 ;; esac

command -v xvfb-run >/dev/null || { echo "::error::xvfb-run not found (apt-get install xvfb)" >&2; exit 1; }

echo "Launching $BIN (sandbox $SANDBOX, up to ${TIMEOUT}s to a healthy state)" >&2
set -m   # own process group per background job, so cleanup can signal the tree
xvfb-run -a "$BIN" >"$stdout_log" 2>&1 &
app_pid=$!
set +m

# Track the APP, not the launcher. `$!` is xvfb-run's pid, and xvfb-run does not
# exec — so an app that ignores SIGTERM keeps running while xvfb-run exits, and
# watching the launcher would report a clean shutdown for a hung app. Matched on
# exact process name inside the group, which excludes xvfb-run and Xvfb (whose
# own command lines both CONTAIN the binary path, so -f would match them too).
app_proc=""
app_name="$(basename "$BIN")"
for _ in $(seq 1 20); do
  app_proc="$(pgrep -g "$app_pid" -x "${app_name:0:15}" 2>/dev/null | head -1 || true)"
  [ -n "$app_proc" ] && break
  kill -0 "$app_pid" 2>/dev/null || break
  sleep 1
done
if [ -n "$app_proc" ]; then
  echo "  app pid $app_proc (launcher $app_pid)" >&2
else
  # Never silently downgrade to the launcher: that is the assertion that fails
  # open. An app that never appeared is itself the failure.
  echo "::error::no '$app_name' process appeared under the launcher within 20s" >&2
  dump_logs
  exit 1
fi
alive() { kill -0 "$app_proc" 2>/dev/null; }

# ── 1. reaches a healthy terminal state ───────────────────────────────────────
deadline=$(( $(date +%s) + TIMEOUT ))
reached=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  logs="$(smoke_all_logs "$SANDBOX")"
  if printf '%s' "$logs" | grep -qE "$UNYT_RE_FAILED"; then
    echo "::error::the app reached a FAILURE state:" >&2
    printf '%s' "$logs" | grep -oE "$UNYT_RE_FAILED.*" | head -3 | sed 's/^/  /' >&2
    dump_logs
    exit 1
  fi
  if printf '%s' "$logs" | grep -qE "$UNYT_RE_HEALTHY"; then
    reached="$(printf '%s' "$logs" | grep -oE "$UNYT_RE_HEALTHY.*" | head -1)"
    break
  fi
  if ! alive; then
    echo "::error::the app exited before reaching any healthy state" >&2
    dump_logs
    exit 1
  fi
  sleep 3
done

if [ -z "$reached" ]; then
  echo "::error::no healthy state within ${TIMEOUT}s — the app never finished starting" >&2
  dump_logs
  exit 1
fi
echo "OK: reached a healthy state -> ${reached}" >&2

# ── 2. stays up ───────────────────────────────────────────────────────────────
# Bounded by construction (a fixed window, never "wait until healthy again"), so
# a permanently flapping conductor fails instead of hanging the job.
echo "Watching ${SETTLE}s for a wedged conductor..." >&2
before_drops="$(smoke_all_logs "$SANDBOX" | grep -cE "$UNYT_RE_DISCONNECTED" || true)"
settle_end=$(( $(date +%s) + SETTLE ))
while [ "$(date +%s)" -lt "$settle_end" ]; do
  if ! alive; then
    echo "::error::the app exited after reaching a healthy state" >&2
    dump_logs
    exit 1
  fi
  logs="$(smoke_all_logs "$SANDBOX")"
  if printf '%s' "$logs" | grep -qE "$UNYT_RE_FAILED"; then
    echo "::error::the app failed after reaching a healthy state:" >&2
    printf '%s' "$logs" | grep -oE "$UNYT_RE_FAILED.*" | head -3 | sed 's/^/  /' >&2
    dump_logs
    exit 1
  fi
  sleep 3
done

after_drops="$(smoke_all_logs "$SANDBOX" | grep -cE "$UNYT_RE_DISCONNECTED" || true)"
new_drops=$(( after_drops - before_drops ))
# One drop inside the window is the heartbeat's normal transient (it reconnects
# with backoff); repeated drops are a conductor that never settles.
if [ "$new_drops" -gt 1 ]; then
  echo "::error::conductor dropped $new_drops times in ${SETTLE}s — it never settled" >&2
  dump_logs
  exit 1
fi
echo "OK: still healthy after ${SETTLE}s ($new_drops transient disconnect(s))" >&2

# ── 3. shuts down ─────────────────────────────────────────────────────────────
echo "Sending SIGTERM..." >&2
kill -TERM -- "-$app_pid" 2>/dev/null || true
exit_deadline=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$exit_deadline" ]; do
  alive || { app_pid=""; echo "OK: exited on SIGTERM" >&2; exit 0; }
  sleep 1
done

echo "::error::still running 30s after SIGTERM — the app is hung on shutdown" >&2
dump_logs
exit 1
