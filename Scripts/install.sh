#!/bin/zsh
# Build Spectra, install to /Applications, and sign with a stable identity so the
# Screen Recording grant survives rebuilds — then just quit and relaunch to get a new build.
#
# Usage:  bash Scripts/install.sh           # Debug (the proven config from build.sh)
#         bash Scripts/install.sh Release    # optimized build
#
# Why this exists: macOS ties Screen Recording (and other TCC grants) to the app's code
# signature AND its on-disk location. Running from DerivedData with ad-hoc signing churns
# both on every rebuild, so the grant never sticks and you keep opening a different .app.
# A fixed /Applications path plus the stable self-signed "yabai-cert" means a grant, once
# given, persists across every future rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-Debug}"
IDENTITY="yabai-cert"
APP="/Applications/Spectra.app"
DDP=".build/DerivedData"

# The self-signed cert is untrusted (CSSMERR_TP_NOT_TRUSTED) by design, so check WITHOUT -v.
if ! security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "Signing identity '$IDENTITY' not found in the keychain."
  echo "Create it once with os-mods/setup-cert.sh, then re-run this."
  exit 1
fi

echo "Regenerating project + building ($CONFIG, clean)…"
xcodegen generate >/dev/null
# CODE_SIGNING_ALLOWED=NO matches Scripts/build.sh (the proven build invocation);
# the bundle is signed in place below.
xcodebuild -project Spectra.xcodeproj -scheme Spectra -configuration "$CONFIG" \
  -destination 'platform=macOS' -derivedDataPath "$DDP" \
  CODE_SIGNING_ALLOWED=NO ENABLE_PREVIEWS=NO clean build >/dev/null

BUILT="$DDP/Build/Products/$CONFIG/Spectra.app"
[ -d "$BUILT" ] || { echo "Build product not found at $BUILT"; exit 1; }

echo "Installing to $APP…"
pkill -x Spectra 2>/dev/null || true
sleep 1
rm -rf "$APP"
cp -R "$BUILT" "$APP"

echo "Signing in place with $IDENTITY…"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP" && echo "signature OK"

echo "Launching…"
open "$APP"
echo "Done. Grant Screen Recording once if asked — it will persist across rebuilds now."
