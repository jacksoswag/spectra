import Cocoa
import QuartzCore
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Dims the exposed desktop (everything NOT covered by a window) to match the windows that
/// are present, so the bright wallpaper in the gaps doesn't clash with the glass windows. A
/// semi-transparent tint sits at the desktop level (below windows) with a sharp vector hole
/// cut for every window, so the real wallpaper still shows pixel-perfect under the windows
/// and only the gaps are tinted. The tint colour is the darkness-weighted average of the
/// windows' own pixels (sampled from a tiny ScreenCaptureKit grid), so the gaps take on the
/// apps' tone. Only active on a Space that actually has a window; empty/fullscreen Spaces are
/// left clean. One overlay per (Space, display), pinned to its Space so it slides correctly.
///
/// Ported from `os-mods/adaptive-menubar` (the compiled Glass.app), adapted to run inside
/// Spectra: it excludes Spectra's own windows from both the colour sample and the window list.
@MainActor
final class AdaptiveTintOverlay {
    // Tuned constants (from os-mods Config). `strength` drives dimScale; `smoothing` drives the EMA.
    private static let darkBias: CGFloat = 0.7          // weight darker (background) window pixels more
    private static let tintBrightness: CGFloat = 0.5    // knock the sampled glass colour down; it reads too bright
    private static let tickInterval: TimeInterval = 1.0 / 60.0
    private static let idleDivisor = 3                  // 20fps idle, full 60fps while dragging
    private static let animationSettle: TimeInterval = 0.2

    private var dimScale: CGFloat = 1.0
    private var emaFactor: CGFloat = 0.25

    private(set) var isActive = false
    var onWindowsChanged: (() -> Void)?

    private let overlays = OverlayStore()
    private let capture = TintCapture()
    private var timer: Timer?
    private var dimColor: [CGDirectDisplayID: RGBA] = [:]
    private var latestWindows: [CGDirectDisplayID: [CGRect]] = [:]
    private var lastLayoutKey: [CGDirectDisplayID: Int] = [:]
    private var freezeUntil: [CGDirectDisplayID: Date] = [:]
    private var tickN = 0

    var windowNumbers: [Int] { overlays.windowNumbers }

    // MARK: - Lifecycle

    func activate(strength: Double, smoothing: Double, displayIDs: [CGDirectDisplayID]) {
        applyParams(strength: strength, smoothing: smoothing)
        guard !isActive else { return }
        isActive = true
        Log.capture.error("[tint] activate strength=\(strength) smoothing=\(smoothing)")
        capture.gridSink = { [weak self] id, grid in
            Task { @MainActor in self?.ingest(id: id, grid: grid) }
        }
        Task { await capture.rebuild() }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        onWindowsChanged?()
    }

    func update(strength: Double, smoothing: Double) {
        applyParams(strength: strength, smoothing: smoothing)
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate(); timer = nil
        Task { await capture.stop() }
        overlays.teardown()
        dimColor.removeAll(); latestWindows.removeAll(); lastLayoutKey.removeAll(); freezeUntil.removeAll()
        onWindowsChanged?()
    }

    func refreshGeometry(displayIDs: [CGDirectDisplayID]) {
        guard isActive else { return }
        overlays.teardown()
        Task { await capture.rebuild() }
        onWindowsChanged?()
    }

    private func applyParams(strength: Double, smoothing: Double) {
        dimScale = CGFloat(max(0, min(1, strength)))
        // smoothing 0 -> snappy (0.5 EMA), 0.5 -> os-mods' 0.25, 1 -> very slow (0.03)
        emaFactor = max(0.03, 0.5 * (1 - CGFloat(max(0, min(1, smoothing)))))
    }

    // MARK: - Colour ingest

