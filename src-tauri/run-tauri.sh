#!/usr/bin/env bash

# Tauri AT-SPI Safe Runner
# This script prevents AT-SPI symbol conflicts when running Tauri apps
# without causing GLIBC version mismatches

# Completely disable accessibility and AT-SPI
export NO_AT_BRIDGE=1
export GTK_A11Y=none
export ACCESSIBILITY_ENABLED=0
export DISABLE_ACCESSIBILITY=1
export ATK_BRIDGE_DISABLE=1

# Disable WebKit problematic features
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export GDK_BACKEND=x11

# Additional AT-SPI blocking environment variables
export QT_ACCESSIBILITY=0
export GNOME_ACCESSIBILITY=0
export GTK_MODULES=""

# Create a stub for the problematic library using a different approach
# Instead of trying to replace the library, we'll prevent it from loading
export LIBATK_BRIDGE_DISABLE=1

# Run the command with all AT-SPI completely disabled
echo "Running Tauri with AT-SPI completely disabled..."
echo "Environment configured to prevent library conflicts..."

# Execute the command
exec "$@" 