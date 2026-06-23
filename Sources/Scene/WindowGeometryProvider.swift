import Foundation
import CoreGraphics
import QuartzCore
import simd

/// Publishes per-display window rectangles (display-local top-left UV) sourced from
/// `CGWindowList` — no permission prompt — for window-aware shaders: per-window chrome
/// (MAOE §12) and geometry-aware generative content (§15.2). Promotes the proven
/// `TintGeometry.spaceWindows` walk into a reusable, throttled provider that mirrors
/// `PointerInputSampler`'s enable-on-demand + immutable-`Snapshot` pattern, so it costs
/// nothing while no rect-consuming effect is in the chain.
///
/// Runs entirely off the main thread on its own serial queue: `CGWindowListCopyWindowInfo`
/// and `CGDisplayBounds` are thread-safe, so there is no AppKit-main hop and no added
/// main-thread cost. The render (link) thread reads the latest published per-display
/// snapshot lock-free via `snapshot(for:)`.
final class WindowGeometryProvider {
    /// Hard cap on windows fed to the GPU (matches `kSpectraMaxWindows` in SpectraCommon.h →
    /// a ~2 KB buffer). Overflow is clamped and logged, never silently truncated.
    static let maxWindows = 64

    /// One window's geometry for the GPU + lifecycle diffing.
    struct Window: Sendable, Equatable {
        var rectUV: SIMD4<Float>   // xy = top-left origin UV, zw = size UV
        var alpha: Float           // kCGWindowAlpha (0..1); a closing window fades this to 0
        var focused: Float         // 1 = frontmost window on its display, else 0
        var cornerRadiusUV: Float  // top-corner radius in UV-Y units
        var id: UInt32             // kCGWindowNumber, for the §5.4 lifecycle id-diff
        /// Display-local top-left rect in points (pre-UV), retained for lifecycle geometry
        /// (minimize-toward-Dock direction) and CPU-side hit tests.
        var rectPoints: CGRect
    }

    /// An immutable per-display view for one render frame; `overflowed` is true when the
    /// live window count exceeded `maxWindows` and was clamped.
    struct Snapshot: Sendable {
        var windows: [Window] = []
        var overflowed = false
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var snapshots: [CGDirectDisplayID: Snapshot] = [:]

    private let queue = DispatchQueue(label: "com.spectra.windowgeometry", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private(set) var enabled = false

    /// Displays to walk (set by the engine alongside enablement). Queue-confined.
    private var displayIDs: [CGDirectDisplayID] = []
    private var tickN = 0

    /// While `CACurrentMediaTime() < boostUntil` the walk runs at 60 Hz instead of the 20 Hz
    /// idle rate, so a button-drag or a window-lifecycle alpha ramp samples smoothly. Lock-
    /// guarded (bumped from arbitrary threads via `boost()`).
    private var boostUntil: Double = 0

    /// 60 Hz timer; the idle divisor drops the actual walk to 20 Hz unless boosted — the same
    /// cadence `AdaptiveTintOverlay` uses.
    private static let idleDivisor = 3

    /// Emitted (on the provider queue) for each window-lifecycle transition the diff detects
    /// (§5.4). Set by the engine; nil until then. Wired in the lifecycle step.
    var onLifecycleEvent: ((WindowLifecycleEvent) -> Void)?
    /// Previous tick's window ids + last-seen geometry per display, for the §5.4 diff.
    private var previous: [CGDirectDisplayID: [UInt32: Window]] = [:]

    // MARK: - Lifecycle

    /// Engage/disengage sampling. Engaging starts the timer and walks once immediately;
    /// disengaging tears it down and clears every snapshot so consumers read empty geometry.
    func setEnabled(_ on: Bool, displays: [CGDirectDisplayID]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.displayIDs = displays
            guard on != self.enabled else { return }
            self.enabled = on
            if on {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(2))
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer
                timer.resume()
            } else {
                self.timer?.cancel()
                self.timer = nil
                self.previous.removeAll()
                self.lock.lock(); self.snapshots.removeAll(); self.lock.unlock()
            }
        }
    }

    /// Update the displays to walk without toggling enablement (display hotplug).
    func setDisplays(_ displays: [CGDirectDisplayID]) {
        queue.async { [weak self] in self?.displayIDs = displays }
    }

    /// Bump the walk to 60 Hz for ~0.5 s (a press/drag, scroll, or a detected lifecycle
    /// alpha ramp). Thread-safe; callable from any thread.
    func boost() {
        lock.lock(); boostUntil = max(boostUntil, CACurrentMediaTime() + 0.5); lock.unlock()
    }

