#!/bin/zsh
# Build Spectra, install to /Applications, and sign with a stable identity so the
# Screen Recording grant survives rebuilds. Quit and relaunch to pick up a new build.
#
# Usage:  bash Scripts/install.sh           # Debug (the proven config from build.sh)
#         bash Scripts/install.sh Release    # optimized build
#
# Why this exists: macOS ties Screen Recording (and other TCC grants) to the app's code
# signature AND its on-disk location. Running from DerivedData with ad-hoc signing churns
# both on every rebuild, so the grant never sticks and you keep opening a different .app.
# A fixed /Applications path plus the stable self-signed "yabai-cert" keeps the signature
# steady; the TCC pre-grant step below keeps the Screen Recording grant from re-prompting.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-Debug}"
IDENTITY="yabai-cert"
APP="/Applications/Spectra.app"
DDP=".build/DerivedData"

# The self-signed cert is untrusted (CSSMERR_TP_NOT_TRUSTED) by design, so check WITHOUT -v.
if ! security find-identity -p codesigning 2>/dev/null | grep -q "${IDENTITY}"; then
  echo "Signing identity '${IDENTITY}' not found in the keychain."
  echo "Create it once with os-mods/setup-cert.sh, then re-run this."
  exit 1
fi

echo "Regenerating project + building (${CONFIG}, clean)..."
xcodegen generate >/dev/null
# CODE_SIGNING_ALLOWED=NO matches Scripts/build.sh (the proven build invocation);
# the bundle is signed in place below.
xcodebuild -project Spectra.xcodeproj -scheme Spectra -configuration "${CONFIG}" \
  -destination 'platform=macOS' -derivedDataPath "${DDP}" \
  CODE_SIGNING_ALLOWED=NO ENABLE_PREVIEWS=NO clean build >/dev/null

BUILT="${DDP}/Build/Products/${CONFIG}/Spectra.app"
[ -d "${BUILT}" ] || { echo "Build product not found at ${BUILT}"; exit 1; }

echo "Installing to ${APP}..."
pkill -x Spectra 2>/dev/null || true
sleep 1
rm -rf "${APP}"
cp -R "${BUILT}" "${APP}"

echo "Signing in place with ${IDENTITY}..."
codesign --force --deep --options runtime --sign "${IDENTITY}" "${APP}"
codesign --verify --strict "${APP}" && echo "signature OK"

# Pre-authorize Screen Recording so macOS 15/26 does not re-prompt on every rebuild.
# Since Sequoia, a non-notarized app is re-asked for Screen Recording the first time it
# launches after its binary changes (i.e. every build), even though the signature (and
# thus the TCC designated requirement) is stable. We cannot notarize a local self-signed
# build, so instead we write the grant straight into the system TCC store, keyed on the
# same stable designated requirement, before launching. Requires SIP off (this machine)
# and a sudo prompt. If it cannot write, the build still launches and you get the normal
# prompt plus a hint to grant the terminal Full Disk Access.
echo "Pre-authorizing Screen Recording (TCC)..."
TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"
REQ="$(codesign -d -r- "${APP}" 2>&1 | awk -F ' => ' '/^designated/{print $2}')"
CSREQ_TMP="$(mktemp)"
if [ -n "${REQ}" ] && printf '%s' "${REQ}" | csreq -r- -b "${CSREQ_TMP}" 2>/dev/null; then
  CSREQ_HEX="$(xxd -p "${CSREQ_TMP}" | tr -d '\n')"
  SQL="INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq) VALUES ('kTCCServiceScreenCapture', 'com.spectra.Spectra', 0, 2, 2, 1, X'${CSREQ_HEX}');"
  if sudo sqlite3 "${TCC_DB}" "${SQL}" 2>/tmp/spectra-tcc-err.txt; then
    sudo killall tccd 2>/dev/null || true   # reload TCC so the grant applies immediately
    echo "  Screen Recording pre-granted (no prompt expected)."
  else
    echo "  TCC write failed: $(cat /tmp/spectra-tcc-err.txt)"
    echo "  If it says 'unable to open' or 'authorization denied', grant your terminal"
    echo "  Full Disk Access in System Settings > Privacy & Security > Full Disk Access."
  fi
else
  echo "  Could not compile the code requirement; skipping (you get the normal prompt)."
fi
rm -f "${CSREQ_TMP}"

echo "Launching..."
open "${APP}"
echo "Done. Screen Recording is pre-granted each build, so no more endless prompts."
