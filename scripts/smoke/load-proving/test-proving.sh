#!/usr/bin/env bash
# Can the load-proving verdicts still fail?
#
#   test-proving.sh
#
# TEMPORARY — scaffolding for .github/workflows/zz-TEMPORARY-load-proving.yaml.
#
# Drives the REAL prove_watch, prove_verdict, prove_control_check and
# publish-verdict.sh against synthetic logs and synthetic frames, because the
# whole point of this lane is that a check which cannot come out red is not a
# check. The frames come from screenshot-stats.py's own encoder, so nothing here
# is a second implementation of anything it asserts about.
#
# The platform capture paths (Xvfb + import, screencapture, PrintWindow) cannot
# be driven off their platform; the CI job is what tests those, and its
# pre-launch control frame is what says whether they can be trusted at all.
# The stubs below are called by the library each scenario sources, inside a
# subshell shellcheck cannot follow into. SC2031 for the same reason: the reads
# it flags are outside that subshell, of a local it never touched.
# shellcheck disable=SC2034,SC2329,SC2031
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$(mktemp -d)"
trap 'rm -rf "$FIXTURES"' EXIT INT TERM

pass=0
fail=0
note() { printf '%-58s %s\n' "$1" "$2"; }
ok()   { pass=$((pass + 1)); note "$1" "pass"; }
bad()  { fail=$((fail + 1)); printf 'FAIL  %-52s %s\n' "$1" "$2" >&2; }

PYTHON=""
for candidate in python3 python; do
  command -v "$candidate" >/dev/null 2>&1 && { PYTHON="$candidate"; break; }
done
[ -n "$PYTHON" ] || { echo "::error::no python3 on PATH" >&2; exit 2; }

# ── the fixtures ──────────────────────────────────────────────────────────────
# Loaded as a module rather than re-encoded here: the analyser's encoder is the
# one that matches its decoder, and a second copy would let them drift apart
# while every test still passed.
# PYTHONDONTWRITEBYTECODE: importing the analyser as a module would otherwise
# leave a __pycache__ in the repo, which is not something a test may do.
PYTHONDONTWRITEBYTECODE=1 "$PYTHON" - "$here/screenshot-stats.py" "$FIXTURES" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("shot", sys.argv[1])
shot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shot)
out = sys.argv[2]
size = 400
background = shot._boot_backgrounds()[0]

frames = {
    "flat.png": shot._encode(size, size, shot._flat_rgb(size, size, (0, 0, 0))),
    "app.png": shot._encode(size, size, shot._with_modal(size, background)),
    "wallpaper.png": shot._encode(size, size, shot._wallpaper(size)),
    "tiny.png": shot._encode(32, 32, shot._flat_rgb(32, 32, (0, 0, 0))),
}
for name, png in frames.items():
    with open("%s/%s" % (out, name), "wb") as fh:
        fh.write(png)
PY
[ -s "$FIXTURES/app.png" ] || { echo "::error::the fixture frames were not written" >&2; exit 2; }

AWAITING='2026-08-14T10:00:00Z  INFO unyt::runtime: Status update: Starting -> LairAwaitingPassword { is_initial_setup: true }'
HEALTHY='2026-08-14T10:00:00Z  INFO unyt::runtime: Status update: LairReady -> HcAuthRequired { agent_key: "uhCAkAAAA", joining_service_url: "https://x" }'
FAILED='2026-08-14T10:00:00Z  INFO unyt::runtime: Status update: ConductorStarting -> ConductorError("boom")'

