#!/usr/bin/env python3
"""Is a captured frame the app's own first screen, or something else entirely?

  screenshot-stats.py <shot.png> [shot.png ...]   one line per shot, then a verdict
  screenshot-stats.py --control <shot.png>        the pre-launch negative control
  screenshot-stats.py --self-test                 prove the verdicts can still fail

Exit status: 0 when at least one shot is PAINTED, 3 when none is but something
was readable, 4 when nothing could be read at all. `--control` answers a
different question and has its own codes — see control() below.

"NOT BLANK" IS NOT THE ASSERTION, and this is the whole point of the file. A
macOS desktop wallpaper is a rich gradient: thousands of distinct colours and a
low dominant share. Since Catalina, a process without the Screen Recording grant
does not get an error from `screencapture` — it gets the desktop with every
application window silently omitted. A variance-only threshold scores that
PAINTED and reports a blank-window release as green. So a frame must be
dominated by a colour THE APP ITSELF DECLARES before it counts as the app's.

One analyser for all three platforms rather than ImageMagick here, `sips` there
and System.Drawing on Windows: three implementations of one threshold drift, and
the threshold is the whole assertion. PNG because it is what all three capture
tools emit by default and it is lossless — a JPEG's ringing would manufacture
the colour variance this looks for.

Pure standard library (zlib is in it), so no runner needs a package installed
before it can answer.

The threshold every phase-1 lane of release-smoke.yaml judges its frame by, and
a phase-1 failure fails the release run — so --self-test runs first in each lane.
"""

import collections
import os
import struct
import sys
import zlib

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
# rather than listing hex values keeps this honest when the CSS moves: the
# numbers below are the CSS, not a snapshot of what a screenshot once looked like.
#
# The window-glow animation is a continuous interpolation, so its intermediate
# frames are colours no keyframe names. They belong in the SET, not in the slack
# around it: widening the tolerance to reach them widens it in every direction at
# once, and the accepted region becomes "any dark grey" — which is most dark
# themes ever drawn. Only the blue channel moves, so the ramp is eleven values.
BOOT_BASE_COLOURS = [
    (0x3F, 0x3F, 0x46),
    (0x4F, 0x4F, 0x5E),
] + [(35, 35, blue) for blue in range(39, 50)]
BOOT_LAYERS = [((68, 68, 75), 0.6), ((0, 0, 0), 0.5)]


def _over(base, layer, alpha):
    return tuple(
        int(round(layer[i] * alpha + base[i] * (1.0 - alpha))) for i in range(3)
    )


def _boot_backgrounds():
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


BOOT_BACKGROUNDS = _boot_backgrounds()

# Per-channel slack on that match, and DELIBERATELY TIGHT: the set above already
# contains every colour the boot screen can actually show, so this covers nothing
# but rounding. A capture on Xvfb, on GDI or on a runner's virtual display goes
# through no colour management, so a rendered pixel differs from the composed
# value by at most a unit. Every unit of slack beyond that widens the accepted
# region into somebody else's dark grey — at 16, #2c2c2c and #444444 both matched.
BACKGROUND_TOLERANCE = 3

# ── the two bars, and why they sit where they do ──────────────────────────────
# MEASURED, NOT REASONED. The first pair of bars here were set from first
# principles — "far above every degenerate case" — and an adversarial frame built
# from the real Linux capture walked straight through them: the app's boot
# background plus the native menu bar, with the modal blanked out, scored 96.88%
# dominant over 203 distinct colours and passed both. The menu bar is drawn by
# the native toolkit and not by the webview, so "the chrome renders, the webview
# content is missing" — very nearly the bug this file exists to catch — was a
# pass. Every frame run 31862262726 captured, plus that one:
#
#   frame                                        dominant   distinct
#   linux-deb        13-t25s   real screen         53.26%       2039
#   linux-appimage   14-t28s   real screen         53.90%       2360
#   windows-2022     04-t8s    real screen         50.00%       1847
#   windows-2025     04-t9s    real screen         50.86%       1881
#   linux-appimage   13-t25s   unpainted white     99.69%        556
#   windows-2022     01/02/03  early               92.94%        449
#   windows-2025     01/02     early               96.55%         49
#   windows-2025     03        early               96.92%          3
#   menu bar only              adversarial         96.88%        203
#
# Nothing observed lives between 53.90% and 92.94% dominant, or between 556 and
# 1847 distinct, so both bars go in the middle of their gap. A tighter bar costs
# nothing in time — each lane polls until a frame passes rather than looking once
# — and Linux painted three seconds into a thirty-second budget.

