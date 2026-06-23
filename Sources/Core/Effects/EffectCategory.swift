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
    case interaction = "Interaction"
    case cursor = "Cursor"
    case chrome = "Window Chrome"
    case system = "System / Desktop"
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
        case .interaction: "cursorarrow.click"
        case .cursor: "cursorarrow"
        case .chrome: "macwindow"
        case .system: "macwindow.on.rectangle"
        case .custom: "wand.and.stars"
        }
    }
}