# ── the scenarios ─────────────────────────────────────────────────────────────
# Each in a subshell: prove_watch keeps its findings in globals, so a scenario
# that shared them with the next would prove nothing about either.
scenario() { # <name> <log> <frame|none> <alive:yes|no> <want-rc> <want-word>
  local name="$1" log="$2" frame="$3" alive="$4" want_rc="$5" want_word="$6"
  local out rc=0
  out="$(
    set +e
    # shellcheck source=proving-common.sh
    . "$here/proving-common.sh"
    PROVE_POLL=0
    PROVE_TIMEOUT=1
    PROVE_POST_SECONDS=0
    PROVE_MAX_SHOTS=2
    prove_python
    prove_init "$(mktemp -d)"
    prove_logs()  { printf '%s\n' "$log"; }
    prove_alive() { [ "$alive" = yes ]; }
    prove_capture() {
      [ "$frame" = none ] && return 1
      cp "$FIXTURES/$frame" "$PROVE_SHOTS_VERDICT/$1-window.png"
    }
    prove_watch >/dev/null 2>&1
    prove_verdict "lane" 2>/dev/null
    exit $?
  )" || rc=$?
  if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | grep -q ": $want_word"; then
    ok "$name"
  else
    bad "$name" "wanted rc=$want_rc '$want_word', got rc=$rc: $out"
  fi
}

scenario "the prompt is up and its window is the app" \
  "$AWAITING" app.png yes 0 "PROVEN"
scenario "a healthy backend behind the app's own screen" \
  "$HEALTHY" app.png yes 0 "PROVEN"
scenario "the prompt is up behind a blank window" \
  "$AWAITING" flat.png yes 1 "NOT PROVEN"
scenario "the prompt is up and the frame is somebody else's desktop" \
  "$AWAITING" wallpaper.png yes 1 "NOT PROVEN"
scenario "a painted screen the backend then failed behind" \
  "$FAILED" app.png yes 1 "NOT PROVEN"
scenario "the app exited before showing anything" \
  "" app.png no 1 "NOT PROVEN"
scenario "no state at all within the timeout" \
  "" app.png yes 1 "NOT PROVEN"
scenario "a window that could never be photographed" \
  "$AWAITING" none yes 2 "CANNOT PROVE"
scenario "frames that are not images" \
  "$AWAITING" tiny.png yes 2 "CANNOT PROVE"

# A painted frame with no state reached is HALF the answer, and half is not a pass.
scenario "a painted screen the log never accounted for" \
  "" app.png yes 1 "NOT PROVEN"

# ── an evidence source that is not a photograph ───────────────────────────────
# macOS gates on the window list rather than on pixels, by overriding
# prove_seek_evidence. The shared watch has to honour that — a loop that only
# ever believed a frame would report every macOS run as unproven.
evidence_case() { # <name> <log> <found:yes|no> <want-rc>
  local name="$1" log="$2" found="$3" want_rc="$4" out rc=0
  out="$(
    set +e
    # shellcheck source=proving-common.sh
    . "$here/proving-common.sh"
    PROVE_POLL=0
    PROVE_TIMEOUT=1
    PROVE_POST_SECONDS=0
    prove_python
    prove_init "$(mktemp -d)"
    prove_logs()  { printf '%s\n' "$log"; }
    prove_alive() { true; }
    prove_capture() { return 1; }
    prove_seek_evidence() {
      [ "$found" = yes ] || return 1
      PROVE_EVIDENCE="WINDOW 7 0 0 800 800 0 \"Unyt Sandbox\""
      return 0
    }
    prove_watch >/dev/null 2>&1
    rc=$?
    printf 'rc=%s evidence=%s\n' "$rc" "${PROVE_EVIDENCE:-<none>}"
    exit "$rc"
  )" || rc=$?
  if [ "$rc" = "$want_rc" ]; then ok "$name"; else bad "$name" "wanted rc=$want_rc, got rc=$rc ($out)"; fi
}

evidence_case "a window list is evidence the watch accepts" "$AWAITING" yes 0
evidence_case "no window means the watch is not satisfied" "$AWAITING" no 1
evidence_case "a window with no state is still not enough" "" yes 1

