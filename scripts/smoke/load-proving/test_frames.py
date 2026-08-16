#!/usr/bin/env python3
"""Can frames.py's verdicts still come out the other way?

A threshold nothing can fail is not a threshold. The numbers in the margin cases
are measurements from run 31862262726, so a bar that moved inside the measured
gap is caught here rather than on a release.
"""

import tempfile
import unittest
from pathlib import Path

from PIL import Image

import frames

SIZE = 400
SHOT = 800
BACKGROUND = frames.boot_backgrounds()[0]
# What the real captures contain: half the frame is content, over about two
# thousand colours.
CONTENT_COLOURS = 2000


def content_colour(n):
    """The n'th of a run of distinct colours, injective while n fits two bytes —
    they ARE two of the channels — so a fixture's colour count is a number the
    case states rather than a collision. Every one is far darker in red than any
    background here, so content can never merge into the fill it is drawn on."""
    return (n // 256, n % 256, (n * 7) % 256)


def flat(size, colour):
    return [colour] * (size * size)


def drawn_on(size, background, content_rows, content_colours, top=0):
    """A boot background with `content_rows` rows of exactly `content_colours`
    distinct colours across it — the two things the bars look at."""
    pixels = flat(size, background)
    for y in range(top, top + content_rows):
        for x in range(size):
            pixels[y * size + x] = content_colour((x + y * size) % content_colours)
    return pixels


def with_modal(size, background):
    """The keystore modal over the boot background, at the proportions the real
    captures have."""
    return drawn_on(size, background, size // 2, CONTENT_COLOURS, top=size // 4)


def wallpaper(size):
    """A wide, rich gradient with no flat majority anywhere near the app's
    palette — what a macOS desktop looks like."""
    return [
        (40 + (x * 180) // size, 90 + (y * 120) // size, 200 - (x * 90) // size)
        for y in range(size)
        for x in range(size)
    ]


def write(directory, name, pixels, size=SIZE, mode="RGB", **save):
    path = Path(directory) / name
    image = Image.new(mode, (size, size))
    image.putdata(pixels)
    image.save(path, **save)
    return str(path)


class Frames(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def assertVerdict(self, want, pixels, size=SIZE, mode="RGB", **save):
        path = write(self.dir, "%d.png" % id(pixels), pixels, size, mode, **save)
        got, detail = frames.assess(path)
        self.assertEqual(want, got, detail)

    def test_unpainted_white_window(self):
        self.assertVerdict(frames.FLAT, flat(SIZE, (255, 255, 255)))

    def test_no_desktop_session_at_all(self):
        self.assertVerdict(frames.FLAT, flat(SIZE, (0, 0, 0)))

    def test_the_boot_background_with_nothing_drawn_on_it(self):
        # The HTML painted; the app did not.
        self.assertVerdict(frames.FLAT, flat(SIZE, BACKGROUND))

    def test_a_flat_frame_with_only_a_cursor_on_it(self):
        # What the distinct-colour count alone would let through once the cursor
        # is antialiased.
        pixels = flat(SIZE, BACKGROUND)
        for y in range(12):
            for x in range(12):
                pixels[y * SIZE + x] = (x * 20 % 256, y * 20 % 256, 128)
        self.assertVerdict(frames.FLAT, pixels)

    def test_a_window_split_into_two_flat_blocks(self):
        # A third of the frame differs from the dominant colour, so the SHARE bar
        # is satisfied and only the colour count says this is not a render.
        pixels = flat(SIZE, BACKGROUND)
        for y in range(SIZE * 2 // 3, SIZE):
            for x in range(SIZE):
                pixels[y * SIZE + x] = (90, 90, 90)
        self.assertVerdict(frames.FLAT, pixels)

    def test_the_background_with_only_a_menu_bar_on_it(self):
        # The frame that walked through the first pair of bars: chrome renders
        # while the webview content is missing.
        self.assertVerdict(frames.FLAT, drawn_on(SHOT, BACKGROUND, 25, 202), SHOT)

    def test_and_that_fixture_is_still_the_frame_that_was_measured(self):
        # Worth nothing unless it still IS the frame measured at 96.88% over 203
        # distinct: a fixture that drifted would keep passing while testing the
        # bars at a distance no real capture sits at.
        path = write(self.dir, "menu.png", drawn_on(SHOT, BACKGROUND, 25, 202), SHOT)
        _, _, counts = frames.count_colours(path)
        self.assertEqual(203, len(counts))
        self.assertAlmostEqual(
            0.96875, counts.most_common(1)[0][1] / sum(counts.values()), 5
        )

    def test_a_real_first_screen_sits_where_the_captures_did(self):
        path = write(self.dir, "real.png", with_modal(SIZE, BACKGROUND))
        _, _, counts = frames.count_colours(path)
        self.assertEqual(2001, len(counts))
        self.assertAlmostEqual(
            0.5, counts.most_common(1)[0][1] / sum(counts.values()), 5
        )

    def test_chrome_rich_enough_to_clear_the_colour_bar(self):
        # Only the SHARE bar rejects this one; remove it and a menu bar over a
        # blank window passes for the app.
        self.assertVerdict(frames.FLAT, drawn_on(SHOT, BACKGROUND, 25, 1200), SHOT)

    def test_the_worst_real_capture_is_still_the_apps_own_screen(self):
        # windows-2022's 1847 colours and linux-appimage's 53.90% dominant, in
        # one frame: both bars sit below the worst thing a real screen did.
        self.assertVerdict(frames.PAINTED, drawn_on(1000, BACKGROUND, 461, 1846), 1000)

    def test_one_colour_short_of_the_bar(self):
        self.assertVerdict(frames.FLAT, drawn_on(SIZE, BACKGROUND, SIZE // 3, 998))

    def test_one_step_over_the_dominant_bar(self):
        self.assertVerdict(frames.FLAT, drawn_on(SIZE, BACKGROUND, 99, 1200))

    def test_a_capture_three_off_the_declared_colour_is_still_the_app(self):
        # Literal offsets, not BACKGROUND_TOLERANCE ± 1: an assertion written in
        # terms of the constant it asserts moves with it and cannot fail.
        # #4f4f5e is the outlying background, so its neighbours cannot answer for it.
        self.assertVerdict(frames.PAINTED, with_modal(SIZE, (0x52, 0x52, 0x61)))

    def test_and_four_off_is_not(self):
        self.assertVerdict(frames.FOREIGN, with_modal(SIZE, (0x53, 0x53, 0x62)))

    def test_ordinary_dark_theme_chrome_is_not_the_app(self):
        # At a per-channel 16 all three of these matched, and every dark GTK
        # dialog and Chromium error page with them.
        for grey in ((0x2C, 0x2C, 0x2C), (0x33, 0x33, 0x33), (0x44, 0x44, 0x44)):
            with self.subTest(grey=grey):
                self.assertVerdict(frames.FOREIGN, with_modal(SIZE, grey))

    def test_every_composited_boot_background_is_the_app(self):
        # A layer added to the CSS without being added to frames.py lands here.
        for background in frames.boot_backgrounds():
            with self.subTest(background=background):
                self.assertVerdict(frames.PAINTED, with_modal(SIZE, background))

    def test_a_window_glow_frame_between_the_two_keyframes(self):
        self.assertVerdict(frames.PAINTED, with_modal(SIZE, (35, 35, 44)))

    def test_a_wallpaper_handed_back_instead_of_the_window(self):
        # Not blank by any measure of variance, and still not the app. This is
        # the case the whole file exists for.
        self.assertVerdict(frames.FOREIGN, wallpaper(SIZE))

    def test_an_rgba_capture_flat(self):
        self.assertVerdict(
            frames.FLAT, [BACKGROUND + (255,)] * (SIZE * SIZE), mode="RGBA"
        )

    def test_an_rgba_capture_painted(self):
        # screencapture writes RGBA; the alpha must not split one visible colour
        # into several.
        pixels = [colour + (255,) for colour in with_modal(SIZE, BACKGROUND)]
        self.assertVerdict(frames.PAINTED, pixels, mode="RGBA")

    def test_a_greyscale_capture_cannot_hold_a_rendered_screen(self):
        self.assertVerdict(
            frames.FLAT,
            [(x + y) % 256 for y in range(SIZE) for x in range(SIZE)],
            mode="L",
        )

    def test_a_one_bit_capture_of_a_bare_display(self):
        # ImageMagick writes a two-colour capture as 1-bit grey, which is what a
        # bare Xvfb root is.
        self.assertVerdict(frames.FLAT, [0] * (SIZE * SIZE), mode="1")

    def test_a_palette_capture_cannot_hold_a_rendered_screen(self):
        path = Path(self.dir) / "palette.png"
        image = Image.new("P", (SIZE, SIZE))
        image.putpalette(
            bytes(b"".join(bytes((i, 255 - i, (i * 3) % 256)) for i in range(256)))
        )
        image.putdata([(x + y) % 256 for y in range(SIZE) for x in range(SIZE)])
        image.save(path)
        self.assertEqual(frames.FLAT, frames.assess(str(path))[0])

    def test_a_jpeg_is_not_a_frame_this_judges(self):
        path = write(self.dir, "shot.jpg", with_modal(SIZE, BACKGROUND))
        self.assertEqual(frames.UNREADABLE, frames.assess(path)[0])

    def test_a_truncated_file(self):
        path = Path(self.dir) / "cut.png"
        whole = write(self.dir, "whole.png", with_modal(SIZE, BACKGROUND))
        path.write_bytes(Path(whole).read_bytes()[:200])
        self.assertEqual(frames.UNREADABLE, frames.assess(str(path))[0])

    def test_a_file_that_is_not_an_image_at_all(self):
        path = Path(self.dir) / "not.png"
        path.write_bytes(b"GIF89a" + b"\x00" * 400)
        self.assertEqual(frames.UNREADABLE, frames.assess(str(path))[0])

    def test_a_capture_too_small_to_be_a_window(self):
        self.assertVerdict(frames.UNREADABLE, flat(64, (1, 2, 3)), 64)

    def test_a_file_that_is_not_there(self):
        self.assertEqual(frames.UNREADABLE, frames.assess(self.dir + "/nothing.png")[0])

    def test_one_painted_frame_is_enough(self):
        results = [("a", frames.FLAT, ""), ("b", frames.PAINTED, "")]
        self.assertEqual(0, frames.exit_code(results))

    def test_readable_but_never_the_app(self):
        self.assertEqual(3, frames.exit_code([("a", frames.FOREIGN, "")]))

    def test_nothing_readable_at_all(self):
        self.assertEqual(4, frames.exit_code([("a", frames.UNREADABLE, "")]))

    def test_one_unreadable_among_readable_frames_is_not_a_blind_run(self):
        results = [("a", frames.UNREADABLE, ""), ("b", frames.FLAT, "")]
        self.assertEqual(3, frames.exit_code(results))


if __name__ == "__main__":
    unittest.main()
