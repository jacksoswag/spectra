import SwiftUI
import simd

/// Centralised design tokens and reusable styling for a premium, dark-leaning
/// macOS look. Keeping these in one place keeps the UI cohesive.
enum Theme {
    static let accent = Color.accentColor
    static let positive = Color.green
    static let warning = Color.orange
    static let danger = Color.red

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 16
    }

    static func categoryTint(_ category: EffectCategory) -> Color {
        switch category {
        case .color: .pink
        case .sharpen: .teal
        case .blur: .blue
        case .distortion: .purple
        case .retro: .green
        case .vhs: .indigo
        case .camcorder: .mint
        case .film: .orange
        case .noise: .gray
        case .pixel: .cyan
        case .glitch: .red
        case .environment: .blue
        case .artistic: .brown
        case .system: .blue
        case .custom: accent
        }
    }
}

// MARK: - Card styling

private struct CardBackground: ViewModifier {
    var selected: Bool = false
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.08),
                                  lineWidth: selected ? 1.5 : 1))
    }
}

extension View {
    func spectraCard(selected: Bool = false) -> some View {
        modifier(CardBackground(selected: selected))
    }
}

// MARK: - Color <-> SIMD bridging

extension Color {
    init(simd: SIMD4<Double>) {
        self = Color(.sRGB, red: simd.x, green: simd.y, blue: simd.z, opacity: simd.w)
    }

    var simd4: SIMD4<Double> {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        return SIMD4(Double(ns.redComponent), Double(ns.greenComponent),
                     Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}