# ── a run must not inherit the last run's evidence ────────────────────────────
# The verdict passes if ANY frame is the app's, so a frame left in the directory
# by an earlier run would prove this artifact with the last one's screenshot.
stale_dir="$(mktemp -d)"
mkdir -p "$stale_dir/verdict"
cp "$FIXTURES/app.png" "$stale_dir/verdict/99-stale-window.png"
stale_rc=0
stale_out="$(
  set +e
  # shellcheck source=proving-common.sh
  . "$here/proving-common.sh"
  PROVE_POLL=0
  PROVE_TIMEOUT=1
  PROVE_POST_SECONDS=0
  prove_python
  prove_init "$stale_dir"
  prove_logs()    { printf '%s\n' "$AWAITING"; }
  prove_alive()   { true; }
  prove_capture() { return 1; }
  prove_watch >/dev/null 2>&1
  prove_verdict "lane" 2>/dev/null
  exit $?
)" || stale_rc=$?
if [ "$stale_rc" = 2 ] && printf '%s' "$stale_out" | grep -q "CANNOT PROVE"; then
  ok "a frame from an earlier run cannot prove this one"
else
  bad "a frame from an earlier run cannot prove this one" "wanted rc=2 CANNOT PROVE, got rc=$stale_rc: $stale_out"
fi
rm -rf "$stale_dir"

# ── a lane that dies still answers ────────────────────────────────────────────
# errexit can end a lane at any line. publish-verdict.sh would red it either way,
# but only the trap can say what killed it.
died_rc=0
died_out="$(
  set +e
  bash -c '
    set -euo pipefail
    . "'"$here"'/proving-common.sh"
    prove_arm_errors "lane"
    false
  ' 2>/dev/null
)" || died_rc=$?
if [ "$died_rc" != 0 ] && printf '%s' "$died_out" | grep -q '^VERDICT lane: CANNOT PROVE — this lane died at line'; then
  ok "a lane killed by errexit still prints a verdict"
else
  bad "a lane killed by errexit still prints a verdict" "rc=$died_rc: $died_out"
fi

answered_out="$(
  set +e
  bash -c '
    set -euo pipefail
    . "'"$here"'/proving-common.sh"
    prove_arm_errors "lane"
    prove_answer "lane" "PROVEN" "all good" 0
  ' 2>/dev/null
)" || true
if [ "$(printf '%s' "$answered_out" | grep -c '^VERDICT ')" = 1 ]; then
  ok "and an answered lane does not get a second verdict behind it"
else
  bad "and an answered lane does not get a second verdict behind it" "$answered_out"
fi

# ── the negative control ──────────────────────────────────────────────────────
control_case() { # <name> <frame|none> <want-rc> <want-word> [advisory]
  local name="$1" frame="$2" want_rc="$3" want_word="$4" advisory="${5:-}" out rc=0
  out="$(
    set +e
    # shellcheck source=proving-common.sh
    . "$here/proving-common.sh"
    prove_python
    prove_init "$(mktemp -d)"
    prove_control() {
      [ "$frame" = none ] && return 1
      cp "$FIXTURES/$frame" "$1"
    }
    prove_control_check "lane" "$advisory" 2>/dev/null
    exit $?
  )" || rc=$?
  if [ "$rc" = "$want_rc" ] && { [ -z "$want_word" ] || printf '%s' "$out" | grep -q ": $want_word"; }; then
    ok "$name"
  else
    bad "$name" "wanted rc=$want_rc '$want_word', got rc=$rc: $out"
  fi
}

control_case "a bare desktop before launch is a usable control" flat.png 0 ""
control_case "a wallpaper before launch is a usable control" wallpaper.png 0 ""
control_case "a control frame that already passes for the app" app.png 3 "UNTRUSTED"
control_case "a control frame nothing could capture" none 2 "CANNOT PROVE"
control_case "a control frame that is not an image" tiny.png 2 "CANNOT PROVE"

