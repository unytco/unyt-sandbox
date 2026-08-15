#!/usr/bin/env bash
# What is actually on a release, as $GITHUB_OUTPUT lines:
#   release-inventory.sh <release-id-or-tag>
# Lanes gate on these, so a platform whose build failed skips instead of running
# checks that all report "the file isn't there".
# Env: GH_TOKEN, UNYT_SMOKE_REPO. UNYT_SMOKE_ASSETS (newline list of names)
# answers from itself instead of the API — how test-oracle.sh drives this.
set -euo pipefail

REF="${1:?usage: release-inventory.sh <release-id-or-tag>}"
REPO="${UNYT_SMOKE_REPO:-${GITHUB_REPOSITORY:-unytco/unyt-sandbox}}"

# Keep these in lockstep with the suffixes the phase-2 lanes pass to
# download-release-asset.sh; a typo here silently skips a lane forever, which is
# the failure this whole file exists to prevent. test-oracle.sh asserts each one
# appears in the workflow. The phase-1 lanes cannot drift the same way — they
# take their suffix from the matrix rows below, which is the same string this
# file tested for presence.
DEB_SUFFIX="linux.deb"
APPIMAGE_SUFFIX="linux.AppImage"
EXE_SUFFIX="x64_windows.exe"
MSI_SUFFIX="x64_windows.msi"

# runner<TAB>arch<TAB>asset-suffix — the macOS matrix, filtered below to the DMGs
# that exist. Each arch needs its own runner: a check runs the bundle it just
# downloaded. Both phases use it.
#
# PINNED IMAGES, never macos-latest: an image rollover would change what a
# release gate tests with no commit to point at. The BUILD deliberately rides
# macos-latest, so these lanes install on an older macOS than built the artifact
# — release-smoke.yaml's header says why that gap is the useful one.
MACOS_ROWS="macos-15	aarch64	aarch64_darwin.dmg
macos-15-intel	x86_64	x64_darwin.dmg"

# kind<TAB>asset-suffix — phase 1's Linux lanes. ONE LANE PER INSTALLER, not one
# per platform: the .deb and the AppImage install differently, so proving one
# proves nothing about the other. The suffixes are the constants above, not
# copies of them: written out by hand they would be a second home, and changing
# one would leave phase 2 calling an artifact absent while phase 1 still built a
# lane for it.
LINUX_PROVE_ROWS="deb	$DEB_SUFFIX
appimage	$APPIMAGE_SUFFIX"

# runner<TAB>kind<TAB>asset-suffix — phase 1's Windows lanes.
#
# THREE LANES, NOT FOUR, and the asymmetry is deliberate. The two images answer
# an OS-VERSION question, and they have answered it identically — 50.00% dominant
# over 1847 distinct colours on windows-2022 against 50.86% over 1881 on
# windows-2025, for the same frame of the same installer. The .msi answers an
# ARTIFACT question instead: a per-machine install into Program Files rather than
# a per-user one under %LOCALAPPDATA%, registered per-machine, with its own
# product version. Running it on both images would re-measure the OS delta at the
# cost of a runner rather than cover anything the .exe pair does not, so it runs
# on the newer image alone — where a policy or path difference shows up first.
WINDOWS_PROVE_ROWS="windows-2022	nsis	$EXE_SUFFIX
windows-2025	nsis	$EXE_SUFFIX
windows-2025	msi	$MSI_SUFFIX"

if [ -n "${UNYT_SMOKE_ASSETS+set}" ]; then
  assets="$UNYT_SMOKE_ASSETS"
else
  command -v gh >/dev/null || { echo "::error::gh CLI not found" >&2; exit 1; }
  if [[ "$REF" =~ ^[0-9]+$ ]]; then
    release_id="$REF"
  else
    release_id="$(gh api "repos/$REPO/releases?per_page=100" --paginate \
      --jq "[.[] | select(.tag_name == \"$REF\") | .id] | first // empty")"
    if [ -z "$release_id" ]; then
      echo "::error::no release tagged '$REF' in $REPO (drafts included — check the token's access)" >&2
      exit 1
    fi
  fi
  assets="$(gh api "repos/$REPO/releases/$release_id" --jq '.assets[].name')"
fi

# A case glob, not a regex: every suffix contains a `.`, which as an ERE metacharacter matches any
# character, so `linux.deb` would also answer true for an asset ending `linuxXdeb`.
has() {
  local name
  while IFS= read -r name; do
    case "$name" in
      *"$1") echo true; return ;;
    esac
  done <<<"$assets"
  echo false
}

