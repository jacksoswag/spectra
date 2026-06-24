import SwiftUI
import AppKit

/// The prism mark used on the menu-bar status item: a beam enters the left face of
/// a triangle and leaves the right as a fanned spectrum — the "Dark Side of the Moon"
/// prism, and the same mark as the app's wordmark (`website/public/logo.svg`), reduced
/// to a clean monochrome line drawing.
///
/// Drawn as a *template* `NSImage` so the menu bar tints it like an SF Symbol — dark on
/// a light bar, light on a dark bar, inverted while the item is highlighted. A coloured
/// image can't do that, so the brand spectrum is implied by the fan rather than painted.
struct PrismMark: View {
    var height: CGFloat = 16

    var body: some View {
        Image(nsImage: PrismMark.image(height: height))
    }
}

extension PrismMark {
    /// Padded bounds of the wordmark's prism, in its own SVG coordinate space, so the
    /// menu-bar mark stays geometrically coherent with the logo.
    private static let box = CGRect(x: -1.5, y: 2.5, width: 33, height: 22)

    static func image(height: CGFloat) -> NSImage {
        let scale = height / box.height
        let size = NSSize(width: box.width * scale, height: height)

        // SVG y points down; AppKit's image space points up. Map and scale each point.
        func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: (x - box.minX) * scale, y: size.height - (y - box.minY) * scale)
        }

        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()

            let prism = NSBezierPath()
            prism.lineJoinStyle = .round
            prism.lineWidth = 1.6 * scale
            prism.move(to: at(15, 5.3))
            prism.line(to: at(24.9, 22.4))
            prism.line(to: at(5.1, 22.4))
            prism.close()
            prism.stroke()

            // The beam enters at a slight upward angle and disperses where it meets the
            // prism's left face: the three rays fan out from that entry point, through the
            // glass and out the right side. Beam and rays share the point, so it's one path.
            let entry = at(10.8, 12.5)

            let beam = NSBezierPath()
            beam.lineCapStyle = .round
            beam.lineWidth = 1.6 * scale
            beam.move(to: at(0, 14.5))
            beam.line(to: entry)
            beam.stroke()

            let spectrum = NSBezierPath()
            spectrum.lineCapStyle = .round
            spectrum.lineWidth = 1.4 * scale
            for end in [at(29, 9), at(29, 15), at(29, 21)] {
                spectrum.move(to: entry)
                spectrum.line(to: end)
            }
            spectrum.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }
}
