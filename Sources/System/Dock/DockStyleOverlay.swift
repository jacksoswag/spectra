import AppKit
import QuartzCore

/// Per-theme Dock treatment (MAOE §9): a borderless, click-through `NSWindow` positioned over
/// the Dock, drawing the style as a `CALayer`. Auto-excluded from Spectra's capture by the PID
/// filter (in-process window) and `sharingType = .none` for external screenshots. The Dock rect
/// and orientation come from `CGWindowList` filtered on `kCGWindowOwnerName == "Dock"`.
@MainActor
final class DockStyleOverlay {
    private var window: StyleWindow?
    private var style: DockStyle = .none
    private var light = LightModel()

    func apply(_ style: DockStyle?, light: LightModel?) {
        let resolved = style ?? .none
        self.style = resolved
        if let light { self.light = light }
        guard resolved != .none else { teardown(); return }
        reconcile()
    }

    func teardown() {
        window?.orderOut(nil)
        window = nil
        style = .none
    }

    /// Recompute the Dock rect and redraw. Cheap; called on apply and can be re-called on a
    /// Dock move (the engine reconciles system effects on the relevant events).
    func reconcile() {
        guard style != .none, let dock = Self.dockRect() else { teardown(); return }
        // Behind the Dock for shadows/frames; in front (still click-through) for outlines.
        let inFront = (style == .neonOutline)
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        // Pad the window so a shadow/outline has room around the Dock rect.
        let pad: CGFloat = 28
        let frame = dock.rect.insetBy(dx: -pad, dy: -pad)
        let w = window ?? StyleWindow(frame: frame)
        window = w
        w.level = NSWindow.Level(rawValue: dockLevel + (inFront ? 1 : -1))
        w.setFrame(frame, display: false)
        w.draw(style: style, light: light, dockRect: CGRect(origin: CGPoint(x: pad, y: pad), size: dock.rect.size),
               orientation: dock.orientation)
        w.orderFrontRegardless()
    }

    enum Orientation { case bottom, left, right }

    /// The Dock's window rect in AppKit global coords (bottom-left) plus its edge, or nil when
    /// the Dock is hidden (auto-hide) — in which case no decoration is drawn.
    private static func dockRect() -> (rect: CGRect, orientation: Orientation)? {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        var best: CGRect?
        for info in infos {
            guard (info[kCGWindowOwnerName as String] as? String) == "Dock",
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width > 40, height > 20 else { continue }
            let r = CGRect(x: x, y: y, width: width, height: height)
            if best == nil || r.width * r.height > best!.width * best!.height { best = r }
        }
        guard let cg = best else { return nil }
        // CG top-left → AppKit bottom-left, flipped about the primary (menu-bar) screen height.
        let primaryH = NSScreen.screens.first?.frame.height ?? cg.maxY
        let appKit = CGRect(x: cg.minX, y: primaryH - cg.maxY, width: cg.width, height: cg.height)
        let orientation: Orientation = cg.width > cg.height ? .bottom : (cg.minX < 4 ? .left : .right)
        return (appKit, orientation)
    }
}

@MainActor
private final class StyleWindow: NSWindow {
    private let content = CALayer()

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        sharingType = .none
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer = content
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func draw(style: DockStyle, light: LightModel, dockRect: CGRect, orientation: DockStyleOverlay.Orientation) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.frame = CGRect(origin: .zero, size: frame.size)
        content.sublayers = nil
        let radius: CGFloat = 18

        switch style {
        case .none:
            break
        case .groundedShadow:
            // A soft ambient shadow grounding the Dock (below it, in the light direction).
            let shadow = CALayer()
            shadow.frame = dockRect.insetBy(dx: -10, dy: -6).offsetBy(dx: 0, dy: -8)
            shadow.backgroundColor = CGColor(gray: 0, alpha: 0.4 * light.intensity)
            shadow.cornerRadius = radius + 8
            shadow.shadowOpacity = 0; shadow.masksToBounds = false
            // Blur via a CIFilter-free gaussian look: a radial-ish gradient is overkill; a soft
            // semi-opaque rounded rect reads as a grounded shadow under the Dock.
            content.addSublayer(shadow)
        case .stageFrame:
            let frameLayer = CALayer()
            frameLayer.frame = dockRect.insetBy(dx: -6, dy: -6)
            frameLayer.cornerRadius = radius + 6
            frameLayer.borderWidth = 1.5
            frameLayer.borderColor = CGColor(gray: 1, alpha: 0.25)
            content.addSublayer(frameLayer)
        case .neonOutline:
            let outline = CALayer()
            outline.frame = dockRect.insetBy(dx: -3, dy: -3)
            outline.cornerRadius = radius + 3
            outline.borderWidth = 2
            let col = light.color
            outline.borderColor = CGColor(srgbRed: col.x, green: col.y, blue: col.z, alpha: 0.9)
            outline.shadowColor = outline.borderColor
            outline.shadowOpacity = 0.9; outline.shadowRadius = 8; outline.masksToBounds = false
            content.addSublayer(outline)
        case .mattePastel:
            let wash = CALayer(); wash.frame = dockRect
            wash.cornerRadius = radius
            wash.backgroundColor = CGColor(srgbRed: 0.98, green: 0.92, blue: 0.86, alpha: 0.14)
            content.addSublayer(wash)
        case .reflective:
            let gloss = CAGradientLayer(); gloss.frame = dockRect
            gloss.cornerRadius = radius
            gloss.colors = [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
                            CGColor(srgbRed: 0.6, green: 0.85, blue: 1, alpha: 0.05)]
            gloss.startPoint = CGPoint(x: 0.5, y: 1); gloss.endPoint = CGPoint(x: 0.5, y: 0)
            content.addSublayer(gloss)
        }
        CATransaction.commit()
    }
}
