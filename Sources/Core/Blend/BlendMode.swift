import Foundation

/// Compositing operators applied between an effect's input ("base") and its
/// processed output. The raw values are the contract shared with the Metal
/// `spectra_blend` function in `SpectraCommon.h` — keep them in sync.
///
/// Declaration order is the order shown in the inspector; it follows the product
/// spec's grouping. Raw values are explicit and must never be reused, so older
/// presets keep decoding to the same operator.
enum BlendMode: Int, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case normal = 0
    case add = 6
    case subtract = 7
    case multiply = 1
    case screen = 2
    case overlay = 3
    case softLight = 4
    case hardLight = 5
    case difference = 8
    case darken = 10
    case lighten = 9
    case colorDodge = 11
    case colorBurn = 12
    case linearDodge = 14
    case linearBurn = 15
    case exclusion = 13

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .add: "Add"
        case .subtract: "Subtract"
        case .multiply: "Multiply"
        case .screen: "Screen"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .difference: "Difference"
        case .darken: "Darken"
        case .lighten: "Lighten"
        case .colorDodge: "Color Dodge"
        case .colorBurn: "Color Burn"
        case .linearDodge: "Linear Dodge"
        case .linearBurn: "Linear Burn"
        case .exclusion: "Exclusion"
        }
    }

    /// Tolerant decode: an unknown stored raw value (e.g. a removed operator)
    /// falls back to `.normal` rather than failing the whole document.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = BlendMode(rawValue: raw) ?? .normal
    }
}