    /// Lock-free latest snapshot for a display (render/link thread). Empty when disengaged.
    nonisolated func snapshot(for displayID: CGDirectDisplayID) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshots[displayID] ?? Snapshot()
    }

    // MARK: - Walk (provider queue)

    private func tick() {
        let now = CACurrentMediaTime()
        lock.lock(); let boosting = now < boostUntil; lock.unlock()
        tickN += 1
        if !boosting && tickN % Self.idleDivisor != 0 { return }

        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return }

        var built: [CGDirectDisplayID: Snapshot] = [:]
        for id in displayIDs {
            built[id] = walk(infos: infos, displayID: id)
        }
        lock.lock(); snapshots = built; lock.unlock()

        if onLifecycleEvent != nil { diffLifecycle(built) }
    }

    /// Build one display's snapshot from the front-to-back window list. The first window that
    /// lands on the display (front-most in z-order) is marked focused — a no-AX focus signal.
    private func walk(infos: [[String: Any]], displayID: CGDirectDisplayID) -> Snapshot {
        let b = CGDisplayBounds(displayID)
        guard b.width > 0, b.height > 0 else { return Snapshot() }
        let invW = Float(1.0 / b.width), invH = Float(1.0 / b.height)
        var windows: [Window] = []
        var overflowed = false
        for info in infos {
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            if owner == "Spectra" { continue }   // never feed our own overlay back into the GPU
            guard let d = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = d["X"], let y = d["Y"], let w = d["Width"], let h = d["Height"] else { continue }
            let c = CGRect(x: x, y: y, width: w, height: h).intersection(b)
            guard !c.isNull, c.width > 1, c.height > 1 else { continue }
            if windows.count >= Self.maxWindows { overflowed = true; break }
            let local = CGRect(x: c.minX - b.minX, y: c.minY - b.minY, width: c.width, height: c.height)
            let alpha = Float((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
            let id = UInt32((info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0)
            let radius = Float(TintGeometry.cornerRadius(forOwner: owner)) * invH
            let rectUV = SIMD4<Float>(Float(local.minX) * invW, Float(local.minY) * invH,
                                      Float(local.width) * invW, Float(local.height) * invH)
            windows.append(Window(rectUV: rectUV, alpha: alpha,
                                  focused: windows.isEmpty ? 1 : 0,
                                  cornerRadiusUV: radius, id: id, rectPoints: local))
        }
        if overflowed {
            Log.render.error("WindowGeometryProvider: >\(Self.maxWindows) windows on display \(displayID, privacy: .public); clamped")
        }
        return Snapshot(windows: windows, overflowed: overflowed)
    }

    // MARK: - Lifecycle diff (§5.4) — populated when `onLifecycleEvent` is wired.

    private func diffLifecycle(_ built: [CGDirectDisplayID: Snapshot]) {
        for (displayID, snap) in built {
            var current: [UInt32: Window] = [:]
            current.reserveCapacity(snap.windows.count)
            for w in snap.windows { current[w.id] = w }
            defer { previous[displayID] = current }

            // First observation of this display: seed the baseline without emitting, so the
            // existing windows don't all spuriously fire `opened`.
            guard let prior = previous[displayID] else { continue }

            // Appeared: a new id entered the set (Matrix window-open decode).
            for (id, w) in current where prior[id] == nil && id != 0 {
                onLifecycleEvent?(WindowLifecycleEvent(kind: .opened, rectUV: w.rectUV,
                                                        rectPoints: w.rectPoints, displayID: displayID,
                                                        dockDirection: .zero))
            }
            // Left the set, or alpha collapsed toward 0 (a close fade). Classify close vs.
            // minimize by the last-seen alpha: a closing window fades alpha toward 0 first; a
            // minimize keeps full alpha as it genies toward the Dock.
            for (id, w) in prior where current[id] == nil && id != 0 {
                let kind: WindowLifecycleEvent.Kind = w.alpha < 0.5 ? .closed : .minimized
                onLifecycleEvent?(WindowLifecycleEvent(kind: kind, rectUV: w.rectUV,
                                                        rectPoints: w.rectPoints, displayID: displayID,
                                                        dockDirection: SIMD2(0, 1)))   // default Dock position (bottom edge)
            }
        }
    }
}

/// A one-shot window-lifecycle transition the geometry diff detects (MAOE §5.4). The event
/// clock fires a decaying burst at `rectUV` (the window's last rect); `dockDirection` aims a
/// minimize trail. No private API: derived purely from `CGWindowList` id-presence + alpha.
struct WindowLifecycleEvent: Sendable {
    enum Kind: Sendable { case opened, closed, minimized }
    var kind: Kind
    var rectUV: SIMD4<Float>
    var rectPoints: CGRect
    var displayID: CGDirectDisplayID
    var dockDirection: SIMD2<Float>
}

/// Flat CPU mirror of the Metal `WindowGeometry` struct (SpectraCommon.h). Layout:
/// `[0]` count, `[1...3]` pad, then 8 floats per window — rect(x,y,w,h), alpha, focused,
/// radius, reserved. Built once per frame by the renderer and bound at fragment buffer 2.
enum WindowGeometryUniforms {
    static let headerFloats = 4
    static let floatsPerWindow = 8
    static let floatCount = headerFloats + WindowGeometryProvider.maxWindows * floatsPerWindow
    static let byteCount = floatCount * MemoryLayout<Float>.stride

    /// Pack a frame's windows into the GPU layout. Clamps to `maxWindows`.
    static func pack(_ windows: [WindowGeometryProvider.Window]) -> [Float] {
        var out = [Float](repeating: 0, count: floatCount)
        let n = min(windows.count, WindowGeometryProvider.maxWindows)
        out[0] = Float(n)
        for i in 0..<n {
            let w = windows[i]
            let base = headerFloats + i * floatsPerWindow
            out[base + 0] = w.rectUV.x; out[base + 1] = w.rectUV.y
            out[base + 2] = w.rectUV.z; out[base + 3] = w.rectUV.w
            out[base + 4] = w.alpha; out[base + 5] = w.focused
            out[base + 6] = w.cornerRadiusUV; out[base + 7] = 0
        }
        return out
    }
}
