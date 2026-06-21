import Foundation
import CoreGraphics

/// Applies per-channel color grades to whole displays via the scanout transfer
/// LUT (`CGSetDisplayTransferByTable`).
///
/// The window server applies this table at scanout — *after* it has composited
/// every Space, every swipe transition, and every full-screen Space — so the
/// grade holds everywhere with no window involved. That is the entire reason
/// per-channel color is routed here instead of through the capture+overlay
/// engine: it sidesteps the Space system rather than fighting it.
///
/// Each display's pre-grade table is captured on first touch and restored on
/// clear/teardown, so disabling Spectra (or the global panic hotkey, which calls
/// `disable()`) always returns the display to its color profile.
@MainActor
final class DisplayGrade {
    /// A 256-entry per-channel transfer table (output value per input index).
    struct LUT: Equatable {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
        var count: Int { red.count }
    }

    private struct Original {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
    }

    private var originals: [CGDirectDisplayID: Original] = [:]
    /// The LUT currently applied per display (so it can be re-asserted later).
    private(set) var applied: [CGDirectDisplayID: LUT] = [:]

    /// Install `lut` on `displayID`. A no-op if the same LUT is already applied, so
    /// repeated reconciles during a parameter drag don't re-push an identical table.
    func setLUT(_ lut: LUT, for displayID: CGDirectDisplayID) {
        guard applied[displayID] != lut else { return }
        captureOriginalIfNeeded(displayID)
        let err = CGSetDisplayTransferByTable(displayID, UInt32(lut.count), lut.red, lut.green, lut.blue)
        if err == .success {
            applied[displayID] = lut
        } else {
            Log.render.error("CGSetDisplayTransferByTable failed for \(displayID, privacy: .public): \(err.rawValue)")
        }
    }

    /// Restore `displayID` to its captured pre-grade table. No-op if not graded.
    func clear(for displayID: CGDirectDisplayID) {
        guard applied[displayID] != nil else { return }
        applied[displayID] = nil
        if let o = originals[displayID] {
            _ = CGSetDisplayTransferByTable(displayID, UInt32(o.red.count), o.red, o.green, o.blue)
        } else {
            CGDisplayRestoreColorSyncSettings()
        }
    }

    /// Reset every display to its ColorSync profile defaults at launch, clearing any
    /// scanout LUT a prior crash left installed. The captured originals live only in
    /// memory, so a crash (or force-quit) that skipped `clearAll` would otherwise strand
    /// the display graded until logout. Called once on launch, before any new grade.
    func clearStaleGradeAtLaunch() {
        CGDisplayRestoreColorSyncSettings()
    }

    /// Restore every graded display. Called on disable/teardown.
    func clearAll() {
        let ids = Array(applied.keys)
        for id in ids { clear(for: id) }
        // Belt-and-suspenders: guarantee nothing graded survives teardown even if a
        // captured original was somehow missing.
        if !ids.isEmpty { CGDisplayRestoreColorSyncSettings() }
    }

    private func captureOriginalIfNeeded(_ displayID: CGDirectDisplayID) {
        guard originals[displayID] == nil else { return }
        let capacity = CGDisplayGammaTableCapacity(displayID)
        guard capacity > 0 else { return }
        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = [CGGammaValue](repeating: 0, count: Int(capacity))
        var b = [CGGammaValue](repeating: 0, count: Int(capacity))
        var sampleCount: UInt32 = 0
        let err = CGGetDisplayTransferByTable(displayID, capacity, &r, &g, &b, &sampleCount)
        guard err == .success, sampleCount > 0 else { return }
        let n = Int(sampleCount)
        originals[displayID] = Original(red: Array(r.prefix(n)),
                                        green: Array(g.prefix(n)),
                                        blue: Array(b.prefix(n)))
    }
}
