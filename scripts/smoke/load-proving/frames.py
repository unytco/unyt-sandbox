#!/usr/bin/env python3
"""Is a captured frame the app's own first screen, or something else entirely?

  frames.py <shot.png> [shot.png ...]   one line per shot, then a verdict

Exit status: 0 when at least one shot is PAINTED, 3 when none is but something
was readable, 4 when nothing could be read at all. prove.py imports assess()
rather than reading those lines back, and decides what a verdict means for a
lane; this command line is for reading an uploaded artifact by hand.

"NOT BLANK" IS NOT THE ASSERTION, and this is the whole point of the file. A
macOS desktop wallpaper is a rich gradient: thousands of distinct colours and a
low dominant share. A process without the Screen Recording grant does not get an
error from `screencapture` — it gets the desktop with every application window
silently omitted. A variance-only threshold scores that PAINTED and reports a
blank-window release as green. So a frame must be dominated by a colour THE APP
ITSELF DECLARES before it counts as the app's.

One analyser for all three platforms rather than ImageMagick here, `sips` there
and System.Drawing on Windows: three implementations of one threshold drift, and
the threshold is the whole assertion.
"""

import collections
import os
import sys

from PIL import Image, UnidentifiedImageError

# ── what the app's own first screen is made of ────────────────────────────────
# The boot screen's background is a STACK of translucent layers, so the colour a
# frame is dominated by is a composite and not any single declared value. Every
# source is in unyt/ui/white-label:
#
#   splashscreen.html, index.html   body            #3f3f46
#   styles/runtime-boot.styles.ts   :host           #4f4f5e, overridden for the
#                                                   whole run by the window-glow
#                                                   animation, which alternates
#                                                   rgb(35,35,49) <-> rgb(35,35,39)
#                                   .translucent-overlay  rgba(68,68,75,0.6)
#                                   .modal-backdrop       rgba(0,0,0,0.5)
#
# Every render path in runtime-boot-view.ts lays the overlay over the host; the
# keystore password prompt adds the backdrop on top of that. Composing them here
# rather than listing hex values keeps this honest when the CSS moves.
#
# The window-glow animation is a continuous interpolation, so its intermediate
# frames are colours no keyframe names. They belong in the SET, not in the slack
# around it: widening the tolerance to reach them widens it in every direction at
# once, and the accepted region becomes "any dark grey". Only the blue channel
# moves, so the ramp is eleven values.
BOOT_BASE_COLOURS = [
    (0x3F, 0x3F, 0x46),
    (0x4F, 0x4F, 0x5E),
] + [(35, 35, blue) for blue in range(39, 50)]
BOOT_LAYERS = [((68, 68, 75), 0.6), ((0, 0, 0), 0.5)]


def _over(base, layer, alpha):
    return tuple(
        int(round(layer[i] * alpha + base[i] * (1.0 - alpha))) for i in range(3)
    )


def boot_backgrounds():
    """Every base, and every prefix of the layer stack over it. A frame taken
    before Lit mounts sees the bare body colour; one taken at the password prompt
    sees both layers; the states in between see one."""
    out = set()
    for base in BOOT_BASE_COLOURS:
        out.add(base)
        for colour, alpha in BOOT_LAYERS:
            out.add(_over(base, colour, alpha))
        stacked = base
        for colour, alpha in BOOT_LAYERS:
            stacked = _over(stacked, colour, alpha)
            out.add(stacked)
    return sorted(out)


BOOT_BACKGROUNDS = boot_backgrounds()

# Per-channel slack on that match, and DELIBERATELY TIGHT: the set above already
# contains every colour the boot screen can show, so this covers nothing but
# rounding. A capture on Xvfb, on GDI or on a runner's virtual display goes
# through no colour management. Every unit beyond that widens the accepted region
# into somebody else's dark grey — at 16, #2c2c2c and #444444 both matched.
BACKGROUND_TOLERANCE = 3

# ── the two bars, and why they sit where they do ──────────────────────────────
# MEASURED, NOT REASONED. Bars set from first principles were walked through by
# an adversarial frame built from a real Linux capture: the app's boot background
# plus the native menu bar, modal blanked out, scored 96.88% dominant over 203
# distinct colours. The menu bar is drawn by the native toolkit and not by the
# webview, so "the chrome renders, the webview content is missing" — the bug this
# file exists to catch — was a pass. Every frame run 31862262726 captured, plus
# that one:
#
#   real screens        50.00% – 53.90% dominant     1847 – 2360 distinct
#   unpainted / early   92.94% – 99.69% dominant        3 –  556 distinct
#   menu bar only       96.88% dominant                     203 distinct
#
# Nothing observed lives between those ranges, so both bars go in the middle of
# their gap. A tighter bar costs nothing in time — each lane polls until a frame
# passes rather than looking once.

# The geometric middle of 556..1847. A CONSEQUENCE WORTH STATING: at 8 bits per
# pixel a greyscale or palette PNG holds 256 colours at most, so a capture in one
# can never clear this bar. That is right rather than unfortunate — a tool that
# quantised the frame has not handed us a screen.
MIN_DISTINCT_COLOURS = 1000

