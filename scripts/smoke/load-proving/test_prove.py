#!/usr/bin/env python3
"""Can the lane verdicts still fail?

  python3 -m unittest discover -s scripts/smoke/load-proving

Drives the REAL watch, verdict, control and publish against a scripted platform:
what the log says, whether the process is alive, and what each capture writes.
The frames come from test_frames.py's builders, so nothing here is a second
implementation of anything frames.py asserts.

The platform capture paths (Xvfb + import, screencapture, PrintWindow) are not
driven from here — test_prove_display.py drives the Linux one against a real X
display, and the release run is what exercises the other two. What IS driven
here is every decision made about what they hand back.
"""

import contextlib
import io
import re
import os
import shutil
import subprocess
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path
from unittest import mock

import frames
import prove
import publish_verdict
import test_frames as build

AWAITING = "2026-08-14T10:00:00Z  INFO unyt::runtime: Status update: Starting -> LairAwaitingPassword { is_initial_setup: true }"
HEALTHY = '2026-08-14T10:00:00Z  INFO unyt::runtime: Status update: LairReady -> HcAuthRequired { agent_key: "uhCAkAAAA", joining_service_url: "https://x" }'
FAILED = '2026-08-14T10:00:00Z  INFO unyt::runtime: Status update: ConductorStarting -> ConductorError("boom")'

FIXTURES = {}


def setUpModule():
    directory = tempfile.mkdtemp()
    background = frames.boot_backgrounds()[0]
    FIXTURES["app"] = build.write(
        directory, "app.png", build.with_modal(400, background)
    )
    FIXTURES["flat"] = build.write(directory, "flat.png", build.flat(400, (0, 0, 0)))
    FIXTURES["wallpaper"] = build.write(
        directory, "wallpaper.png", build.wallpaper(400)
    )
    FIXTURES["tiny"] = build.write(directory, "tiny.png", build.flat(32, (0, 0, 0)), 32)


class FakeLane(prove.Lane):
    """A lane whose platform half is a script: `frame` is the fixture each
    capture writes, None for an app that owns no window and "blind" for one with
    a window it cannot photograph. Takes (artifact, shots) like a real lane, so
    prove.main can build one."""

    script = {"log": "", "alive": True, "frame": "app", "control": "flat"}

    def __init__(self, artifact, shots):
        super().__init__("fake", artifact, shots)
        self.poll_seconds = 0
        self.timeout_seconds = 0
        self.post_seconds = 0
        self.max_shots = 2
        self.script = dict(self.script)
        self.captures = 0
        self.prepare()

    def logs(self):
        log = self.script["log"]
        return log() if callable(log) else log

    def alive(self):
        return self.script["alive"]

    def capture(self, slug):
        self.captures += 1
        if self.script["frame"] is None:
            return False
        self.saw_window = True
        if self.script["frame"] == "blind":
            return False
        shutil.copy(FIXTURES[self.script["frame"]], self.verdict_dir / (slug + ".png"))
        return True

    def control_capture(self, slug, path):
        if self.script["control"] is None:
            return False
        shutil.copy(FIXTURES[self.script["control"]], path)
        return True


