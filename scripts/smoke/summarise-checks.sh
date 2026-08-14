#!/usr/bin/env bash
# The result table, and the guard that says every check actually reported.
#
#   summarise-checks.sh --label <label> --results <file> -- <print-checks command...>
#
# WHY THIS EXISTS AS ITS OWN THING. Each check is now its own CI step, and that
# buys visibility at the cost of a new way to be wrong: a check can stop
# happening. A step nobody wired up, a step someone deleted, a `--only` id that
# no longer resolves, a container that died half way — each of those produces a
# SHORTER table rather than a red one, and a shorter table is exactly as green as
# a clean one. Same family as every other defect in this suite: "nothing was
# checked" reading as "nothing wrong", reappearing one level further out.
#
# So the expected list is asked for, never repeated here: the command passed
# after `--` is the check script's own `--print-checks`, and anything it declares
# that has no row is a failure that names itself. Two rows for one check is the
# same failure wearing the other hat — a check wired up twice means some other
# check is not wired up at all.
#
# Rows are `<display name>|<verdict>`, which is what the check scripts append to
# UNYT_SMOKE_RESULTS. `warn` is a pass for the exit status and still prints as
# warn: it is the declared-state tripwire the Windows signing check uses, and a
# warn that failed the job would be a red people learn to scroll past.
set -uo pipefail

LABEL=""
RESULTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --label)   LABEL="${2:?--label needs a value}"; shift 2 ;;
    --results) RESULTS="${2:?--results needs a file}"; shift 2 ;;
    --) shift; break ;;
    *) echo "::error::unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$RESULTS" ] || { echo "::error::--results <file> is required" >&2; exit 2; }
[ $# -gt 0 ] || { echo "::error::a --print-checks command is required after --" >&2; exit 2; }

# FAILS CLOSED on an unreadable list. With no expected checks every row is
# unaccounted for and every absence is invisible, so the guard would report a
# clean table having compared against nothing.
declared="$("$@")" || {
  echo "::error::could not read the check list ($*) — refusing to report a table that was" >&2
  echo "  compared against nothing." >&2
  exit 2
}
# CARRIAGE RETURNS ARE STRIPPED FROM BOTH SIDES, and this is not cosmetic. On
# Windows the check list comes from `pwsh -PrintChecks` and the rows from
# PowerShell's Add-Content, and BOTH emit CRLF — while this comparison runs in
# git-bash. With the `\r` left on, every declared name ends in one and every
# verdict begins after one, so nothing ever matches and a flawless Windows run
# reports every single check as DID NOT RUN. Measured both ways: LF in, clean
# table; CRLF in, twelve false absences. Harmless on the platforms that never
# produce one.
declared="${declared//$'\r'/}"
if [ -z "$declared" ]; then
  echo "::error::the check list ($*) is empty, so nothing could be found missing" >&2
  exit 2
fi
[ -f "$RESULTS" ] || : >"$RESULTS"

status=0
printf '%-18s %-52s %s\n' "IMAGE" "CHECK" "RESULT"
while IFS=$'\t' read -r _ name; do
  [ -n "$name" ] || continue
  verdicts="$(tr -d '\r' <"$RESULTS" | awk -F'|' -v n="$name" '$1 == n { print $2 }')"
  count="$(printf '%s' "$verdicts" | grep -c . || true)"
  if [ "$count" -eq 0 ]; then
    printf '%-18s %-52s %s\n' "$LABEL" "$name" "DID NOT RUN"
    echo "::error::'$name' never reported on $LABEL — the check did not run, so nothing about" >&2
    echo "  it is known. A missing row is not a pass." >&2
    status=1
  elif [ "$count" -gt 1 ]; then
    printf '%-18s %-52s %s\n' "$LABEL" "$name" "REPORTED ${count}x"
    echo "::error::'$name' reported $count times on $LABEL — a check is wired up twice, which" >&2
    echo "  means some other check is probably not wired up at all." >&2
    status=1
  else
    printf '%-18s %-52s %s\n' "$LABEL" "$name" "$verdicts"
    case "$verdicts" in
      pass|warn) ;;
      *) status=1 ;;
    esac
  fi
done <<<"$declared"

exit "$status"
