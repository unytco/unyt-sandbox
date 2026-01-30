#!/usr/bin/env bash
# Copy per-variant icons into src-tauri/icons/ so the active app uses the right icons.
# Run from repo root. Set TAURI_APP_VARIANT (e.g. unyt-sandbox, holo-hosting).
# Uses src-tauri/icons/<variant>/ if it exists; otherwise falls back to src-tauri/icons/default/.
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
DEFAULT="$ICONS/default"
if [ -d "$SRC" ]; then
  SOURCE="$SRC"
  echo "Using variant icons: $SOURCE"
elif [ -d "$DEFAULT" ]; then
  SOURCE="$DEFAULT"
  echo "Variant icon dir not found ($SRC), using default: $SOURCE"
else
  echo "Variant icon dir not found: $SRC and default not found: $DEFAULT (TAURI_APP_VARIANT=$VARIANT)"
  exit 1
fi

# Copy icon set into icons root (no --delete so we keep variant subdirs)
rsync -a "$SOURCE/" "$ICONS/"
echo "Copied icons from $SOURCE to $ICONS"
