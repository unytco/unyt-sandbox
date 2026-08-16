#!/usr/bin/env python3
"""Does a shipped installer put the app's own first screen on a screen?

The verdict is one `VERDICT <lane>: <WORD> — <why>` line on stdout, and nothing
else is written there.

  PROVEN       the app reached a state a user could see AND a frame of its own
               window is the app's own screen.
  WINDOW-ONLY  macOS only: a real on-screen window at a real size, paint
               unverified. Green, and never the word a photographed lane gets.
  NOT PROVEN   the app ran and one of those two is missing.
  CANNOT PROVE we could not look — no display, no capture, no install.
  UNTRUSTED    we could look, but not at the app.

Nothing here ever skips: a runner that cannot answer says so and goes red.

WHAT THE PRE-LAUNCH CONTROL CANNOT COVER, since a window-scoped capture has no
window to aim at before launch: it photographs the SCREEN, while the verdict
frames photograph the app's WINDOW. It answers "is this runner's screen
mistakable for the app", not "is this window capture aimed properly". Windows
and macOS each narrow the gap with a second control; nothing closes it before
the app exists.
"""

import collections
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback
from pathlib import Path

import frames

HERE = Path(__file__).resolve().parent
SMOKE_COMMON = HERE.parent / "common.sh"

EXIT_CODES = {
    "PROVEN": 0,
    "WINDOW-ONLY": 0,
    "NOT PROVEN": 1,
    "CANNOT PROVE": 2,
    "UNTRUSTED": 3,
}


class Answer(Exception):
    def __init__(self, word, why):
        super().__init__(why)
        self.word = word
        self.why = why


def note(message):
    print(message, file=sys.stderr, flush=True)


