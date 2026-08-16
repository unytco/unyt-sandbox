#!/usr/bin/env python3
"""Turn one lane's verdict line into the step's colour and its summary.

A LANE THAT PRINTED NO VERDICT IS RED: this whole exercise exists because steps
were going green without answering.

A verdict line is `VERDICT <lane>: <WORD> — <why>`, and only the WORD decides.
It is read as a FIELD by name — never matched as a substring, since the why
carries app log lines that could contain one of these words, and never located
by the em dash, since a runner reading that in the wrong code page would leave a
green lane unparseable.
"""

import os
import sys

# Two green words on purpose: in the Checks list a window-only lane and a
# photographed one would otherwise look identical.
GREEN = ("PROVEN", "WINDOW-ONLY")

# "NO ANSWER" is this file's own; every other word comes from a lane.
WORDS = (
    "CANNOT PROVE",
    "WINDOW-ONLY",
    "NOT PROVEN",
    "NO ANSWER",
    "UNTRUSTED",
    "PROVEN",
)


def verdict_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return [line.strip() for line in handle if line.startswith("VERDICT ")]
    except OSError:
        return []


def word_of(verdict):
    """The word a lane answered with. An unrecognised one is returned as it
    stands: it is not in GREEN, so a lane that invents a word goes red rather
    than being guessed at."""
    tail = verdict.split(": ", 1)[-1].strip()
    for word in WORDS:
        if tail == word or tail.startswith(word + " "):
            return word
    return tail.split(" —")[0].strip()


def publish(path, lane, code):
    lines = verdict_lines(path)
    if len(lines) > 1:
        # Reading the first would pick whichever it happened to print before the
        # one that mattered.
        print(
            "::error title=%s answered twice::%d verdict lines" % (lane, len(lines)),
            file=sys.stderr,
        )
        for line in lines:
            print("  " + line, file=sys.stderr)
        return (
            "VERDICT %s: NO ANSWER — the lane printed %d verdicts, so none of them is the answer"
            % (lane, len(lines)),
            1,
        )
    if not lines:
        return (
            "VERDICT %s: NO ANSWER — the lane exited %s without printing a verdict, so it proved nothing and reported nothing"
            % (lane, code),
            1,
        )

    verdict, word = lines[0], word_of(lines[0])
    # A code that is not a plain number must never be read as 0: the Windows lane
    # hands this over $GITHUB_ENV, so one stray carriage return is all it would
    # take.
    if not str(code).isdigit():
        print(
            "::error title=%s reported no usable exit code::'%s' is not a number"
            % (lane, code),
            file=sys.stderr,
        )
        return verdict, 1
    numeric = int(code)
    if word in GREEN and numeric != 0:
        print(
            "::error title=%s contradicts itself::it says %s and exited %d"
            % (lane, word, numeric),
            file=sys.stderr,
        )
        return verdict, 1
    if word in GREEN:
        if word == "WINDOW-ONLY":
            print(
                "::warning title=%s: not pixel-verified::the app launched and put a window on screen; whether the webview painted into it was NOT checked here"
                % lane,
                file=sys.stderr,
            )
        return verdict, 0
    if numeric == 0:
        print(
            "::error title=%s contradicts itself::it exited 0 saying '%s'"
            % (lane, word),
            file=sys.stderr,
        )
        return verdict, 1
    print(
        "::error title=%s: %s::%s" % (lane, word, verdict.split(" — ", 1)[-1]),
        file=sys.stderr,
    )
    return verdict, 1


def main(argv):
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    if len(argv) != 3:
        print(
            "::error::usage: publish_verdict.py <verdict-file> <lane> <exit-code>",
            file=sys.stderr,
        )
        return 2
    path, lane, code = argv
    verdict, status = publish(path, lane, code)
    print(verdict)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("### load proving — %s\n\n```\n%s\n```\n" % (lane, verdict))
            if word_of(verdict) == "WINDOW-ONLY":
                handle.write(
                    "NOT PIXEL-VERIFIED — this lane checked that a window exists, not that anything was drawn in it.\n"
                )
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
