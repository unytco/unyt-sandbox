#!/usr/bin/env bash
# The result table, and the guard that says every check actually reported.
#
#   summarise-checks.sh --label <label> --results <file> -- <print-checks command...>
#
# One step per check buys visibility at the cost of a check being able to stop
# HAPPENING, and every way that occurs produces a SHORTER table — exactly as
# green as a clean one. So the expected list is asked for (the `--print-checks`
# command after `--`), never repeated here.
#
# `warn` passes the exit status and still prints as warn: it is the Windows
# signing tripwire, and a warn that failed the job is a red people scroll past.
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

# FAILS CLOSED on an unreadable list: with no expected checks every absence is
# invisible, and the guard would report a clean table having compared nothing.
declared="$("$@")" || {
  echo "::error::could not read the check list ($*) — refusing to report a table that was" >&2
  echo "  compared against nothing." >&2
  exit 2
}
# CRs stripped from BOTH sides: on Windows the list and the rows both come from
# PowerShell as CRLF while this runs in git-bash, and unstripped a flawless run
# reports every check as DID NOT RUN.
declared="${declared//$'\r'/}"
if [ -z "$declared" ]; then
  echo "::error::the check list ($*) is empty, so nothing could be found missing" >&2
  exit 2
fi
[ -f "$RESULTS" ] || : >"$RESULTS"

status=0

# The table below reads a row's SECOND field and nothing else, so
# `name|pass|whatever` would print the pass it did not earn; and a row naming a
# check that no longer exists is never looked up, so a rename drops it silently.
declared_names=""
while IFS=$'\t' read -r _ name; do
  [ -n "$name" ] && declared_names="$declared_names$name"$'\n'
done <<<"$declared"

# Collected for the table below: an annotation does not stop a `pass` in the
# RESULT column, which is the part a reader scans, being believed.
malformed_names=""
reject() { # <name> <reason...>
  echo "::error::${*:2}" >&2
  [ -n "$1" ] && malformed_names="$malformed_names$1"$'\n'
  status=1
}
# `|| [ -n "$row" ]`: read drops an unterminated final line, and the awk below does not — so the
# last check on the lane would go into the table unvetted.
while IFS= read -r row || [ -n "$row" ]; do
  [ -n "$row" ] || continue
  IFS='|' read -r row_name row_verdict <<<"$row"
  # Field COUNT, not "is the third empty": `name|pass|` leaves the third unset and rode through.
  case "$row" in
    *'|'*'|'*) reject "$row_name" "malformed result row on $LABEL: '$row' — expected exactly <check>|<verdict>"; continue ;;
  esac
  if [ -z "$row_name" ] || [ -z "$row_verdict" ]; then
    reject "$row_name" "malformed result row on $LABEL: '$row' — expected exactly <check>|<verdict>"
    continue
  fi
  case "$row_verdict" in
    pass | warn | FAIL) ;;
    *)
      reject "$row_name" "'$row_name' on $LABEL reported the verdict '$row_verdict' — expected pass, warn or FAIL"
      continue
      ;;
  esac
  printf '%s' "$declared_names" | grep -qxF -- "$row_name" || {
    echo "::error::'$row_name' reported on $LABEL but no check declares it — the result contract and" >&2
    echo "  the check list have drifted, so some check is reporting under a name nobody reads." >&2
    status=1
  }
done < <(tr -d '\r' <"$RESULTS")

printf '%-18s %-52s %s\n' "IMAGE" "CHECK" "RESULT"
while IFS=$'\t' read -r _ name; do
  [ -n "$name" ] || continue
  verdicts="$(tr -d '\r' <"$RESULTS" | awk -F'|' -v n="$name" '$1 == n { print $2 }')"
  count="$(printf '%s' "$verdicts" | grep -c . || true)"
  if printf '%s' "$malformed_names" | grep -qxF -- "$name"; then
    # Ahead of the count: an empty verdict is one defect, not also a check that never reported.
    printf '%-18s %-52s %s\n' "$LABEL" "$name" "MALFORMED"
  elif [ "$count" -eq 0 ]; then
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