class Quiet(unittest.TestCase):
    """Every case drives code that narrates to stderr; only the answers matter."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.noise = io.StringIO()
        self.stderr = contextlib.redirect_stderr(self.noise)
        self.stderr.__enter__()
        self.addCleanup(self.stderr.__exit__, None, None, None)

    def fake(self, **script):
        lane = FakeLane(str(Path(self.dir) / "artifact.deb"), self.dir)
        lane.script.update(script)
        return lane

    def conclude(self, **script):
        lane = self.fake(**script)
        lane.watch()
        return lane.verdict()


class Verdicts(Quiet):
    def test_the_prompt_is_up_and_its_window_is_the_app(self):
        self.assertEqual("PROVEN", self.conclude(log=AWAITING)[0])

    def test_a_healthy_backend_behind_the_apps_own_screen(self):
        self.assertEqual("PROVEN", self.conclude(log=HEALTHY)[0])

    def test_the_prompt_is_up_behind_a_blank_window(self):
        word, why = self.conclude(log=AWAITING, frame="flat")
        self.assertEqual("NOT PROVEN", word)
        self.assertIn("carries enough to be a screen", why)

    def test_the_frame_is_somebody_elses_desktop(self):
        word, why = self.conclude(log=AWAITING, frame="wallpaper")
        self.assertEqual("NOT PROVEN", word)
        self.assertIn("is not the app", why)

    def test_a_painted_screen_the_backend_then_failed_behind(self):
        word, why = self.conclude(log=FAILED)
        self.assertEqual("NOT PROVEN", word)
        self.assertIn("failure state", why)

    def test_the_app_exited_before_showing_anything(self):
        self.assertEqual("NOT PROVEN", self.conclude(alive=False)[0])

    def test_no_state_at_all_within_the_timeout(self):
        # A painted frame with no state reached is HALF the answer, and half is
        # not a pass.
        word, why = self.conclude()
        self.assertEqual("NOT PROVEN", word)
        self.assertIn("never reached", why)

    def test_a_window_that_could_never_be_photographed(self):
        word, why = self.conclude(log=AWAITING, frame="blind")
        self.assertEqual("CANNOT PROVE", word)
        self.assertIn("attempt(s) failed", why)

    def test_an_app_that_owns_no_window_at_all(self):
        # A different finding from the one above, and about the artifact rather
        # than the runner.
        word, why = self.conclude(log=AWAITING, frame=None)
        self.assertEqual("NOT PROVEN", word)
        self.assertIn("never owned a visible window", why)

    def test_frames_that_are_not_images(self):
        self.assertEqual("CANNOT PROVE", self.conclude(log=AWAITING, frame="tiny")[0])

    def test_a_frame_from_an_earlier_run_cannot_prove_this_one(self):
        stale = Path(self.dir) / "verdict"
        stale.mkdir(parents=True, exist_ok=True)
        shutil.copy(FIXTURES["app"], stale / "99-stale.png")
        # The constructor prepares the directories, which is what clears it.
        word, _ = self.conclude(log=AWAITING, frame="blind")
        self.assertEqual("CANNOT PROVE", word)

    def test_a_backend_that_failed_after_reaching_its_state(self):
        # A conductor that crashed BEHIND the prompt: the state was reached, the
        # window painted, and the run is still not a pass. Both halves have to
        # be true at once for this to be the case it names, so the failure
        # arrives on a later poll than the state does.
        polls = []

        def log():
            polls.append(1)
            return AWAITING if len(polls) < 3 else AWAITING + "\n" + FAILED

        lane = self.fake(log=log, frame="flat")
        lane.timeout_seconds = 30
        lane.post_seconds = 30
        lane.max_shots = 99
        lane.watch()
        self.assertTrue(lane.reached and lane.failed_state)
        word, why = lane.verdict()
        self.assertEqual("NOT PROVEN", word)
        self.assertIn("failure state", why)

    def test_and_a_painted_window_does_not_rescue_it(self):
        # EVERY OTHER CONDITION FOR PROVEN IS SATISFIED HERE: the state was
        # reached, and the frame the failure poll takes is the app's own screen.
        # A painted screen with a failed backend behind it is a different bug,
        # not a pass, and this is the only shape that says so.
        polls = []

        def log():
            polls.append(1)
            return AWAITING if len(polls) < 3 else AWAITING + "\n" + FAILED

        lane = self.fake(log=log, frame="flat")
        lane.timeout_seconds = 30
        lane.post_seconds = 30
        lane.max_shots = 99

        def capture(slug):
            lane.saw_window = True
            fixture = "app" if len(polls) >= 3 else "flat"
            shutil.copy(FIXTURES[fixture], lane.verdict_dir / (slug + ".png"))
            return True

        lane.capture = capture
        lane.watch()
        self.assertTrue(lane.reached and lane.failed_state)
        results = frames.report(sorted(lane.verdict_dir.glob("*.png")), io.StringIO())
        self.assertEqual(
            0, frames.exit_code(results), "no frame painted, so this proves nothing"
        )
        self.assertEqual("NOT PROVEN", lane.verdict()[0])

    def test_the_watch_keeps_looking_until_the_state_arrives(self):
        polls = []

        def log():
            polls.append(1)
            return AWAITING if len(polls) > 2 else ""

        lane = self.fake(log=log, frame="app")
        lane.timeout_seconds = 30
        lane.watch()
        self.assertEqual("PROVEN", lane.verdict()[0])
        self.assertGreater(len(polls), 2)


class EvidenceThatIsNotAPhotograph(Quiet):
    """macOS gates on the window list by overriding seek_evidence. The shared
    watch has to honour that — a loop that only ever believed a frame would
    report every macOS run as unproven."""

    def lane(self, log, found):
        lane = self.fake(log=log, frame="blind")

        def seek_evidence(slug, force=False):
            if not found:
                return False
            lane.window_line = 'WINDOW 7 0 0 800 800 0 "Unyt Sandbox"'
            lane.on_screen = True
            return True

        lane.seek_evidence = seek_evidence
        return lane

    def test_a_window_list_is_evidence_the_watch_accepts(self):
        lane = self.lane(AWAITING, True)
        lane.watch()
        self.assertIn("WINDOW 7", lane.window_line)
        self.assertTrue(lane.on_screen)

    def test_no_window_means_the_watch_is_not_satisfied(self):
        lane = self.lane(AWAITING, False)
        lane.watch()
        self.assertFalse(lane.on_screen)

    def test_a_window_with_no_state_is_still_not_enough(self):
        # Both halves or nothing: the window is there and the log never said the
        # app got anywhere, which is half an answer.
        lane = self.lane("", True)
        lane.watch()
        self.assertIsNone(lane.reached)
        self.assertNotIn(lane.verdict()[0], ("PROVEN", "WINDOW-ONLY"))


class SeekPaint(Quiet):
    """The bounded phase macOS runs after its watch: it can only ever upgrade a
    verdict the lane already earned, so a budget that never ran out or a loop
    that stopped at the first frame whatever it held would both turn that
    upgrade into a lie."""

    def lane(self, frames_before_paint, ceiling=8):
        lane = self.fake(frame="flat")
        lane.poll_seconds = 0
        lane.max_shots = lane.hard_max_shots = ceiling
        attempts = []

        def capture(slug):
            attempts.append(slug)
            if frames_before_paint is None:
                return False
            fixture = "app" if len(attempts) >= frames_before_paint else "flat"
            shutil.copy(FIXTURES[fixture], lane.verdict_dir / (slug + ".png"))
            return True

        lane.capture = capture
        lane.attempts = attempts
        # Seeded the way macOS arrives here: its watch has already answered
        # "on screen" off the window list.
        lane.on_screen = True
        return lane

    def test_a_window_that_is_the_apps_screen_at_once(self):
        lane = self.lane(1)
        # A pass has to NAME THE FRAME: macOS cites it in a PROVEN line, and
        # what the watch already answered is a different claim.
        self.assertRegex(lane.seek_paint("pixel", 1) or "", r"^\d+-pixel-t\d+s$")

    def test_a_window_that_paints_on_the_third_attempt(self):
        lane = self.lane(3)
        self.assertTrue(lane.seek_paint("pixel", 3))

    def test_a_window_that_never_paints_runs_out_of_budget(self):
        lane = self.lane(99)
        started = time.monotonic()
        self.assertIsNone(lane.seek_paint("pixel", 1))
        self.assertLess(time.monotonic() - started, 10)

    def test_a_window_nothing_could_photograph_is_not_a_pass(self):
        lane = self.lane(None)
        self.assertIsNone(lane.seek_paint("pixel", 1))

    def test_a_phase_with_no_frames_left_never_calls_the_capture(self):
        # A ceiling of zero means the capture is refused before it is called, so
        # nothing this phase counts on is ever touched. It has to end anyway.
        lane = self.lane(99, ceiling=0)
        self.assertIsNone(lane.seek_paint("pixel", 5))
        self.assertEqual([], lane.attempts)

    def test_the_frame_ceiling_ends_it_as_surely_as_the_clock(self):
        # Past the ceiling nothing is captured at all, so a loop that only
        # watched the clock would poll out its remaining seconds taking no
        # frames — and the caller would report those non-attempts as frames that
        # were photographed and found wanting.
        # HOW LONG IT TOOK IS PART OF THE ASSERTION: the return is the same
        # whichever budget ended the loop, so only the clock tells them apart —
        # and a bound here is what turns a loop that stopped ending into a
        # failing case instead of a suite that hangs.
        lane = self.lane(99, ceiling=2)
        started = time.monotonic()
        self.assertIsNone(lane.seek_paint("pixel", 600))
        self.assertEqual(2, len(lane.attempts))
        self.assertLess(time.monotonic() - started, 30)


class Controls(Quiet):
    def status(self, control):
        lane = self.fake(control=control)
        return lane.one_control("00-control-before-launch", Path(self.dir) / "c.png")

    def test_a_bare_desktop_before_launch_is_a_usable_control(self):
        self.assertEqual(("usable", None, None), self.status("flat"))

    def test_a_wallpaper_before_launch_is_a_usable_control(self):
        self.assertEqual("usable", self.status("wallpaper")[0])

    def test_a_control_frame_that_already_passes_for_the_app(self):
        status, word, why = self.status("app")
        self.assertEqual(("passes-for-app", "UNTRUSTED"), (status, word))
        self.assertIn("before the app was launched", why)

    def test_a_control_frame_nothing_could_capture(self):
        self.assertEqual(("uncapturable", "CANNOT PROVE"), self.status(None)[:2])

    def test_a_control_frame_that_is_not_an_image(self):
        self.assertEqual(("unreadable", "CANNOT PROVE"), self.status("tiny")[:2])

    def test_a_gating_lane_stops_on_a_control_it_cannot_trust(self):
        lane = self.fake(control="app")
        with self.assertRaises(prove.Answer) as raised:
            lane.check_controls()
        self.assertEqual("UNTRUSTED", raised.exception.word)

    def test_an_advisory_lane_records_the_same_finding_and_carries_on(self):
        # macOS: the control cannot red a lane whose verdict never rested on a
        # frame, and the status is what decides whether pixels may decide.
        lane = self.fake(control="app")
        lane.controls = (("00-control-screen", True), ("00-control-window-rect", True))
        lane.check_controls()
        self.assertEqual(
            {
                "00-control-screen": "passes-for-app",
                "00-control-window-rect": "passes-for-app",
            },
            lane.control_status,
        )

    def test_one_control_that_could_not_be_captured_does_not_end_a_gating_lane(self):
        # Two controls answer different questions — the whole desktop, and one
        # window's worth of it — so the one that worked still answers its own.
        lane = self.fake(control="flat")
        lane.controls = (
            ("00-control-desktop", False),
            ("00-control-splash-rect", False),
        )
        capture = lane.control_capture
        lane.control_capture = lambda slug, path: (
            slug.endswith("desktop") and capture(slug, path)
        )
        lane.check_controls()
        self.assertEqual(
            {"00-control-desktop": "usable", "00-control-splash-rect": "uncapturable"},
            lane.control_status,
        )

    def test_but_a_lane_that_could_capture_nothing_at_all_stops(self):
        lane = self.fake(control=None)
        lane.controls = (
            ("00-control-desktop", False),
            ("00-control-splash-rect", False),
        )
        with self.assertRaises(prove.Answer) as raised:
            lane.check_controls()
        self.assertEqual("CANNOT PROVE", raised.exception.word)

    def test_a_lane_that_names_no_slug_writes_the_frame_it_always_did(self):
        lane = self.fake(control="flat")
        lane.check_controls()
        self.assertTrue((lane.context_dir / "00-control-before-launch.png").exists())

    def test_two_controls_leave_two_named_frames(self):
        # A shared filename would leave the second answering for both, with only
        # the sub-rect's finding surviving into the artifact.
        lane = self.fake(control="flat")
        lane.controls = (("00-control-screen", True), ("00-control-window-rect", True))
        lane.check_controls()
        self.assertEqual(
            ["00-control-screen.png", "00-control-window-rect.png"],
            sorted(path.name for path in lane.context_dir.glob("*.png")),
        )


class TheMacLanesPixelPhase(Quiet):
    """The one upgrade in this system: a window-list green becomes a
    photographed green. It may rest on nothing but a frame this lane's own
    analyser called the app's own screen."""

    WINDOW = 'WINDOW 7 0 0 800 800 0 "Unyt Sandbox"'

    def lane(self, frame, grant="granted", control="usable", reached=True, failed=None):
        os.environ["UNYT_PROVE_PIXEL_SECONDS"] = "1"
        self.addCleanup(os.environ.pop, "UNYT_PROVE_PIXEL_SECONDS", None)
        lane = prove.MacosLane(str(Path(self.dir) / "unyt.dmg"), self.dir)
        lane.prepare()
        lane.poll_seconds = 0
        lane.app = types.SimpleNamespace(pid=4242)
        lane.window_info = lambda pid=0: subprocess.CompletedProcess(
            [], 0, stdout="GRANT  screen-recording=%s\n" % grant, stderr=""
        )
        lane.window_line = self.WINDOW
        lane.largest_window = lambda: lane.window_line
        lane.control_status = {slug: control for slug, _ in lane.controls}
        lane.reached = (
            "Status update: Starting -> LairAwaitingPassword {" if reached else None
        )
        lane.failed_state = failed
        lane.captured = []

        def capture_window(slug):
            lane.captured.append(slug)
            if frame is None:
                return False
            shutil.copy(FIXTURES[frame], lane.verdict_dir / (slug + ".png"))
            return True

        lane.capture_window = capture_window
        return lane

    def test_a_frame_that_is_the_apps_screen_is_what_earns_proven(self):
        lane = self.lane("app")
        lane.after_watch()
        word, why = lane.verdict()
        self.assertEqual("PROVEN", word)
        self.assertRegex(lane.painted_frame, r"^frame \d+-pixel-t\d+s$")
        self.assertIn(lane.painted_frame, why)

    def test_a_blank_window_is_window_only_however_many_frames_it_took(self):
        # The bug this split exists to make impossible: the window list already
        # says a window is there, and that must never stand in for a photograph.
        lane = self.lane("flat")
        lane.after_watch()
        word, why = lane.verdict()
        self.assertEqual("WINDOW-ONLY", word)
        self.assertIsNone(lane.painted_frame)
        self.assertIn("none is the app's own screen", why)

    def test_and_a_phase_that_photographed_nothing_is_window_only_too(self):
        lane = self.lane(None)
        lane.after_watch()
        word, why = lane.verdict()
        self.assertEqual("WINDOW-ONLY", word)
        self.assertIn("not one window-scoped capture succeeded", why)

    def test_a_failed_backend_never_spends_the_pixel_budget(self):
        # The state half is a precondition, not something a photograph could
        # rescue — and this is the branch that stops a dead backend going green.
        lane = self.lane("app", failed='ConductorError("boom")')
        lane.after_watch()
        self.assertEqual([], lane.captured)
        word, why = lane.verdict()
        self.assertEqual("NOT PROVEN", word)
        self.assertIn("failure state", why)

    def test_a_runner_without_the_grant_never_photographs_at_all(self):
        lane = self.lane("app", grant="not-granted")
        lane.after_watch()
        self.assertEqual([], lane.captured)
        self.assertEqual("WINDOW-ONLY", lane.verdict()[0])

    def test_nor_does_one_whose_control_frame_cannot_be_trusted(self):
        lane = self.lane("app", control="passes-for-app")
        lane.after_watch()
        self.assertEqual([], lane.captured)
        self.assertEqual("WINDOW-ONLY", lane.verdict()[0])

    def test_an_app_that_never_put_a_window_up_is_not_proven(self):
        lane = self.lane("app")
        lane.window_line = None
        lane.largest_window = lambda: None
        self.assertEqual("NOT PROVEN", lane.verdict()[0])

    def test_a_window_that_never_reached_a_state_is_not_proven(self):
        lane = self.lane("app", reached=False)
        self.assertEqual("NOT PROVEN", lane.verdict()[0])

    def test_a_window_that_is_not_the_splashs_size_says_so(self):
        lane = self.lane("app")
        # A size largest_window() can actually return: the main window replaces
        # the splash mid-run and is a different shape.
        lane.window_line = 'WINDOW 7 0 0 1200 900 0 "Unyt Sandbox"'
        word, why = lane.verdict()
        self.assertEqual("WINDOW-ONLY", word)
        self.assertIn("not the 800x800 the splash declares", why)

    def test_the_window_list_is_read_by_field(self):
        # The largest layer-0 window big enough to be one a user sees, out of a
        # dump that also carries the survey lines and a window too small to be
        # the app's.
        lane = self.lane("app")
        dump = (
            "DUMP   pid=4242 layer=0\n"
            "KEYS   total=3 pid=3 bounds=3 layer=3 name=1\n"
            "GRANT  screen-recording=granted\n"
            'WINDOW 3 0 0 300 200 0 "Unyt Sandbox" \n'
            'WINDOW 9 0 0 640 480 0 "Unyt Sandbox" \n'
            'WINDOW 7 0 0 800 800 0 "Unyt Sandbox" Unyt\n'
        )
        lane.window_info = lambda pid=0: subprocess.CompletedProcess(
            [], 0, stdout=dump, stderr=""
        )
        del lane.largest_window
        self.assertEqual("7", lane.largest_window().split()[1])


