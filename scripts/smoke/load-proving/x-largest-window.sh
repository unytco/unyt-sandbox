#!/usr/bin/env bash
# The window id of the largest visible top-level window on $DISPLAY.
#
#   x-largest-window.sh [pid]
#
# TEMPORARY — scaffolding for .github/workflows/zz-TEMPORARY-load-proving.yaml.
#
# Prints one id (hex or decimal — ImageMagick's -window takes either) and exits
# 0, or prints nothing and exits 1 when the display has no window worth aiming
# at. LARGEST, because a toolkit maps small utility windows next to the real one
# and a frame of one of those would be a true picture of the wrong thing.
#
# `xdotool search --pid` is preferred when it answers, but it CANNOT BE RELIED
# ON: it reads _NET_WM_PID, which the client has to have set — ImageMagick's own
# `display` does not, and a lane that trusted it would report "the app mapped no
# window" about a window plainly on the display. The fallback asks the X server
# for the root window's children instead, which needs nothing of the client. That
# is only sound because the display is private to this run: on a shared desktop
# the largest window would be somebody else's.
set -uo pipefail

PID="${1:-}"

geometry_of() { # <id> -> "<id> <w> <h>"
  xdotool getwindowgeometry --shell "$1" 2>/dev/null |
    awk -F= -v id="$1" '/^WIDTH=/ { w = $2 } /^HEIGHT=/ { h = $2 }
      END { if (w != "" && h != "") print id, w, h }'
}

by_pid() {
  local id
  [ -n "$PID" ] || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    geometry_of "$id"
  done < <(xdotool search --onlyvisible --pid "$PID" 2>/dev/null || true)
}

# `$(NF-1)` is the `<w>x<h>[+-]<x>[+-]<y>` token: a window title may contain
# spaces, so counting from the end is the only stable way to find it. The offsets
# can be NEGATIVE for a window placed partly off-screen, which a `\+`-only match
# would skip — and skipping the app's window reads as "the app showed nothing".
by_root_children() {
  xwininfo -root -children 2>/dev/null |
    awk '/^ +0x[0-9a-fA-F]+/ {
      geom = $(NF - 1)
      if (match(geom, /^[0-9]+x[0-9]+[-+]/)) { split(geom, a, /[x+-]/); print $1, a[1], a[2] }
    }'
}

largest() { # reads "<id> <w> <h>" lines
  local id w h area best=0 chosen=""
  while read -r id w h; do
    [ -n "$id" ] || continue
    area=$((w * h))
    if [ "$area" -gt "$best" ]; then
      best="$area"
      chosen="$id"
    fi
  done
  printf '%s\n' "$chosen"
}

# THE PID ANSWER WINS WHEN THERE IS ONE. The fallback asks the X server for the
# root's children, which is every client's window and not just ours — sound only
# because this display is private to this run, and worth saying which was used.
chosen="$(by_pid | largest)"
source=_NET_WM_PID
if [ -z "$chosen" ]; then
  chosen="$(by_root_children | largest)"
  source="the root window's children (this display has no other client)"
fi

[ -n "$chosen" ] || exit 1
echo "  window $chosen, found via $source" >&2
printf '%s\n' "$chosen"
