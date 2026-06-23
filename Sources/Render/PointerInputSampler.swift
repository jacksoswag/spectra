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
        /// Any mouse button currently held (left, right, or other — MAOE §5.2).
        var pressed = false
        /// LEFT button specifically held (for the pencil draw-on-screen tool, which must not draw
        /// while the right button erases).
        var leftPressed = false
        /// `CACurrentMediaTime()` of the last RIGHT-button down (−1 = none). The pencil tool clears
        /// the drawing on its rising edge.
        var rightDownTime: Double = -1
        /// `CACurrentMediaTime()` of the last mouse-down (any button) and its position
        /// (−1 = none yet). Drives the press crown, the click-to-pop hit test, and the
        /// press-hold line warp.
        var lastDownTime: Double = -1
        var lastDownPos: CGPoint = .zero
        /// `CACurrentMediaTime()` of the last mouse-up (−1 = none yet). Drives the release
        /// collapse/ripple.
        var lastUpTime: Double = -1
        /// `CACurrentMediaTime()` of the last scroll-wheel event (−1 = none yet) and the
        /// event's scrolling delta. Drive the scroll-reactive effects (Matrix drift, CMYK).
        var lastScrollTime: Double = -1
        var scrollDelta: CGVector = .zero
        /// Current pointer position (AppKit global, bottom-left) regardless of press state,
        /// its smoothed speed (points/sec), and the time of the last significant move. Drive
        /// the movement-reactive effects (light leak, speed lines, CMYK) — MAOE §7.
        var pointerPos: CGPoint = .zero
        var pointerSpeed: Double = 0
        var lastMoveTime: Double = -1
        /// `CACurrentMediaTime()` of the last keystroke (−1 = none) and a 0…1 seed from its
        /// keycode, for the keyboard-reactive effects (MAOE §15.1). Populated only while the
        /// key monitor is engaged (Input Monitoring granted).
        var lastKeyTime: Double = -1
        var keySeed: Double = 0
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var snapshot = Snapshot()

    private var timer: Timer?
    private var downMonitorLocal: Any?
    private var downMonitorGlobal: Any?
    private var scrollMonitorLocal: Any?
    private var scrollMonitorGlobal: Any?
    private var keyMonitorLocal: Any?
    private var keyMonitorGlobal: Any?
    private(set) var enabled = false
    private(set) var keyboardEnabled = false
    private var lastKeyTime: Double = -1
    private var keySeed: Double = 0

    /// Fired on the main thread for each discrete pointer event (any-button down, scroll) and
    /// every tick while a button is held, so the engine can arm the decay render clock (§5.2)
    /// and boost the geometry provider. Set by `RenderEngine`; nil otherwise.
    var onEvent: (() -> Void)?

    // Main-thread working state, folded into a fresh Snapshot each tick.
    private var trail: [CGPoint] = []
    private var pressed = false
    private var lastDownTime: Double = -1
    private var lastDownPos: CGPoint = .zero
    private var lastUpTime: Double = -1
    private var lastScrollTime: Double = -1
    private var scrollDelta: CGVector = .zero
    private var prevPos: CGPoint = .zero
    private var pointerSpeed: Double = 0
    private var lastMoveTime: Double = -1
    private var prevRight = false
    private var rightDownTime: Double = -1

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
            // Catch every press — even a sub-frame tap — so a quick click always fires. Any
            // mouse button (left, right, other), so every click/press-driven effect inherits
            // any-button behaviour (MAOE §5.2). Local fires when Spectra is frontmost (its own
            // windows), global when another app is. Neither needs accessibility permission.
            let downMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            downMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: downMask) { [weak self] event in
                MainActor.assumeIsolated { self?.handleDown() }
                return event
            }
            downMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: downMask) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleDown() }
            }
            scrollMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated { self?.handleScroll(event) }
                return event
            }
            scrollMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated { self?.handleScroll(event) }
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
            for m in [downMonitorLocal, downMonitorGlobal, scrollMonitorLocal, scrollMonitorGlobal] {
                if let m { NSEvent.removeMonitor(m) }
            }
            downMonitorLocal = nil
            downMonitorGlobal = nil
            scrollMonitorLocal = nil
            scrollMonitorGlobal = nil
            trail.removeAll()
            pressed = false
            lastDownTime = -1
            lastDownPos = .zero
            lastUpTime = -1
            lastScrollTime = -1
            scrollDelta = .zero
            publish(Snapshot())
        }
    }

    /// A mouse-down (any button): stamp the click (for the crown + pop + line warp), and seed
    /// the drag rope at the press point so the trail starts clean rather than from wherever the
    /// cursor last idled.
    private func handleDown() {
        lastDownTime = CACurrentMediaTime()
        lastDownPos = NSEvent.mouseLocation
        pressed = true
        trail = [lastDownPos]
        onEvent?()
    }

    /// Engage/disengage the keyboard monitor (MAOE §15.1). The global monitor only delivers
    /// events while Input Monitoring is granted, so this degrades gracefully when denied. The
    /// 60 Hz publish timer is shared with pointer sampling; if pointer sampling is off, this
    /// starts a lightweight timer of its own so key ages still publish.
    func setKeyboardEnabled(_ on: Bool) {
        guard on != keyboardEnabled else { return }
        keyboardEnabled = on
        if on {
            keyMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handleKey(event) }
                return event
            }
            keyMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handleKey(event) }
            }
            if timer == nil {
                let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } else {
            if let m = keyMonitorLocal { NSEvent.removeMonitor(m) }
            if let m = keyMonitorGlobal { NSEvent.removeMonitor(m) }
            keyMonitorLocal = nil
            keyMonitorGlobal = nil
            lastKeyTime = -1
            keySeed = 0
            if !enabled { timer?.invalidate(); timer = nil; publish(Snapshot()) }
        }
    }

    private func handleKey(_ event: NSEvent) {
        lastKeyTime = CACurrentMediaTime()
        keySeed = Double(event.keyCode % 64) / 64.0
        onEvent?()
    }

    /// A scroll-wheel event: stamp the time + delta for the scroll-reactive effects.
    private func handleScroll(_ event: NSEvent) {
        lastScrollTime = CACurrentMediaTime()
        scrollDelta = CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        onEvent?()
    }

    /// 60Hz: advance the drag trail while held, detect release, and publish.
    private func tick() {
        let pos = NSEvent.mouseLocation
        let buttons = NSEvent.pressedMouseButtons
        let isDown = buttons != 0                        // any button (MAOE §5.2)
        let leftDown = (buttons & 1) != 0
        let rightDown = (buttons & 2) != 0
        if rightDown && !prevRight { rightDownTime = CACurrentMediaTime() }   // rising edge → pencil clear
        prevRight = rightDown
        // Always-on movement tracking (independent of press) for the movement-reactive effects.
        // Speed in points/sec, EMA-smoothed; a significant move arms the decay clock so the
        // effect renders while the cursor flies, then idles.
        let moveDist = hypot(pos.x - prevPos.x, pos.y - prevPos.y)
        prevPos = pos
        pointerSpeed = pointerSpeed * 0.6 + (moveDist * 60.0) * 0.4
        if moveDist > 1.5 {
            lastMoveTime = CACurrentMediaTime()
            onEvent?()
        }
        if isDown { onEvent?() }                          // keep the decay clock alive while held
        if isDown {
            if !pressed {           // press began between ticks and the monitor missed it (rare)
                pressed = true
                if lastDownTime < 0 { lastDownTime = CACurrentMediaTime(); lastDownPos = pos }
                trail = [pos]       // seed the rope; the insert below is skipped so it isn't doubled
            } else {
                trail.insert(pos, at: 0)
                if trail.count > Self.trailCount { trail.removeLast() }
            }
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
        s.leftPressed = leftDown
        s.rightDownTime = rightDownTime
        s.lastDownTime = lastDownTime
        s.lastDownPos = lastDownPos
        s.lastUpTime = lastUpTime
        s.lastScrollTime = lastScrollTime
        s.scrollDelta = scrollDelta
        s.pointerPos = pos
        s.pointerSpeed = pointerSpeed
        s.lastMoveTime = lastMoveTime
        s.lastKeyTime = lastKeyTime
        s.keySeed = keySeed
        publish(s)
    }

    private func publish(_ s: Snapshot) {
        lock.lock(); snapshot = s; lock.unlock()
    }
}
