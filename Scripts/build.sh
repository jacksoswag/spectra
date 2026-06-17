#!/bin/bash
# Regenerate the Xcode project, clean-build, INSTALL to /Applications, and relaunch.
#
# Clean build (deliberate): regenerating with xcodegen confused incremental builds into
# reusing stale objects ("BUILD SUCCEEDED" with an unchanged binary). A clean build is
# slower but guarantees the binary matches the source.
#
# Install-to-/Applications + relaunch (added 2026-06-17): xcodebuild writes the product into
# DerivedData, but the app was being launched from a stale ./build/Debug copy that nothing
# updated, so rebuilds appeared to "do nothing." Worse, ad-hoc TCC grants (Screen Recording,
# Input Monitoring) are keyed to the bundle path, so running from a shifting path kept losing
# permission. Now the freshly-built binary always replaces /Applications/Spectra.app and is
# relaunched: one authoritative copy at one stable path, so permissions stick and "rebuild"
# always runs what you just compiled.
set -o pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null 2>&1 || { echo "xcodegen failed"; exit 1; }

xcodebuild -project Spectra.xcodeproj -scheme Spectra -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO ENABLE_PREVIEWS=NO \
  clean build 2>&1 \
  | grep -E "error:|warning: .*unused|BUILD (SUCCEEDED|FAILED)"
status=${PIPESTATUS[0]}
echo "build exit: $status"
[ "$status" -eq 0 ] || exit "$status"

# Locate the freshly-built product (DerivedData path, resolved from the build settings).
PRODUCTS=$(xcodebuild -project Spectra.xcodeproj -scheme Spectra -configuration Debug \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/{print $2; exit}')
SRC="$PRODUCTS/Spectra.app"
DST="/Applications/Spectra.app"
if [ ! -d "$SRC" ]; then echo "ERROR: built app not found at: $SRC"; exit 1; fi

pkill -x Spectra 2>/dev/null
sleep 1
rm -rf "$DST"
cp -R "$SRC" "$DST"
# Centralize on ONE app: drop the old stale local copy AND the DerivedData product, so
# /Applications/Spectra.app is the only launchable copy (no "debug vs application" duplicate).
rm -rf "./build/Debug/Spectra.app"
rm -rf "$SRC"
open "$DST"
echo "installed + launched (only copy): $DST"
