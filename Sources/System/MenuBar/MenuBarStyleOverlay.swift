import AppKit
import QuartzCore

/// Per-theme menu-bar treatment (MAOE §9): a borderless, click-through `NSWindow` above the
/// menu-bar chrome on each screen, drawing the style as a `CALayer` composite. Self-excluded
/// from Spectra's capture automatically (the SCK filter excludes the whole PID, so this
/// in-process window is never filmed); also `sharingType = .none` so external screenshots skip
/// the decoration. Never intercepts input (`ignoresMouseEvents`).
@MainActor
final class MenuBarStyleOverlay {
    private var windows: [CGDirectDisplayID: StyleWindow] = [:]
    private var style: MenuBarStyle = .none
    private var light = LightModel()

    /// Apply (or clear with `.none`) the menu-bar style across every screen.
    func apply(_ style: MenuBarStyle?, light: LightModel?) {
        let resolved = style ?? .none
        self.style = resolved
        if let light { self.light = light }
        guard resolved != .none else { teardown(); return }
        reconcile()
    }

    func teardown() {
        for w in windows.values { w.orderOut(nil) }
        windows.removeAll()
        style = .none
    }

    private func reconcile() {
        var live: Set<CGDirectDisplayID> = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            live.insert(id)
            // Menu-bar strip = the top inset between frame and visibleFrame, plus a soft falloff
            // band below it for the shadow.
            let menuBarH = screen.frame.maxY - screen.visibleFrame.maxY
            guard menuBarH > 0 else { windows[id]?.orderOut(nil); windows[id] = nil; continue }
            let falloff: CGFloat = 16
            let rect = CGRect(x: screen.frame.minX, y: screen.visibleFrame.maxY - falloff,
                              width: screen.frame.width, height: menuBarH + falloff)
            let w = windows[id] ?? StyleWindow(frame: rect)
            windows[id] = w
            w.setFrame(rect, display: false)
            w.draw(style: style, light: light, menuBarHeight: menuBarH, falloff: falloff)
            w.orderFrontRegardless()
        }
        for (id, w) in windows where !live.contains(id) { w.orderOut(nil); windows[id] = nil }
    }
}

/// A click-through borderless window hosting one styled `CALayer` for the menu-bar strip.
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
        level = OverlayWindow.aboveMenuBarLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        sharingType = .none
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer = content
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A small random-grain image for the silent-film grain layer (built once).
    static let noiseImage: CGImage? = {
        let w = 160, h = 28, bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in stride(from: 0, to: bytes.count, by: 4) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let v = UInt8((seed >> 33) & 0xFF)
            bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255
        }
        return bytes.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }()

    func draw(style: MenuBarStyle, light: LightModel, menuBarHeight: CGFloat, falloff: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.frame = CGRect(origin: .zero, size: frame.size)
        content.sublayers = nil
        let w = content.bounds.width, h = content.bounds.height
        // The strip occupies the top `menuBarHeight`; the falloff band sits below it.
        let barRect = CGRect(x: 0, y: h - menuBarHeight, width: w, height: menuBarHeight)

        switch style {
        case .none:
            break
        case .softShadow:
            // A soft drop shadow under the menu bar, biased by the light direction.
            let shadow = CAGradientLayer()
            shadow.frame = CGRect(x: 0, y: max(0, h - menuBarHeight - falloff), width: w, height: falloff)
            let a = 0.35 * light.intensity
            shadow.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: a)]
            shadow.startPoint = CGPoint(x: 0.5, y: 0); shadow.endPoint = CGPoint(x: 0.5, y: 1)
            content.addSublayer(shadow)
        case .caption:
            // Silent-film caption card: a warm-dark strip with jittering vertical scratch lines,
            // animated grain, a projector flicker, and a hairline caption border.
            let now = CACurrentMediaTime()
            let card = CALayer(); card.frame = barRect
            card.backgroundColor = CGColor(srgbRed: 0.07, green: 0.06, blue: 0.05, alpha: 0.55)
            content.addSublayer(card)
            let flick = CABasicAnimation(keyPath: "opacity")
            flick.fromValue = 0.82; flick.toValue = 1.0; flick.duration = 0.14
            flick.autoreverses = true; flick.repeatCount = .infinity; flick.timeOffset = now
            card.add(flick, forKey: "projector")

            // Vertical film scratches: thin lines that blink at staggered rates (film wear).
            let xs: [CGFloat] = [0.1, 0.27, 0.46, 0.63, 0.81, 0.93]
            for (k, fx) in xs.enumerated() {
                let line = CALayer()
                line.frame = CGRect(x: w * fx + CGFloat((k * 7) % 11), y: barRect.minY,
                                    width: k == 2 ? 1.5 : 1.0, height: barRect.height)
                line.backgroundColor = CGColor(gray: k % 2 == 0 ? 0.95 : 0.02, alpha: 0.55)
                let f = CABasicAnimation(keyPath: "opacity")
                f.fromValue = 0.0; f.toValue = 0.6; f.duration = 0.07 + Double(k) * 0.06
                f.autoreverses = true; f.repeatCount = .infinity; f.timeOffset = now + Double(k) * 0.4
                line.add(f, forKey: "scratch")
                content.addSublayer(line)
            }

            // Animated grain over the card.
            if let noise = Self.noiseImage {
                let grain = CALayer(); grain.frame = barRect
                grain.contents = noise; grain.opacity = 0.12
                let g = CABasicAnimation(keyPath: "opacity")
                g.fromValue = 0.06; g.toValue = 0.2; g.duration = 0.09
                g.autoreverses = true; g.repeatCount = .infinity; g.timeOffset = now
                grain.add(g, forKey: "grain")
                content.addSublayer(grain)
            }

            let border = CALayer()
            border.frame = CGRect(x: 0, y: barRect.minY, width: w, height: 1.2)
            border.backgroundColor = CGColor(gray: 0.95, alpha: 0.6)
            content.addSublayer(border)
        case .reflective:
            // Frutiger clear reflective bar: a glossy top-weighted gradient.
            let gloss = CAGradientLayer(); gloss.frame = barRect
            gloss.colors = [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28),
                            CGColor(srgbRed: 0.7, green: 0.88, blue: 1, alpha: 0.06)]
            gloss.startPoint = CGPoint(x: 0.5, y: 1); gloss.endPoint = CGPoint(x: 0.5, y: 0)
            content.addSublayer(gloss)
        case .pastel:
            // Fuji matte pastel wash.
            let wash = CALayer(); wash.frame = barRect
            wash.backgroundColor = CGColor(srgbRed: 0.98, green: 0.92, blue: 0.86, alpha: 0.16)
            content.addSublayer(wash)
        }
        CATransaction.commit()
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