    /// Average the grid cells under a window with a darkness weighting, giving the gap tint.
    private func ingest(id: CGDirectDisplayID, grid: Grid) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return }
        let dispW = screen.frame.width, dispH = screen.frame.height
        let rects = latestWindows[id] ?? TintGeometry.spaceWindows(displayID: id).windowRects
        guard !rects.isEmpty else { return }
        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, wsum: CGFloat = 0
        for r in 0..<grid.rows {
            let cy = (CGFloat(r) + 0.5) * dispH / CGFloat(grid.rows)
            for c in 0..<grid.cols {
                let cx = (CGFloat(c) + 0.5) * dispW / CGFloat(grid.cols)
                guard rects.contains(where: { $0.contains(CGPoint(x: cx, y: cy)) }) else { continue }
                let p = grid.px[r * grid.cols + c]
                let lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b
                let w = (1 - Self.darkBias) + Self.darkBias * (1 - lum)
                rr += p.r * w; gg += p.g * w; bb += p.b * w; wsum += w
            }
        }
        if wsum > 0 {
            let wasNil = dimColor[id] == nil
            dimColor[id] = RGBA(r: rr / wsum, g: gg / wsum, b: bb / wsum, a: 1)
            if wasNil { Log.capture.error("[tint] first colour set d=\(id, privacy: .public) rects=\(rects.count)") }
        }
    }

    // MARK: - Tick (rebuild the cutout from live geometry, gate on a non-empty Space)

    private func tick() {
        guard isActive else { return }
        let mouseDown = NSEvent.pressedMouseButtons != 0
        tickN += 1
        if !mouseDown && tickN % Self.idleDivisor != 0 { return }
        let now = Date()
        let space = TintGeometry.currentSpaceID()
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let sw = TintGeometry.spaceWindows(displayID: id)
            latestWindows[id] = sw.windowRects
            if sw.fullscreen { overlays.hide(space: space, screen: screen); continue }
            var hasher = Hasher(); hasher.combine(sw.all.count)
            for w in sw.all {
                hasher.combine(Int(w.rect.minX)); hasher.combine(Int(w.rect.minY))
                hasher.combine(Int(w.rect.width)); hasher.combine(Int(w.rect.height))
            }
            let rectsKey = hasher.finalize()
            let moved = (lastLayoutKey[id] ?? rectsKey) != rectsKey
            lastLayoutKey[id] = rectsKey
            if moved && !mouseDown { freezeUntil[id] = now.addingTimeInterval(Self.animationSettle) }
            if let f = freezeUntil[id], now < f { continue }
            guard !sw.windowRects.isEmpty, let color = dimColor[id] else {
                overlays.hide(space: space, screen: screen); continue
            }
            let opacity = min(1, max(0, sw.avgAlpha * dimScale))
            let created = overlays.update(space: space, screen: screen, windows: sw.all,
                                          color: color, opacity: opacity, rectsKey: rectsKey,
                                          ema: emaFactor, tintBrightness: Self.tintBrightness)
            if created { onWindowsChanged?() }
        }
    }
}

// MARK: - Colour ------------------------------------------------------------------

struct RGBA: Sendable {
    var r, g, b, a: CGFloat
    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
    func lerp(to t: RGBA, _ f: CGFloat) -> RGBA {
        RGBA(r: r + (t.r - r) * f, g: g + (t.g - g) * f, b: b + (t.b - b) * f, a: a + (t.a - a) * f)
    }
}

// MARK: - Geometry ----------------------------------------------------------------

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

enum TintGeometry {
    /// One window's cutout: display-local top-left rect, plus the corner radius to round its top.
    struct Win { let rect: CGRect; let radius: CGFloat }
    struct SpaceWindows { let all: [Win]; let windowRects: [CGRect]; let avgAlpha: CGFloat; let fullscreen: Bool }

    private static let cornerRadii: [String: CGFloat] = ["Safari": 16, "Claude": 10]
    static func cornerRadius(forOwner owner: String) -> CGFloat {
        cornerRadii[owner] ?? 11
    }

