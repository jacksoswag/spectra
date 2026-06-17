// Standalone proof — NOT part of the Spectra app target (lives outside Sources/).
//
// Installs a bold, unmistakable color grade on every online display via the display
// transfer LUT (CGSetDisplayTransferByTable). That LUT is applied by WindowServer at
// scanout — above every Space, every swipe transition, and every full-screen Space —
// so it tests the one claim that matters before we build anything on it:
//
//   "A scanout-level grade holds across Space swipes and full-screen with no shatter."
//
// Run it, swipe across Spaces, pop into a full-screen window, and watch the warm cast.
// It auto-restores after 60s; Ctrl-C restores immediately. Reversible, no entitlement,
// no Screen Recording permission, nothing touching the overlay/capture engine.

import CoreGraphics
import Foundation

let capacity = 256

/// A strong warm grade: boosted red, cut green, killed blue, with a contrast S-curve.
/// Chosen to be impossible to mistake for "no change" yet still readable while swiping.
func makeTables() -> ([CGGammaValue], [CGGammaValue], [CGGammaValue]) {
    var r = [CGGammaValue](repeating: 0, count: capacity)
    var g = [CGGammaValue](repeating: 0, count: capacity)
    var b = [CGGammaValue](repeating: 0, count: capacity)
    for i in 0..<capacity {
        let x = CGGammaValue(i) / CGGammaValue(capacity - 1)
        let c = max(0, min(1, (x - 0.5) * 1.3 + 0.5))   // contrast
        r[i] = min(1, c * 1.15)
        g[i] = c * 0.55
        b[i] = c * 0.22
    }
    return (r, g, b)
}

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return ids
}

func apply() {
    let (r, g, b) = makeTables()
    for id in onlineDisplays() {
        let err = CGSetDisplayTransferByTable(id, UInt32(capacity), r, g, b)
        FileHandle.standardError.write("display \(id): CGSetDisplayTransferByTable -> \(err.rawValue)\n".data(using: .utf8)!)
    }
}

/// Resets every display's gamma to its ColorSync profile — the guaranteed recovery path.
func restore() { CGDisplayRestoreColorSyncSettings() }

// Safety nets so the screen never gets stuck graded.
signal(SIGINT)  { _ in restore(); _exit(0) }
signal(SIGTERM) { _ in restore(); _exit(0) }
atexit { restore() }

apply()
print("""
GRADE APPLIED to all displays (strong warm cast).
  • Swipe across Spaces — the cast should hold through the transition with no shatter.
  • Open or switch into a full-screen window — it should be graded too.
Auto-restores in 60s. Press Ctrl-C to restore immediately.
""")
fflush(stdout)
Thread.sleep(forTimeInterval: 60)
restore()
print("Restored.")
