#!/usr/bin/env bash
# Copy per-variant icons into src-tauri/icons/ so the active app uses the right icons.
# Run from repo root. Set TAURI_APP_VARIANT to unyt-sandbox or holo-hosting.
# Expects src-tauri/icons/<variant>/ (e.g. icons/unyt-sandbox/, icons/holo-hosting/).
# If TAURI_APP_VARIANT unset, does nothing.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_TAURI="$REPO_ROOT/src-tauri"
ICONS="$SRC_TAURI/icons"
VARIANT="${TAURI_APP_VARIANT:-}"

if [ -z "$VARIANT" ]; then
  echo "TAURI_APP_VARIANT not set, skipping icon copy"
  exit 0
fi

SRC="$ICONS/$VARIANT"
if [ ! -d "$SRC" ]; then
  echo "Variant icon dir not found: $SRC (TAURI_APP_VARIANT=$VARIANT)"
  exit 1
fi

# Copy variant set into icons root (no --delete so we keep icons/unyt-sandbox/ and icons/holo-hosting/)
rsync -a "$SRC/" "$ICONS/"
echo "Copied icons from $SRC to $ICONS"