class TheWindowsLanesDecisions(Quiet):
    def lane(self):
        lane = prove.WindowsLane(str(Path(self.dir) / "unyt.msi"), self.dir)
        lane.prepare()
        return lane

    def frames_of(self, lane, *pixels):
        for index, colour in enumerate(pixels):
            build.write(lane.verdict_dir, "%02d.png" % index, build.flat(400, colour))
        return frames.report(sorted(lane.verdict_dir.glob("*.png")), io.StringIO())

    def test_every_frame_uniform_black_is_a_desktop_we_were_not_shown(self):
        # Not "the app drew nothing": a window existed, so this is the runner.
        lane = self.lane()
        why = lane.unreadable_screen(self.frames_of(lane, (0, 0, 0), (0, 0, 0)))
        self.assertIn("uniform black", why)

    def test_one_frame_that_is_not_black_is_a_finding_about_the_build(self):
        lane = self.lane()
        self.assertIsNone(
            lane.unreadable_screen(self.frames_of(lane, (0, 0, 0), (9, 9, 9)))
        )

    def test_and_a_painted_frame_is_never_a_runner_failure(self):
        lane = self.lane()
        build.write(lane.verdict_dir, "a.png", build.flat(400, (0, 0, 0)))
        build.write(
            lane.verdict_dir,
            "b.png",
            build.with_modal(400, frames.boot_backgrounds()[0]),
        )
        results = frames.report(sorted(lane.verdict_dir.glob("*.png")), io.StringIO())
        self.assertIsNone(lane.unreadable_screen(results))

    def test_each_control_asks_the_helper_for_its_own_frame(self):
        # The two controls exist because a sub-rect can clear a bar the whole
        # desktop does not; routed by the same argument they would be one frame
        # taken twice.
        lane = self.lane()
        asked = []
        lane.helper = lambda **arguments: asked.append(arguments) or ["WROTE desktop x"]
        for slug, _ in lane.controls:
            path = lane.context_dir / (slug + ".png")
            path.write_bytes(b"")
            lane.control_capture(slug, path)
        self.assertEqual(["DesktopTo"], list(asked[0]))
        self.assertEqual({"RectTo", "RectW", "RectH"}, set(asked[1]))
        self.assertEqual(lane.DECLARED, asked[1]["RectW"])

    def test_the_helper_tokens_this_lane_reads_are_the_ones_it_prints(self):
        # NOTHING ELSE JOINS THEM. Rename one on either side and the lane stops
        # seeing a frame it was handed: a control that silently never wrote, or
        # a CopyFromScreen frame — which CAN be the desktop — promoted to the
        # evidence PrintWindow was supposed to give.
        helper = (prove.HERE / "window-capture.ps1").read_text(encoding="utf-8")
        self.assertEqual(
            {"desktop", "rect", "print", "copy"},
            set(re.findall(r"Report '(\w+)'", helper)),
        )
        for line in ("WROTE $What", '"STATION ', '"WINDOW '):
            with self.subTest(line=line):
                self.assertIn(line, helper)

    def test_and_a_frame_reported_under_any_other_tag_is_not_this_lanes(self):
        lane = self.lane()
        for slug, tag in (
            ("00-control-desktop", "desktop"),
            ("00-control-splash-rect", "rect"),
        ):
            path = lane.context_dir / (slug + ".png")
            path.write_bytes(b"")
            lane.helper = lambda tag=tag, **arguments: ["WROTE %s x" % tag]
            self.assertTrue(lane.control_capture(slug, path), slug)
            lane.helper = lambda **arguments: ["WROTE somethingelse x"]
            self.assertFalse(lane.control_capture(slug, path), slug)

    def test_a_helper_that_named_no_station_is_the_helper_failing(self):
        # Not a station named "": that is the diagnosis this lane would give for
        # a helper that died before it printed anything.
        for lines in ([], ["WROTE desktop x"], ["STATION "]):
            with self.subTest(lines=lines):
                # A lane each: preflight resolves the artifact path as it goes.
                lane = self.lane()
                Path(lane.artifact).write_bytes(b"")
                lane.helper = lambda **arguments: lines
                with self.assertRaises(prove.Answer) as raised:
                    lane.preflight()
                self.assertEqual("CANNOT PROVE", raised.exception.word)
                self.assertIn("no window station", raised.exception.why)

    def test_and_a_station_that_is_not_the_interactive_one_is_the_runner(self):
        lane = self.lane()
        Path(lane.artifact).write_bytes(b"")
        lane.helper = lambda **arguments: ["STATION Service-0x0-3e7$"]
        with self.assertRaises(prove.Answer) as raised:
            lane.preflight()
        self.assertIn("interactive window station", raised.exception.why)

    def test_a_frame_is_the_print_when_there_is_one_and_the_copy_otherwise(self):
        lane = self.lane()
        lane.app = types.SimpleNamespace(pid=7)
        written = []

        def helper(**arguments):
            written.append(arguments)
            Path(arguments["PrintTo"]).write_bytes(b"")
            Path(arguments["CopyTo"]).write_bytes(b"")
            return ["WINDOW 1 0 0 800 800 x", "WROTE print p", "WROTE copy c"]

        lane.helper = helper
        self.assertTrue(lane.capture("01-t0s"))
        self.assertTrue(lane.saw_window)
        # The PrintWindow frame decides; the CopyFromScreen one stays context.
        self.assertEqual(
            ["01-t0s-print.png"], [p.name for p in lane.verdict_dir.glob("*.png")]
        )

        lane.helper = lambda **arguments: (
            Path(arguments["CopyTo"]).write_bytes(b"")
            or ["WINDOW 1 0 0 800 800 x", "WROTE copy c"]
        )
        self.assertTrue(lane.capture("02-t2s"))
        self.assertIn(
            "02-t2s-screen.png", [p.name for p in lane.verdict_dir.glob("*.png")]
        )


