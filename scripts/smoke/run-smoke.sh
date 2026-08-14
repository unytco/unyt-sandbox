#!/usr/bin/env bash
# Release install-smoke: does the artifact we shipped work on a user's machine?
#
#   run-smoke.sh <artifact.deb|artifact.AppImage> [image ...]
#   run-smoke.sh --print-images
#   run-smoke.sh --print-checks <artifact>
#   run-smoke.sh --print-computed-depends <artifact.deb> [image]
#
# and, one check at a time — what release-smoke.yaml drives so that each check is
# its own CI step, with UNYT_SMOKE_STATE naming a directory the four share:
#
#   run-smoke.sh --start <artifact> <image>   start a container for this artifact
#   run-smoke.sh --exec <check-id>            run ONE check in it
#   run-smoke.sh --summary                    the table, and the did-it-run guard
#   run-smoke.sh --stop                       tear the container down
#
# PRISTINE containers, not a CI runner: a runner already carries hundreds of
# libraries, so an under-declared dependency is satisfied there and the run goes
# green while a user's machine fails.
#
# Detached container + `docker exec`, NOT GitHub's job-level `container:` — that
# injects its own Node.js and tooling and the image stops being pristine.
#
# Needs only Docker. The whole-run path drives the same --start/--exec machinery.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── THE MATRIX ────────────────────────────────────────────────────────────────
# BOTH ENDS of the supported range, because they fail differently and each hides
# the other's bug: the OLD end catches a missing glibc floor (installs, dies at
# exec), the NEW end catches bundled libs colliding with the host's newer ones
# (tauri-apps/tauri#15665). Testing only the middle LTSs misses both — keep both
# ends when adding.
UNYT_SMOKE_IMAGES=(ubuntu:22.04 ubuntu:24.04 debian:13 ubuntu:26.04)

# release-smoke.yaml builds its matrix by ASKING for this list: a second copy in
# YAML would drift, and the workflow would silently stop testing an image.
if [ "${1:-}" = "--print-images" ]; then
  printf '%s\n' "${UNYT_SMOKE_IMAGES[@]}"
  exit 0
fi

# The two Linux bundles need different sequences: a .deb declares dependencies
# that apt must resolve, an AppImage declares nothing and bundles them instead.
driver_for() {
  case "$1" in
    *.deb)      printf 'container-checks.sh\n' ;;
    *.AppImage) printf 'container-checks-appimage.sh\n' ;;
    *) echo "::error::unsupported artifact '$1' (expected .deb or .AppImage)" >&2; return 1 ;;
  esac
}

abs_artifact() {
  local a="$1"
  [ -f "$a" ] || { echo "::error::artifact not found: $a" >&2; return 1; }
  printf '%s/%s\n' "$(cd "$(dirname "$a")" && pwd)" "$(basename "$a")"
}

# Everything the checks say about themselves comes from the driver, never from a
# list repeated here — same rule as the image matrix above.
print_checks() { bash "$here/$(driver_for "$1")" --print-checks; }

# ── the state directory ───────────────────────────────────────────────────────
# Shared by --start/--exec/--summary/--stop. Rows live on the HOST, so a
# container that dies still leaves what it had already reported.
STATE_ROOT="${UNYT_SMOKE_STATE:-}"
STATE_OWNED=""

need_state() {
  [ -n "$STATE_ROOT" ] || {
    echo "::error::UNYT_SMOKE_STATE must name a directory for --start/--exec/--summary/--stop" >&2
    return 2
  }
  mkdir -p "$STATE_ROOT" && touch "$STATE_ROOT/results"
}
need_docker() { command -v docker >/dev/null || { echo "::error::docker not found" >&2; return 1; }; }
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'; }
current_lane() { cat "$STATE_ROOT/current" 2>/dev/null || true; }

log_line() {
  printf '%s\n' "$1"
  [ -z "${UNYT_SMOKE_LOG:-}" ] || printf '%s\n' "$1" >>"$UNYT_SMOKE_LOG"
}

