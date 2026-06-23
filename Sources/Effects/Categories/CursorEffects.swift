import Foundation

/// The Cursor effect (MAOE §6): a single stack row that sets the pointer — a built-in world sprite,
/// the system pointer, or user-supplied images (one per state). It carries no GPU pass;
/// `SpectraEngine.resolveCursorSpec` reads the row and builds the `CursorSpec`, and `CursorSampler`
/// loads the art. The engine injects this row when a preset with a cursor loads, so the pointer
/// always shows up as an editable effect in the stack. Click/drag cursor reactions stay separate
/// effects in the Interaction category.
enum CursorEffects {
    static let customCursorID = "cursor.custom"

    /// Pointer dropdown order: 0 = Custom Image (the image fields below), 1 = System, then the
    /// built-in world sprites in `SpriteKind.allCases` order (index = kind index + 2).
    static let pointerOptions: [String] = ["Custom Image", "System"] + SpriteKind.allCases.map(\.displayLabel)

    static let all: [EffectDescriptor] = [
        EffectDescriptor(
            id: customCursorID, name: "Cursor", category: .cursor,
            subtitle: "Set the pointer: a built-in sprite, the system cursor, or your own images.",
            icon: "cursorarrow.motionlines",
            parameters: [
                .options("pointer", "Pointer", pointerOptions, default: 0),
                .toggle("press", "Press Animation", default: false,
                        help: "Dip / scale the pointer while the mouse button is held."),
                .image("arrow", "Arrow Image", help: "Used when Pointer = Custom Image. The default pointer."),
                .image("hand", "Hand Image", help: "Used when Pointer = Custom Image. Shown over links; falls back to Arrow."),
                .image("text", "Text Image", help: "Used when Pointer = Custom Image. Shown over text; falls back to Arrow."),
            ],
            passes: [], tags: ["cursor", "pointer", "custom", "image", "sprite"],
            controllerKind: .cursorStyle),
    ]

    /// Map a pointer dropdown index (+ the row's images) to a `CursorStyle`. Returns nil when
    /// "Custom Image" is selected but no image is set yet, so the cursor is left untouched.
    static func style(forOptionIndex idx: Int, images: CursorImageSet) -> CursorStyle? {
        switch idx {
        case 0: return images.isEmpty ? nil : .customImage(images)
        case 1: return .system
        default:
            let sprites = SpriteKind.allCases
            let i = idx - 2
            return (i >= 0 && i < sprites.count) ? .sprite(sprites[i]) : nil
        }
    }

    /// The dropdown index that represents a `CursorStyle` (for injecting a preset's cursor as a row).
    static func optionIndex(for style: CursorStyle) -> Int {
        switch style {
        case .customImage: return 0
        case .system: return 1
        case .sprite(let k): return SpriteKind.allCases.firstIndex(of: k).map { $0 + 2 } ?? 1
        case .neonCyan, .pixelGreen, .warmTint: return 1   // restyles aren't a sprite row; fall back to System
        }
    }
}