# No single colour may be more than this much of the frame. THE BAR THE MENU-BAR
# FRAME BROKE: a colour count alone cannot tell a screen from a blank window with
# something small and rich on it, because a strip of chrome carries hundreds of
# colours in 3% of the pixels.
MAX_DOMINANT_SHARE = 0.75

# A 1x1 or 16x16 capture is a tool that failed and wrote something anyway; it
# cannot be evidence about an 800x800 window whatever its colour variance.
MIN_DIMENSION = 200

# FOREIGN is the verdict this file exists for: a frame with plenty of content
# whose dominant colour is not one the app declares. A wallpaper lands here, and
# so does a capture that photographed the wrong window.
PAINTED, FOREIGN, FLAT, UNREADABLE = "PAINTED", "FOREIGN", "FLAT", "UNREADABLE"


class Unreadable(Exception):
    """The file is not an image this can read. Never a verdict about the app."""


def count_colours(path):
    """(width, height, Counter of 8-bit RGB tuples). Alpha is dropped on purpose:
    a screenshot is composited already, and an alpha channel the capture tool
    invented would otherwise split one visible colour into several."""
    try:
        with Image.open(path) as image:
            # PNG because it is what all three capture tools emit by default and
            # it is lossless — a JPEG's ringing would manufacture the colour
            # variance this looks for, and a frame in one is a capture path that
            # is not the one these bars were measured against.
            if image.format != "PNG":
                raise Unreadable("not a PNG (%s)" % (image.format or "unknown format"))
            image.load()
            width, height = image.size
            counts = collections.Counter(image.convert("RGB").getdata())
    except (UnidentifiedImageError, ValueError) as exc:
        raise Unreadable("%s" % exc) from exc
    except OSError as exc:
        raise Unreadable("%s" % exc) from exc
    return width, height, counts


def nearest_background(colour):
    """The declared background this colour matches, or None."""
    best, best_distance = None, BACKGROUND_TOLERANCE + 1
    for candidate in BOOT_BACKGROUNDS:
        distance = max(abs(colour[i] - candidate[i]) for i in range(3))
        if distance < best_distance:
            best, best_distance = candidate, distance
    return best if best_distance <= BACKGROUND_TOLERANCE else None


def assess(path):
    """(verdict, one-line description). Never raises: an unreadable file is its
    own answer, not a crash that would read as a failed app."""
    if not os.path.exists(path):
        return UNREADABLE, "no such file"
    try:
        width, height, counts = count_colours(path)
    except Unreadable as exc:
        return UNREADABLE, str(exc)

    # BEFORE the counter is read: a frame with no pixels in it makes
    # most_common() empty, and the IndexError would be reported as "the analyser
    # itself failed" when the truth is a capture tool that wrote nothing.
    if width < MIN_DIMENSION or height < MIN_DIMENSION:
        return (
            UNREADABLE,
            "%dx%d — smaller than %dpx, so the capture tool failed and wrote something anyway"
            % (
                width,
                height,
                MIN_DIMENSION,
            ),
        )

    total = sum(counts.values())
    dominant, dominant_n = counts.most_common(1)[0]
    share = dominant_n / total
    top = ", ".join(
        "#%02x%02x%02x %.1f%%" % (c[0], c[1], c[2], 100.0 * n / total)
        for c, n in counts.most_common(5)
    )
    facts = "%dx%d distinct=%d dominant=#%02x%02x%02x (%.2f%%) top5=[%s]" % (
        width,
        height,
        len(counts),
        dominant[0],
        dominant[1],
        dominant[2],
        100.0 * share,
        top,
    )

    if len(counts) < MIN_DISTINCT_COLOURS:
        return FLAT, "%s — under %d distinct colours" % (facts, MIN_DISTINCT_COLOURS)
    if share > MAX_DOMINANT_SHARE:
        return (
            FLAT,
            "%s — over %.1f%% of the frame is one single colour, so whatever else is on it is too little to be a screen"
            % (
                facts,
                100.0 * MAX_DOMINANT_SHARE,
            ),
        )
    matched = nearest_background(dominant)
    if matched is None:
        return (
            FOREIGN,
            "%s — its dominant colour is none of the app's declared boot backgrounds, so this frame is not the app's window"
            % facts,
        )
    return PAINTED, "%s — dominated by the app's own #%02x%02x%02x" % (
        facts,
        matched[0],
        matched[1],
        matched[2],
    )


def report(paths, out=sys.stdout):
    """[(path, verdict, detail)], printed as it goes."""
    results = []
    for path in paths:
        verdict, detail = assess(path)
        results.append((path, verdict, detail))
        print("%-10s %s: %s" % (verdict, os.path.basename(path), detail), file=out)
    return results


def exit_code(results):
    verdicts = [verdict for _, verdict, _ in results]
    if PAINTED in verdicts:
        return 0
    if verdicts and set(verdicts) == {UNREADABLE}:
        return 4
    return 3


def main(argv):
    if not argv:
        print("::error::usage: frames.py <shot.png> [...]", file=sys.stderr)
        return 2
    return exit_code(report(argv))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