record_row() { # <artifact> <image> <name> <verdict>
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >>"$STATE_ROOT/results"
}

# ── start ─────────────────────────────────────────────────────────────────────
cmd_start() { # <artifact> <image>
  local artifact image driver lane out rc
  artifact="$(abs_artifact "${1:?usage: --start <artifact> <image>}")" || return 1
  image="${2:?usage: --start <artifact> <image>}"
  driver="$(driver_for "$artifact")" || return 1
  need_state || return $?

  lane="$STATE_ROOT/$(slug "$(basename "$artifact")")__$(slug "$image")"
  mkdir -p "$lane"
  rm -f "$lane/down"
  printf '%s\n' "$artifact" >"$lane/artifact"
  printf '%s\n' "$image"    >"$lane/image"
  printf '%s\n' "$driver"   >"$lane/driver"
  printf '%s\n' "$lane"     >"$STATE_ROOT/current"
  # Starting a lane clears it: a re-run would otherwise double every row, and
  # the guard reads a doubled row as a check wired up twice.
  if [ -s "$STATE_ROOT/results" ]; then
    awk -F'|' -v a="$(basename "$artifact")" -v i="$image" \
      '!($1 == a && $2 == i)' "$STATE_ROOT/results" >"$STATE_ROOT/results.keep"
    mv "$STATE_ROOT/results.keep" "$STATE_ROOT/results"
  fi
  grep -qxF "$(basename "$artifact")|$image|$driver" "$STATE_ROOT/lanes" 2>/dev/null ||
    printf '%s|%s|%s\n' "$(basename "$artifact")" "$image" "$driver" >>"$STATE_ROOT/lanes"

  log_line ""
  log_line "############################################################"
  log_line "# $image — $(basename "$artifact")"
  log_line "############################################################"

  if ! need_docker; then
    printf 'docker is not installed on this machine\n' >"$lane/down"
    return 1
  fi
  # --shm-size: WebKit needs more than Docker's 64MB default or the webview
  # process dies on start for reasons that look nothing like the real cause.
  out="$(docker run -d --shm-size=1g \
    -v "$artifact:/artifact/$(basename "$artifact"):ro" \
    -v "$here:/smoke:ro" \
    "$image" bash -c 'while :; do sleep 1; done' 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    # The lane is kept, with a reason: every check step then reports "did not
    # run, because <this>" instead of a pile of unrelated diagnoses.
    printf 'the %s container never started (docker exit %s): %s\n' "$image" "$rc" "$out" >"$lane/down"
    echo "::error::could not start a $image container (exit $rc): $out" >&2
    return 1
  fi
  printf '%s\n' "$out" >"$lane/cid"
  echo "  container ${out:0:12} up ($image)" >&2

  # Proven per container: an unreaped orphan keeps answering `kill -0`, and the
  # only symptom is the launch check calling a clean shutdown "hung".
  if ! docker exec "$out" bash -c '
      bash -c "sleep 0.2 & echo \$! >/tmp/orphan; exit 0"
      sleep 1
      ! kill -0 "$(cat /tmp/orphan)" 2>/dev/null
    ' >/dev/null 2>&1; then
    printf 'PID 1 in the %s container does not reap orphans\n' "$image" >"$lane/down"
    echo "::error::PID 1 in the $image container is not reaping orphaned processes, so an app" >&2
    echo "  that exits cleanly stays a zombie and the launch check reports it as hung. Whatever" >&2
    echo "  holds this container open has to reap — see the docker run above." >&2
    return 1
  fi
  return 0
}

# ── exec one check ────────────────────────────────────────────────────────────
container_state() { docker inspect -f "{{.State.$1}}" "$2" 2>/dev/null || true; }

