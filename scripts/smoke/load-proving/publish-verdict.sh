#!/usr/bin/env bash
# Turn one lane's verdict line into the step's colour and its summary.
#
#   publish-verdict.sh <verdict-file> <lane> <lane-exit-code>
#
# TEMPORARY — scaffolding for .github/workflows/zz-TEMPORARY-load-proving.yaml.
#
# One home for the mapping, so all six jobs conclude the same way. A LANE THAT
# PRINTED NO VERDICT IS RED: this whole exercise exists because steps were going
# green without answering, and a silent lane is exactly that failure.
#
# A verdict line is `VERDICT <lane>: <WORD> — <why>`. Only the WORD decides, and
# it is read as a FIELD, never matched as text: `state_note` and `screen_note`
# carry app log lines and analyser output into the tail of that line, so a
# substring match would let a log line reading "PROVEN" turn a red lane green.
set -uo pipefail

# Git Bash resolves a forward-slash path; `D:\a\_temp\x` it would create as a
# file with backslashes in its name, in whatever the current directory is.
FILE="${1:?usage: publish-verdict.sh <verdict-file> <lane> <exit-code>}"
FILE="${FILE//\\//}"
LANE="${2:?lane name required}"
CODE="${3:?the exit code of the lane is required}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
SUMMARY="${SUMMARY//\\//}"

# `[ "$CODE" -ne 0 ]` on a non-numeric CODE is a USAGE ERROR, not a false
# comparison: test exits 2, the `if` takes its else branch and the contradiction
# guard below is disarmed. The Windows lane hands this over $GITHUB_ENV, so one
# stray carriage return is all it would take.
case "$CODE" in
  '' | *[!0-9]*)
    echo "::error title=$LANE reported no usable exit code::'$CODE' is not a number" >&2
    CODE=99 ;;
esac

verdict="$(grep -m1 '^VERDICT ' "$FILE" 2>/dev/null || true)"
count="$(grep -c '^VERDICT ' "$FILE" 2>/dev/null || true)"

# Two verdicts is a lane that answered twice, and reading the first would pick
# whichever it happened to print before the one that mattered.
if [ "${count:-0}" -gt 1 ]; then
  echo "::error title=$LANE answered twice::$count verdict lines, so which one is the answer is not decidable" >&2
  grep '^VERDICT ' "$FILE" | sed 's/^/  /' >&2
  verdict="VERDICT $LANE: NO ANSWER — the lane printed $count verdicts, so none of them can be taken as the answer"
  CODE=2
fi

if [ -z "$verdict" ]; then
  verdict="VERDICT $LANE: NO ANSWER — the lane exited $CODE without printing a verdict, so it proved nothing and reported nothing"
  echo "::error title=$LANE answered nothing::the lane exited $CODE and printed no verdict line" >&2
  CODE=2
fi

# The word between the first ": " and the em dash, and nothing else.
word="${verdict#*": "}"
word="${word%% —*}"

printf '%s\n' "$verdict"
{
  printf '### load proving — %s\n\n' "$LANE"
  # shellcheck disable=SC2016  # a markdown fence, not an expansion
  printf '```\n%s\n```\n' "$verdict"
} >>"$SUMMARY"

# 0 is the ONLY pass, and it has to agree with the words: a lane that exits 0
# while saying anything else is a broken lane, not a passing one.
case "$word" in
  PROVEN)
    if [ "$CODE" != 0 ]; then
      echo "::error title=$LANE contradicts itself::it says PROVEN and exited $CODE" >&2
      exit 1
    fi
    exit 0 ;;
  # macOS. Green, because the app did launch and did put a window up — but never
  # the same word as a lane that photographed the screen, because the Checks list
  # is where this gets read and there the two would be indistinguishable.
  WINDOW-ONLY)
    if [ "$CODE" != 0 ]; then
      echo "::error title=$LANE contradicts itself::it says WINDOW-ONLY and exited $CODE" >&2
      exit 1
    fi
    echo "::warning title=$LANE: not pixel-verified::the app launched and put a window on screen; whether the webview painted into it was NOT checked here" >&2
    printf 'NOT PIXEL-VERIFIED — this lane checked that a window exists, not that anything was drawn in it.\n' >>"$SUMMARY"
    exit 0 ;;
esac

if [ "$CODE" = 0 ]; then
  echo "::error title=$LANE contradicts itself::it exited 0 saying '$word'" >&2
  exit 1
fi

case "$CODE" in
  1) echo "::error title=$LANE: NOT PROVEN::the app did not put a first screen on screen here" >&2 ;;
  2) echo "::error title=$LANE: CANNOT PROVE::nothing could be captured on this runner — see the frames artifact" >&2 ;;
  3) echo "::error title=$LANE: UNTRUSTED::the capture path photographs something that passes for the app even with the app not running, so no verdict from this runner means anything" >&2 ;;
  *) echo "::error title=$LANE failed unexpectedly::exit $CODE" >&2 ;;
esac
exit 1
