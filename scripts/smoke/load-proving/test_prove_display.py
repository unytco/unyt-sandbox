#!/usr/bin/env python3
"""Does the Linux lane photograph the app's own window, on a real display?

  python3 -m unittest discover -s scripts/smoke/load-proving

The rest of the suite scripts the platform away; this is the only thing that
drives the real Xvfb start, the real window search and the real `import`. It
skips where those are absent and FAILS where CI says they should be there —
ci.yaml installs them, and a job that skipped this silently would claim a
capture path it never touched.

The app is stood in for by `display` showing a frame we composed, which is
enough to answer the two questions that matter about the capture path: is it
aimed at the app's window rather than at the screen, and can it still come out
NOT PROVEN when the window is blank."""

import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image

import frames
import prove
import test_frames as build

TOOLS = ("Xvfb", "xdotool", "xwininfo")
WINDOW = 800
AWAITING = "Status update: Starting -> LairAwaitingPassword { is_initial_setup: true }"


def viewer():
    """The stand-in app: something that maps a window with our pixels in it.
    ImageMagick 6 ships `display`; 7 ships it as a subcommand of `magick`."""
    if shutil.which("display"):
        return ["display"]
    if shutil.which("magick"):
        return ["magick", "display"]
    return None


def absent_tools():
    missing = [tool for tool in TOOLS if not shutil.which(tool)]
    if not (shutil.which("import") or shutil.which("magick")):
        missing.append("import")
    if not viewer():
        missing.append("display")
    return missing


class ARealDisplay(unittest.TestCase):
    def setUp(self):
        missing = absent_tools()
        # Loud on the runner that installs them, quiet on the ones that cannot:
        # the macOS and Windows lanes run this same discovery and have no Xvfb,
        # and CI is set on all three.
        if missing and os.environ.get("CI") and sys.platform == "linux":
            self.fail("this runner is missing " + ", ".join(missing))
        if missing:
            self.skipTest("needs " + ", ".join(missing))
        self.dir = tempfile.mkdtemp()
        # Its own sandbox, so a test never clears a real run's data root.
        os.environ["UNYT_PROVE_SANDBOX"] = "/tmp/ut-prove-test"
        self.addCleanup(os.environ.pop, "UNYT_PROVE_SANDBOX", None)
        self.addCleanup(os.environ.pop, "DISPLAY", None)

    def lane_showing(self, pixels, log=AWAITING):
        """A lane whose app is `display` with a frame of our choosing in it."""
        window = Path(self.dir) / "window.png"
        image = Image.new("RGB", (WINDOW, WINDOW))
        image.putdata(pixels)
        image.save(window)
        show = viewer()
        app = Path(self.dir) / "app.sh"
        app.write_text(
            "#!/bin/sh\necho '%s'\nexec %s -immutable %s\n"
            % (log, " ".join(show), window),
            encoding="utf-8",
        )
        app.chmod(0o755)

        class Standin(prove.LinuxLane):
            def install(self):
                self.launch_argv = [str(app)]
                self.proc_name = show[0]

        # The file only has to exist: this stand-in never installs it.
        artifact = Path(self.dir) / "artifact.deb"
        artifact.write_bytes(b"")
        lane = Standin(str(artifact), self.dir)
        lane.poll_seconds = 1
        lane.timeout_seconds = 40
        lane.post_seconds = 6
        self.addCleanup(lane.stop)
        return lane

    def test_a_window_showing_the_apps_own_screen_is_proven(self):
        lane = self.lane_showing(build.with_modal(WINDOW, frames.boot_backgrounds()[0]))
        word, why = lane.run()
        self.assertEqual("PROVEN", word, why)

    def test_and_the_frame_it_judged_is_the_window_not_the_screen(self):
        # The display is 1400x1050 and the window is 800x800. A full-screen grab
        # would be the whole desktop with the app somewhere on it — which is what
        # a variance-only check would happily score as painted.
        lane = self.lane_showing(build.with_modal(WINDOW, frames.boot_backgrounds()[0]))
        lane.run()
        judged = sorted(lane.verdict_dir.glob("*.png"))
        self.assertTrue(judged)
        for frame in judged:
            with Image.open(frame) as shot:
                self.assertLess(
                    shot.size[0], 1400, "%s is the whole screen" % frame.name
                )

    def test_a_blank_window_on_a_real_display_is_not_proven(self):
        # The end-to-end version of the bar: everything real except what the
        # window contains.
        lane = self.lane_showing(build.flat(WINDOW, (255, 255, 255)))
        word, why = lane.run()
        self.assertEqual("NOT PROVEN", word, why)

    def test_the_pre_launch_control_of_a_bare_display_is_usable(self):
        # A bare Xvfb root is what the control photographs, and the lane is only
        # allowed to run because that frame does not pass for the app.
        lane = self.lane_showing(build.flat(WINDOW, (0, 0, 0)))
        lane.prepare()
        lane.preflight()
        lane.check_controls()
        self.assertEqual(["usable"], list(lane.control_status.values()))


if __name__ == "__main__":
    unittest.main()