cmd_exec() { # <check-id>
  local id lane artifact image driver cid name row verdict rc reason
  id="${1:?usage: --exec <check-id>}"
  need_state || return $?
  lane="$(current_lane)"
  [ -n "$lane" ] && [ -d "$lane" ] || {
    echo "::error::no smoke container has been started — run --start first" >&2
    return 2
  }
  artifact="$(cat "$lane/artifact")"; image="$(cat "$lane/image")"; driver="$(cat "$lane/driver")"
  name="$(bash "$here/$driver" --print-checks | awk -F'\t' -v i="$id" '$1 == i { print $2 }')"
  [ -n "$name" ] || { echo "::error::no such check in $driver: $id" >&2; return 2; }

  # A container that is already known to be gone. Reported once, as itself,
  # rather than re-diagnosed per step — the point is that the reader is looking
  # at one failure, not five.
  if [ -s "$lane/down" ]; then
    echo "::error::'$name' DID NOT RUN — $(cat "$lane/down")" >&2
    record_row "$(basename "$artifact")" "$image" "$name" "DID NOT RUN"
    return 1
  fi
  cid="$(cat "$lane/cid" 2>/dev/null || true)"
  if [ "$(container_state Running "$cid")" != true ]; then
    reason="the $image container is gone before this check ran (exit $(container_state ExitCode "$cid"))"
    printf '%s\n' "$reason" >"$lane/down"
    echo "::error title=Smoke container died::'$name' DID NOT RUN — $reason" >&2
    record_row "$(basename "$artifact")" "$image" "$name" "DID NOT RUN"
    return 1
  fi

  local -a run=(docker exec
    -e UNYT_SMOKE_STATE=/tmp/unyt-smoke-state
    -e UNYT_SMOKE_RESULTS=/tmp/unyt-smoke-state/results
    "$cid" bash "/smoke/$driver" --only "$id" "/artifact/$(basename "$artifact")")
  if [ -n "${UNYT_SMOKE_LOG:-}" ]; then
    "${run[@]}" 2>&1 | tee -a "$UNYT_SMOKE_LOG"
    rc=${PIPESTATUS[0]}
  else
    "${run[@]}"
    rc=$?
  fi

  # THE ROW IS READ BACK OUT OF THE CONTAINER, not taken from the exit status.
  row="$(docker exec "$cid" tail -n 1 /tmp/unyt-smoke-state/results 2>/dev/null || true)"
  if [ "${row%%|*}" != "$name" ]; then
    if [ "$(container_state Running "$cid")" != true ]; then
      reason="the $image container died while running '$name' (exit $(container_state ExitCode "$cid"))"
      printf '%s\n' "$reason" >"$lane/down"
      echo "::error title=Smoke container died::$reason" >&2
      record_row "$(basename "$artifact")" "$image" "$name" "DID NOT RUN"
    else
      echo "::error::'$name' reported no result row (driver exit $rc) — it did not complete, so" >&2
      echo "  there is no verdict to read. This is a broken check, not a passing one." >&2
      record_row "$(basename "$artifact")" "$image" "$name" "NO VERDICT"
    fi
    return 1
  fi
  verdict="${row##*|}"
  record_row "$(basename "$artifact")" "$image" "$name" "$verdict"
  [ "$verdict" = pass ]
}

# ── stop ──────────────────────────────────────────────────────────────────────
cmd_stop() {
  local lane cid
  need_state || return $?
  lane="$(current_lane)"
  [ -n "$lane" ] && [ -d "$lane" ] || return 0
  cid="$(cat "$lane/cid" 2>/dev/null || true)"
  [ -z "$cid" ] || docker rm -f "$cid" >/dev/null 2>&1 || true
  rm -f "$STATE_ROOT/current"
  return 0
}

