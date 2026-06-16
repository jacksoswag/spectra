import Foundation
import CoreGraphics

/// Immutable snapshot of a connected display's geometry and timing. Used by the
/// UI (per-display targeting/presets) and by the capture/render pipelines.
struct DisplayInfo: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    /// Global frame in points (AppKit coordinate space).
    let frame: CGRect
    /// Native backing resolution in pixels.
    let pixelWidth: Int
    let pixelHeight: Int
    /// Backing scale factor (1 for standard, 2 for Retina).
    let scale: CGFloat
    /// Maximum refresh rate in Hz (e.g. 60, 120 for ProMotion).
    let refreshRate: Double
    let isMain: Bool
    /// Peak EDR headroom (`NSScreen.maximumExtendedDynamicRangeColorComponentValue`).
    /// 1.0 on SDR displays; >1 on EDR/HDR-capable panels.
    var maxEDRHeadroom: Double = 1.0

    /// Whether this display can present extended-dynamic-range content.
    var supportsEDR: Bool { maxEDRHeadroom > 1.0 }

    var pointSize: CGSize { frame.size }

    var resolutionLabel: String { "\(pixelWidth) × \(pixelHeight)" }

    var refreshLabel: String {
        refreshRate > 0 ? "\(Int(refreshRate.rounded())) Hz" : "—"
    }
}
