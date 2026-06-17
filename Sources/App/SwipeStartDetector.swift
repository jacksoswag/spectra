import AppKit
import CoreGraphics

/// Detects the START of a trackpad horizontal swipe — the gesture that switches
/// Spaces — so the overlay can be hidden the instant the drag begins, BEFORE the
/// window server animates the transition.
///
/// Why it exists: `NSWorkspace.activeSpaceDidChangeNotification` fires at the *end*
/// of a Space switch (commit), not the start. Until then the opaque overlay is still
/// visible and keeps rendering the live capture — which during a swipe IS the swipe
/// animation — so it slides out with the outgoing Space showing a processed, doubled
/// copy of the transition (the "shattering / next Space moving twice as fast across
/// the former Space" artifact). Hiding the overlay the moment the gesture begins
/// removes that ghost; the engine's existing settle + frame-gated reveal path brings
/// it back once the new Space lands. (Keyboard / yabai Space switches generate no
/// scroll events, so the detector never fires for them — they stay covered by the
/// commit-time `activeSpaceDidChange` hide, unchanged.)
///
/// Implementation: a LISTEN-ONLY `CGEventTap` at the HID level. It never consumes or
/// alters events (every event is returned unchanged), so it cannot affect scrolling
/// or any other input — it only observes. A global `NSEvent` monitor is deliberately
/// not used: the system Space-switch gesture is claimed by the window server and is
/// not reliably delivered to a session-level monitor.
///
/// Honest limitations: at the HID layer a 3/4-finger Space swipe and a fast 2-finger
/// horizontal scroll both arrive as continuous scroll frames with no finger count, so
/// the horizontal-dominant heuristic can occasionally fire on a 2-finger scroll. The
/// hide self-reveals within ~0.45s when no Space change follows (see
/// `RenderEngine.hideOverlaysForSwipeStart`), so a false positive is a brief flicker,
/// not a stuck overlay. Whether the gesture even reaches the tap is machine-dependent;
/// the first several detections are written to `/tmp/spectra-swipe-probe.txt` so it can
/// be confirmed on-device. If the tap cannot be created (Input Monitoring not granted),
/// it logs and no-ops, leaving the commit-time hide as the only protection.
@MainActor
final class SwipeStartDetector {
    /// Called on the main actor when a horizontal swipe gesture is in progress.
    /// Expected to be idempotent and cheap — it may fire on several frames per gesture.
    var onSwipeStart: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Horizontal point-delta magnitude (per frame) below which motion is ignored, so
    /// the very start of a gesture (near-zero deltas) and tiny jitters don't trigger.
    private static let minHorizontalDelta = 1.5
    /// Cap on probe-log lines so the file can't grow unbounded across a session.
    private static let maxProbeLines = 12
    private var probeLines = 0

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let detector = Unmanaged<SwipeStartDetector>.fromOpaque(refcon).takeUnretainedValue()

            // The system disables a tap that is slow or after certain input; re-arm it.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { detector.reEnable() }
                return Unmanaged.passUnretained(event)
            }
            guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

            // Trackpad only: a hardware mouse wheel is not a Space-switch gesture.
            guard event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 else {
                return Unmanaged.passUnretained(event)
            }
            let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)   // horizontal
            let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)   // vertical
            guard abs(dx) > 2 * abs(dy), abs(dx) > 1.5 else {
                return Unmanaged.passUnretained(event)
            }
            let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            MainActor.assumeIsolated { detector.handleHorizontalSwipe(phase: phase, dx: dx, dy: dy) }
            return Unmanaged.passUnretained(event)   // never consume or modify
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.render.error("Swipe-start detector unavailable: could not create event tap (grant Spectra Input Monitoring).")
            writeProbe("START: tap FAILED to create — grant Spectra under System Settings > Privacy & Security > Input Monitoring, then relaunch.\n", truncate: true)
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        writeProbe("START: tap created OK — swipe horizontally across Spaces to test.\n", truncate: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
        runLoopSource = nil
        tap = nil
    }

    private func reEnable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleHorizontalSwipe(phase: Int64, dx: Double, dy: Double) {
        onSwipeStart?()
        // One-time on-device confirmation that the gesture actually reaches the tap, and
        // what its shape is (so the heuristic can be tuned). Bounded; remove once trusted.
        guard probeLines < Self.maxProbeLines else { return }
        probeLines += 1
        writeProbe("swipe phase=\(phase) dx=\(String(format: "%.2f", dx)) dy=\(String(format: "%.2f", dy))\n")
    }

    private func writeProbe(_ line: String, truncate: Bool = false) {
        let path = "/tmp/spectra-swipe-probe.txt"
        if !truncate, let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