# ── summary, and the did-it-run guard ─────────────────────────────────────────
# EVERY DECLARED CHECK MUST HAVE REPORTED, per started lane. One step per check
# makes a silently-missing check real, and each such case produces a SHORTER
# table rather than a red one.
cmd_summary() {
  local artifact image driver rows overall=0
  need_state || return $?
  [ -s "$STATE_ROOT/lanes" ] || {
    echo "::error::no smoke run was started, so there is nothing to summarise" >&2
    return 1
  }
  rows="$STATE_ROOT/lane-rows"
  # One table per lane, each guarded against the driver's OWN check list —
  # summarise-checks.sh is the single home for that comparison, so a lane that
  # went quiet reads the same here as it does on macOS and Windows.
  while IFS='|' read -r artifact image driver; do
    printf '\n##### %s on %s #####\n' "$artifact" "$image"
    awk -F'|' -v a="$artifact" -v i="$image" '$1 == a && $2 == i { print $3 "|" $4 }' \
      "$STATE_ROOT/results" >"$rows"
    bash "$here/summarise-checks.sh" --label "$image" --results "$rows" \
      -- bash "$here/$driver" --print-checks || overall=1
  done <"$STATE_ROOT/lanes"
  rm -f "$rows"
  [ "$overall" -eq 0 ] && printf '\nAll checks passed.\n'
  return "$overall"
}

# ── the whole run, locally ────────────────────────────────────────────────────
cmd_run() { # <artifact> [image ...]
  local artifact images image id rc=0
  artifact="$(abs_artifact "$1")" || return 1
  shift
  images=("$@")
  [ ${#images[@]} -gt 0 ] || images=("${UNYT_SMOKE_IMAGES[@]}")
  driver_for "$artifact" >/dev/null || return 1

  if [ -z "$STATE_ROOT" ]; then
    STATE_ROOT="$(mktemp -d)"
    STATE_OWNED=1
  fi
  mkdir -p "$STATE_ROOT"
  # Never leave a container behind on someone's laptop, whatever goes wrong.
  trap 'cmd_stop >/dev/null 2>&1; [ -z "$STATE_OWNED" ] || rm -rf "$STATE_ROOT"' EXIT INT TERM

  for image in "${images[@]}"; do
    cmd_start "$artifact" "$image" || rc=1
    while IFS=$'\t' read -r id _; do
      cmd_exec "$id" || rc=1
    done < <(print_checks "$artifact")
    cmd_stop
  done

  printf '\n############################################################\n'
  printf '# summary\n'
  printf '############################################################\n'
  cmd_summary || rc=1
  return "$rc"
}

# ── regeneration path for expected-deb-depends.txt ────────────────────────────
# Install into a throwaway container and print what dpkg-shlibdeps computes,
# nothing else.
cmd_print_computed_depends() { # <artifact.deb> [image]
  local artifact base image
  artifact="$(abs_artifact "${1:?usage: --print-computed-depends <artifact.deb> [image]}")" || return 1
  [ "$(driver_for "$artifact")" = container-checks.sh ] || {
    echo "::error::--print-computed-depends applies to a .deb only" >&2
    return 1
  }
  base="$(basename "$artifact")"
  image="${2:-${UNYT_SMOKE_IMAGES[0]}}"
  docker run --rm \
    -v "$artifact:/artifact/$base:ro" \
    -v "$here:/smoke:ro" \
    "$image" bash -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y "/artifact/'"$base"'" >/dev/null 2>&1
      apt-get install -y -qq binutils dpkg-dev >/dev/null 2>&1
      pkg=$(dpkg-deb -f "/artifact/'"$base"'" Package)
      bin=$(dpkg -L "$pkg" | grep -E "^/usr/bin/" | head -1)
      UNYT_SMOKE_PRINT_COMPUTED=1 bash /smoke/check-deb-depends.sh \
        "/artifact/'"$base"'" "$bin" 2>/dev/null
    '
}

case "${1:-}" in
  --print-checks)           shift; print_checks "${1:?usage: --print-checks <artifact>}" ;;
  --print-computed-depends) shift; need_docker && cmd_print_computed_depends "$@" ;;
  --start)                  shift; cmd_start "$@" ;;
  --exec)                   shift; need_docker && cmd_exec "$@" ;;
  --summary)                shift; cmd_summary "$@" ;;
  --stop)                   shift; need_docker && cmd_stop "$@" ;;
  "") echo "::error::usage: run-smoke.sh <artifact.deb|artifact.AppImage> [image ...]" >&2; exit 2 ;;
  -*) echo "::error::unknown option '$1'" >&2; exit 2 ;;
  *)                        cmd_run "$@" ;;
esac
exit $?