# The geometric middle of 556..1847 (1014^2 ~ 556 x 1847). A CONSEQUENCE WORTH
# STATING: at 8 bits per pixel a greyscale or palette PNG holds 256 colours at
# most, so a capture in one can never clear this bar. That is right rather than
# unfortunate — a tool that quantised the frame has not handed us a screen.
MIN_DISTINCT_COLOURS = 1000

# No single colour may be more than this much of the frame. THE BAR THE MENU-BAR
# FRAME BROKE: a colour count alone cannot tell a screen from a blank window with
# something small and rich on it, because a strip of chrome carries hundreds of
# colours in 3% of the pixels.
MAX_DOMINANT_SHARE = 0.75

# A 1x1 or 16x16 capture is a tool that failed and wrote something anyway; it
# cannot be evidence about an 800x800 window whatever its colour variance.
MIN_DIMENSION = 200

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

# FOREIGN is the verdict this file exists for: a frame with plenty of content
# whose dominant colour is not one the app declares. A wallpaper lands here, and
# so does a capture that photographed the wrong window.
PAINTED, FOREIGN, FLAT, UNREADABLE = "PAINTED", "FOREIGN", "FLAT", "UNREADABLE"


class Unreadable(Exception):
    """The file is not a PNG this can decode. Never a verdict about the app."""


# ── decoding ──────────────────────────────────────────────────────────────────
# Channel count per PNG colour type (0 grey, 2 RGB, 3 palette, 4 grey+alpha, 6 RGBA).
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def _chunks(data):
    # Chunk CRCs are deliberately not verified: every corruption a capture tool
    # can realistically produce is a SHORT file, and those already fail — in
    # _unfilter for a truncated IDAT, in zlib for a mangled stream, and in the
    # length check below for a truncated chunk. A CRC pass would add cost per
    # frame and catch only a bit-flip nothing here can cause.
    pos = len(PNG_SIGNATURE)
    while pos + 8 <= len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        kind = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + length]
        if len(body) != length:
            raise Unreadable("truncated %s chunk" % kind.decode("latin-1"))
        yield kind, body
        pos += 12 + length


def _unfilter(raw, height, bpp, stride):
    """Reverse the per-scanline filters (PNG spec section 9). The rows chain, so
    this cannot be narrowed to the part of the image anyone looks at."""
    out = bytearray()
    prev = bytearray(stride)
    pos = 0
    for _ in range(height):
        if pos + 1 + stride > len(raw):
            raise Unreadable(
                "the compressed image data is shorter than %d rows" % height
            )
        ft = raw[pos]
        line = bytearray(raw[pos + 1 : pos + 1 + stride])
        pos += 1 + stride
        if ft == 0:
            pass
        elif ft == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ft == 2:
            # zip drives the loop in C; Up is the one filter with no dependency
            # on the pixel to its left, so it can be done wholesale.
            line = bytearray([(x + y) & 0xFF for x, y in zip(line, prev)])
        elif ft == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                c = prev[i - bpp] if i >= bpp else 0
                b = prev[i]
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                if pa <= pb and pa <= pc:
                    pr = a
                elif pb <= pc:
                    pr = b
                else:
                    pr = c
                line[i] = (line[i] + pr) & 0xFF
        else:
            raise Unreadable("unknown scanline filter %d" % ft)
        out += line
        prev = line
    return out


