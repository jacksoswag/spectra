import Foundation

/// How a world restyles the cursor (MAOE §6). The restyle variants operate on whatever shape
/// the system cursor currently is (so they cover I-beam / resize / loading states); a `sprite`
/// style is the world's own pointer and is shown whenever it is active, independent of the
/// system cursor's current shape.
enum CursorStyle: Codable, Sendable, Hashable {
    case system
    case neonCyan
    case pixelGreen
    case warmTint
    case sprite(SpriteKind)
    case customImage(CursorImageSet)   // user-supplied sprite images (Custom Cursor effect)

    /// Stable index handed to the cursor shader's `styleIndex` branch. Sprite/custom styles do no
    /// shader work (the sprite is substituted upstream), so they share the passthrough index.
    var shaderIndex: Int {
        switch self {
        case .system, .sprite, .customImage: return 0
        case .neonCyan: return 1
        case .pixelGreen: return 2
        case .warmTint: return 3
        }
    }

    /// The sprite to substitute for the arrow, if this is a built-in sprite style.
    var spriteKind: SpriteKind? {
        if case let .sprite(kind) = self { return kind }
        return nil
    }

    /// The user-supplied images, if this is a custom-image style.
    var customImages: CursorImageSet? {
        if case let .customImage(set) = self { return set }
        return nil
    }
}

/// User-supplied cursor sprite images (filenames under `AppPaths.cursorsDirectory`), one per role.
/// An empty filename for a role falls back to the arrow image; an all-empty set means no cursor.
struct CursorImageSet: Codable, Sendable, Hashable {
    var arrow: String = ""
    var hand: String = ""
    var text: String = ""
    var isEmpty: Bool { arrow.isEmpty && hand.isEmpty && text.isEmpty }
}

/// Bespoke per-world cursor art (MAOE §6). Each is a pre-rasterized sprite with an authored
/// hotspot, shown as the world's pointer whenever its sprite style is active.
enum SpriteKind: String, Codable, Sendable, Hashable, CaseIterable {
    case noirObject    // Noir 1930s real-world object (with a pressed frame)
    case retro8090     // CRT / VHS 80s-90s icon
    case aero2000s     // Frutiger 2000s maximalist icon
    case typewriter    // Reading typewriter
    case serif         // Fuji serif pointer
    case matrixPixel   // Matrix phosphor-green pixel arrow
    case cyberSteel    // Cyberpunk industrial brushed-steel pointer
    case nightWarm     // Night Light warm amber pointer
    case comicInk      // Comic Book bold-ink pop-art arrow
    case pencilTip     // Pencil Sketch graphite pencil
    case printRoof     // Print Art pagoda-roof concave-edge pointer

    /// Asset basename in `Resources/CursorSprites/` (e.g. `noir-object@2x.png`).
    var assetName: String {
        switch self {
        case .noirObject: return "noir-object"
        case .retro8090: return "retro-8090"
        case .aero2000s: return "aero-2000s"
        case .typewriter: return "typewriter"
        case .serif: return "serif"
        case .matrixPixel: return "matrix-pixel"
        case .cyberSteel: return "cyber-steel"
        case .nightWarm: return "night-warm"
        case .comicInk: return "comic-ink"
        case .pencilTip: return "pencil-tip"
        case .printRoof: return "print-roof"
        }
    }

    /// Short label for the Cursor effect's pointer dropdown.
    var displayLabel: String {
        switch self {
        case .noirObject: return "Noir"
        case .retro8090: return "Retro 80/90s"
        case .aero2000s: return "Frutiger Aero"
        case .typewriter: return "Typewriter"
        case .serif: return "Serif Nib"
        case .matrixPixel: return "Matrix"
        case .cyberSteel: return "Cyber Steel"
        case .nightWarm: return "Night"
        case .comicInk: return "Comic Ink"
        case .pencilTip: return "Pencil"
        case .printRoof: return "Print"
        }
    }
}

/// How strongly the cursor styling applies. `none` reverts to the system cursor and disables
/// the composite pass entirely (zero cost, click accuracy untouched).
enum CursorIntensity: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    case minimal
    case full

    /// Shader-side intensity multiplier (0…1).
    var scalar: Float {
        switch self {
        case .none: return 0
        case .minimal: return 0.5
        case .full: return 1
        }
    }
}

/// A world's (or the global override's) cursor choice.
struct CursorSpec: Codable, Sendable, Hashable {
    var style: CursorStyle
    var intensity: CursorIntensity
    /// Lets a sprite cursor depress / scale on press (Noir's click depression, scroll wiggle),
    /// driven by `pressAge` in the compositor.
    var pressAnim: Bool

    init(style: CursorStyle, intensity: CursorIntensity = .full, pressAnim: Bool = false) {
        self.style = style
        self.intensity = intensity
        self.pressAnim = pressAnim
    }

    /// The default when no world specifies a cursor and no global override is set: draw the
    /// real system cursor with no composite pass.
    static let systemDefault = CursorSpec(style: .system, intensity: .none)
}
