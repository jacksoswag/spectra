#!/bin/bash
# release.sh — build, Developer ID sign, notarize, staple, and package Spectra as a
# notarized DMG for direct distribution.
#
# This is INERT until you have an Apple Developer ID certificate and notary
# credentials. It fails fast with instructions if either is missing. No secrets live
# in this file: signing reads the certificate from your keychain, and notarization
# reads a keychain-stored credential profile.
#
# One-time setup:
#   1. Apple Developer Program membership.
#   2. Create a "Developer ID Application" certificate (Xcode > Settings > Accounts >
#      Manage Certificates > +, or developer.apple.com).
#   3. Create an app-specific password at appleid.apple.com, then store notary
#      credentials in the keychain once:
#        xcrun notarytool store-credentials spectra-notary \
#          --apple-id "you@example.com" --team-id "YOURTEAMID" --password "app-specific-pw"
#   4. Run with your Team ID:
#        DEVELOPMENT_TEAM=YOURTEAMID bash Scripts/release.sh
#
# Config can be overridden via environment variables (see below).
set -euo pipefail
cd "$(dirname "$0")/.."

# ---- Config ----
TEAM_ID="${DEVELOPMENT_TEAM:-}"                       # 10-character Apple Team ID
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-spectra-notary}"   # notarytool keychain profile name
CONFIG="Release"
APP_NAME="Spectra"
DDP=".build/ReleaseDerivedData"
OUT="dist"

# ---- Preflight (fail fast, with fixes) ----
if [ -z "$TEAM_ID" ]; then
  echo "error: set DEVELOPMENT_TEAM to your 10-character Apple Team ID." >&2
  echo "       Signing/notarization is not configured yet; see the header of this script." >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  echo "error: no '$SIGN_IDENTITY' certificate in your keychain." >&2
  echo "       Create one in Xcode > Settings > Accounts > Manage Certificates." >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "error: notary credential profile '$NOTARY_PROFILE' not found or invalid." >&2
  echo "       Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id $TEAM_ID --password <app-specific-pw>" >&2
  exit 1
fi

# ---- Build (Developer ID, hardened runtime, secure timestamp) ----
echo "==> Generating project + building $CONFIG (sign: $SIGN_IDENTITY / team $TEAM_ID)…"
xcodegen generate >/dev/null
rm -rf "$DDP" "$OUT"; mkdir -p "$OUT"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration "$CONFIG" \
  -destination 'platform=macOS' -derivedDataPath "$DDP" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" ENABLE_PREVIEWS=NO clean build >/dev/null

APP="$DDP/Build/Products/$CONFIG/$APP_NAME.app"
[ -d "$APP" ] || { echo "error: build product not found at $APP" >&2; exit 1; }

# ---- Verify the signature is Developer ID + hardened ----
echo "==> Verifying signature…"
codesign --verify --strict --deep "$APP"
codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" \
  || { echo "error: app is not Developer ID signed." >&2; exit 1; }
codesign -d --entitlements - "$APP" >/dev/null

# ---- Notarize + staple the app (so it launches offline once copied out) ----
ZIP="$OUT/$APP_NAME.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> Notarizing the app (this can take a few minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

# ---- Build the DMG (drag onto Applications to install) ----
echo "==> Building DMG…"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
DMG="$OUT/$APP_NAME${VERSION:+-$VERSION}.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target
# (A branded background image + icon layout can be added here later with a .DS_Store
# template; a plain compressed DMG installs fine.)
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# ---- Sign, notarize, and staple the DMG ----
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
echo "==> Notarizing the DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# ---- Verify Gatekeeper will accept it ----
echo "==> Verifying Gatekeeper acceptance…"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG" || true
spctl -a -vvv "$APP" || true

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo ""
echo "Done: $DMG"
echo "  sha256: $SHA"
echo "  Test it on a CLEAN Mac (SIP on, no dev certs) before release: it must open with"
echo "  no Gatekeeper warning. Keep the sha256 for the Sparkle appcast later."