def count_colours(path):
    """(width, height, Counter of 8-bit RGB tuples). Alpha is dropped on purpose:
    a screenshot is composited already, and an alpha channel the capture tool
    invented would otherwise split one visible colour into several."""
    with open(path, "rb") as fh:
        data = fh.read()
    if not data.startswith(PNG_SIGNATURE):
        raise Unreadable("not a PNG (%d bytes, starts %r)" % (len(data), data[:8]))

    width = height = depth = colour_type = interlace = None
    palette = b""
    idat = bytearray()
    for kind, body in _chunks(data):
        if kind == b"IHDR":
            width, height, depth, colour_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", body
            )
        elif kind == b"PLTE":
            palette = body
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    if width is None:
        raise Unreadable("no IHDR chunk")
    if interlace != 0:
        raise Unreadable("interlaced PNGs are not decoded here")
    if colour_type not in CHANNELS:
        raise Unreadable("unknown colour type %d" % colour_type)
    if colour_type == 3:
        if depth not in (1, 2, 4, 8):
            raise Unreadable("palette PNG at bit depth %d" % depth)
        if not palette:
            raise Unreadable("palette PNG with no PLTE chunk")
    elif colour_type == 0:
        # Sub-byte greyscale is not a curiosity here: ImageMagick writes a
        # two-colour frame as 1-bit grey, which is exactly what a capture of a
        # bare Xvfb root window is. Refusing it made the Linux control frame
        # unreadable and the lane unable to answer.
        if depth not in (1, 2, 4, 8, 16):
            raise Unreadable("greyscale PNG at bit depth %d" % depth)
    elif depth not in (8, 16):
        raise Unreadable("bit depth %d on colour type %d" % (depth, colour_type))
    if not idat:
        raise Unreadable("no IDAT chunk")

    channels = CHANNELS[colour_type]
    stride = (width * channels * depth + 7) // 8
    bpp = max(1, (channels * depth) // 8)
    pixels = _unfilter(zlib.decompress(bytes(idat)), height, bpp, stride)

    counts = collections.Counter()
    if colour_type == 2 and depth == 8:
        for y in range(height):
            row = pixels[y * stride : (y + 1) * stride]
            counts.update(bytes(row[i : i + 3]) for i in range(0, width * 3, 3))
    elif colour_type == 6 and depth == 8:
        for y in range(height):
            row = pixels[y * stride : (y + 1) * stride]
            counts.update(bytes(row[i : i + 3]) for i in range(0, width * 4, 4))
    else:
        step = depth // 8 if depth >= 8 else 0
        # Sub-byte samples are a fraction of full scale, so 1-bit white is 1 and
        # has to be stretched to 255 before it can be compared with anything.
        full_scale = (1 << depth) - 1
        for y in range(height):
            row = pixels[y * stride : (y + 1) * stride]
            for x in range(width):
                if colour_type == 3:
                    idx = _sample(row, x, depth)
                    if (idx + 1) * 3 > len(palette):
                        raise Unreadable(
                            "palette index %d is outside the PLTE chunk" % idx
                        )
                    counts[bytes(palette[idx * 3 : idx * 3 + 3])] += 1
                elif depth < 8:
                    g = _sample(row, x, depth) * 255 // full_scale
                    counts[bytes((g, g, g))] += 1
                else:
                    # 16-bit samples: the high byte is the visible one, and
                    # keeping the low byte would count dithering as colour.
                    base = x * channels * step
                    if colour_type in (0, 4):
                        g = row[base]
                        counts[bytes((g, g, g))] += 1
                    else:
                        counts[
                            bytes((row[base], row[base + step], row[base + 2 * step]))
                        ] += 1
    return width, height, counts


def _sample(row, x, depth):
    """The x'th unsigned sample of a scanline, for the depths that pack several
    into a byte. Palette indices and greyscale values are the same extraction."""
    if depth == 8:
        return row[x]
    per_byte = 8 // depth
    byte = row[x // per_byte]
    shift = 8 - depth * (x % per_byte + 1)
    return (byte >> shift) & ((1 << depth) - 1)


# ── the verdict ───────────────────────────────────────────────────────────────
def nearest_background(colour):
    """The declared background this colour matches, or None."""
    best, best_distance = None, BACKGROUND_TOLERANCE + 1
    for candidate in BOOT_BACKGROUNDS:
        distance = max(abs(colour[i] - candidate[i]) for i in range(3))
        if distance < best_distance:
            best, best_distance = candidate, distance
    if best_distance <= BACKGROUND_TOLERANCE:
        return best
    return None


def assess(path):
    """(verdict, one-line description). Never raises: an unreadable file is its
    own answer, not a crash that would read as a failed app."""
    try:
        width, height, counts = count_colours(path)
    except Unreadable as exc:
        return UNREADABLE, "%s" % exc
    except (OSError, zlib.error) as exc:
        return UNREADABLE, "%s" % exc

    # BEFORE the counter is read: a 0-pixel frame makes most_common() empty, and
    # an IndexError here would be reported by every caller as "the analyser
    # itself failed" when the truth is that the capture tool wrote a frame with
    # nothing in it — a finding about the runner.
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
    hexes = ", ".join(
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
        hexes,
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
    matched = nearest_background(tuple(dominant))
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


def main(paths):
    if not paths:
        print("::error::usage: screenshot-stats.py <shot.png> [...]", file=sys.stderr)
        return 2
    verdicts = []
    for path in paths:
        if not os.path.exists(path):
            verdict, detail = UNREADABLE, "no such file"
        else:
            verdict, detail = assess(path)
        verdicts.append(verdict)
        print("%-10s %s: %s" % (verdict, os.path.basename(path), detail))
    if PAINTED in verdicts:
        return 0
    if UNREADABLE in verdicts and len(set(verdicts)) == 1:
        return 4
    return 3


def control(path):
    """The pre-launch negative control: a frame taken BEFORE the app is running.
    It must not score PAINTED. If it does, the capture path is photographing
    something that looks like the app while the app does not exist — so every
    verdict that job would go on to produce is void.

    0 the capture path can be trusted · 4 it produced nothing readable ·
    5 it produced a frame that would have passed for the app."""
    if not os.path.exists(path):
        print("UNREADABLE %s: no such file" % os.path.basename(path))
        return 4
    verdict, detail = assess(path)
    print("%-10s %s: %s" % (verdict, os.path.basename(path), detail))
    if verdict == PAINTED:
        return 5
    if verdict == UNREADABLE:
        return 4
    return 0


# ── the regression test ───────────────────────────────────────────────────────
# Every case below is one the real captures produce, and each must still be able
# to come out the other way: a threshold nothing can fail is not a threshold.
def _encode(width, height, rows, colour_type=2, depth=8, palette=b"", filter_type=0):
    """A minimal PNG encoder, so the self-test drives the real decoder rather
    than a fixture someone has to keep in the repo."""
    channels = CHANNELS[colour_type]
    stride = (width * channels * depth + 7) // 8
    bpp = max(1, (channels * depth) // 8)
    raw = bytearray()
    prev = bytearray(stride)
    for row in rows:
        line = bytearray(row)
        if filter_type == 0:
            encoded = line
        elif filter_type == 1:
            encoded = bytearray(line)
            for i in range(stride - 1, bpp - 1, -1):
                encoded[i] = (line[i] - line[i - bpp]) & 0xFF
        elif filter_type == 2:
            encoded = bytearray([(x - y) & 0xFF for x, y in zip(line, prev)])
        elif filter_type == 3:
            encoded = bytearray(stride)
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                encoded[i] = (line[i] - ((left + prev[i]) >> 1)) & 0xFF
        elif filter_type == 4:
            encoded = bytearray(stride)
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                c = prev[i - bpp] if i >= bpp else 0
                b = prev[i]
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                encoded[i] = (line[i] - pr) & 0xFF
        else:
            raise ValueError(filter_type)
        raw += bytes([filter_type]) + encoded
        prev = line

    def chunk(kind, body):
        return (
            struct.pack(">I", len(body))
            + kind
            + body
            + struct.pack(">I", zlib.crc32(kind + body))
        )

    out = PNG_SIGNATURE
    out += chunk(
        b"IHDR", struct.pack(">IIBBBBB", width, height, depth, colour_type, 0, 0, 0)
    )
    if palette:
        out += chunk(b"PLTE", palette)
    out += chunk(b"IDAT", zlib.compress(bytes(raw)))
    out += chunk(b"IEND", b"")
    return out


def _flat_rgb(width, height, colour):
    return [bytes(colour) * width for _ in range(height)]


def _content_colour(n):
    """The n'th of a run of distinct colours. Injective while n fits two bytes —
    they ARE two of the channels — so a fixture's colour count is a number the
    case states, not a side effect of arithmetic that happens to collide. Every
    colour it returns is far darker in red than any background here, so content
    can never merge into the fill it is drawn on."""
    return bytes((n // 256, n % 256, (n * 7) % 256))


# What the real captures contain, so the fixtures are calibrated the same way the
# bars are: half the frame is content, over about two thousand colours (run
# 31862262726 measured 50.00-53.90% dominant over 1847-2360 distinct).
CONTENT_COLOURS = 2000


def _drawn_on(size, background, content_rows, content_colours, top=0):
    """A boot background with `content_rows` rows of exactly `content_colours`
    distinct colours drawn across it. ONE BUILDER FOR EVERY CASE, because the two
    bars look at exactly two things — how much of the frame is not its background,
    and how many colours are on it — so the modal, a menu bar over a blank
    window, and any margin between them differ only in these numbers."""
    rows = _flat_rgb(size, size, background)
    for y in range(top, top + content_rows):
        row = bytearray(rows[y])
        for x in range(size):
            row[x * 3 : x * 3 + 3] = _content_colour((x + y * size) % content_colours)
        rows[y] = bytes(row)
    return rows


def _with_modal(size, background):
    """The keystore modal over the boot background, at the proportions the real
    captures have: half the frame, over two thousand colours."""
    return _drawn_on(size, background, size // 2, CONTENT_COLOURS, top=size // 4)


def _wallpaper(size):
    """What a macOS desktop looks like when a capture without the Screen
    Recording grant hands back the desktop instead of the window: a wide, rich
    gradient with no flat majority anywhere near the app's palette."""
    return [
        bytes(
            b"".join(
                bytes(
                    (
                        40 + (x * 180) // size,
                        90 + (y * 120) // size,
                        200 - (x * 90) // size,
                    )
                )
                for x in range(size)
            )
        )
        for y in range(size)
    ]


def _self_test():
    import tempfile

    passed = failed = 0

    def run(png, fn):
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as fh:
            fh.write(png)
            path = fh.name
        try:
            return fn(path)
        finally:
            os.unlink(path)

    def case(name, png, want):
        nonlocal passed, failed
        got, detail = run(png, assess)
        if got == want:
            passed += 1
            print("pass  %-56s %s" % (name, got))
        else:
            failed += 1
            print(
                "FAIL  %-56s wanted %s, got %s (%s)" % (name, want, got, detail),
                file=sys.stderr,
            )

    def control_case(name, png, want):
        nonlocal passed, failed
        got = run(png, control)
        if got == want:
            passed += 1
            print("pass  %-56s control exit %d" % (name, got))
        else:
            failed += 1
            print(
                "FAIL  %-56s wanted control exit %d, got %d" % (name, want, got),
                file=sys.stderr,
            )

    def dominant_case(name, png, want):
        """The decoded colour itself, where the verdict would not notice a wrong
        one — a decoder that got the scaling wrong still reports a flat frame."""
        nonlocal passed, failed
        _, _, counts = run(png, count_colours)
        got = tuple(counts.most_common(1)[0][0])
        if got == want:
            passed += 1
            print("pass  %-56s #%02x%02x%02x" % (name, got[0], got[1], got[2]))
        else:
            failed += 1
            print("FAIL  %-56s wanted %s, got %s" % (name, want, got), file=sys.stderr)

    def calibration_case(name, png, want):
        """(distinct, dominant share) of a fixture, asserted directly. The bars
        are set from measurements of real frames, so a fixture that drifted off
        those numbers would still pass every verdict above while quietly
        testing them at a distance the real captures never sit at."""
        nonlocal passed, failed
        _, _, counts = run(png, count_colours)
        got = (
            len(counts),
            round(counts.most_common(1)[0][1] / sum(counts.values()), 5),
        )
        if got == want:
            passed += 1
            print(
                "pass  %-56s %d colours, %.2f%% dominant" % (name, got[0], 100 * got[1])
            )
        else:
            failed += 1
            print("FAIL  %-56s wanted %s, got %s" % (name, want, got), file=sys.stderr)

    size = 400
    prompt_background = _boot_backgrounds()[0]

    # The two things a broken run actually produces.
    case(
        "an unpainted white window",
        _encode(size, size, _flat_rgb(size, size, (255, 255, 255))),
        FLAT,
    )
    case(
        "a capture with no desktop session (all black)",
        _encode(size, size, _flat_rgb(size, size, (0, 0, 0))),
        FLAT,
    )
    # The background alone is NOT a screen: the HTML painted, the app did not.
    case(
        "the boot background with nothing drawn on it",
        _encode(size, size, _flat_rgb(size, size, prompt_background)),
        FLAT,
    )

    # A flat frame with a cursor on it: the case the distinct-colour count alone
    # would let through once the cursor is antialiased.
    cursor = _flat_rgb(size, size, prompt_background)
    for y in range(12):
        row = bytearray(cursor[y])
        for x in range(12):
            row[x * 3 : x * 3 + 3] = bytes((x * 20 % 256, y * 20 % 256, 128))
        cursor[y] = bytes(row)
    case("a flat frame with only a cursor on it", _encode(size, size, cursor), FLAT)

    # Two flat blocks: a third of the frame differs from the dominant colour, so
    # the SHARE bar is satisfied and only the distinct-colour count says this is
    # not a render. The boot screen has a conic-gradient logo ring and
    # antialiased text on it; nothing it draws is two solid rectangles. This is
    # the one case the colour bar has to catch alone — remove that bar and this
    # frame passes for the app.
    two_tone = _flat_rgb(size, size, prompt_background)
    for y in range(size * 2 // 3, size):
        two_tone[y] = bytes((90, 90, 90)) * size
    case("a window split into two flat blocks", _encode(size, size, two_tone), FLAT)

    # THE ADVERSARIAL PAIR, at the real captures' 800x800: the first reproduces
    # the frame that walked through the old bars exactly — 96.88% dominant over
    # 203 distinct. The second carries a strip rich enough to clear the colour
    # bar on its own, so the SHARE bar is the only thing rejecting it; remove
    # that bar and a menu bar over a blank window passes for the app.
    shot = 800
    menu_bar = _encode(shot, shot, _drawn_on(shot, prompt_background, 25, 202))
    case("the app's background with only a menu bar drawn on it", menu_bar, FLAT)
    # The real frame's own numbers, to the hundredth: this fixture is only worth
    # anything while it still IS the frame that walked through the old bars.
    calibration_case(
        "and it is the frame that was measured at 96.88%", menu_bar, (203, 0.96875)
    )
    calibration_case(
        "a real first screen sits where the captures did",
        _encode(size, size, _with_modal(size, prompt_background)),
        (2001, 0.5),
    )
    case(
        "the same frame with chrome rich enough to clear the colour bar",
        _encode(shot, shot, _drawn_on(shot, prompt_background, 25, 1200)),
        FLAT,
    )

    # ── THE MARGINS, which is where a bar is really pinned ────────────────────
    # A case at the middle of the gap only proves the bar is somewhere in it: at
    # 2001 colours and 50% dominant, MIN_DISTINCT_COLOURS could be 1900 and
    # MAX_DOMINANT_SHARE 0.52 with every case still green — while both reject
    # frames the table above records as REAL SCREENS. So one case sits on the
    # worst real capture (windows-2022's 1847 colours, linux-appimage's 53.90%
    # dominant, together), and one sits a single step the wrong side of each bar.
    # Between them the two constants can only move inside the measured gap.
    case(
        "the worst real capture is still the app's own screen",
        _encode(1000, 1000, _drawn_on(1000, prompt_background, 461, 1846)),
        PAINTED,
    )
    case(
        "one colour short of the bar, with room to spare on the other",
        _encode(size, size, _drawn_on(size, prompt_background, size // 3, 998)),
        FLAT,
    )
    case(
        "one step over the dominant bar, with colours to spare",
        _encode(size, size, _drawn_on(size, prompt_background, 99, 1200)),
        FLAT,
    )

    # BOTH SIDES OF THE COLOUR SLACK, for the same reason: every other case uses
    # a declared colour exactly, so nothing would notice a tolerance of zero —
    # and the constant exists precisely because a real capture differs by a unit.
    # #4f4f5e is the outlying background, so its neighbours cannot answer for it.
    # The offsets are LITERAL, not BACKGROUND_TOLERANCE ± 1: written in terms of
    # the constant they would move with it, and an assertion that follows the
    # thing it asserts cannot fail.
    for offset, verdict in ((3, PAINTED), (4, FOREIGN)):
        drifted = tuple(c + offset for c in (0x4F, 0x4F, 0x5E))
        case(
            "a capture %d off the app's #4f4f5e in every channel" % offset,
            _encode(size, size, _with_modal(size, drifted)),
            verdict,
        )

    # The slack around the app's palette has to stay narrow enough to exclude
    # ordinary dark-theme chrome — at a per-channel 16 both of these matched, and
    # every dark GTK dialog and Chromium error page with them.
    for grey in ((0x2C, 0x2C, 0x2C), (0x33, 0x33, 0x33), (0x44, 0x44, 0x44)):
        case(
            "a dark-grey window that is not the app's #%02x%02x%02x" % grey,
            _encode(size, size, _with_modal(size, grey)),
            FOREIGN,
        )

    # A capture tool that wrote a frame with no pixels in it: readable as a PNG,
    # and an answer about the RUNNER rather than a crash blamed on the analyser.
    case(
        "a frame with no pixels at all",
        _encode(0, 0, [], colour_type=2),
        UNREADABLE,
    )
    case(
        "a frame with width but no rows",
        _encode(400, 0, [], colour_type=2),
        UNREADABLE,
    )

    # THE ONE THIS FILE EXISTS FOR. A desktop wallpaper is not blank by any
    # measure of variance, and must still not pass for the app's window.
    wallpaper = _wallpaper(size)
    case(
        "a macOS wallpaper handed back instead of the window",
        _encode(size, size, wallpaper),
        FOREIGN,
    )
    control_case(
        "a wallpaper as the pre-launch control", _encode(size, size, wallpaper), 0
    )
    control_case(
        "a control frame that already looks like the app",
        _encode(size, size, _with_modal(size, prompt_background)),
        5,
    )
    control_case(
        "a control frame on a blank desktop",
        _encode(size, size, _flat_rgb(size, size, (0, 0, 0))),
        0,
    )
    control_case(
        "a control frame nothing could read", b"not a png at all" + b"\x00" * 400, 4
    )

    # Every composited background the boot screens can show, each with content on
    # it. A layer added to the CSS without being added above lands here.
    for background in _boot_backgrounds():
        case(
            "the boot screen on #%02x%02x%02x" % background,
            _encode(size, size, _with_modal(size, background)),
            PAINTED,
        )
    # And the animation's in-between frames, which are in no list.
    case(
        "a window-glow frame between the two keyframes",
        _encode(size, size, _with_modal(size, (35, 35, 44))),
        PAINTED,
    )

    # The same image through every scanline filter: the decoder is the assertion
    # here, and a filter it gets wrong would show up as a different verdict.
    painted = _with_modal(size, prompt_background)
    for ft in (1, 2, 3, 4):
        case(
            "filter %d decodes to the same screen" % ft,
            _encode(size, size, painted, filter_type=ft),
            PAINTED,
        )

    # Formats a capture tool may hand us. RGBA is what screencapture writes.
    rgba = [
        b"".join(bytes(prompt_background) + b"\xff" for _ in range(size))
        for _ in range(size)
    ]
    case("an RGBA capture, flat", _encode(size, size, rgba, colour_type=6), FLAT)
    # The same screen with an alpha channel on it, built from the same rows so
    # the two cases cannot drift into testing different frames.
    rgba_painted = [
        b"".join(bytes(row[i : i + 3]) + b"\xff" for i in range(0, size * 3, 3))
        for row in painted
    ]
    case(
        "an RGBA capture, painted",
        _encode(size, size, rgba_painted, colour_type=6),
        PAINTED,
    )
    case(
        "a 16-bit capture, flat",
        _encode(
            size,
            size,
            [
                b"".join(bytes((c, 0)) for c in prompt_background) * size
                for _ in range(size)
            ],
            colour_type=2,
            depth=16,
        ),
        FLAT,
    )
    # FLAT, not FOREIGN, and the format is the whole reason: eight bits per pixel
    # of grey is 256 colours at the very most, so no greyscale capture can clear
    # the colour bar however varied it looks. A tool that handed us one did not
    # hand us a rendered screen.
    grey = [bytes([(x + y) % 256 for x in range(size)]) for y in range(size)]
    case(
        "a greyscale capture, which cannot hold a rendered screen",
        _encode(size, size, grey, colour_type=0),
        FLAT,
    )
    # WHAT THE LINUX CONTROL FRAME ACTUALLY IS: ImageMagick writes a two-colour
    # capture as 1-bit grey, so a bare Xvfb root arrives at this decoder packed
    # eight pixels to the byte. Refusing that depth made the control unreadable
    # and the whole lane unable to answer.
    case(
        "a 1-bit capture of a bare display",
        _encode(
            size, size, [bytes(size // 8) for _ in range(size)], colour_type=0, depth=1
        ),
        FLAT,
    )
    # A 4-bit frame can hold sixteen colours, so the depth is itself evidence
    # that nothing rendered: it can never clear the distinct-colour bar.
    case(
        "a 4-bit capture, which cannot hold a rendered screen",
        _encode(
            size,
            size,
            [
                bytes(
                    [
                        ((x * 2 + y) % 16) * 16 + ((x * 2 + 1 + y) % 16)
                        for x in range(size // 2)
                    ]
                )
                for y in range(size)
            ],
            colour_type=0,
            depth=4,
        ),
        FLAT,
    )
    # The scaling, asserted directly: a 1-bit sample of 1 is WHITE, and reading it
    # as the byte 1 would make every bare display #010101 — not black, not white,
    # and near enough to nothing that the verdict would still look right.
    dominant_case(
        "1-bit white is white, not the byte 1",
        _encode(
            size,
            size,
            [b"\xff" * (size // 8) for _ in range(size)],
            colour_type=0,
            depth=1,
        ),
        (255, 255, 255),
    )
    dominant_case(
        "a 2-bit mid grey is stretched to full range",
        _encode(
            size,
            size,
            [b"\x55" * (size // 4) for _ in range(size)],
            colour_type=0,
            depth=2,
        ),
        (85, 85, 85),
    )
    # Same reasoning as the greyscale case: a PLTE chunk holds 256 entries, so a
    # palette capture is a quantised frame whatever it depicts.
    pal = bytes(b"".join(bytes((i, 255 - i, (i * 3) % 256)) for i in range(256)))
    palette_rows = [bytes([(x + y) % 256 for x in range(size)]) for y in range(size)]
    case(
        "a palette capture, which cannot hold a rendered screen",
        _encode(size, size, palette_rows, colour_type=3, palette=pal),
        FLAT,
    )
    flat_palette = _encode(
        size, size, [bytes([7] * size) for _ in range(size)], colour_type=3, palette=pal
    )
    case("a palette capture, flat", flat_palette, FLAT)
    # The palette lookup itself, which no verdict above would notice: a decoder
    # that read the index as a grey level, or indexed the wrong entry, still
    # reports a frame with too few colours in it.
    dominant_case(
        "a palette index resolves through the PLTE chunk",
        flat_palette,
        (7, 248, 21),
    )

    # "We could not look" must stay distinct from "there was nothing to see".
    case("a truncated file", _encode(size, size, painted)[:200], UNREADABLE)
    case("a file that is not a PNG at all", b"GIF89a" + b"\x00" * 400, UNREADABLE)
    case(
        "a capture too small to be a window",
        _encode(64, 64, _flat_rgb(64, 64, (1, 2, 3))),
        UNREADABLE,
    )
    case(
        "an interlaced PNG we decline to decode",
        _interlaced(size, painted),
        UNREADABLE,
    )

    print("")
    print("screenshot stats regression: %d passed, %d failed" % (passed, failed))
    # A floor, so deleting cases fails as loudly as breaking one.
    if passed + failed < 76:
        print(
            "::error::only %d cases ran — assertions were deleted" % (passed + failed),
            file=sys.stderr,
        )
        return 1
    return 1 if failed else 0


def _interlaced(size, rows):
    """The same image with the interlace flag set, which the decoder must refuse
    rather than misread."""
    png = bytearray(_encode(size, size, rows))
    # IHDR body starts at 8 (signature) + 8 (length+type); interlace is its 13th byte.
    png[8 + 8 + 12] = 1
    body = bytes(png[8 + 4 : 8 + 8 + 13])
    png[8 + 8 + 13 : 8 + 8 + 17] = struct.pack(">I", zlib.crc32(body))
    return bytes(png)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        sys.exit(_self_test())
    if len(sys.argv) > 1 and sys.argv[1] == "--control":
        if len(sys.argv) != 3:
            print(
                "::error::usage: screenshot-stats.py --control <shot.png>",
                file=sys.stderr,
            )
            sys.exit(2)
        sys.exit(control(sys.argv[2]))
    sys.exit(main(sys.argv[1:]))
