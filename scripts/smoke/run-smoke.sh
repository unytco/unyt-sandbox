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
# Runs the check sequence in a PRISTINE container per image and prints one table
# per artifact. The image list is UNYT_SMOKE_IMAGES below — one place, with the
# reasoning for what it spans.
#
# Containers rather than a CI runner, deliberately. A GitHub runner is a build
# image carrying hundreds of preinstalled libraries, so an under-declared
# dependency is already satisfied there and the run goes green while a real
# user's machine fails. A stock distro image is both more faithful and runnable
# on a laptop, which is what makes this iterable.
#
# A DETACHED CONTAINER PLUS `docker exec`, AND NOT GitHub's job-level
# `container:` key. That key would make one-step-per-check trivial and would
# quietly destroy the only thing this lane is for: GitHub injects its own
# Node.js and tooling into a job container so it can run actions inside it, so
# the image stops being pristine — and pristineness is exactly what catches a
# package that under-declares its dependencies. Here the runner's tooling stays
# outside and the container gets `sleep infinity` and nothing else.
#
# The whole-run path drives the same --start/--exec/--summary/--stop machinery,
# so local iteration and CI exercise one mechanism rather than two.
#
# Needs only Docker on the host — no drivers, no display, nothing installed.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── THE MATRIX ────────────────────────────────────────────────────────────────
# One list, deliberately spanning BOTH ends of the supported range, because the
# two ends fail differently and each hides the other's bug:
#
#   OLD end  — the glibc floor. A binary built on a newer host imports symbols the
#              old runtime lacks; it installs cleanly and dies at exec. This is
#              also where the .deb's missing `libc6 (>= 2.34)` actually bites.
#   NEW end  — library conflicts. Bundled copies of libwayland/glib/gstreamer
#              collide with the host's newer ones (tauri-apps/tauri#15665), which
#              only shows up on a distro newer than the build machine.
#
# Testing only the LTSs in the middle would miss both. Keep both ends when adding.
#
#   ubuntu:22.04  glibc 2.35  our support floor
#   ubuntu:24.04  glibc 2.39  previous LTS, large install base
#   debian:13     glibc 2.41  current Debian stable
#   ubuntu:26.04  glibc 2.43  current Ubuntu LTS, and what `ubuntu:latest` resolves to
#
# debian:12 (2.36) was dropped: it sits between the two Ubuntu LTSs and exercises
# nothing they don't.
UNYT_SMOKE_IMAGES=(ubuntu:22.04 ubuntu:24.04 debian:13 ubuntu:26.04)

# THE MATRIX, READABLE FROM OUTSIDE. release-smoke.yaml runs one job per image
# and builds that matrix by asking this script, rather than repeating the list in
# YAML — two copies of it would drift the moment someone adds a distro here and
# not there, and the drift would be invisible: the workflow would simply stop
# testing the image nobody remembered to add. Declared once, below; read here.
# Deliberately before the artifact argument is required, since listing the matrix
# needs no artifact.
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
# One per run, shared by --start/--exec/--summary/--stop. It holds the container
# id, what is being smoked, and the rows earned so far. The rows live on the HOST
# rather than only in the container, so a container that dies still leaves behind
# everything it had already reported.
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
  # STARTING A LANE CLEARS IT. Rows and the lane entry are both keyed on
  # (artifact, image), so starting the same one twice — a re-run after a failure
  # — would otherwise leave every check reported twice, and the guard reads a
  # doubled row as "one check is wired up twice", which is a red run for a
  # perfectly good re-run.
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
  #
  # PID 1 IS A BASH LOOP, AND `sleep infinity` IS WRONG HERE. Something has to
  # hold the container open between execs, and the obvious choice does not reap:
  # when the app is orphaned (xvfb-run exits first) it is reparented to PID 1,
  # and under `sleep` it stays a ZOMBIE — whose pid still answers `kill -0`. The
  # launch check's `alive()` is that exact test, so a perfectly clean shutdown
  # reported as "still running 30s after SIGTERM — hung on shutdown". Measured,
  # not reasoned: under `sleep infinity` the orphan sits in state `Z`, under a
  # bash loop it is reaped. This is what PID 1 already was before the run was
  # split into one exec per check (the driver script itself), so the loop
  # restores the old behaviour rather than compensating for it.
  #
  # `--init` fixes it too, and is deliberately NOT used: it bind-mounts the
  # host's tini into the container, and host tooling inside the image is the one
  # thing this lane may not have — the same reason the job-level `container:` key
  # is refused. A loop built from the image's own bash injects nothing.
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

  # PROVEN, NOT ASSUMED, per container. An orphan left unreaped keeps answering
  # `kill -0`, and the only symptom is the launch check calling a clean shutdown
  # "hung" — a diagnosis that reads as a defect in the app and takes an afternoon
  # to trace back to this line. A second here is cheaper than that, and it is
  # what stops PID 1 being "simplified" back to `sleep infinity`.
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
  # The status alone cannot tell a check that went red from a driver that died
  # before reaching a verdict, and those must never look the same — the whole
  # suite exists because "nothing was checked" kept reading as "nothing wrong".
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
# EVERY CHECK THE DRIVER DECLARES MUST HAVE REPORTED, for every lane that was
# started. Splitting the run into one step per check makes a check that silently
# stopped existing a real possibility — a step nobody wired up, a step someone
# deleted, a container that died half way — and each of those produces a shorter
# table rather than a red one. The old shape of this guard ("no result rows at
# all") only caught the case where nothing ran; this catches the case where
# almost everything did.
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
