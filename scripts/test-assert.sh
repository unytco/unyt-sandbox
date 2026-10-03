#!/usr/bin/env bash
# Sourced by the script tests, never run.

pass=0
fail=0

check() { # <description> <command...>
  local what="$1"
  shift
  if "$@"; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    echo "FAIL  $what" >&2
  fi
}
refuses() { # <error text> <command...>
  local want="$1" out
  shift
  if out="$("$@" 2>&1)"; then return 1; fi
  [[ "$out" == *"$want"* ]]
}
report() { # <suite>
  echo "$1: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}