    /// Windows on this display's current Space (excluding Spectra's own), with live opacity.
    static func spaceWindows(displayID: CGDirectDisplayID) -> SpaceWindows {
        let b = CGDisplayBounds(displayID)
        guard b.width > 0, b.height > 0,
              let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return SpaceWindows(all: [], windowRects: [], avgAlpha: 1, fullscreen: false) }
        var all: [Win] = [], rects: [CGRect] = []
        var alphaSum: CGFloat = 0, alphaN = 0
        var fullscreen = false
        for info in infos {
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            if owner == "Spectra" { continue }   // never tint from / cut for our own overlay windows
            guard let d = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = d["X"], let y = d["Y"], let w = d["Width"], let h = d["Height"] else { continue }
            if hideWhenFullscreen, abs(x - b.minX) < 2, abs(y - b.minY) < 2, abs(w - b.width) < 2, abs(h - b.height) < 2 {
                fullscreen = true
            }
            let c = CGRect(x: x, y: y, width: w, height: h).intersection(b)
            guard !c.isNull, c.width > 1, c.height > 1 else { continue }
            let local = CGRect(x: c.minX - b.minX, y: c.minY - b.minY, width: c.width, height: c.height)
            all.append(Win(rect: local, radius: cornerRadius(forOwner: owner)))
            rects.append(local)
            let a = CGFloat((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
            alphaSum += a; alphaN += 1
        }
        let avgAlpha = alphaN > 0 ? alphaSum / CGFloat(alphaN) : 1
        return SpaceWindows(all: all, windowRects: rects, avgAlpha: avgAlpha, fullscreen: fullscreen)
    }

    private static let hideWhenFullscreen = true

    /// A rect with its TOP two corners rounded (bottom square), matching how macOS rounds a
    /// window's top corners. Built in bottom-left coords (the window's top edge is the rect's max-Y).
    static func roundedTopRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, min(rect.width, rect.height) / 2)
        let p = CGMutablePath()
        let minX = rect.minX, maxX = rect.maxX, yb = rect.minY, yt = rect.maxY
        p.move(to: CGPoint(x: minX, y: yb))
        p.addLine(to: CGPoint(x: maxX, y: yb))
        p.addLine(to: CGPoint(x: maxX, y: yt - r))
        p.addQuadCurve(to: CGPoint(x: maxX - r, y: yt), control: CGPoint(x: maxX, y: yt))
        p.addLine(to: CGPoint(x: minX + r, y: yt))
        p.addQuadCurve(to: CGPoint(x: minX, y: yt - r), control: CGPoint(x: minX, y: yt))
        p.closeSubpath()
        return p
    }

    // Per-Space awareness via SkyLight (the same private call yabai uses), resolved by dlsym so a
    // missing symbol degrades to a single shared Space (0) instead of crashing.
    private static let activeSpaceFn: (() -> UInt64)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let cidSym = dlsym(h, "SLSMainConnectionID"),
              let spSym = dlsym(h, "SLSGetActiveSpace") else { return nil }
        typealias CIDFn = @convention(c) () -> Int32
        typealias SpFn = @convention(c) (Int32) -> UInt64
        let cid = unsafeBitCast(cidSym, to: CIDFn.self)()
        let sp = unsafeBitCast(spSym, to: SpFn.self)
        return { sp(cid) }
    }()
    static func currentSpaceID() -> UInt64 { activeSpaceFn?() ?? 0 }
}

// MARK: - Overlay store (one window per Space+display) -----------------------------

private final class TintOverlayWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class OverlayStore {
    private final class Overlay {
        let window: NSWindow; let dim: CALayer; let mask: CAShapeLayer; var shown: RGBA
        var lastColorKey: UInt32 = 0; var lastRectsKey: Int = 0
        init(_ w: NSWindow, _ d: CALayer, _ m: CAShapeLayer) { window = w; dim = d; mask = m; shown = .clear }
    }
    private var overlays: [UInt64: [CGDirectDisplayID: Overlay]] = [:]

    var windowNumbers: [Int] {
        overlays.values.flatMap { $0.values.map { $0.window.windowNumber } }
    }

    func teardown() {
        for byDisplay in overlays.values { for ov in byDisplay.values { ov.window.orderOut(nil) } }
        overlays.removeAll()
    }

    func hide(space: UInt64, screen: NSScreen) {
        guard let id = screen.tintDisplayID, let ov = overlays[space]?[id], ov.window.isVisible else { return }
        ov.window.orderOut(nil)
    }

