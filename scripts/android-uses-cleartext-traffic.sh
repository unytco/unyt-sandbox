#!/usr/bin/env bash
# Set manifestPlaceholders["usesCleartextTraffic"] to "true" in the Android app build.gradle.kts.
# Tauri's generator sets it to false; run this after any step that (re)generates gen/android, before Gradle build.
# Run from repo root.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GRADLE_KTS="$REPO_ROOT/src-tauri/gen/android/app/build.gradle.kts"

if [ ! -f "$GRADLE_KTS" ]; then
  echo "File not found: $GRADLE_KTS"
  exit 1
fi

# Replace false with true for usesCleartextTraffic (portable sed)
tmp=$(mktemp)
sed 's/manifestPlaceholders\["usesCleartextTraffic"\] = "false"/manifestPlaceholders["usesCleartextTraffic"] = "true"/g' "$GRADLE_KTS" > "$tmp"
mv "$tmp" "$GRADLE_KTS"
echo "Set usesCleartextTraffic to true in $GRADLE_KTS"