# `advisory` is how macOS runs it: the control still reports, but it cannot
# condemn a lane whose verdict never rested on a frame in the first place.
control_case "advisory: a frame that passes for the app only warns" app.png 0 "" advisory
control_case "advisory: nothing capturable only warns" none 0 "" advisory

# ── the step's colour ─────────────────────────────────────────────────────────
# publish-verdict.sh is the only thing that decides whether a job is green, so a
# bug here is a bug that turns every other assertion into decoration.
publish_case() { # <name> <verdict-line> <lane-rc> <want-rc>
  local name="$1" line="$2" lane_rc="$3" want_rc="$4" file rc=0
  file="$(mktemp)"
  printf '%s\n' "$line" >"$file"
  GITHUB_STEP_SUMMARY=/dev/null bash "$here/publish-verdict.sh" "$file" lane "$lane_rc" >/dev/null 2>&1 || rc=$?
  rm -f "$file"
  if [ "$rc" = "$want_rc" ]; then ok "$name"; else bad "$name" "wanted rc=$want_rc, got $rc"; fi
}

publish_case "a proven lane is the only green one" "VERDICT lane: PROVEN — all good" 0 0
publish_case "not proven is red" "VERDICT lane: NOT PROVEN — blank window" 1 1
publish_case "cannot prove is red" "VERDICT lane: CANNOT PROVE — no capture" 2 1
publish_case "untrusted is red" "VERDICT lane: UNTRUSTED — the desktop passes for the app" 3 1
publish_case "a lane saying PROVEN while exiting non-zero is red" "VERDICT lane: PROVEN — all good" 1 1
publish_case "a lane exiting 0 without saying PROVEN is red" "VERDICT lane: NOT PROVEN — blank" 0 1
publish_case "a lane that printed no verdict at all is red" "" 0 1
publish_case "a lane whose output is not a verdict is red" "some unrelated line" 0 1
publish_case "a lane that answered twice is red" \
  "VERDICT lane: PROVEN — all good
VERDICT lane: NOT PROVEN — blank" 0 1
publish_case "macOS's window-only verdict is green, and only with 0" \
  "VERDICT lane: WINDOW-ONLY — a window, no paint" 0 0
publish_case "a window-only verdict that exited non-zero is red" \
  "VERDICT lane: WINDOW-ONLY — a window, no paint" 1 1

# THE TWO WAYS THIS FILE USED TO FAIL OPEN, both found by review and both green
# before the fix.
# `[ "$CODE" -ne 0 ]` on a non-number is a USAGE ERROR, not a false comparison:
# test exits 2, the `if` takes its else branch and the guard is disarmed. The
# Windows lane hands this over $GITHUB_ENV, so one carriage return would do it.
for bad_code in 'abc' '0x0' ' 0' '1 ' ''; do
  publish_case "a non-numeric exit code '$bad_code' cannot pass for 0" \
    "VERDICT lane: PROVEN — all good" "$bad_code" 1
done
# The verdict word is read as a FIELD. Matched as text, an app log line quoted
# into the tail of a NOT PROVEN verdict turned the lane green — the exit code has
# to be 0 here, because that is the combination the substring match let through.
publish_case "a log line quoting the word does not make a red lane green" \
  "VERDICT lane: NOT PROVEN — the log never said: PROVEN was not reached" 0 1
publish_case "and the same line with a red exit code stays red" \
  "VERDICT lane: NOT PROVEN — the log never said: PROVEN was not reached" 1 1
publish_case "and it does not make a green lane red either" \
  "VERDICT lane: PROVEN — the log said: NOT PROVEN somewhere in it" 0 0

# ── the tally ─────────────────────────────────────────────────────────────────
echo ""
echo "load-proving regression: $pass passed, $fail failed"
# A floor, so deleting assertions fails as loudly as breaking one.
if [ "$((pass + fail))" -lt 42 ]; then
  echo "::error::only $((pass + fail)) cases ran — assertions were deleted" >&2
  exit 1
fi
[ "$fail" -eq 0 ]