deb="$(has "$DEB_SUFFIX")"
appimage="$(has "$APPIMAGE_SUFFIX")"
exe="$(has "$EXE_SUFFIX")"
msi="$(has "$MSI_SUFFIX")"

# Tab-separated rows on stdin into a `matrix.include` array, keeping only the
# rows whose asset the release carries. The LAST field is always that asset
# suffix; $1 names the fields in order. One function for all three matrices —
# three hand-written loops would drift from each other and from has().
matrix_of() { # <key,key,…>
  local json="[" row i n
  local -a keys fields
  IFS=',' read -r -a keys <<<"$1"
  n=${#keys[@]}
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r -a fields <<<"$row"
    # A row that lost a field would otherwise emit an object missing a key the
    # matrix reads, and the lane would run with an empty runner or suffix.
    [ "${#fields[@]}" -eq "$n" ] || {
      echo "::error::matrix row has ${#fields[@]} fields, expected $n ($1): $row" >&2
      return 1
    }
    [ "$(has "${fields[$((n - 1))]}")" = true ] || continue
    [ "$json" = "[" ] || json="$json,"
    json="$json{"
    i=0
    while [ "$i" -lt "$n" ]; do
      [ "$i" -eq 0 ] || json="$json,"
      json="$json\"${keys[$i]}\":\"${fields[$i]}\""
      i=$((i + 1))
    done
    json="$json}"
  done
  printf '%s]' "$json"
}

dmgs="$(matrix_of runner,arch,asset <<<"$MACOS_ROWS")"
prove_linux="$(matrix_of kind,suffix <<<"$LINUX_PROVE_ROWS")"
prove_windows="$(matrix_of runner,kind,suffix <<<"$WINDOWS_PROVE_ROWS")"

{
  echo "deb=$deb"
  echo "appimage=$appimage"
  echo "exe=$exe"
  echo "msi=$msi"
  echo "dmgs=$dmgs"
  echo "prove_linux=$prove_linux"
  echo "prove_windows=$prove_windows"
} | tee /dev/stderr

# A release with NOTHING on it is a broken release, not an empty one — say so
# rather than skipping every lane and leaving a green run that smoked nothing.
if [ "$deb$appimage$exe$msi$dmgs" = "falsefalsefalsefalse[]" ]; then
  echo "::error::release '$REF' carries none of the installers this suite knows how to smoke — every lane would skip and the run would pass having checked nothing"
  exit 1
fi

# AND THE SAME FAILURE ONE ARTIFACT AT A TIME, which the guard above cannot see:
# the tests are exact suffixes, so a build that renames its arch or platform
# token — those come from tauri-action's assetNamePattern in
# release-tauri-app.yaml, not from here — reports THAT artifact absent while the
# others still match. Its lane then stops existing, on this release and every
# later one, with nothing red to say so. So anything shaped like an installer
# that no suffix claimed is treated as a rename. Adding an artifact type to the
# release means adding a suffix here, and until it does the release is red.
unclaimed=""
while IFS= read -r name; do
  case "$name" in
    *"$DEB_SUFFIX" | *"$APPIMAGE_SUFFIX" | *"$EXE_SUFFIX" | *"$MSI_SUFFIX") continue ;;
    # Not an installer at all: the .happ, the .dna, the updater bundles and their
    # signatures all end elsewhere.
    *.deb | *.AppImage | *.exe | *.msi | *.dmg) ;;
    *) continue ;;
  esac
  # The DMGs are claimed by MACOS_ROWS rather than by a constant of their own.
  claimed=false
  while IFS=$'\t' read -r _ _ suffix; do
    case "$name" in *"$suffix") claimed=true ;; esac
  done <<<"$MACOS_ROWS"
  [ "$claimed" = true ] || unclaimed="${unclaimed:+$unclaimed }$name"
done <<<"$assets"
if [ -n "$unclaimed" ]; then
  echo "::error::release '$REF' carries installer(s) no lane knows how to smoke: $unclaimed — a renamed asset reads as an absent one, so its lane would silently stop running"
  exit 1
fi
