// Standalone proof — NOT part of the Spectra app target (lives outside Sources/).
//
// Tests whether a CROSS-CHANNEL color transform can be applied globally, above the
// whole Space system, by synthesizing a display ICC profile and assigning it via
// ColorSync. The window server color-manages all content to the display profile at
// scanout — across every Space, swipe transition, full-screen Space, and Mission
// Control — so if this holds, the per-channel scanout-LUT ceiling is beaten and the
// app's real (cross-channel) color looks can go global.
//
// The transform here is a RED<->BLUE channel swap, produced by swapping the profile's
// rXYZ and bXYZ colorant tags in the raw ICC bytes. A per-channel gamma LUT cannot
// route one channel's value to another, so "reds look blue everywhere" is a clean,
// unmistakable proof that the transform is genuinely cross-channel AND genuinely global.
//
// It captures your CURRENT display profile and restores that exact profile on exit
// (Ctrl-C, timeout, or signal), so your calibration is preserved.

import Foundation
import CoreGraphics
import ApplicationServices

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(("profile-proof: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

let displayID = CGMainDisplayID()

guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
    die("could not get display UUID")
}
guard let current = ColorSyncProfileCreateWithDisplayID(displayID)?.takeRetainedValue() else {
    die("could not read the current display profile")
}
var cfErr: Unmanaged<CFError>?
guard let origCF = ColorSyncProfileCopyData(current, &cfErr)?.takeRetainedValue() else {
    die("could not copy the current profile data")
}
let orig = origCF as Data

// MARK: - ICC byte surgery: swap the rXYZ and bXYZ colorant tags.

func beU32(_ d: Data, _ o: Int) -> Int {
    (Int(d[o]) << 24) | (Int(d[o + 1]) << 16) | (Int(d[o + 2]) << 8) | Int(d[o + 3])
}
func tagSig(_ d: Data, _ o: Int) -> String {
    String(bytes: d[o..<o + 4], encoding: .ascii) ?? ""
}

// ICC layout: 128-byte header, then at offset 128 a UInt32 tag count, then that many
// 12-byte entries of (signature, offset, size).
guard orig.count > 132 else { die("profile too small to be valid ICC") }
let tagCount = beU32(orig, 128)
var rOff = -1, rSize = 0, bOff = -1, bSize = 0
for i in 0..<tagCount {
    let entry = 132 + i * 12
    guard entry + 12 <= orig.count else { break }
    switch tagSig(orig, entry) {
    case "rXYZ": rOff = beU32(orig, entry + 4); rSize = beU32(orig, entry + 8)
    case "bXYZ": bOff = beU32(orig, entry + 4); bSize = beU32(orig, entry + 8)
    default: break
    }
}
guard rOff >= 0, bOff >= 0 else {
    die("profile has no rXYZ/bXYZ colorant tags — not a matrix profile, can't swap channels")
}
guard rSize == bSize, rOff + rSize <= orig.count, bOff + bSize <= orig.count else {
    die("rXYZ/bXYZ tags have unexpected size/offset")
}

var swapped = orig
let rBlock = Array(orig[rOff..<rOff + rSize])
let bBlock = Array(orig[bOff..<bOff + bSize])
swapped.replaceSubrange(rOff..<rOff + rSize, with: bBlock)
swapped.replaceSubrange(bOff..<bOff + bSize, with: rBlock)

let origURL = URL(fileURLWithPath: "/tmp/spectra-orig-profile.icc")
let swapURL = URL(fileURLWithPath: "/tmp/spectra-swap-profile.icc")
do {
    try orig.write(to: origURL)
    try swapped.write(to: swapURL)
} catch { die("could not write profile files: \(error)") }

// MARK: - Assign / restore via ColorSync.

let deviceClass = kColorSyncDisplayDeviceClass.takeUnretainedValue()
let defaultProfileID = kColorSyncDeviceDefaultProfileID.takeUnretainedValue()

@discardableResult
func assign(_ url: URL) -> Bool {
    let info = [defaultProfileID: url] as CFDictionary
    return ColorSyncDeviceSetCustomProfiles(deviceClass, uuid, info)
}
func restore() {
    assign(origURL)
    CGDisplayRestoreColorSyncSettings()
}

// DispatchSource signal handlers (run on a background queue so they fire even while
// the main thread sleeps below) — restore the original profile before exiting.
func installRestore(on sig: Int32) -> DispatchSourceSignal {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.global())
    src.setEventHandler { restore(); print("\nRestored original display profile (signal)."); _exit(0) }
    src.resume()
    return src
}
let sigSources = [installRestore(on: SIGINT), installRestore(on: SIGTERM)]
_ = sigSources

let ok = assign(swapURL)
print("""
ASSIGNED a red<->blue swapped display profile (cross-channel) — applied=\(ok).
  • Reds should look blue (and blues red) EVERYWHERE.
  • Swipe across Spaces — the swap should hold through the transition.
  • Go full-screen and open Mission Control — both should be swapped too.
Auto-restores your original profile in 60s. Press Ctrl-C to restore immediately.
""")
fflush(stdout)
Thread.sleep(forTimeInterval: 60)
restore()
print("Restored original display profile.")