class WhatTheMacLaneLeavesBehind(Quiet):
    def lane(self):
        lane = prove.MacosLane(str(Path(self.dir) / "unyt.dmg"), self.dir)
        lane.prepare()
        return lane

    def test_a_copy_that_failed_is_a_runner_fault_not_a_broken_bundle(self):
        # Otherwise it surfaces two checks later as "the bundle has no
        # executable in it", which sends a release investigation at the build.
        lane = self.lane()
        (lane.work / "mnt" / "Unyt.app").mkdir(parents=True)
        mounted = subprocess.CompletedProcess([], 0, "", "")
        failed = subprocess.CompletedProcess([], 1, "", "")
        with (
            mock.patch.object(prove.subprocess, "run", return_value=mounted),
            mock.patch.object(prove, "run_loud", return_value=failed),
            mock.patch.object(prove.shutil, "rmtree") as removed,
        ):
            with self.assertRaises(prove.Answer) as raised:
                lane.install()
        self.assertEqual("CANNOT PROVE", raised.exception.word)
        self.assertIn("ditto", raised.exception.why)
        # And it is /Applications it would have copied into: bundle identity and
        # signature evaluation both depend on the path it runs from.
        self.assertEqual(Path("/Applications/Unyt.app"), removed.call_args[0][0])

    def test_a_detach_that_failed_keeps_the_handle(self):
        # A volume this lane has forgotten is one nothing will unmount again.
        lane = self.lane()
        lane.mount = lane.work / "mnt"
        with mock.patch.object(
            prove, "run", return_value=subprocess.CompletedProcess([], 1, "", "busy")
        ):
            lane.detach()
        self.assertIsNotNone(lane.mount)

    def test_and_one_that_worked_lets_it_go(self):
        lane = self.lane()
        lane.mount = lane.work / "mnt"
        with mock.patch.object(
            prove, "run", return_value=subprocess.CompletedProcess([], 0, "", "")
        ):
            lane.detach()
        self.assertIsNone(lane.mount)


