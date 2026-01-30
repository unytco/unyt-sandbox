#!/usr/bin/env bash
# Generate src-tauri/tauri.conf.json from template using env vars.
# Run from repo root. Set TAURI_PRODUCT_NAME, TAURI_APP_IDENTIFIER, TAURI_DEEP_LINK_SCHEME
# (and optionally TAURI_SPLASHSCREEN_TITLE, TAURI_APP_VARIANT). Defaults = current app (Unyt-tx5 / co.unyt.tx5.sandbox).
# MAIN_BINARY_NAME is set from TAURI_APP_VARIANT so Linux .deb icon/desktop names are unique per variant.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_TAURI="$REPO_ROOT/src-tauri"
TEMPLATE="$SRC_TAURI/tauri.conf.template.json"
OUT="$SRC_TAURI/tauri.conf.json"

PRODUCT_NAME="${TAURI_PRODUCT_NAME:-Unyt-tx5}"
IDENTIFIER="${TAURI_APP_IDENTIFIER:-co.unyt.tx5.sandbox}"
DEEP_LINK_SCHEME="${TAURI_DEEP_LINK_SCHEME:-unyt-tx5}"
SPLASHSCREEN_TITLE="${TAURI_SPLASHSCREEN_TITLE:-Unyt Loading}"
MAIN_BINARY_NAME="${TAURI_APP_VARIANT:-unyt-sandbox}"

sed -e "s|{{PRODUCT_NAME}}|$PRODUCT_NAME|g" \
    -e "s|{{IDENTIFIER}}|$IDENTIFIER|g" \
    -e "s|{{DEEP_LINK_SCHEME}}|$DEEP_LINK_SCHEME|g" \
    -e "s|{{SPLASHSCREEN_TITLE}}|$SPLASHSCREEN_TITLE|g" \
    -e "s|{{MAIN_BINARY_NAME}}|$MAIN_BINARY_NAME|g" \
    "$TEMPLATE" > "$OUT"
echo "Generated $OUT (productName=$PRODUCT_NAME, identifier=$IDENTIFIER, mainBinaryName=$MAIN_BINARY_NAME)"