    /// Render the dim for `space` on `screen`. Returns true if a new overlay window was created
    /// (so the caller can refresh capture exceptions). `windows` are display-local top-left rects.
    @discardableResult
    func update(space: UInt64, screen: NSScreen, windows: [TintGeometry.Win], color: RGBA,
                opacity: CGFloat, rectsKey: Int, ema: CGFloat, tintBrightness: CGFloat) -> Bool {
        let (ov, created) = overlayFor(space: space, screen: screen)
        guard let ov else { return false }
        ov.shown = ov.shown.lerp(to: color, ema)
        func q(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        let tb = tintBrightness
        let colorKey = (q(ov.shown.r * tb) << 24) | (q(ov.shown.g * tb) << 16) | (q(ov.shown.b * tb) << 8) | q(opacity)
        let wasVisible = ov.window.isVisible
        if wasVisible, colorKey == ov.lastColorKey, rectsKey == ov.lastRectsKey { return created }
        ov.lastColorKey = colorKey; ov.lastRectsKey = rectsKey

        let H = ov.dim.bounds.height
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: ov.dim.bounds.size))   // whole screen
        for win in windows {                                            // rounded-top holes
            let r = win.rect
            let bl = CGRect(x: r.minX, y: H - r.minY - r.height, width: r.width, height: r.height)
            path.addPath(TintGeometry.roundedTopRect(bl, radius: win.radius))
        }
        if !wasVisible { ov.window.orderFrontRegardless() }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ov.mask.path = path   // even-odd: screen minus windows = the exposed desktop gaps
        ov.dim.backgroundColor = CGColor(srgbRed: ov.shown.r * tb, green: ov.shown.g * tb, blue: ov.shown.b * tb, alpha: opacity)
        CATransaction.commit()
        return created
    }

    private func overlayFor(space: UInt64, screen: NSScreen) -> (Overlay?, Bool) {
        guard let id = screen.tintDisplayID else { return (nil, false) }
        if let ov = overlays[space]?[id] {
            if ov.window.frame.size != screen.frame.size {
                ov.window.setFrame(screen.frame, display: true)
                ov.dim.frame = CGRect(origin: .zero, size: screen.frame.size)
                ov.mask.frame = ov.dim.frame
            }
            return (ov, false)
        }
        let ov = makeWindow(frame: screen.frame)
        overlays[space, default: [:]][id] = ov
        return (ov, true)
    }

    private func makeWindow(frame: NSRect) -> Overlay {
        let w = TintOverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.hasShadow = false; w.ignoresMouseEvents = true
        w.backgroundColor = .clear; w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        w.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]   // pinned to ONE Space
        w.sharingType = .readOnly                                      // capturable, for Spectra's overlay exceptions
        let dim = CALayer(); dim.frame = CGRect(origin: .zero, size: frame.size)
        let mask = CAShapeLayer(); mask.frame = dim.frame; mask.fillRule = .evenOdd
        dim.mask = mask
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true; view.layer = dim
        w.contentView = view
        return Overlay(w, dim, mask)
    }
}

