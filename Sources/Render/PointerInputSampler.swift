import AppKit
import QuartzCore

/// Owns the main-thread-only AppKit reads needed to drive INTERACTIVE effects — the live
/// mouse position (`NSEvent.mouseLocation`), the button state (`NSEvent.pressedMouseButtons`),
/// and the moment/place of each click (`.leftMouseDown` monitors) — and publishes them as an
/// immutable, thread-safe snapshot the off-main render callback consumes.
///
/// Same split as `CursorSampler`: `NSEvent` is illegal on the render (link) thread, so every
/// AppKit read lives here on the main actor and only plain values cross the thread boundary via
/// the lock-free `current()`. Engaged only while an interactive effect (water splash, bubble
/// pop) is in the chain, so it costs nothing otherwise.
@MainActor
final class PointerInputSampler {
    /// Recent positions retained for the drag trail, sampled at 60Hz (~0.2s of history). The
    /// splash shader builds its dragged-water rope from these, so the body lags the cursor with
    /// a little liquid inertia instead of snapping to it.
    nonisolated static let trailCount = 12

    /// An immutable view of pointer state for one render frame. Positions are AppKit global
    /// points (bottom-left origin), matching `OverlayWindow.frame` so the per-display UV
    /// conversion mirrors the cursor compositor's placement math.
    struct Snapshot {
        /// Recent pointer positions, newest first; `trailLength` entries are valid.
        var trail = [CGPoint](repeating: .zero, count: PointerInputSampler.trailCount)
        var trailLength = 0
        /// Left button currently held.
        var pressed = false
        /// `CACurrentMediaTime()` of the last mouse-down and its position (−1 = none yet).
        /// Drives the press crown and the click-to-pop hit test.
        var lastDownTime: Double = -1
        var lastDownPos: CGPoint = .zero
        /// `CACurrentMediaTime()` of the last mouse-up (−1 = none yet). Drives the release
        /// collapse/ripple.
        var lastUpTime: Double = -1
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var snapshot = Snapshot()

    private var timer: Timer?
    private var downMonitorLocal: Any?
    private var downMonitorGlobal: Any?
    private(set) var enabled = false

    // Main-thread working state, folded into a fresh Snapshot each tick.
    private var trail: [CGPoint] = []
    private var pressed = false
    private var lastDownTime: Double = -1
    private var lastDownPos: CGPoint = .zero
    private var lastUpTime: Double = -1

    /// Thread-safe: read the latest published snapshot. Called from the render (link) thread.
    nonisolated func current() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    /// Engage/disengage sampling. Engaging starts the 60Hz timer and the click monitors and
    /// publishes one snapshot immediately; disengaging tears them down and clears the snapshot
    /// so interactive effects fall inert (no press, ages large).
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            // Catch every click — even a sub-frame tap — so a quick click always pops the bubble
            // under it. Local fires when Spectra is frontmost (its own windows), global when
            // another app is. Neither needs accessibility permission for mouse events.
            downMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handleDown() }
                return event
            }
            downMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleDown() }
            }
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            tick()
        } else {
            timer?.invalidate()
            timer = nil
            if let m = downMonitorLocal { NSEvent.removeMonitor(m) }
            if let m = downMonitorGlobal { NSEvent.removeMonitor(m) }
            downMonitorLocal = nil
            downMonitorGlobal = nil
            trail.removeAll()
            pressed = false
            lastDownTime = -1
            lastUpTime = -1
            publish(Snapshot())
        }
    }

    /// A mouse-down: stamp the click (for the crown + pop), and seed the drag rope at the press
    /// point so the trail starts clean rather than from wherever the cursor last idled.
    private func handleDown() {
        lastDownTime = CACurrentMediaTime()
        lastDownPos = NSEvent.mouseLocation
        pressed = true
        trail = [lastDownPos]
    }

    /// 60Hz: advance the drag trail while held, detect release, and publish.
    private func tick() {
        let pos = NSEvent.mouseLocation
        let isDown = NSEvent.pressedMouseButtons & 0x1 != 0
        if isDown {
            if !pressed {           // press began between ticks and the monitor missed it (rare)
                pressed = true
                if lastDownTime < 0 { lastDownTime = CACurrentMediaTime(); lastDownPos = pos }
                trail = [pos]
            }
            trail.insert(pos, at: 0)
            if trail.count > Self.trailCount { trail.removeLast() }
        } else if pressed {
            pressed = false
            lastUpTime = CACurrentMediaTime()
            // Keep the frozen trail so the release-collapse animation can retract along it; it
            // ages out via lastUpTime.
        }

        var s = Snapshot()
        let n = min(trail.count, Self.trailCount)
        for i in 0..<n { s.trail[i] = trail[i] }
        s.trailLength = n
        s.pressed = pressed
        s.lastDownTime = lastDownTime
        s.lastDownPos = lastDownPos
        s.lastUpTime = lastUpTime
        publish(s)
    }

    private func publish(_ s: Snapshot) {
        lock.lock(); snapshot = s; lock.unlock()
    }
}
