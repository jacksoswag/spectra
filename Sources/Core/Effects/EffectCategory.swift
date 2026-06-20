import Foundation

/// Top-level grouping for the effect library. Drives the searchable library UI
/// and preset organisation.
enum EffectCategory: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case color = "Color"
    case sharpen = "Sharpen"
    case blur = "Blur"
    case distortion = "Distortion"
    case retro = "Retro / CRT"
    case vhs = "VHS"
    case camcorder = "Camcorder"
    case film = "Film"
    case noise = "Noise"
    case pixel = "Pixel"
    case glitch = "Glitch"
    case environment = "Environment"
    case artistic = "Artistic"
    case accessibility = "Accessibility"
    case custom = "Custom"

    var id: String { rawValue }

    var displayName: String { rawValue }

    /// SF Symbol used in the sidebar / library headers.
    var iconSystemName: String {
        switch self {
        case .color: "paintpalette"
        case .sharpen: "triangle"
        case .blur: "drop"
        case .distortion: "tornado"
        case .retro: "tv"
        case .vhs: "rectangle.on.rectangle.angled"
        case .camcorder: "video"
        case .film: "film"
        case .noise: "waveform.path"
        case .pixel: "squareshape.split.3x3"
        case .glitch: "bolt.horizontal"
        case .environment: "cloud.rain"
        case .artistic: "paintbrush.pointed.fill"
        case .accessibility: "accessibility"
        case .custom: "wand.and.stars"
        }
    }

    /// Short description shown as a section subtitle.
    var summary: String {
        switch self {
        case .color: "Grade, balance, and stylise color."
        case .sharpen: "Enhance detail and local contrast."
        case .blur: "Soften, defocus, and add motion."
        case .distortion: "Bend, warp, and displace the image."
        case .retro: "CRT tubes, masks, and analog TV."
        case .vhs: "Magnetic tape artifacts and decay."
        case .camcorder: "Consumer camcorder looks and overlays."
        case .film: "Celluloid grain, gate weave, and halation."
        case .noise: "A procedural noise framework."
        case .pixel: "Pixelation, dithering, and quantization."
        case .glitch: "Digital corruption and signal failure."
        case .environment: "Atmospheric weather and light."
        case .artistic: "Painterly, cel, ink, and pixel mediums."
        case .accessibility: "Vision assistance and comfort."
        case .custom: "Your imported and authored effects."
        }
    }
}
