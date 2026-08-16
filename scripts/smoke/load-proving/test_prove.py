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
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

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
        self.stderr = contextlib.redirect_stderr(io.StringIO())
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
            lane.evidence = 'WINDOW 7 0 0 800 800 0 "Unyt Sandbox"'
            return True

        lane.seek_evidence = seek_evidence
        return lane

    def test_a_window_list_is_evidence_the_watch_accepts(self):
        lane = self.lane(AWAITING, True)
        lane.watch()
        self.assertIn("WINDOW 7", lane.evidence)

    def test_no_window_means_the_watch_is_not_satisfied(self):
        lane = self.lane(AWAITING, False)
        lane.watch()
        self.assertIsNone(lane.evidence)

    def test_a_window_with_no_state_is_still_not_enough(self):
        lane = self.lane("", True)
        lane.watch()
        self.assertIsNone(lane.reached)


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
        # Seeded the way macOS arrives here — its watch has already put the
        # window list in evidence — so a loop that stopped setting it would be
        # caught holding a stale answer rather than an empty one.
        lane.evidence = 'WINDOW 7 0 0 800 800 0 "Unyt Sandbox"'
        return lane

    def test_a_window_that_is_the_apps_screen_at_once(self):
        lane = self.lane(1)
        self.assertTrue(lane.seek_paint("pixel", 1))
        # A pass has to NAME THE FRAME: macOS quotes the evidence in its PROVEN
        # line, and the window list left there by the watch is still in it.
        self.assertRegex(lane.evidence, r"^frame \d+-pixel-t\d+s$")

    def test_a_window_that_paints_on_the_third_attempt(self):
        lane = self.lane(3)
        self.assertTrue(lane.seek_paint("pixel", 3))

    def test_a_window_that_never_paints_runs_out_of_budget(self):
        lane = self.lane(99)
        self.assertFalse(lane.seek_paint("pixel", 1))

    def test_a_window_nothing_could_photograph_is_not_a_pass(self):
        lane = self.lane(None)
        self.assertFalse(lane.seek_paint("pixel", 1))

    def test_a_phase_with_no_frames_left_never_calls_the_capture(self):
        # A ceiling of zero means the capture is refused before it is called, so
        # nothing this phase counts on is ever touched. It has to end anyway.
        lane = self.lane(99, ceiling=0)
        self.assertFalse(lane.seek_paint("pixel", 5))
        self.assertEqual([], lane.attempts)

    def test_the_frame_ceiling_ends_it_as_surely_as_the_clock(self):
        # Past the ceiling nothing is captured at all, so a loop that only
        # watched the clock would poll out its remaining seconds taking no
        # frames — and the caller would report those non-attempts as frames that
        # were photographed and found wanting.
        lane = self.lane(99, ceiling=2)
        self.assertFalse(lane.seek_paint("pixel", 600))
        self.assertEqual(2, len(lane.attempts))


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
        path.write_text(printed)
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

    def test_the_summary_carries_the_verdict(self):
        summary = Path(self.dir) / "summary.md"
        os.environ["GITHUB_STEP_SUMMARY"] = str(summary)
        self.addCleanup(os.environ.pop, "GITHUB_STEP_SUMMARY", None)
        path = Path(self.dir) / "verdict.txt"
        path.write_text("VERDICT lane: WINDOW-ONLY — a window, no paint\n")
        with contextlib.redirect_stdout(io.StringIO()):
            publish_verdict.main([str(path), "lane", "0"])
        self.assertIn("NOT PIXEL-VERIFIED", summary.read_text())


class EveryWayOutSaysSomething(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.stderr = contextlib.redirect_stderr(io.StringIO())
        self.stderr.__enter__()
        self.addCleanup(self.stderr.__exit__, None, None, None)

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

    def test_every_word_maps_to_an_exit_code(self):
        self.assertEqual({0, 1, 2, 3}, set(prove.EXIT_CODES.values()))
        self.assertEqual(0, prove.EXIT_CODES["WINDOW-ONLY"])

    def test_a_lane_nobody_named_is_a_usage_error(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(2, prove.main(["solaris", "artifact", self.dir]))


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


if __name__ == "__main__":
    unittest.main()