def shell_value(name, path=SMOKE_COMMON):
    """Missing is fatal — a lane matching nothing would report every healthy app
    as one that never reached a state."""
    match = re.search(
        r"^%s=(['\"]?)(.*)\1$" % re.escape(name),
        # Our own files are always UTF-8; a Windows runner's locale is not.
        path.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if not match:
        raise Answer("CANNOT PROVE", "%s is not in %s" % (name, path))
    return match.group(2)


def first_match(pattern, text):
    """The match through to the end of its line — that tail is what lets the
    verdict say WHICH state was reached."""
    hit = pattern.search(text)
    if not hit:
        return None
    end = text.find("\n", hit.start())
    return text[hit.start() : None if end < 0 else end].rstrip()


def run(argv, **kwargs):
    # Captured, never inherited: stdout is the verdict channel, and one stray
    # line on it is a lane that answered twice.
    #
    # Decoded in the runner's locale, because a tool writes its own platform's
    # encoding and PowerShell's is the Windows console's. Every token a decision
    # rests on is ASCII, so `errors="replace"` costs nothing and keeps a window
    # title in some other encoding from ending the lane.
    kwargs.setdefault("stdout", subprocess.PIPE)
    kwargs.setdefault("stderr", subprocess.PIPE)
    kwargs.setdefault("text", True)
    kwargs.setdefault("errors", "replace")
    return subprocess.run(argv, check=False, **kwargs)


def run_loud(argv, **kwargs):
    """An installer, whose narration belongs in the log."""
    return subprocess.run(
        argv, check=False, stdout=sys.stderr, stderr=sys.stderr, **kwargs
    )


def need(tool, why):
    if not shutil.which(tool):
        raise Answer("CANNOT PROVE", "%s is not on this runner, so %s" % (tool, why))


def short_tmp(variable, default="/tmp/ut-prove"):
    # lair binds a unix-domain socket under the data root and unix sockets cap
    # the path at ~108 characters, most of which the app needs.
    path = os.environ.get(variable, default)
    if not re.fullmatch(r"/tmp/[A-Za-z0-9._-]+", path):
        raise Answer(
            "CANNOT PROVE",
            "%s must be a short /tmp/<name> path, not '%s'" % (variable, path),
        )
    return Path(path)


def indent(text):
    return "\n".join("  " + line for line in (text or "").rstrip().splitlines())


def tail(path, lines=40):
    try:
        return "\n".join(
            Path(path)
            .read_text(encoding="utf-8", errors="replace")
            .splitlines()[-lines:]
        )
    except OSError as exc:
        return "(nothing readable at %s: %s)" % (path, exc)


def read_all(files, directories, pattern):
    """Both kinds of sink, because the rolling file is durable and the
    redirected streams catch a crash from before the log dir exists. A file that
    will not open is said out loud — that is otherwise why a lane reports "the
    app never reached any state"."""
    paths = [Path(path) for path in files]
    for directory in directories:
        paths += sorted(Path(directory).glob(pattern)) if directory else []
    parts = []
    for path in paths:
        if not path.exists():
            continue
        try:
            parts.append(path.read_text(encoding="utf-8", errors="replace"))
        except OSError as exc:
            note("::warning::could not read %s — %s" % (path, exc))
    return "\n".join(parts)


def end_process(proc):
    """The process this lane started, and only that one. Every platform can do
    this much; the Windows lane has nothing else, because Windows has no process
    group to signal."""
    if proc and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(5)
        except subprocess.TimeoutExpired:
            proc.kill()


def end_process_group(*pids):
    """The whole tree, on POSIX only — os.killpg and SIGKILL do not exist on
    Windows. The launcher is often reaped before this runs, so the group is
    taken from whichever pid still resolves to one."""
    for pid in pids:
        if pid is None:
            continue
        try:
            group = os.getpgid(pid)
        except OSError:
            continue
        try:
            os.killpg(group, signal.SIGTERM)
            time.sleep(2)
            os.killpg(group, signal.SIGKILL)
        except OSError:
            pass
        return


def grant_of(text):
    """Whether this process may read screen pixels, as mac-window-info.swift
    reports it."""
    hit = re.search(r"^GRANT\s+screen-recording=(\S+)\s*$", text, re.MULTILINE)
    return hit.group(1) if hit else None


def pixels_may_decide(grant, statuses):
    if grant != "granted":
        return False
    return bool(statuses) and all(status == "usable" for status in statuses)


class Lane:
    # Polled, never slept: WebView2 and WebKitGTK cold-start times vary
    # several-fold between runs on one runner, so a fixed wait is a flake or a
    # waste.
    poll_seconds = 2
    max_shots = 24
    hard_max_shots = 40
    timeout_seconds = 240
    # The webview paints a moment after Rust logs the state.
    post_seconds = 30

    # (slug, advisory). An advisory control still decides whether a frame may
    # mean anything, but cannot red a lane that never used one as evidence.
    controls = (("00-control-before-launch", False),)

    def __init__(self, platform, artifact, shots):
        self.artifact = artifact
        self.label = "%s/%s" % (platform, os.path.basename(artifact))
        self.shots = Path(shots)
        self.verdict_dir = self.shots / "verdict"
        self.context_dir = self.shots / "context"
        self.shot_count = 0
        self.capture_failures = 0
        self.saw_window = False
        self.reached = None
        self.failed_state = None
        self.on_screen = False
        self.control_status = {}
        self.handles = []
        self.re_ready = re.compile(shell_value("UNYT_RE_BACKEND_READY"))
        self.re_failed = re.compile(shell_value("UNYT_RE_FAILED"))
        self.re_awaiting = re.compile(shell_value("UNYT_RE_AWAITING_PASSWORD"))
        self.bundle_id = shell_value("UNYT_BUNDLE_ID")

    def preflight(self):
        """Refuse a runner that cannot answer, before anything is installed."""

    def install(self):
        raise NotImplementedError

    def launch(self):
        raise NotImplementedError

    def logs(self):
        raise NotImplementedError

    def alive(self):
        raise NotImplementedError

    def capture(self, slug):
        """Photograph the app's own window into verdict/, and whatever context
        the platform can add into context/. True when verdict/ gained a frame."""
        raise NotImplementedError

    def control_capture(self, slug, path):
        """The same capture path, before the app exists."""
        raise NotImplementedError

    def opened(self, path, mode="wb"):
        handle = open(path, mode)
        self.handles.append(handle)
        return handle

    def stop(self):
        for handle in self.handles:
            handle.close()

    def diagnostics(self):
        """What a human reading a red lane needs: log tails, window lists."""

    def after_watch(self):
        """A second phase, which may only ever upgrade the verdict the watch has
        already earned."""

    def check_controls(self):
        """One that could not be CAPTURED ends the lane only when no control
        could be: the ones that worked still answer their own question."""
        uncapturable = 0
        gating = 0
        for slug, advisory in self.controls:
            path = self.context_dir / (slug + ".png")
            status, word, why = self.one_control(slug, path)
            self.control_status[slug] = status
            if advisory:
                continue
            gating += 1
            if status == "uncapturable":
                uncapturable += 1
                note("::warning::%s captured nothing at all" % slug)
                continue
            if word:
                raise Answer(word, why)
        if gating and uncapturable == gating:
            raise Answer(
                "CANNOT PROVE",
                "nothing could be captured on this runner even before the app was started",
            )

    def one_control(self, slug, path):
        """(status, word, why) — the word is what a non-advisory lane answers."""
        if not self.control_capture(slug, path):
            return (
                "uncapturable",
                "CANNOT PROVE",
                ("nothing could be captured here even before the app was started"),
            )
        verdict, detail = frames.assess(path)
        note("%-10s %s: %s" % (verdict, path.name, detail))
        if verdict == frames.PAINTED:
            return (
                "passes-for-app",
                "UNTRUSTED",
                (
                    "%s was captured before the app was launched and already scores as the"
                    " app, so this capture path cannot answer the question" % path.name
                ),
            )
        if verdict == frames.UNREADABLE:
            return (
                "unreadable",
                "CANNOT PROVE",
                (
                    "the pre-launch frame could not be read, so the capture path is unusable"
                ),
            )
        note(
            "OK: %s does not pass for the app, so a later frame that does means the app"
            % path.name
        )
        return "usable", None, None

    def shoot(self, slug, force=False):
        """A failed capture is counted rather than fatal, so a lane that managed
        no frame at all cannot read as blank."""
        if self.shot_count >= self.hard_max_shots:
            return None
        if self.shot_count >= self.max_shots and not force:
            return None
        self.shot_count += 1
        slug = "%02d-%s" % (self.shot_count, slug)
        if self.capture(slug):
            return slug
        self.capture_failures += 1
        return None

    def seek_frame(self, slug, force=False):
        """The slug of a photograph of the app's own window that IS the app's
        own screen, or None. NEVER OVERRIDDEN, so no platform can hand this
        answer to something that was never photographed; one that can answer "on
        screen" another way overrides seek_evidence instead."""
        taken = self.shoot(slug, force)
        if not taken:
            return None
        found = sorted(self.verdict_dir.glob(taken + "*.png"))
        if frames.exit_code(frames.report(found, sys.stderr)) != 0:
            return None
        return taken

    def seek_evidence(self, slug, force=False):
        """What counts as the app being on screen. A photograph of its own
        window is the default; a platform may override with less."""
        if not self.seek_frame(slug, force):
            return False
        self.on_screen = True
        return True

    def seek_paint(self, prefix, budget):
        """The slug of the first frame that is the app's own screen, or None.
        Bounded by the clock AND by the frame ceiling: past the ceiling shoot()
        captures nothing, so a loop watching only the clock would poll out its
        seconds and the caller would read those non-attempts as judged frames."""
        started = time.monotonic()
        while True:
            taken = self.shot_count
            painted = self.seek_frame(
                "%s-t%ds" % (prefix, time.monotonic() - started), True
            )
            if painted:
                return painted
            if self.shot_count == taken or time.monotonic() - started >= budget:
                return None
            time.sleep(self.poll_seconds)

    def watch(self):
        started = time.monotonic()
        reached_at = None
        while True:
            elapsed = int(time.monotonic() - started)
            log = self.logs()

            if not self.failed_state:
                self.failed_state = first_match(self.re_failed, log)
                if self.failed_state:
                    note(
                        "::error::the app reached a FAILURE state: " + self.failed_state
                    )
                    self.seek_evidence("t%ds-failed" % elapsed, True)
                    return

            if not self.reached:
                self.reached = first_match(self.re_ready, log) or first_match(
                    self.re_awaiting, log
                )
                if self.reached:
                    reached_at = time.monotonic()
                    note("OK: the app reached -> " + self.reached)

            # Forced once the state is reached: the frames from the window in
            # which the prompt is actually up are worth the budget.
            if not self.on_screen:
                self.seek_evidence("t%ds" % elapsed, bool(self.reached))

            if self.reached and self.on_screen:
                return
            if self.reached and time.monotonic() - reached_at >= self.post_seconds:
                note(
                    "::error::%ds after the app reached its state, nothing shows it on screen"
                    % self.post_seconds
                )
                return
            if not self.alive():
                note(
                    "::error::the app exited before reaching any state a user could see"
                )
                self.seek_evidence("t%ds-exited" % elapsed, True)
                return
            if time.monotonic() - started >= self.timeout_seconds:
                note(
                    "::error::no LairAwaitingPassword and no healthy state within %ds"
                    % self.timeout_seconds
                )
                self.seek_evidence("t%ds-timeout" % elapsed, True)
                return
            time.sleep(self.poll_seconds)

    def state_note(self):
        if self.failed_state:
            return "the app reached a failure state (%s)" % self.failed_state
        if self.reached:
            return "the app reached %s" % self.reached
        return "the app never reached LairAwaitingPassword or a healthy state"

    def screen_note(self, results):
        # FLAT names no cause: it covers a strip of chrome on a blank window and
        # a greyscale capture, which cannot hold a render at all.
        for verdict, phrasing in (
            (frames.PAINTED, "a frame of its window is the app's own screen (%s)"),
            (
                frames.FOREIGN,
                "every frame of its window shows something that is not the app (%s)",
            ),
            (frames.FLAT, "no frame of its window carries enough to be a screen (%s)"),
        ):
            for _, got, detail in results:
                if got == verdict:
                    return phrasing % detail
        return "no frame of its window could be read as an image"

    def unreadable_screen(self, results):
        """A platform's reason to read frames that are not the app's screen as a
        failure to LOOK rather than a failure of the build."""
        return None

    def no_frames(self):
        # "The app showed no window" is about the artifact; "nothing could be
        # photographed" is about the runner. Never the same answer.
        if self.shot_count and not self.saw_window:
            return (
                "NOT PROVEN",
                "the app ran but never owned a visible window to photograph",
            )
        return "CANNOT PROVE", (
            "not one frame of the app's window was captured (%d attempt(s) failed)"
            % self.capture_failures
        )

    def verdict(self):
        found = sorted(self.verdict_dir.glob("*.png"))
        if not found:
            return self.no_frames()
        results = frames.report(found, sys.stderr)
        code = frames.exit_code(results)
        if code == 4:
            return "CANNOT PROVE", (
                "%d frame(s) were written but none could be read as an image"
                % len(results)
            )
        blocked = self.unreadable_screen(results)
        if blocked:
            return "CANNOT PROVE", blocked
        both = "%s, and %s" % (self.state_note(), self.screen_note(results))
        if code == 0 and not self.failed_state and self.reached:
            return "PROVEN", both
        return "NOT PROVEN", both

    def prepare(self):
        # Cleared, not just created: the verdict passes if ANY frame is the
        # app's, so a frame left by an earlier run would prove this artifact with
        # the last one's screenshot.
        for directory in (self.verdict_dir, self.context_dir):
            shutil.rmtree(directory, ignore_errors=True)
            directory.mkdir(parents=True)

    def run(self):
        self.prepare()
        try:
            self.preflight()
            self.check_controls()
            self.install()
            self.launch()
            self.watch()
            self.after_watch()
            self.diagnostics()
            return self.verdict()
        finally:
            self.stop()


class LinuxLane(Lane):
    """Not a pristine container, unlike run-smoke.sh: the question here is
    whether the app paints, not whether it declares its dependencies, and a
    container puts an X server and a `docker cp` between us and the frame."""

    def __init__(self, artifact, shots):
        super().__init__("linux", artifact, shots)
        self.sandbox = short_tmp("UNYT_PROVE_SANDBOX")
        self.work = Path(tempfile.mkdtemp())
        self.stdout_log = self.sandbox / "app-stdout.log"
        self.display = None
        self.xvfb = None
        self.app = None
        self.app_pid = None
        self.proc_name = None
        self.launch_argv = None
        self.grabber = None

    def preflight(self):
        if not os.path.isfile(self.artifact):
            raise Answer("CANNOT PROVE", "no such artifact: %s" % self.artifact)
        for tool in ("Xvfb", "xdotool", "xwininfo"):
            need(tool, "there is no way to look at a screen")
        # ImageMagick 6 ships `import`, 7 renames it under `magick`.
        for candidate in (["import"], ["magick", "import"]):
            if shutil.which(candidate[0]):
                self.grabber = candidate
                break
        if not self.grabber:
            raise Answer(
                "CANNOT PROVE",
                "neither 'import' nor 'magick' is installed, so nothing can be captured",
            )
        self.start_display()

    def start_display(self):
        """-displayfd, so there is no lock-file scan and no race. Explicit
        rather than xvfb-run, which picks a display it never tells the caller —
        and the capture has to address the same one the app was given.
        1400x1050 leaves room around the 800x800 splash, so it is never
        clipped."""
        log = self.opened(self.work / "xvfb.log", "w")
        read_fd, write_fd = os.pipe()
        self.xvfb = subprocess.Popen(
            [
                "Xvfb",
                "-displayfd",
                str(write_fd),
                "-screen",
                "0",
                "1400x1050x24",
                "-nolisten",
                "tcp",
            ],
            pass_fds=(write_fd,),
            stdout=log,
            stderr=log,
        )
        os.close(write_fd)
        number = ""
        if select.select([read_fd], [], [], 30)[0]:
            number = os.read(read_fd, 32).decode("ascii", "replace").strip()
        os.close(read_fd)
        if not number.isdigit():
            note("::error::no Xvfb display came up, so there is no screen to look at:")
            note(indent((self.work / "xvfb.log").read_text(errors="replace")))
            raise Answer("CANNOT PROVE", "no X display could be started on this runner")
        self.display = ":" + number
        os.environ["DISPLAY"] = self.display
        note("display %s (1400x1050)" % self.display)

    def install(self):
        artifact = os.path.abspath(self.artifact)
        if artifact.endswith(".deb"):
            self.install_deb(artifact)
        elif artifact.endswith(".AppImage"):
            self.install_appimage(artifact)
        else:
            raise Answer(
                "CANNOT PROVE",
                "unsupported artifact '%s' (expected .deb or .AppImage)" % artifact,
            )
        if not self.proc_name:
            self.proc_name = os.path.basename(self.launch_argv[0])
        note("launching %s (process '%s')" % (self.launch_argv[0], self.proc_name))

    def install_deb(self, artifact):
        # apt-get, not `dpkg -i`: whether the dependencies are declared is
        # run-smoke.sh's question. An absolute path, because apt reads a bare
        # name as a package.
        if run_loud(["sudo", "apt-get", "install", "-y", artifact]).returncode:
            raise Answer(
                "NOT PROVEN",
                "the package would not install, so there was nothing to launch",
            )
        package = run(["dpkg-deb", "-f", artifact, "Package"]).stdout.strip()
        listed = run(["dpkg", "-L", package]).stdout.splitlines()
        binaries = [
            f
            for f in listed
            if f.startswith("/usr/bin/") and os.path.isfile(f) and os.access(f, os.X_OK)
        ]
        if not binaries:
            raise Answer(
                "NOT PROVEN", "%s installed no executable under /usr/bin" % package
            )
        self.launch_argv = [binaries[0]]

    def install_appimage(self, artifact):
        app = self.work / "app.AppImage"
        shutil.copy(artifact, app)
        app.chmod(0o755)
        # FUSE is absent on the runners and libfuse2 is renamed on newer Ubuntu,
        # so extraction is the portable path.
        os.environ["APPIMAGE_EXTRACT_AND_RUN"] = "1"
        if run_loud([str(app), "--appimage-extract"], cwd=self.work).returncode:
            raise Answer(
                "NOT PROVEN",
                "the AppImage would not extract, so there was nothing to launch",
            )
        if run_loud(
            [
                "sudo",
                "apt-get",
                "install",
                "-y",
                "libwebkit2gtk-4.1-0",
                "libgbm1",
                "libgl1",
                "libegl1",
            ]
        ).returncode:
            raise Answer(
                "CANNOT PROVE",
                "the AppImage's GTK baseline would not install on this runner",
            )
        self.launch_argv = [str(app)]
        # The app runs as its INNER binary, so the process to watch cannot be
        # guessed from the .AppImage filename.
        for desktop in sorted((self.work / "squashfs-root").glob("*.desktop")):
            for line in desktop.read_text(errors="replace").splitlines():
                if line.startswith("Exec="):
                    self.proc_name = line[len("Exec=") :].split()[0]
                    return
        raise Answer(
            "NOT PROVEN",
            "the AppImage's .desktop declares no Exec, so there is no process to watch",
        )

    def launch(self):
        shutil.rmtree(self.sandbox, ignore_errors=True)
        for sub in ("data", "cache", "config", "state"):
            (self.sandbox / sub).mkdir(parents=True)
        env = dict(os.environ)
        env.update(
            {
                "XDG_DATA_HOME": str(self.sandbox / "data"),
                "XDG_CACHE_HOME": str(self.sandbox / "cache"),
                "XDG_CONFIG_HOME": str(self.sandbox / "config"),
                "XDG_STATE_HOME": str(self.sandbox / "state"),
                # Without this the single-instance plugin is installed and a
                # second launch focuses the first window instead of starting.
                "AGENT_ID": os.environ.get("AGENT_ID", "prove"),
                "RUST_LOG": os.environ.get("RUST_LOG", "info"),
                # With no GPU, WebKitGTK's DMABUF/GBM/EGL path fails and the
                # webview dies mid-boot — indistinguishable from a real failure.
                "WEBKIT_DISABLE_DMABUF_RENDERER": "1",
                "WEBKIT_DISABLE_COMPOSITING_MODE": "1",
                "LIBGL_ALWAYS_SOFTWARE": "1",
                "GDK_BACKEND": "x11",
                # Deliberately not set: UNYT_BYPASS_PASSWORD. Parking at
                # LairAwaitingPassword with the prompt on screen is the thing
                # being proven.
            }
        )
        self.app = subprocess.Popen(
            self.launch_argv,
            stdout=self.opened(self.stdout_log),
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )
        # Track the app, not the launcher. pgrep matches the first 15 characters.
        for _ in range(30):
            found = run(
                ["pgrep", "-g", str(self.app.pid), "-x", self.proc_name[:15]]
            ).stdout.split()
            if found:
                self.app_pid = int(found[0])
                break
            if self.app.poll() is not None:
                break
            time.sleep(1)
        if not self.app_pid:
            note(indent(tail(self.stdout_log)))
            raise Answer(
                "NOT PROVEN",
                "no '%s' process appeared within 30s — the app never started"
                % self.proc_name,
            )
        note("app pid %d (launcher %d)" % (self.app_pid, self.app.pid))

    def logs(self):
        return read_all(
            [self.stdout_log],
            [self.sandbox / "data" / self.bundle_id / "logs"],
            "unyt.v*.log.*",
        )

    def alive(self):
        # poll() first, so a dead direct child is reaped rather than answering
        # signal 0 as a zombie.
        self.app.poll()
        try:
            os.kill(self.app_pid, 0)
        except OSError:
            return False
        return True

    def windows(self):
        # `xdotool search --pid` reads _NET_WM_PID, which a client need not set.
        # The fallback asks the X server for the root's children, which needs
        # nothing of the client — sound only because this display is private to
        # this run.
        found = []
        search = run(["xdotool", "search", "--onlyvisible", "--pid", str(self.app_pid)])
        # xdotool exits 1 both for "no window" and for "no display", so only its
        # stderr tells the probe failing apart from the app owning nothing.
        if search.stderr.strip():
            note("::warning::xdotool search: %s" % search.stderr.strip())
        for window in search.stdout.split():
            shell = run(["xdotool", "getwindowgeometry", "--shell", window]).stdout
            size = dict(
                line.split("=", 1) for line in shell.splitlines() if "=" in line
            )
            if "WIDTH" in size and "HEIGHT" in size:
                found.append((window, int(size["WIDTH"]), int(size["HEIGHT"])))
        if found:
            return found
        for line in run(["xwininfo", "-root", "-children"]).stdout.splitlines():
            fields = line.split()
            if len(fields) < 2 or not fields[0].startswith("0x"):
                continue
            # A title may contain spaces, so the `<w>x<h>[+-]<x>[+-]<y>` token is
            # counted from the end. Its offsets are negative for a window placed
            # partly off-screen, which is still a window the app put up.
            geometry = re.match(r"^(\d+)x(\d+)[-+]", fields[-2])
            if geometry:
                found.append(
                    (fields[0], int(geometry.group(1)), int(geometry.group(2)))
                )
        return found

    def window(self):
        """The largest, because a toolkit maps small utility windows next to the
        real one and a frame of one of those is a true picture of the wrong
        thing. Re-asked every time, since a full boot replaces the splash with
        the main window."""
        best = sorted(self.windows(), key=lambda found: found[1] * found[2])
        return best[-1][0] if best else None

    def grab(self, target, path):
        result = run(
            self.grabber + ["-display", self.display, "-window", target, str(path)]
        )
        return result.returncode == 0 and path.exists() and path.stat().st_size > 0

    def control_capture(self, slug, path):
        return self.grab("root", path)

    def capture(self, slug):
        # The whole display as context whatever else happens: when the window
        # frame comes back wrong, it is what says whether anything was there.
        self.grab("root", self.context_dir / (slug + "-root.png"))
        window = self.window()
        if not window:
            return False
        # Ever, not currently: a window that appeared and went away is a
        # different finding from one that never existed.
        self.saw_window = True
        return self.grab(window, self.verdict_dir / (slug + "-window.png"))

    def diagnostics(self):
        note("--- app stdout/stderr (tail) ---")
        note(indent(tail(self.stdout_log)))
        if not self.saw_window:
            note(indent(run(["xwininfo", "-root", "-tree"]).stdout))

    def stop(self):
        # The whole session, so the app's conductor and keystore go with it: an
        # AppImage runs an inner binary, and ending the launcher alone would
        # leave the app on the runner.
        if self.app:
            end_process_group(self.app.pid, self.app_pid)
            end_process(self.app)
        end_process(self.xvfb)
        super().stop()
        shutil.rmtree(self.work, ignore_errors=True)


class MacosLane(Lane):
    """Two modes, because without the TCC "Screen Recording" grant
    `screencapture` does not fail: it returns the desktop with every application
    window omitted. So the lane measures whether it has the grant, tries, and
    falls back to the window list — which is only partly redacted, since
    kCGWindowName is withheld without the grant and the owner pid, the layer and
    the bounds are not.

    It is never PROVEN off anything but a frame of the app's own window, and
    never red for want of a photograph it could not take."""

    # Advisory, because this lane's verdict does not rest on pixels. The frame
    # that would decide is one window's worth of the screen, which can clear a
    # bar the whole screen does not — hence the second control, a rect at the
    # top-left where the menu bar is.
    controls = (("00-control-screen", True), ("00-control-window-rect", True))
    # A whole-screen retina PNG per poll is tens of megabytes of artifact for
    # frames that decide nothing here.
    max_shots = 6
    hard_max_shots = 8

    # The splash is declared 800x800 in unyt/src-tauri/tauri.conf.json. The floor
    # is well under it because a full boot replaces the splash with the main
    # window, which is a different size and still a window the app put up.
    MIN_WINDOW_W, MIN_WINDOW_H = 400, 300
    DECLARED_W, DECLARED_H = 800, 800

    def __init__(self, artifact, shots):
        super().__init__("macos", artifact, shots)
        self.home = short_tmp("UNYT_PROVE_HOME")
        self.work = Path(tempfile.mkdtemp())
        self.stdout_log = self.work / "app-stdout.log"
        self.probe = self.work / "window-info"
        self.mount = None
        self.app = None
        self.binary = None
        self.grant = "unknown"
        self.window_line = None
        self.painted_frame = None
        self.pixel_outcome = ""

    def window_info(self, pid=0):
        return run([str(self.probe), str(pid)])

    def preflight(self):
        if not os.path.isfile(self.artifact):
            raise Answer("CANNOT PROVE", "no such artifact: %s" % self.artifact)
        # A runner with no Aqua session cannot show a GUI app anything, and its
        # window list would be empty for a reason unrelated to the artifact.
        session = run(["launchctl", "managername"]).stdout.strip()
        note("launchctl managername: %s" % (session or "<none>"))
        if session != "Aqua":
            note(
                "::error title=No window server on this runner::the launchd session is '%s', not Aqua"
                % session
            )
            raise Answer(
                "CANNOT PROVE",
                "this runner has no Aqua (GUI) session, so nothing can put a window on a screen here",
            )
        need("swiftc", "the window probe could not be built")
        # main.swift because swiftc accepts top-level statements only in a file
        # by that name.
        shutil.copy(HERE / "mac-window-info.swift", self.work / "main.swift")
        if run_loud(
            ["swiftc", "-O", "-o", str(self.probe), str(self.work / "main.swift")]
        ).returncode:
            raise Answer(
                "CANNOT PROVE",
                "the window probe would not compile, so nothing could be asked of the window server",
            )
        # Asked before anything is installed: the whole macOS approach rests on
        # the owner pid and the bounds surviving the redaction.
        probed = self.window_info(0)
        note(probed.stdout)
        if probed.stderr.strip():
            note(indent(probed.stderr))
        if probed.returncode == 3:
            raise Answer(
                "CANNOT PROVE", "the window server returned no window list at all"
            )
        if probed.returncode == 5:
            note(
                "::error title=The macOS window list is not evidence::the owner pid or the bounds are redacted across the whole list"
            )
            raise Answer(
                "UNTRUSTED",
                "the window list carries no usable owner pid or bounds on this macOS, so it cannot say whether the app put a window on screen",
            )
        # 0 and 1 are both "the list answered" — pid 0 owns nothing.
        if probed.returncode not in (0, 1):
            raise Answer(
                "CANNOT PROVE",
                "the window probe exited %d, which it is not supposed to be able to do"
                % probed.returncode,
            )
        self.grant = grant_of(probed.stdout) or "unknown"
        note("screen recording (before launch): %s" % self.grant)

    def control_capture(self, slug, path):
        argv = ["screencapture", "-x"]
        if slug.endswith("window-rect"):
            argv.append("-R0,0,%d,%d" % (self.DECLARED_W, self.DECLARED_H))
        run(argv + [str(path)])
        return path.exists() and path.stat().st_size > 0

    def install(self):
        attach = self.work / "hdiutil-attach.log"
        with open(attach, "w") as log:
            try:
                # A disk image carrying a licence agreement waits for a keypress,
                # which would hang the job until the runner's six-hour timeout.
                code = subprocess.run(
                    [
                        "hdiutil",
                        "attach",
                        "-nobrowse",
                        "-readonly",
                        "-noverify",
                        "-noautoopen",
                        "-mountpoint",
                        str(self.work / "mnt"),
                        self.artifact,
                    ],
                    stdout=log,
                    stderr=log,
                    stdin=subprocess.DEVNULL,
                    check=False,
                    timeout=int(os.environ.get("UNYT_HDIUTIL_TIMEOUT", "120")),
                ).returncode
            except subprocess.TimeoutExpired:
                code = 124
        if code:
            note(
                "::error::hdiutil could not mount %s (exit %d):"
                % (os.path.basename(self.artifact), code)
            )
            note(indent(attach.read_text(errors="replace")))
            raise Answer(
                "NOT PROVEN",
                "the disk image would not mount, so nothing could be installed",
            )
        self.mount = self.work / "mnt"

        bundles = sorted(self.mount.glob("*.app"))
        if len(bundles) != 1:
            raise Answer(
                "CANNOT PROVE",
                "the disk image contains %d .app bundles — refusing to pick one at random"
                % len(bundles),
            )
        # /Applications, where a user drags it: bundle identity, signature
        # evaluation and the app's own idea of where it lives all depend on the
        # path it runs from.
        bundle = Path("/Applications") / bundles[0].name
        shutil.rmtree(bundle, ignore_errors=True)
        # ditto, not cp -R: it preserves the xattrs and symlinks the signature
        # covers.
        copied = run_loud(["ditto", str(bundles[0]), str(bundle)])
        if copied.returncode:
            # About the runner, not the build: a failed copy would otherwise be
            # reported as a bundle with no executable in it.
            raise Answer(
                "CANNOT PROVE",
                "ditto exited %d copying %s into /Applications, so nothing was installed to launch"
                % (copied.returncode, bundles[0].name),
            )
        self.detach()

        executable = run(
            [
                "plutil",
                "-extract",
                "CFBundleExecutable",
                "raw",
                "-o",
                "-",
                str(bundle / "Contents/Info.plist"),
            ]
        ).stdout.strip()
        self.binary = bundle / "Contents/MacOS" / executable
        if not executable or not os.access(self.binary, os.X_OK):
            raise Answer(
                "NOT PROVEN",
                "the installed bundle has no Contents/MacOS/<CFBundleExecutable> — got '%s'"
                % (executable or "<no Info.plist>"),
            )

    def launch(self):
        # HOME is the whole redirection: tauri's app_data_dir / app_log_dir and
        # app_dirs2 all resolve through it. AGENT_ID is deliberately not set — it
        # lengthens the data root, and the socket path has no room to spare.
        shutil.rmtree(self.home, ignore_errors=True)
        self.home.mkdir(parents=True)
        env = dict(
            os.environ, HOME=str(self.home), RUST_LOG=os.environ.get("RUST_LOG", "info")
        )
        # The binary directly, not `open`: `open` hands the launch to launchd,
        # which gives the app launchd's environment and drops HOME with it. A
        # bundled binary run this way still gets a window-server connection.
        self.app = subprocess.Popen(
            [str(self.binary)],
            stdout=self.opened(self.stdout_log),
            stderr=subprocess.STDOUT,
            env=env,
        )
        note("launched %s (pid %d, HOME=%s)" % (self.binary, self.app.pid, self.home))

    def logs(self):
        # Tauri's app_log_dir is ~/Library/Logs/<id>. Application Support is read
        # too, so a change in tauri's resolution shows up as a log we still find
        # rather than as a silent "no state reached".
        return read_all(
            [self.stdout_log],
            [
                self.home / "Library/Logs" / self.bundle_id,
                self.home / "Library/Application Support" / self.bundle_id / "logs",
            ],
            "unyt.v*.log.*",
        )

    def alive(self):
        return self.app.poll() is None

    def largest_window(self):
        best = None
        for line in self.window_info(self.app.pid).stdout.splitlines():
            fields = line.split()
            if len(fields) < 7 or fields[0] != "WINDOW":
                continue
            width, height = int(fields[4]), int(fields[5])
            if width < self.MIN_WINDOW_W or height < self.MIN_WINDOW_H:
                continue
            if not best or width * height > best[1]:
                best = (line, width * height)
        return best[0] if best else None

    def capture(self, slug):
        # A whole-screen frame is context here whatever the mode: without the
        # grant it is the desktop with the app omitted, and with it the app is
        # one window on a desktop rather than the thing being judged.
        path = self.context_dir / (slug + "-screen.png")
        run(["screencapture", "-x", str(path)])
        return path.exists() and path.stat().st_size > 0

    def capture_window(self, slug):
        """`-l <windowid>` asks the window server for that window's own content,
        so what comes back is the app whatever is in front of it — unlike a
        whole-screen frame it cannot be a picture of the desktop. `-o` drops the
        drop shadow, which would pad the frame with desktop pixels."""
        line = self.largest_window()
        if not line:
            return False
        path = self.verdict_dir / (slug + "-window.png")
        shot = run(["screencapture", "-x", "-o", "-l", line.split()[1], str(path)])
        if not (path.exists() and path.stat().st_size > 0):
            if shot.stderr.strip():
                note(indent(shot.stderr))
            return False
        # The window that was PHOTOGRAPHED, so the verdict's size describes the
        # frame: the splash is replaced by the main window mid-run.
        self.window_line = line
        return True

    def seek_evidence(self, slug, force=False):
        self.shoot(slug, force)
        line = self.largest_window()
        if not line:
            return False
        note("OK: the app owns an on-screen window — " + line)
        self.saw_window = True
        self.window_line = line
        self.on_screen = True
        return True

    def after_watch(self):
        # The grant is measured as titles ANYWHERE in the list, so a desktop with
        # nothing titled on it answers "not-granted" for want of anything to read.
        # Re-read here, over a list that now contains the app's own window.
        grant = grant_of(self.window_info(self.app.pid).stdout) or self.grant
        statuses = [self.control_status.get(slug) for slug, _ in self.controls]
        may = pixels_may_decide(grant, statuses)
        if may:
            self.pixel_outcome = "the window list carries titles, so this process has Screen Recording, and neither pre-launch frame passes for the app"
        elif grant != "granted":
            self.pixel_outcome = "the window list carries no titles, so this process does not have Screen Recording and a capture would return the desktop rather than the app's own window"
        else:
            self.pixel_outcome = (
                "a pre-launch control frame cannot be trusted (%s)"
                % ", ".join(
                    "%s is %s" % (slug, status)
                    for (slug, _), status in zip(self.controls, statuses)
                )
            )
        note("pixel mode: %s — %s" % ("ON" if may else "OFF", self.pixel_outcome))
        # The state half is a precondition, not something pixels could rescue: a
        # run that failed or never reached a state is NOT PROVEN whatever a frame
        # shows.
        if not (may and self.window_line and self.reached and not self.failed_state):
            return
        budget = int(os.environ.get("UNYT_PROVE_PIXEL_SECONDS", "30"))
        note("--- photographing the app's own window (%ds budget) ---" % budget)
        self.max_shots = self.hard_max_shots = self.shot_count + 16
        before = len(list(self.verdict_dir.glob("*.png")))
        failures = self.capture_failures
        self.capture = self.capture_window
        painted = self.seek_paint("pixel", budget)
        if painted:
            # The slug seek_frame returned, and nothing else: PROVEN may only
            # ever cite a photograph, and the watch's own answer was a list.
            self.painted_frame = "frame " + painted
            note(
                "OK: a window-scoped capture is the app's own screen (%s)"
                % self.painted_frame
            )
            return
        # Opposite findings, so they are never worded the same: frames that are
        # not a screen say something about the build, and no frames at all say
        # the capture path could not photograph a window demonstrably there.
        taken = len(list(self.verdict_dir.glob("*.png"))) - before
        if taken:
            self.pixel_outcome = (
                "%d frames of that window were captured and none is the app's own screen — either the webview drew nothing, or this runner handed back the desktop instead of the window"
                % taken
            )
            note(
                "::warning title=macOS photographed the window and it is not a screen::%s"
                % self.pixel_outcome
            )
        else:
            self.pixel_outcome = (
                "not one window-scoped capture succeeded, so nothing was photographed to judge (%d failed attempt(s))"
                % (self.capture_failures - failures)
            )
            note(
                "::warning title=macOS could not photograph the window at all::%s"
                % self.pixel_outcome
            )

    def diagnostics(self):
        note("--- app stdout/stderr (tail) ---")
        note(indent(tail(self.stdout_log)))
        note("--- the window list as it stands now ---")
        note(self.window_info(self.app.pid).stdout)
        for what, directory in (
            ("window-scoped frames (these decide the verdict)", self.verdict_dir),
            ("whole-screen frames (context, never the verdict)", self.context_dir),
        ):
            found = sorted(directory.glob("*.png"))
            if found:
                note("--- what the %s contain ---" % what)
                frames.report(found, sys.stderr)

    def verdict(self):
        state = self.state_note()
        if not self.window_line:
            return (
                "NOT PROVEN",
                "%s, and it never put an on-screen window of at least %dx%d up, so there was nothing to photograph either"
                % (state, self.MIN_WINDOW_W, self.MIN_WINDOW_H),
            )
        fields = self.window_line.split()
        width, height = int(fields[4]), int(fields[5])
        size = "%dx%d" % (width, height)
        if not (
            self.DECLARED_W * 3 // 4 <= width <= self.DECLARED_W * 5 // 4
            and self.DECLARED_H * 3 // 4 <= height <= self.DECLARED_H * 5 // 4
        ):
            # Not fatal — a full boot replaces the splash with the main window.
            # Loud, because the other reason to see it is somebody else's window.
            note(
                "::warning title=Not the splash's declared size::the window is %s, and the splash declares %dx%d"
                % (size, self.DECLARED_W, self.DECLARED_H)
            )
            size = "%s, not the %dx%d the splash declares" % (
                size,
                self.DECLARED_W,
                self.DECLARED_H,
            )
        if self.failed_state or not self.reached:
            # Ahead of the pixel result: a painted screen with a failed backend
            # behind it is a different bug, not a pass.
            return "NOT PROVEN", "%s, though it did put a %s window on screen" % (
                state,
                size,
            )
        if self.painted_frame:
            return (
                "PROVEN",
                "%s, put a %s window on screen, and a window-scoped capture of it is the app's own screen (%s)"
                % (state, size, self.painted_frame),
            )
        return (
            "WINDOW-ONLY",
            "%s and put a %s window on screen; no photograph of that window says it is a screen the app painted (%s), so what the webview drew into it is NOT verified here"
            % (state, size, self.pixel_outcome),
        )

    def detach(self):
        if not self.mount:
            return
        if run(["hdiutil", "detach", "-quiet", str(self.mount)]).returncode:
            forced = run(["hdiutil", "detach", "-quiet", "-force", str(self.mount)])
            if forced.returncode:
                # Said out loud, and the handle kept: a volume this lane has
                # forgotten is one nothing will try to unmount again.
                note(
                    "::warning::%s is still mounted — hdiutil detach exited %d: %s"
                    % (self.mount, forced.returncode, forced.stderr.strip())
                )
                return
        self.mount = None

    def stop(self):
        # The app, not its tree: what it spawned is left to the runner, which is
        # thrown away at the end of the job.
        end_process(self.app)
        self.detach()
        super().stop()
        shutil.rmtree(self.work, ignore_errors=True)


Entry = collections.namedtuple("Entry", "key name location")

UNINSTALL_ROOTS = (
    ("HKCU", r"Software\Microsoft\Windows\CurrentVersion\Uninstall"),
    ("HKLM", r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"),
    ("HKLM", r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"),
)


def registry_value(key, name):
    import winreg

    try:
        value = winreg.QueryValueEx(key, name)[0]
    except OSError:
        return None
    return value if isinstance(value, str) else None


def uninstall_entries():
    import winreg

    hives = {"HKCU": winreg.HKEY_CURRENT_USER, "HKLM": winreg.HKEY_LOCAL_MACHINE}
    found = []
    for hive, path in UNINSTALL_ROOTS:
        try:
            root = winreg.OpenKey(hives[hive], path)
        except OSError:
            continue
        with root:
            for index in range(winreg.QueryInfoKey(root)[0]):
                try:
                    name = winreg.EnumKey(root, index)
                    with winreg.OpenKey(root, name) as key:
                        found.append(
                            Entry(
                                "%s\\%s\\%s" % (hive, path, name),
                                registry_value(key, "DisplayName"),
                                registry_value(key, "InstallLocation"),
                            )
                        )
                except OSError:
                    continue
    return found


def installer_kind(path):
    return {".exe": "nsis", ".msi": "msi"}.get(
        os.path.splitext(path)[1].lower(), "unsupported"
    )


def install_argv(path, kind, log=None):
    """The same commands check-windows.ps1 uses, so both install to the same
    place under the same product identity.

    NSIS takes an UPPERCASE /S — the switch is case-sensitive and /s runs the
    installer interactively, hanging the job on a dialog. msiexec takes /l*v
    because its exit code says almost nothing: 1619 is "could not open the
    package" whether the path was wrong, the file truncated or the installer
    corrupt. NSIS has no equivalent, so a log path is ignored there."""
    if kind != "msi":
        return [path, "/S"]
    argv = ["msiexec.exe", "/i", path, "/quiet", "/norestart"]
    return argv + ["/l*v", log] if log else argv


def to_windows_path(path):
    """msiexec will not open a forward-slash path: it answers 1619,
    ERROR_INSTALL_PACKAGE_OPEN_FAILED, which reads as a corrupt package rather
    than a mistyped one — and the path reaches this lane from a bash script,
    so it arrives with bash's separators. A forward slash is never part of a
    Windows filename, so this cannot corrupt one."""
    return path.replace("/", "\\")


def install_succeeded(code):
    """Only 0. msiexec's 3010 and 1641 mean it installed and wants a reboot, and
    this lane refuses them: a reboot-pending install is not a state any user is
    looking at."""
    return code == 0


def install_location(raw):
    """NSIS writes it quoted, the MSI bare with a trailing separator; verbatim,
    the quoted form fails every path test."""
    if not raw:
        return None
    return raw.strip().strip('"').rstrip("\\/") or None


def select_install_entry(entries):
    """The first entry rather than none, since something did just install."""
    named = [entry for entry in entries if entry.name and "unyt" in entry.name.lower()]
    for candidates in (named, entries):
        if candidates:
            return candidates[0]
    return None


class WindowsLane(Lane):
    """Both installers, one lane: the NSIS .exe and the .msi install to
    different places under different registry hives, so proving one proves
    nothing about the other.

    The capture stays in PowerShell — window-capture.ps1 runs under Windows
    PowerShell 5.1 because System.Drawing is a .NET Framework assembly, and no
    cmdlet does window-scoped capture."""

    # A second control because the fallback frame is an 800x800 sub-rect of the
    # desktop, which can clear a bar the whole desktop does not.
    controls = (("00-control-desktop", False), ("00-control-splash-rect", False))
    # The splash's own footprint, from unyt/src-tauri/tauri.conf.json.
    DECLARED = 800

    def __init__(self, artifact, shots):
        super().__init__("windows", artifact, shots)
        self.kind = installer_kind(artifact)
        self.app = None
        self.exe = None
        self.install_dir = None
        self.log_dir = None
        self.stdout_log = self.shots / "app-stdout.log"
        self.stderr_log = self.shots / "app-stderr.log"

    def helper(self, **arguments):
        """One PowerShell invocation per frame, doing everything that frame
        needs: window-capture.ps1 compiles its capture code on every start, so a
        call per check would cost more than the poll interval."""
        argv = [
            "powershell",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(HERE / "window-capture.ps1"),
        ]
        for name, value in arguments.items():
            argv += ["-" + name, str(value)]
        result = run(argv)
        if result.stderr.strip():
            note(indent(result.stderr))
        if result.returncode:
            note("::error::window-capture.ps1 exited %d" % result.returncode)
        return result.stdout.splitlines()

    def preflight(self):
        if self.kind == "unsupported":
            raise Answer(
                "CANNOT PROVE",
                "'%s' is neither an .exe nor an .msi, so there is no way to install it"
                % os.path.basename(self.artifact),
            )
        if not os.path.isfile(self.artifact):
            raise Answer(
                "CANNOT PROVE",
                "there is no file at '%s', so nothing was installed and nothing could have been"
                % self.artifact,
            )
        size = os.path.getsize(self.artifact)
        self.artifact = to_windows_path(os.path.abspath(self.artifact))
        note("artifact: %s (%s, %d bytes)" % (self.artifact, self.kind, size))
        # A runner whose agent sits on a non-interactive window station has no
        # visible desktop, and every frame would be black for a reason that has
        # nothing to do with the artifact.
        station = ""
        for line in self.helper():
            if line.startswith("STATION "):
                station = line.partition(" ")[2].strip()
        # No station line at all is the helper failing, not a station named "".
        if not station:
            raise Answer(
                "CANNOT PROVE",
                "window-capture.ps1 named no window station, so nothing here can photograph anything",
            )
        note("window station: %s" % station)
        if station != "WinSta0":
            note(
                "::error title=No interactive desktop on this runner::the process is on window station '%s', not WinSta0"
                % station
            )
            raise Answer(
                "CANNOT PROVE",
                "this runner has no interactive window station ('%s'), so nothing can put anything on a screen here"
                % station,
            )
        # The data root cannot be redirected: tauri resolves it through
        # SHGetKnownFolderPath, which reads the user's profile and ignores
        # %LOCALAPPDATA%. So the runner itself is the sandbox, and its
        # cleanliness is measured rather than assumed.
        data_root = Path(os.environ["LOCALAPPDATA"]) / self.bundle_id
        if data_root.exists():
            note(
                "::error::%s already exists, so this runner has run the app before"
                % data_root
            )
            raise Answer(
                "CANNOT PROVE",
                "the runner's app-data directory is not clean, so this would not be a first-install launch",
            )
        self.log_dir = data_root / "logs"

    def control_capture(self, slug, path):
        if slug.endswith("desktop"):
            want, lines = "desktop", self.helper(DesktopTo=path)
        else:
            want = "rect"
            lines = self.helper(RectTo=path, RectW=self.DECLARED, RectH=self.DECLARED)
        return self.wrote(lines) == {want} and path.exists()

    def install(self):
        before = {entry.key for entry in uninstall_entries()}
        # Into the shots directory, which is uploaded whatever the verdict.
        argv = install_argv(
            self.artifact, self.kind, to_windows_path(str(self.shots / "msiexec.log"))
        )
        note("installing: " + subprocess.list2cmdline(argv))
        try:
            code = subprocess.run(
                argv, timeout=300, check=False, stdout=sys.stderr, stderr=sys.stderr
            ).returncode
        except subprocess.TimeoutExpired:
            raise Answer(
                "NOT PROVEN",
                "the %s installer never finished, so it was waiting for input"
                % self.kind,
            ) from None
        if not install_succeeded(code):
            raise Answer(
                "NOT PROVEN",
                "the %s installer exited %d, so this is not an install a user would be looking at (3010 would mean it installed and wants a reboot first)"
                % (self.kind, code),
            )
        # CANNOT PROVE, not NOT PROVEN: this is only how THIS LANE finds the
        # program. Whether registering it is required at all is
        # check-windows.ps1's 'registers' and 'executable' checks.
        entry = select_install_entry(
            [e for e in uninstall_entries() if e.key not in before]
        )
        if not entry:
            raise Answer(
                "CANNOT PROVE",
                "the %s install registered no uninstall entry, so this lane has no way to find what it installed"
                % self.kind,
            )
        self.install_dir = install_location(entry.location)
        if not self.install_dir:
            raise Answer(
                "CANNOT PROVE",
                "the %s install registered '%s' with no InstallLocation, so this lane has no way to find what it installed"
                % (self.kind, entry.name),
            )
        note("installed %s -> %s" % (entry.name, self.install_dir))
        # An installer that returns 0 and registers a directory it never created
        # has installed nothing, and that must not surface later as a capture
        # failure that sounds like the app.
        if not os.path.isdir(self.install_dir):
            raise Answer(
                "NOT PROVEN",
                "the %s install registered '%s' and did not create it, so nothing was installed there"
                % (self.kind, self.install_dir),
            )
        # The app, not the uninstaller: NSIS drops both under one directory.
        programs = [
            path
            for path in Path(self.install_dir).rglob("*.exe")
            if not path.name.lower().startswith("uninstall")
        ]
        if not programs:
            raise Answer(
                "NOT PROVEN",
                "the %s installer registered itself but put no program under %s"
                % (self.kind, self.install_dir),
            )
        self.exe = max(programs, key=lambda path: path.stat().st_size)

    def launch(self):
        env = dict(
            os.environ,
            RUST_LOG=os.environ.get("RUST_LOG", "info"),
            # A runner has no GPU and WebView2's default compositing path draws
            # nothing on one. The software rasterizer is deliberately left
            # enabled — disabling it as well is what turns "no GPU" into "no
            # pixels". Deliberately unset: UNYT_BYPASS_PASSWORD, and AGENT_ID,
            # which the Linux lane needs only for the single-instance plugin.
            WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--disable-gpu --disable-gpu-compositing",
        )
        # Captured even though windows_subsystem = "windows" means nothing
        # reaches a terminal: a Rust panic before tracing is initialised still
        # writes to stderr, and that is the difference between a diagnosable
        # crash and "the app never reached any state".
        try:
            self.app = subprocess.Popen(
                [str(self.exe)],
                cwd=self.install_dir,
                env=env,
                stdout=self.opened(self.stdout_log),
                stderr=self.opened(self.stderr_log),
            )
        except OSError as exc:
            raise Answer(
                "NOT PROVEN", "the installed program would not start: %s" % exc
            ) from None
        note(
            "launched %s (%d bytes, pid %d)"
            % (self.exe, self.exe.stat().st_size, self.app.pid)
        )

    def logs(self):
        return read_all(
            [self.stdout_log, self.stderr_log], [self.log_dir], "unyt.v*.log.*"
        )

    def alive(self):
        return self.app.poll() is None

    def capture(self, slug):
        printed = self.verdict_dir / (slug + "-print.png")
        copied = self.context_dir / (slug + "-screen.png")
        lines = self.helper(
            TargetPid=self.app.pid,
            PrintTo=printed,
            CopyTo=copied,
            DesktopTo=self.context_dir / (slug + "-desktop.png"),
        )
        for line in lines:
            if line.startswith(("WINDOW ", "FAILED ")):
                note("  " + line)
            if line.startswith("WINDOW "):
                self.saw_window = True
        wrote = self.wrote(lines)
        # PrintWindow asks the window to render itself, so it returns the app's
        # own content whatever is in front of it. CopyFromScreen reads the
        # desktop at the window's coordinates, so it returns whatever is there —
        # evidence only when PrintWindow gave us nothing at all.
        if "print" in wrote:
            return True
        if "copy" in wrote:
            copied.replace(self.verdict_dir / (slug + "-screen.png"))
            return True
        return False

    @staticmethod
    def wrote(lines):
        """Which frames the helper says it wrote: print | copy | desktop | rect."""
        return {line.split()[1] for line in lines if line.startswith("WROTE ")}

    def unreadable_screen(self, results):
        # Every frame uniform black, with a window that existed, is a desktop we
        # were not shown rather than an app that drew nothing.
        if any(verdict == frames.PAINTED for _, verdict, _ in results):
            return None
        if not all(frames.uniform_black(path) for path, _, _ in results):
            return None
        note(
            "::error title=Every Windows frame came back black::the window existed, so the desktop could not be read rather than the app being blank"
        )
        return "the app had a window but every capture of it is uniform black, which on a CI runner means the desktop could not be read rather than that the app was blank"

    def diagnostics(self):
        note("--- windows this process owned ---")
        for line in self.helper(TargetPid=self.app.pid):
            note("  " + line)
        note("--- app log (tail) ---")
        note(indent("\n".join(self.logs().splitlines()[-40:])))

    def stop(self):
        end_process(self.app)
        super().stop()


LANES = {"linux": LinuxLane, "macos": MacosLane, "windows": WindowsLane}


def utf8(stream):
    """The verdict line carries an em dash and whatever the app logged, and a
    Windows code page that cannot encode one would kill the lane at the last
    line it prints."""
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")


def main(argv):
    utf8(sys.stdout)
    utf8(sys.stderr)
    if len(argv) != 3 or argv[0] not in LANES:
        note("::error::usage: prove.py <linux|macos|windows> <artifact> <shots-dir>")
        return 2
    platform, artifact, shots = argv
    label = "%s/%s" % (platform, os.path.basename(artifact))
    try:
        word, why = LANES[platform](artifact, shots).run()
    except Answer as answer:
        word, why = answer.word, answer.why
    except Exception as exc:
        # Every way out of a lane says something. A lane that printed nothing is
        # already red, but its summary could then only say "exited N without a
        # verdict" — and the reason is the value of the run.
        traceback.print_exc()
        word, why = "CANNOT PROVE", "this lane died before it could answer: %r" % (exc,)
    print("VERDICT %s: %s — %s" % (label, word, why))
    return EXIT_CODES[word]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