class StoppingTheApp(unittest.TestCase):
    """A lane ends what it started, and there are two implementations of that:
    end_process everywhere, and the process group on POSIX. Each is driven
    against a real process on the platform that uses it — the Windows lanes have
    only the first, and nothing else here exercises a syscall."""

    def sleeper(self, seconds=300):
        proc = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(%d)" % seconds]
        )
        self.addCleanup(self.reap, proc)
        return proc

    @staticmethod
    def reap(proc):
        if proc.poll() is None:
            proc.kill()
            proc.wait(30)

    def test_a_running_process_is_ended(self):
        proc = self.sleeper()
        prove.end_process(proc)
        self.assertIsNotNone(proc.poll())

    def test_one_that_already_exited_is_not_an_error(self):
        # stop() runs in a finally, on every path out of a lane, including the
        # ones where the app died by itself.
        proc = self.sleeper(0)
        proc.wait(30)
        prove.end_process(proc)
        self.assertIsNotNone(proc.poll())

    def test_and_a_lane_that_launched_nothing_stops_cleanly(self):
        prove.end_process(None)


@unittest.skipUnless(
    hasattr(os, "killpg"),
    "process groups are POSIX; the Windows lane ends the app with end_process",
)
class EndingTheWholeTreeOnPosix(unittest.TestCase):
    """The Linux lane launches into a session of its own so that the app's
    conductor and keystore go with it. An AppImage's launcher exits into its
    inner binary, and every poll of the watch reaps the launcher — so the group
    has to come from whichever pid is still there."""

    def test_a_child_that_outlived_its_launcher_is_still_ended(self):
        launcher = subprocess.Popen(
            [
                "sh",
                "-c",
                "%s -c 'import time; time.sleep(300)' & echo $!" % sys.executable,
            ],
            stdout=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        child = int(launcher.stdout.readline().strip())
        launcher.stdout.close()
        launcher.wait(30)  # reaped, exactly as the watch reaps it
        prove.end_process_group(launcher.pid, child)
        self.assertTrue(self.gone(child), "the app outlived the lane")

    @staticmethod
    def gone(pid):
        """Dead, or a zombie nobody has reaped yet: either way it is not
        running, and whose job it is to reap it is not this code's business."""
        for _ in range(50):
            try:
                os.kill(pid, 0)
            except OSError:
                return True
            if sys.platform == "linux":
                try:
                    with open("/proc/%d/stat" % pid, encoding="utf-8") as stat:
                        if stat.read().rsplit(")", 1)[1].split()[0] == "Z":
                            return True
                except OSError:
                    return True
            time.sleep(0.1)
        return False


class WhichPidTheGroupComesFrom(unittest.TestCase):
    """The choice itself, with the syscalls stubbed, so it is asserted on every
    platform the suite runs on rather than only where killpg exists."""

    def signals_for(self, *pids, alive=()):
        sent = []

        def getpgid(pid):
            if pid not in alive:
                raise ProcessLookupError(pid)
            return 77

        with (
            mock.patch.object(prove.os, "getpgid", getpgid, create=True),
            mock.patch.object(
                prove.os,
                "killpg",
                lambda group, sig: sent.append((group, sig)),
                create=True,
            ),
            mock.patch.object(prove.signal, "SIGKILL", 9, create=True),
            mock.patch.object(prove.time, "sleep", lambda seconds: None),
        ):
            prove.end_process_group(*pids)
        return sent

    def test_the_reaped_launcher_is_skipped_for_the_pid_still_running(self):
        self.assertEqual(2, len(self.signals_for(1, 2, alive=(2,))))
        self.assertEqual(
            [77, 77], [group for group, _ in self.signals_for(1, 2, alive=(2,))]
        )

    def test_the_launcher_answers_when_it_is_the_one_still_there(self):
        self.assertEqual(2, len(self.signals_for(1, 2, alive=(1,))))

    def test_and_nothing_is_signalled_when_nothing_is_left(self):
        self.assertEqual([], self.signals_for(1, 2))

    def test_a_pid_that_was_never_recorded_is_not_a_crash(self):
        self.assertEqual([], self.signals_for(None, None))


class WhenPixelsMayDecide(unittest.TestCase):
    """What a false PROVEN on macOS would have to get past."""

    def test_a_capable_runner_with_clean_controls_may_photograph(self):
        self.assertTrue(prove.pixels_may_decide("granted", ["usable", "usable"]))

    def test_one_control_that_passes_for_the_app_stops_it(self):
        self.assertFalse(
            prove.pixels_may_decide("granted", ["usable", "passes-for-app"])
        )

    def test_and_so_does_one_that_could_not_be_captured(self):
        self.assertFalse(prove.pixels_may_decide("granted", ["uncapturable", "usable"]))

    def test_a_runner_that_cannot_photograph_the_window_never_does(self):
        self.assertFalse(prove.pixels_may_decide("not-granted", ["usable", "usable"]))

    def test_and_neither_does_one_with_no_control_at_all(self):
        self.assertFalse(prove.pixels_may_decide("granted", []))

    def test_only_the_word_the_probe_actually_prints_arms_it(self):
        for word in ("GRANTED", "granted-ish", "", None):
            with self.subTest(word=word):
                self.assertFalse(prove.pixels_may_decide(word, ["usable"]))

    def test_the_grant_is_read_out_of_the_probes_own_output(self):
        dump = 'DUMP   pid=1\nKEYS   total=4\nGRANT  screen-recording=granted\nWINDOW 7 0 0 8 8 0 "x"'
        self.assertEqual("granted", prove.grant_of(dump))

    def test_and_reads_not_granted_as_itself(self):
        self.assertEqual(
            "not-granted", prove.grant_of("GRANT screen-recording=not-granted")
        )

    def test_and_says_nothing_when_the_probe_printed_nothing(self):
        self.assertIsNone(prove.grant_of("KEYS total=0"))

    def test_the_line_the_swift_prints_is_the_line_this_reads(self):
        # NOTHING ELSE JOINS THEM, and a drift is silent in the worst way: the
        # read comes back empty, pixel mode is off for good, and the lane
        # reports WINDOW-ONLY — green, and indistinguishable from a runner that
        # really has no grant.
        swift = (prove.HERE / "mac-window-info.swift").read_text(encoding="utf-8")
        printed = re.search(r'emit\("(GRANT[^\\"]*)', swift)
        self.assertTrue(printed, "mac-window-info.swift prints no GRANT line")
        for word in ("granted", "not-granted"):
            self.assertEqual(word, prove.grant_of(printed.group(1) + word))


class TheLogOracle(unittest.TestCase):
    """The patterns have one home in scripts/smoke/common.sh, and this lane reads
    them from it — a pattern that moves there must break this, not match nothing."""

    def test_every_pattern_the_lane_needs_is_in_common_sh(self):
        for name in (
            "UNYT_RE_BACKEND_READY",
            "UNYT_RE_FAILED",
            "UNYT_RE_AWAITING_PASSWORD",
        ):
            with self.subTest(name=name):
                self.assertTrue(prove.shell_value(name))

    def test_the_bundle_id_comes_from_there_too(self):
        self.assertEqual("co.unyt.unyt.sandbox", prove.shell_value("UNYT_BUNDLE_ID"))

    def test_a_pattern_that_moved_is_fatal_rather_than_silent(self):
        with self.assertRaises(prove.Answer):
            prove.shell_value("UNYT_RE_NO_SUCH_THING")

    def test_a_state_is_reported_with_the_rest_of_its_line(self):
        import re

        matched = prove.first_match(
            re.compile("LairAwaitingPassword"), AWAITING + "\nnext line"
        )
        self.assertTrue(matched.endswith("{ is_initial_setup: true }"))


class TheStepsColour(unittest.TestCase):
    """publish_verdict.py is the only thing that decides whether a job is green,
    so a bug here turns every other assertion into decoration."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.stderr = contextlib.redirect_stderr(io.StringIO())
        self.stderr.__enter__()
        self.addCleanup(self.stderr.__exit__, None, None, None)

    def publish(self, printed, code):
        path = Path(self.dir) / "verdict.txt"
        # UTF-8, as prove.py writes it: the default is the runner's code page,
        # and on Windows that is not the encoding publish_verdict reads.
        path.write_text(printed, encoding="utf-8")
        return publish_verdict.publish(str(path), "lane", code)[1]

    def test_a_proven_lane_is_the_only_green_one(self):
        self.assertEqual(0, self.publish("VERDICT lane: PROVEN — all good\n", "0"))

    def test_not_proven_is_red(self):
        self.assertEqual(
            1, self.publish("VERDICT lane: NOT PROVEN — blank window\n", "1")
        )

    def test_cannot_prove_is_red(self):
        self.assertEqual(
            1, self.publish("VERDICT lane: CANNOT PROVE — no capture\n", "2")
        )

    def test_untrusted_is_red(self):
        self.assertEqual(
            1, self.publish("VERDICT lane: UNTRUSTED — the desktop passes\n", "3")
        )

    def test_a_lane_saying_proven_while_exiting_non_zero_is_red(self):
        self.assertEqual(1, self.publish("VERDICT lane: PROVEN — all good\n", "1"))

    def test_a_lane_exiting_zero_without_saying_proven_is_red(self):
        self.assertEqual(1, self.publish("VERDICT lane: NOT PROVEN — blank\n", "0"))

    def test_a_lane_that_printed_no_verdict_at_all_is_red(self):
        self.assertEqual(1, self.publish("", "0"))

    def test_a_lane_whose_output_is_not_a_verdict_is_red(self):
        self.assertEqual(1, self.publish("some unrelated line\n", "0"))

    def test_a_lane_that_never_wrote_a_file_is_red(self):
        self.assertEqual(
            1, publish_verdict.publish(self.dir + "/nothing", "lane", "0")[1]
        )

    def test_a_lane_that_answered_twice_is_red(self):
        # Reading the first would pick whichever it printed before the one that
        # mattered.
        printed = "VERDICT lane: PROVEN — all good\nVERDICT lane: NOT PROVEN — blank\n"
        self.assertEqual(1, self.publish(printed, "0"))

    def test_the_window_only_verdict_is_green_and_only_with_zero(self):
        self.assertEqual(
            0, self.publish("VERDICT lane: WINDOW-ONLY — a window, no paint\n", "0")
        )

    def test_a_window_only_verdict_that_exited_non_zero_is_red(self):
        self.assertEqual(
            1, self.publish("VERDICT lane: WINDOW-ONLY — a window, no paint\n", "1")
        )

    def test_a_non_numeric_exit_code_cannot_pass_for_zero(self):
        # The Windows lane hands this over $GITHUB_ENV, so one carriage return
        # would do it.
        for code in ("abc", "0x0", " 0", "1 ", ""):
            with self.subTest(code=code):
                self.assertEqual(
                    1, self.publish("VERDICT lane: PROVEN — all good\n", code)
                )

    def test_a_log_line_quoting_the_word_does_not_make_a_red_lane_green(self):
        # The word is read as a field, never matched as text: the why carries app
        # log lines into the tail of the line.
        printed = (
            "VERDICT lane: NOT PROVEN — the log never said: PROVEN was not reached\n"
        )
        self.assertEqual(1, self.publish(printed, "0"))
        self.assertEqual(1, self.publish(printed, "1"))

    def test_and_it_does_not_make_a_green_lane_red_either(self):
        printed = "VERDICT lane: PROVEN — the log said: NOT PROVEN somewhere in it\n"
        self.assertEqual(0, self.publish(printed, "0"))

    def test_a_separator_no_encoding_survived_still_names_the_word(self):
        # A verdict written or read in the wrong code page arrives with the em
        # dash mangled. The WORD is what decides a release, and it is read by
        # name — this must not turn a green lane red or a red one green.
        for dash in ("\u2014", "\u2013", "?", "\ufffd", "â\u20ac\u201d"):
            with self.subTest(dash=dash):
                self.assertEqual(
                    0, self.publish("VERDICT lane: PROVEN %s all good\n" % dash, "0")
                )
                self.assertEqual(
                    1, self.publish("VERDICT lane: NOT PROVEN %s blank\n" % dash, "1")
                )
                self.assertEqual(
                    1,
                    self.publish(
                        "VERDICT lane: CANNOT PROVE %s no capture\n" % dash, "2"
                    ),
                )

    def test_and_a_word_no_lane_answers_with_is_not_guessed_at(self):
        self.assertEqual(1, self.publish("VERDICT lane: NEARLY — close enough\n", "0"))

    def test_the_summary_carries_the_verdict(self):
        summary = Path(self.dir) / "summary.md"
        os.environ["GITHUB_STEP_SUMMARY"] = str(summary)
        self.addCleanup(os.environ.pop, "GITHUB_STEP_SUMMARY", None)
        path = Path(self.dir) / "verdict.txt"
        path.write_text(
            "VERDICT lane: WINDOW-ONLY — a window, no paint\n", encoding="utf-8"
        )
        with contextlib.redirect_stdout(io.StringIO()):
            publish_verdict.main([str(path), "lane", "0"])
        self.assertIn("NOT PIXEL-VERIFIED", summary.read_text(encoding="utf-8"))


class EveryWayOutSaysSomething(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.installed = False
        self.stderr = contextlib.redirect_stderr(io.StringIO())
        self.stderr.__enter__()
        self.addCleanup(self.stderr.__exit__, None, None, None)

    def complete_lane(self, **script):
        """A lane with a platform half that does nothing but succeed, so main()
        runs the whole way through."""
        outer = self

        class Complete(FakeLane):
            def __init__(self, artifact, shots):
                super().__init__(artifact, shots)
                self.script.update(script)

            def install(self):
                outer.installed = True

            def launch(self):
                pass

        return Complete

    def test_a_proven_lane_exits_zero_and_says_so_once(self):
        # The whole way through, and the line it printed is the one the verdict
        # step reads: this is where the two files' `VERDICT …: WORD — why`
        # contract is pinned, em dash and all.
        code, printed = self.drive(self.complete_lane(log=AWAITING))
        self.assertEqual(0, code)
        self.assertEqual(1, len(printed))
        self.assertIn("PROVEN", printed[0])
        verdict = Path(self.dir) / "verdict.txt"
        verdict.write_text(printed[0] + "\n", encoding="utf-8")
        self.assertEqual(0, publish_verdict.publish(str(verdict), "lane", "0")[1])

    def test_a_control_that_passes_for_the_app_stops_before_installing(self):
        code, printed = self.drive(self.complete_lane(log=AWAITING, control="app"))
        self.assertEqual(3, code)
        self.assertIn("UNTRUSTED", printed[0])
        self.assertFalse(self.installed)

    def drive(self, lane_class):
        prove.LANES["under-test"] = lane_class
        self.addCleanup(prove.LANES.pop, "under-test", None)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = prove.main(["under-test", "artifact.deb", self.dir])
        return code, out.getvalue().strip().splitlines()

    def test_a_lane_that_dies_still_prints_a_verdict(self):
        class Dies(FakeLane):
            def install(self):
                raise RuntimeError("dpkg fell over")

        code, printed = self.drive(Dies)
        self.assertEqual(2, code)
        self.assertEqual(1, len(printed))
        self.assertIn("CANNOT PROVE", printed[0])
        self.assertIn("dpkg fell over", printed[0])

    def test_an_answered_lane_does_not_get_a_second_verdict_behind_it(self):
        class Refuses(FakeLane):
            def install(self):
                raise prove.Answer("NOT PROVEN", "the package would not install")

        code, printed = self.drive(Refuses)
        self.assertEqual(1, code)
        self.assertEqual(
            [
                "VERDICT under-test/artifact.deb: NOT PROVEN — the package would not install"
            ],
            printed,
        )

    def test_a_lane_always_stops_what_it_started(self):
        stopped = []

        class Stops(FakeLane):
            def install(self):
                raise prove.Answer("CANNOT PROVE", "nope")

            def stop(self):
                stopped.append(True)

        self.drive(Stops)
        self.assertEqual([True], stopped)

    def test_every_word_maps_to_the_exit_code_publish_verdict_expects(self):
        self.assertEqual(
            {
                "PROVEN": 0,
                "WINDOW-ONLY": 0,
                "NOT PROVEN": 1,
                "CANNOT PROVE": 2,
                "UNTRUSTED": 3,
            },
            prove.EXIT_CODES,
        )
        # The two green words, and only those, are the ones publish_verdict lets
        # through with exit 0.
        green = {word for word, code in prove.EXIT_CODES.items() if code == 0}
        self.assertEqual(set(publish_verdict.GREEN), green)

    def test_a_lane_nobody_named_is_a_usage_error(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(2, prove.main(["solaris", "artifact", self.dir]))


class TheLinuxWindowSearch(Quiet):
    """Which window the Linux lane aims at, out of what the two tools say."""

    def lane(self):
        lane = prove.LinuxLane(str(Path(self.dir) / "unyt.deb"), self.dir)
        lane.app_pid = 4242
        return lane

    def answering(self, replies):
        def fake(argv, **kwargs):
            spelled = " ".join(str(word) for word in argv)
            for fragment, out in replies.items():
                if fragment in spelled:
                    return subprocess.CompletedProcess(argv, 0, stdout=out, stderr="")
            return subprocess.CompletedProcess(argv, 1, stdout="", stderr="")

        return mock.patch.object(prove, "run", fake)

    def test_the_largest_window_the_app_owns_wins(self):
        # A toolkit maps small utility windows next to the real one.
        with self.answering(
            {
                "xdotool search": "111\n222\n",
                "--shell 111": "WINDOW=111\nWIDTH=300\nHEIGHT=200\n",
                "--shell 222": "WINDOW=222\nWIDTH=800\nHEIGHT=800\n",
            }
        ):
            self.assertEqual("222", self.lane().window())

    def test_the_root_children_answer_when_no_client_set_its_pid(self):
        # _NET_WM_PID is the client's to set, and a window placed partly
        # off-screen carries negative offsets a `+`-only match would skip —
        # skipping the app's window reads as "the app showed nothing".
        tree = (
            "xwininfo: Window id: 0x1 (the root window) (has no name)\n"
            "\n  2 children:\n"
            '     0x400001 "Unyt": ("unyt" "Unyt")  800x800-10-20  -10-20\n'
            '     0x400002 "tip": ()  40x20+0+0  +0+0\n'
        )
        with self.answering({"xwininfo": tree}):
            self.assertEqual("0x400001", self.lane().window())

    def test_a_probe_that_could_not_open_the_display_is_said_out_loud(self):
        # xdotool exits 1 for "no window" and for "no display" alike, so the
        # code says nothing and only its stderr tells them apart. Reading the
        # first as the second blames the artifact for our tooling.
        def failing(argv, **kwargs):
            broken = "Error: Can't open display: :99"
            if "xdotool search" in " ".join(str(word) for word in argv):
                return subprocess.CompletedProcess(argv, 1, stdout="", stderr=broken)
            return subprocess.CompletedProcess(argv, 1, stdout="", stderr="")

        with mock.patch.object(prove, "run", failing):
            self.lane().window()
        self.assertIn("Can't open display", self.noise.getvalue())

    def test_and_a_display_with_no_window_on_it_is_not(self):
        with self.answering({"xdotool search": "", "xwininfo": ""}):
            self.lane().window()
        self.assertNotIn("xdotool search:", self.noise.getvalue())

    def test_and_a_display_with_nothing_on_it_is_no_window(self):
        with self.answering(
            {"xwininfo": "xwininfo: Window id: 0x1\n\n  0 children.\n"}
        ):
            self.assertIsNone(self.lane().window())


class TheSandboxPath(unittest.TestCase):
    """lair binds a unix-domain socket under the data root, and unix sockets cap
    the path at ~108 characters."""

    def test_a_short_tmp_path_is_taken_as_given(self):
        os.environ["UNYT_PROVE_SANDBOX"] = "/tmp/ut-prove-test"
        self.addCleanup(os.environ.pop, "UNYT_PROVE_SANDBOX", None)
        self.assertEqual(
            Path("/tmp/ut-prove-test"), prove.short_tmp("UNYT_PROVE_SANDBOX")
        )

    def test_anywhere_else_is_refused_rather_than_used(self):
        for path in (
            "/var/folders/zz/T/some-very-long-temporary-directory",
            "relative",
            "/tmp/a b",
        ):
            with self.subTest(path=path):
                os.environ["UNYT_PROVE_SANDBOX"] = path
                self.addCleanup(os.environ.pop, "UNYT_PROVE_SANDBOX", None)
                with self.assertRaises(prove.Answer):
                    prove.short_tmp("UNYT_PROVE_SANDBOX")


class WhatWindowsIsToldToInstall(unittest.TestCase):
    def test_an_exe_is_the_nsis_installer(self):
        self.assertEqual(
            "nsis", prove.installer_kind(r"C:\a\unyt_1.0.0_x64_windows.exe")
        )

    def test_an_msi_is_the_msi(self):
        self.assertEqual(
            "msi", prove.installer_kind(r"C:\a\unyt_1.0.0_x64_windows.msi")
        )

    def test_the_extension_is_matched_without_case(self):
        self.assertEqual("msi", prove.installer_kind(r"C:\a\UNYT.MSI"))

    def test_anything_else_is_refused_rather_than_guessed(self):
        self.assertEqual("unsupported", prove.installer_kind(r"C:\a\unyt.zip"))

    def test_a_name_with_dots_in_it_is_read_by_its_last_one(self):
        self.assertEqual(
            "nsis", prove.installer_kind(r"C:\a\unyt_0.101.0-dev.0_x64.exe")
        )

    def test_nsis_runs_itself_with_an_uppercase_switch(self):
        # /s runs the installer interactively and hangs the job on a dialog.
        self.assertEqual(
            [r"C:\a\x.exe", "/S"], prove.install_argv(r"C:\a\x.exe", "nsis")
        )

    def test_an_msi_is_installed_silently_and_reboots_nothing(self):
        self.assertEqual(
            ["msiexec.exe", "/i", r"C:\a\x.msi", "/quiet", "/norestart"],
            prove.install_argv(r"C:\a\x.msi", "msi"),
        )

    def test_an_msi_install_logs_what_it_did(self):
        # Without a log, 1619 is all a failed install ever says.
        self.assertEqual(
            [
                "msiexec.exe",
                "/i",
                r"C:\a\x.msi",
                "/quiet",
                "/norestart",
                "/l*v",
                r"C:\shots\m.log",
            ],
            prove.install_argv(r"C:\a\x.msi", "msi", r"C:\shots\m.log"),
        )

    def test_and_nsis_which_has_no_such_switch_is_unchanged_by_one(self):
        self.assertEqual(
            [r"C:\a\x.exe", "/S"],
            prove.install_argv(r"C:\a\x.exe", "nsis", r"C:\m.log"),
        )

    def test_a_bash_path_is_spelled_the_way_msiexec_can_open_it(self):
        self.assertEqual(
            r"D:\a\_temp\unyt.msi", prove.to_windows_path("D:/a/_temp/unyt.msi")
        )

    def test_and_a_path_already_in_that_spelling_is_left_alone(self):
        self.assertEqual(
            r"D:\a\_temp\unyt.msi", prove.to_windows_path(r"D:\a\_temp\unyt.msi")
        )

    def test_a_path_with_a_space_reaches_msiexec_as_one_argument(self):
        # Start-Process joined its arguments with spaces and quoted nothing; an
        # argv list is what stops a runner's temp directory re-splitting one.
        argv = prove.install_argv(r"C:\Program Files\a b.msi", "msi")
        self.assertIn('"C:\\Program Files\\a b.msi"', subprocess.list2cmdline(argv))

    def test_exit_zero_is_the_only_clean_install(self):
        self.assertTrue(prove.install_succeeded(0))

    def test_a_reboot_pending_install_is_not_one_a_user_is_looking_at(self):
        for code in (3010, 1641, 1603):
            with self.subTest(code=code):
                self.assertFalse(prove.install_succeeded(code))

    def test_nsis_quotes_its_install_location(self):
        self.assertEqual(
            r"C:\Program Files\Unyt Sandbox",
            prove.install_location(r'"C:\Program Files\Unyt Sandbox"'),
        )

    def test_the_msi_trails_a_separator_on_the_same_directory(self):
        self.assertEqual(
            r"C:\Program Files\Unyt Sandbox",
            prove.install_location("C:\\Program Files\\Unyt Sandbox\\"),
        )

    def test_an_empty_install_location_is_unknown_not_the_current_directory(self):
        self.assertIsNone(prove.install_location("   "))
        self.assertIsNone(prove.install_location(None))

    def test_the_app_is_picked_out_of_everything_an_install_registered(self):
        entries = [
            prove.Entry("k1", "WebView2 Runtime", r"c:\wv2"),
            prove.Entry("k2", "Unyt Sandbox", r"c:\unyt"),
        ]
        self.assertEqual("k2", prove.select_install_entry(entries).key)

    def test_an_unrecognised_name_is_still_what_just_installed(self):
        entries = [prove.Entry("k1", "WebView2 Runtime", r"c:\wv2")]
        self.assertEqual("k1", prove.select_install_entry(entries).key)

    def test_and_nothing_registered_is_nothing_to_launch(self):
        self.assertIsNone(prove.select_install_entry([]))

    def test_a_hive_key_with_no_display_name_is_not_an_error(self):
        # A real Uninstall hive is full of them, and reading .name off one is
        # how every Windows lane would die instead of answering.
        entries = [
            prove.Entry("k1", None, None),
            prove.Entry("k2", "Unyt Sandbox", "c:\\u"),
        ]
        self.assertEqual("k2", prove.select_install_entry(entries).key)
        self.assertEqual("k1", prove.select_install_entry(entries[:1]).key)


if __name__ == "__main__":
    unittest.main()
