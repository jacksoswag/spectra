import AppKit
import Metal
import QuartzCore

/// A layer-backed view whose backing layer is a `CAMetalLayer`. Keeps the
/// drawable size synchronised with the view's pixel dimensions.
final class MetalLayerHostView: NSView {
    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        // Default to an 8-bit SDR drawable: half the bandwidth and VRAM of a
        // 16-bit float drawable, which matters at native Retina resolution. EDR
        // (16-bit float + extended range) is opted into only on capable displays
        // via setEDR, where bright effect output can map to real HDR luminance.
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.presentsWithTransaction = false
        layer.allowsNextDrawableTimeout = true
        // Double-buffered, not triple. GPU time (~12ms) fits inside the 60Hz frame
        // budget with headroom, so a third in-flight drawable just sits buffered ahead
        // of scan-out — it adds ~one frame of present latency without improving
        // throughput. Because present() runs in a display-synced command buffer, that
        // extra buffered frame also inflates the reported latency (which closes at
        // command-buffer completion). Kept in lock-step with DisplayRenderer.maxInFlight;
        // raise both back to 3 if the heaviest chains start dropping frames.
        layer.maximumDrawableCount = 2
        layer.displaySyncEnabled = true
        layer.needsDisplayOnBoundsChange = true
        return layer
    }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(device: MTLDevice, scale: CGFloat) {
        metalLayer.device = device
        metalLayer.contentsScale = scale
        updateDrawableSize(scale: scale)
    }

    /// Switch the drawable between SDR (8-bit) and EDR (16-bit float, extended
    /// range) based on the target display's capability.
    func setEDR(enabled: Bool) {
        if enabled {
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedSRGB)
            metalLayer.wantsExtendedDynamicRangeContent = true
        } else {
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            metalLayer.wantsExtendedDynamicRangeContent = false
        }
    }

    func updateDrawableSize(scale: CGFloat) {
        let size = bounds.size
        let pixelSize = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        if metalLayer.drawableSize != pixelSize {
            metalLayer.drawableSize = pixelSize
        }
    }
}

/// A borderless, click-through, always-on-top window that fills a single display
/// and hosts the Metal layer onto which the processed desktop is presented. The
/// window sits above ordinary application windows — including Spectra's own Studio and
/// Settings windows, which sit below it and are captured + rendered through the chain
/// like any other window (only the overlay itself is excluded from capture).
final class OverlayWindow: NSWindow {
    /// The overlay sits just *below* the Dock — and therefore below the menu bar
    /// and its status items too — so it still covers every ordinary application
    /// window (normal, floating, and modal-panel levels are all lower) while
    /// leaving the menu bar, Spectra's own status item, and the Dock visible and
    /// clickable. At the previous `.overlayWindow` level (102) the opaque overlay
    /// painted over the menu bar item and the Studio window, so once a shader was
    /// enabled it could not be changed or removed without quitting from the Dock.
    ///
    /// Tradeoff: windows another app pins at or above the utility level (= this
    /// level, `.dockWindow - 1`) — floating HUD/tool palettes, always-on-top
    /// widgets — render over the shader rather than under it. Keeping the menu bar
    /// usable is worth that; the alternative (covering everything) is what hid the
    /// controls.
    ///
    /// The default ("Cover menu bar & Dock" off). Effects stop at the desktop; the
    /// real menu bar, status items, and Dock paint over the shader.
    static let belowMenuBarLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)

    /// The "Cover menu bar & Dock" level: above the menu bar, its status items, and
    /// the Dock, so warp/grade/bloom cover the *entire* display. Bounded just one
    /// step above the highest system chrome — deliberately NOT `CGShieldingWindowLevel()`
    /// (~2.1e9), which would also float over Mission Control and other apps'
    /// full-screen UI. The overlay stays click-through (`ignoresMouseEvents`), so the
    /// covered menu bar and Dock remain clickable underneath; Spectra's own control
    /// windows sit below the overlay (captured and rendered through the chain), and a
    /// global panic hotkey disables the overlay if the controls are ever hard to reach.
    static let aboveMenuBarLevel = NSWindow.Level(rawValue:
        max(Int(CGWindowLevelForKey(.mainMenuWindow)),
            max(Int(CGWindowLevelForKey(.statusWindow)),
                Int(CGWindowLevelForKey(.dockWindow)))) + 1)

    let displayID: CGDirectDisplayID
    private let host: MetalLayerHostView

    /// Steady-state behavior: present on the current Space only, follows the user.
    static let singleSpaceBehavior: NSWindow.CollectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
    /// Transient behavior used only for an instant while carrying the window onto a
    /// newly-active Space (never left set, or it merges every desktop).
    static let allSpacesBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

    init(displayID: CGDirectDisplayID, frame: CGRect, scale: CGFloat, device: MTLDevice) {
        self.displayID = displayID
        self.host = MetalLayerHostView(frame: CGRect(origin: .zero, size: frame.size))

        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)

        isReleasedWhenClosed = false
        level = Self.belowMenuBarLevel
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = true
        // `.transient` keeps the overlay on the current Space and auto-hides it in
        // Exposé / Mission Control; `.fullScreenAuxiliary` additionally lets it
        // appear over another app's full-screen Space. `.canJoinAllSpaces` is
        // deliberately NOT used as a steady state — one opaque window present on
        // *every* Space at once is fed by a single active-Space capture, so it
        // visually merges the desktops and breaks Mission Control (tried and reverted
        // on-device). Instead the overlay FOLLOWS the user one Space at a time; see
        // `carryToActiveSpace`.
        collectionBehavior = Self.singleSpaceBehavior
        displaysWhenScreenProfileChanges = true
        isExcludedFromWindowsMenu = true
        sharingType = .none

        contentView = host
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.configure(device: device, scale: scale)
        setFrame(frame, display: false)
    }

    var metalLayer: CAMetalLayer { host.metalLayer }

    /// Raise the overlay above the menu bar/status items/Dock (covering them with
    /// processed output) or drop it back below them. Applied live; the renderer
    /// re-pegs control windows to match.
    func setCoversMenuBarAndDock(_ covers: Bool) {
        level = covers ? Self.aboveMenuBarLevel : Self.belowMenuBarLevel
    }

    /// Reliably carry this single-Space overlay onto the now-active Space. Ordering a
    /// `.transient` window front from another Space can leave it on the *outgoing*
    /// Space (the "shader only works on one Space" symptom). Briefly joining all
    /// Spaces lands it on the active one; we revert to single-Space on the next
    /// runloop turn so the overlay is never permanently present everywhere (which
    /// merges desktops and Mission Control).
    func carryToActiveSpace() {
        collectionBehavior = Self.allSpacesBehavior
        orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.collectionBehavior = Self.singleSpaceBehavior
            self.orderFrontRegardless()
        }
    }

    /// Enable EDR presentation for this display (no-op visual change on SDR panels).
    func setEDR(enabled: Bool) { host.setEDR(enabled: enabled) }

    /// Update geometry when the display configuration changes.
    func update(frame: CGRect, scale: CGFloat) {
        setFrame(frame, display: false)
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.updateDrawableSize(scale: scale)
        host.metalLayer.contentsScale = scale
    }

    func show() {
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
