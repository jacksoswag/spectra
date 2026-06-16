#!/bin/bash
# Regenerate the Xcode project and build, surfacing only diagnostics.
#
# Uses `clean build` deliberately: regenerating the project with xcodegen on every run
# was confusing Swift's incremental dependency tracking, producing "BUILD SUCCEEDED"
# binaries that silently reused stale objects (changes not actually compiled in). A
# clean build is slower but guarantees the binary matches the source.
set -o pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null 2>&1 || { echo "xcodegen failed"; exit 1; }
xcodebuild -project Spectra.xcodeproj -scheme Spectra -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO ENABLE_PREVIEWS=NO \
  clean build 2>&1 \
  | grep -E "error:|warning: .*unused|BUILD (SUCCEEDED|FAILED)"
echo "exit: ${PIPESTATUS[0]}"