private extension NSScreen {
    var tintDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

// MARK: - Low-res colour capture --------------------------------------------------

struct Grid: Sendable { let cols: Int; let rows: Int; let px: [RGBA] }

private final class TintGridOutput: NSObject, SCStreamOutput {
    let displayID: CGDirectDisplayID
    let cols: Int, rows: Int
    private let sink: @Sendable (CGDirectDisplayID, Grid) -> Void
    init(displayID: CGDirectDisplayID, cols: Int, rows: Int, sink: @escaping @Sendable (CGDirectDisplayID, Grid) -> Void) {
        self.displayID = displayID; self.cols = cols; self.rows = rows; self.sink = sink
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sb),
              let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = arr.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let px = CMSampleBufferGetImageBuffer(sb), let g = grid(px) else { return }
        sink(displayID, g)
    }
    private func grid(_ px: CVImageBuffer) -> Grid? {
        guard CVPixelBufferGetPixelFormatType(px) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(px) else { return nil }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        guard w > 0, h > 0 else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(px), bpp = 4
        guard bpr >= w * bpp else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out = [RGBA](repeating: .clear, count: cols * rows)
        for ry in 0..<rows {
            let y0 = ry * h / rows, y1 = max(y0 + 1, (ry + 1) * h / rows)
            for cx in 0..<cols {
                let x0 = cx * w / cols, x1 = max(x0 + 1, (cx + 1) * w / cols)
                var rb: CGFloat = 0, gb: CGFloat = 0, bb: CGFloat = 0, n = 0
                var y = y0
                while y < y1 && y < h {
                    var x = x0
                    while x < x1 && x < w { let o = y * bpr + x * bpp; bb += CGFloat(p[o]); gb += CGFloat(p[o+1]); rb += CGFloat(p[o+2]); n += 1; x += 1 }
                    y += 1
                }
                let inv = 1.0 / (CGFloat(max(1, n)) * 255.0)
                out[ry * cols + cx] = RGBA(r: rb * inv, g: gb * inv, b: bb * inv, a: 1)
            }
        }
        return Grid(cols: cols, rows: rows, px: out)
    }
}

@MainActor
private final class TintCapture: NSObject, SCStreamDelegate {
    private static let gridCols = 64
    private static let captureFPS = 10
    private var streams: [CGDirectDisplayID: SCStream] = [:]
    // SCStream does NOT retain its output, so the GridOutput must be held alive here or it
    // deallocates and the stream silently delivers no frames (the bug that hid the tint).
    private var outputs: [CGDirectDisplayID: TintGridOutput] = [:]
    private let sampleQueue = DispatchQueue(label: "spectra.tint.sample", qos: .userInitiated)
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    var gridSink: (@Sendable (CGDirectDisplayID, Grid) -> Void)?

    func rebuild() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
            Log.capture.error("[tint] rebuild: SCShareableContent unavailable (Screen Recording not granted?)")
            return
        }
        let excluded = content.applications.filter { $0.processID == ownPID }   // never sample Spectra's own windows
        let screens = NSScreen.screens.compactMap { s -> (CGDirectDisplayID, SCDisplay)? in
            guard let id = s.tintDisplayID, let scd = content.displays.first(where: { $0.displayID == id }) else { return nil }
            return (id, scd)
        }
        Log.capture.error("[tint] rebuild: \(screens.count) screen(s), \(excluded.count) excluded")
        let wanted = Set(screens.map { $0.0 })
        for (id, st) in streams where !wanted.contains(id) { try? await st.stopCapture(); streams[id] = nil; outputs[id] = nil }
        for (id, scd) in screens { await start(id: id, display: scd, excluded: excluded) }
    }

    func stop() async {
        for st in streams.values { try? await st.stopCapture() }
        streams.removeAll()
        outputs.removeAll()
    }

    private func start(id: CGDirectDisplayID, display: SCDisplay, excluded: [SCRunningApplication]) async {
        if let old = streams[id] { try? await old.stopCapture(); streams[id] = nil; outputs[id] = nil }
        let cols = Self.gridCols
        let rows = max(1, Int((Double(cols) * Double(display.height) / Double(max(1, display.width))).rounded()))
        let cfg = SCStreamConfiguration()
        cfg.width = cols; cfg.height = rows; cfg.scalesToFit = true
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.captureFPS))
        cfg.queueDepth = 4; cfg.showsCursor = false; cfg.pixelFormat = kCVPixelFormatType_32BGRA
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let sink = gridSink ?? { _, _ in }
        let out = TintGridOutput(displayID: id, cols: cols, rows: rows, sink: sink)
        outputs[id] = out   // retain or the stream stops delivering frames
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture(); streams[id] = stream
            Log.capture.error("[tint] stream started display \(id, privacy: .public)")
        } catch {
            Log.capture.error("Adaptive tint sample stream failed for \(id, privacy: .public): \(error.localizedDescription)")
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, let id = self.streams.first(where: { $0.value === stream })?.key else { return }
            self.streams[id] = nil
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self.rebuild()
        }
    }
}
