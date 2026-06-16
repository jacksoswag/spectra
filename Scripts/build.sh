#!/bin/bash
# Regenerate the Xcode project and build, surfacing only diagnostics.
set -o pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null 2>&1 || { echo "xcodegen failed"; exit 1; }
xcodebuild -project Spectra.xcodeproj -scheme Spectra -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO ENABLE_PREVIEWS=NO build 2>&1 \
  | grep -E "error:|warning: .*unused|BUILD (SUCCEEDED|FAILED)"
echo "exit: ${PIPESTATUS[0]}"
