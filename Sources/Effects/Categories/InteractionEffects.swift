import Foundation
import simd

/// Event-driven interaction effects (MAOE §7.1): click pulses, drag trails, scroll/space
/// signatures, and window-lifecycle bursts. Each is a single `fx_int_*` pass that self-decays
/// off the system-injected pointer/event ages and rides the §5.2 decay render gate (so it costs
/// nothing idle). Each carries a `consumesPointer` / `consumesEvent` pass flag (derived from its
/// trigger in `fx`), which engages the sampler and selects the injected block.
///
/// Parameter declaration order IS the GPU slot order (a `.color` takes 4 slots), and must match
/// each shader's `u.params[...]` reads in Interaction.metal.
enum InteractionEffects {
    static let all: [EffectDescriptor] = [
        clickPulse, clickRipple, glyphBurst, inkRipple, powBurst, powSprite,
        dragTrail, liquidTrail, glyphTrail, shadowDeform,
        scrollDrift, cmykShift, lightLeak, speedLines,
        hyperspaceStreak, spaceGlyphRain, iris, filmSquares,
        bubblePop, bubbleTrail, windowGlitch, shadowCollapse, captionCollapse, decode,
        pencilDraw, audioPulse, keyGlyph,
    ]

    /// Audio-reactive bloom pulse (§15.1). Continuous (renders with the audio level); silent
    /// frames cost a cheap early-out. Worlds opt in via `WorldSpec.audioReactive`.
    static let audioPulse = EffectDescriptor(
        id: "interaction.audioPulse", name: "Audio Pulse", category: .interaction,
        subtitle: "Bloom that pulses to system audio (§15.1).", icon: "waveform",
        function: "fx_int_audioPulse",
        parameters: [
            .color("color", "Color", default: SIMD4(0.6, 0.4, 1.0, 1.0)),
            .slider("strength", "Strength", 0.0...3.0, default: 1.2),
        ],
        tags: ["interaction", "audio", "reactive"], isAnimated: true, triggerKind: .continuous,
        consumesAmbient: true)

    /// Keyboard-reactive glyph (§15.1), event-driven off the keystroke. Worlds opt in via
    /// `WorldSpec.keyboardReactive`; the global key monitor needs Input Monitoring.
    static let keyGlyph = EffectDescriptor(
        id: "interaction.keyGlyph", name: "Key Glyph", category: .interaction,
        subtitle: "A cipher glyph blooms on each keystroke (§15.1).", icon: "keyboard",
        function: "fx_int_keyGlyph",
        parameters: [
            .color("color", "Color", default: green),
            .slider("glyphSize", "Glyph Size", 0.02...0.12, default: 0.05),
        ],
        tags: ["interaction", "keyboard", "matrix"], triggerKind: .onClick, consumesAmbient: true)

    private static let green = SIMD4<Double>(0.25, 1.0, 0.4, 1.0)
    private static let warm = SIMD4<Double>(1.0, 0.6, 0.3, 1.0)
    private static let cyan = SIMD4<Double>(0.6, 0.9, 1.0, 1.0)

    private static func fx(_ id: String, _ name: String, _ subtitle: String, _ icon: String,
                           _ function: String, _ params: [EffectParameter], tags: [String]) -> EffectDescriptor {
        let trig = trigger(for: id)
        // Inject the pointer block for click/press effects (and the continuous Pencil stroke), the
        // event block for the discrete scroll/move/space/lifecycle effects. Derived from the trigger
        // so a new effect injects the right block automatically; the renderer reads these flags
        // instead of a fragment-name allowlist. (audioPulse/keyGlyph are ambient, built separately.)
        let consumesPointer: Bool
        let consumesEvent: Bool
        switch trig {
        case .onClick, .onPress, .continuous: consumesPointer = true; consumesEvent = false
        case .onScroll, .onMove, .onSpaceSwitch, .onLifecycle: consumesPointer = false; consumesEvent = true
        }
        return EffectDescriptor(id: "interaction.\(id)", name: name, category: .interaction,
                         subtitle: subtitle, icon: icon, function: function, parameters: params,
                         tags: ["interaction"] + tags, triggerKind: trig,
                         consumesPointer: consumesPointer, consumesEvent: consumesEvent)
    }

    /// Classify each interaction effect by what drives it (MAOE §10), so the renderer can skip
    /// the pass while the decay gate is idle.
    private static func trigger(for id: String) -> EffectTriggerKind {
        switch id {
        case "clickPulse", "clickRipple", "glyphBurst", "inkRipple", "powBurst", "powSprite": return .onClick
        case "dragTrail", "liquidTrail", "glyphTrail", "shadowDeform", "lightLeak": return .onPress
        case "scrollDrift": return .onScroll
        case "cmykShift", "speedLines": return .onMove
        case "hyperspaceStreak", "spaceGlyphRain", "iris", "filmSquares": return .onSpaceSwitch
        case "pencilDraw": return .continuous   // persistent strokes must composite every frame
        default: return .onLifecycle   // bubblePop, bubbleTrail, windowGlitch, shadowCollapse, captionCollapse, decode
        }
    }

    // MARK: Click

    static let clickPulse = fx("clickPulse", "Click Pulse", "Warm ring on click (Golden Hour).",
        "cursorarrow.click", "fx_int_clickPulse", [
            .color("color", "Color", default: SIMD4(1.0, 0.82, 0.45, 1.0)),
            .slider("maxRadius", "Radius", 0.01...0.3, default: 0.028),
            .slider("thickness", "Thickness", 0.002...0.06, default: 0.006),
            .slider("life", "Duration", 0.1...1.5, default: 0.5, unit: "s"),
        ], tags: ["click", "ring"])

    static let clickRipple = fx("clickRipple", "Click Ripple", "Cyan→magenta chromatic ripple (Cyberpunk).",
        "cursorarrow.click.2", "fx_int_clickRipple", [
            .slider("maxRadius", "Radius", 0.01...0.3, default: 0.035),
            .slider("thickness", "Thickness", 0.002...0.06, default: 0.006),
            .slider("life", "Duration", 0.1...1.5, default: 0.5, unit: "s"),
            .slider("split", "Chromatic Split", 0.0...0.06, default: 0.007),
        ], tags: ["click", "ripple", "chromatic"])

    static let glyphBurst = fx("glyphBurst", "Glyph Burst", "Cipher glyphs scatter from the click (Matrix).",
        "sparkles", "fx_int_glyphBurst", [
            .color("color", "Color", default: green),
            .integer("count", "Glyphs", 1...16, default: 6),
            .slider("spread", "Spread", 0.02...0.3, default: 0.045),
            .slider("life", "Duration", 0.1...1.5, default: 0.6, unit: "s"),
            .slider("glyphSize", "Glyph Size", 0.008...0.05, default: 0.013),
        ], tags: ["click", "glyph", "matrix"])

    static let inkRipple = fx("inkRipple", "Ink Ripple", "Pressure ink blob on the paper (Noir).",
        "drop.fill", "fx_int_inkRipple", [
            .slider("maxRadius", "Radius", 0.01...0.25, default: 0.028),
            .slider("darkness", "Darkness", 0.0...1.0, default: 0.5),
            .slider("life", "Duration", 0.1...1.5, default: 0.45, unit: "s"),
        ], tags: ["click", "ink", "noir"])

    static let powSprite = fx("powSprite", "POW Sprite", "A real comic \"POW!\" sprite popped on click.",
        "burst.fill", "fx_int_powSprite", [
            .slider("size", "Size", 0.03...0.2, default: 0.045),
            .slider("life", "Duration", 0.2...1.2, default: 0.55, unit: "s"),
        ], tags: ["click", "comic", "sprite"])

    static let powBurst = fx("powBurst", "POW Burst", "Halftone comic starburst on click.",
        "burst.fill", "fx_int_powBurst", [
            .color("color", "Color", default: SIMD4(1.0, 0.9, 0.15, 1.0)),
            .slider("maxRadius", "Radius", 0.02...0.3, default: 0.04),
            .slider("spikes", "Spikes", 4.0...20.0, default: 10, step: 1),
            .slider("life", "Duration", 0.1...1.2, default: 0.45, unit: "s"),
        ], tags: ["click", "comic", "halftone"])

    /// Draw-on-screen tool (Pencil Sketch): drag with the LEFT button to draw graphite lines (width
    /// inverse to speed); a stroke begins once the cursor moves, so a single click leaves no dot.
    /// Double-click to clear. The persistent stroke layer is owned by the renderer
    /// (`DisplayRenderer.updatePencilLayer`); this pass only composites it. Params: 0..3 ink, 4 strength.
    static let pencilDraw = fx("pencilDraw", "Pencil Draw", "Drag to draw graphite lines on screen; double-click clears (Pencil Sketch).",
        "pencil.tip", "fx_int_pencilDraw", [
            .color("ink", "Ink", default: SIMD4(0.18, 0.17, 0.19, 1.0)),
            .slider("strength", "Strength", 0.0...1.0, default: 0.9),
        ], tags: ["draw", "pencil", "tool"])

    // MARK: Drag / trail

    static let dragTrail = fx("dragTrail", "Gold Dust", "Sparse floating gold-dust motes scattered along the drag — no connected line (Golden Hour).",
        "sparkles", "fx_int_dragTrail", [
            .color("color", "Color", default: warm),
            .slider("size", "Size", 0.003...0.03, default: 0.006),
        ], tags: ["drag", "trail", "dust"])

    static let liquidTrail = fx("liquidTrail", "Liquid Trail", "Surface-tension refraction along the drag.",
        "drop.triangle", "fx_int_liquidTrail", [
            .slider("strength", "Strength", 0.0...2.0, default: 0.5),
        ], tags: ["drag", "trail", "liquid"])

    static let glyphTrail = fx("glyphTrail", "Glyph Trail", "Cipher glyphs stamped along the drag (Matrix).",
        "character.cursor.ibeam", "fx_int_glyphTrail", [
            .color("color", "Color", default: green),
            .slider("glyphSize", "Glyph Size", 0.012...0.06, default: 0.016),
        ], tags: ["drag", "glyph", "matrix"])

    static let shadowDeform = fx("shadowDeform", "Shadow Deform", "A soft shadow deforms under the drag (Noir).",
        "scribble.variable", "fx_int_shadowDeform", [
            .slider("darkness", "Darkness", 0.0...1.0, default: 0.35),
            .slider("radius", "Radius", 0.005...0.08, default: 0.014),
        ], tags: ["drag", "shadow", "noir"])

    // MARK: Scroll / movement

    static let scrollDrift = fx("scrollDrift", "Scroll Drift", "Glyph columns drift on scroll (Matrix).",
        "arrow.up.arrow.down", "fx_int_scrollDrift", [
            .color("color", "Color", default: green),
            .slider("columns", "Columns", 8.0...80.0, default: 40, step: 1),
            .slider("life", "Duration", 0.2...2.0, default: 1.0, unit: "s"),
        ], tags: ["scroll", "glyph", "matrix"])

    static let cmykShift = fx("cmykShift", "CMYK Shift", "Print registration offset by velocity (Print Art).",
        "circle.grid.cross", "fx_int_cmykShift", [
            .slider("strength", "Strength", 0.0...3.0, default: 1.0),
        ], tags: ["scroll", "motion", "print"])

    static let lightLeak = fx("lightLeak", "Light Leak", "Small warm film leak that persists while the button is held (Fuji).",
        "sun.max", "fx_int_lightLeak", [
            .color("color", "Color", default: SIMD4(1.0, 0.55, 0.25, 1.0)),
            .slider("life", "Duration", 0.1...1.0, default: 0.4, unit: "s"),
        ], tags: ["motion", "film", "fuji"])

    static let speedLines = fx("speedLines", "Speed Lines", "Comic speed-lines on a fast cursor.",
        "wind", "fx_int_speedLines", [
            .slider("density", "Density", 8.0...80.0, default: 40),
            .slider("falloff", "Falloff", 0.1...0.6, default: 0.5),
        ], tags: ["motion", "comic"])

    // MARK: Space switch

    static let hyperspaceStreak = fx("hyperspaceStreak", "Hyperspace Streak", "Radial streaks on Space switch (Cyberpunk).",
        "sparkle.magnifyingglass", "fx_int_hyperspaceStreak", [
            .slider("strength", "Strength", 0.0...2.0, default: 1.0),
            .slider("life", "Duration", 0.3...2.0, default: 1.2, unit: "s"),
        ], tags: ["space", "streak", "cyberpunk"])

    static let spaceGlyphRain = fx("spaceGlyphRain", "Space Glyph Rain", "Dense glyph rain on Space switch (Matrix).",
        "cloud.rain", "fx_int_spaceGlyphRain", [
            .color("color", "Color", default: green),
            .slider("columns", "Columns", 16.0...80.0, default: 50, step: 1),
            .slider("life", "Duration", 0.3...2.0, default: 1.3, unit: "s"),
        ], tags: ["space", "glyph", "matrix"])

    static let iris = fx("iris", "Iris", "Iris-in/out across the Space switch (Noir).",
        "circle.dashed", "fx_int_iris", [
            .slider("life", "Duration", 0.3...2.0, default: 1.2, unit: "s"),
        ], tags: ["space", "iris", "noir"])

    static let filmSquares = fx("filmSquares", "Film Squares", "Sprocket squares sweep the Space switch (Fuji).",
        "film", "fx_int_filmSquares", [
            .color("color", "Color", default: SIMD4(0.95, 0.92, 0.8, 1.0)),
            .slider("life", "Duration", 0.3...2.0, default: 1.0, unit: "s"),
        ], tags: ["space", "film", "fuji"])

    // MARK: Window-lifecycle bursts

    static let bubblePop = fx("bubblePop", "Bubble Pop", "A bubble pops where a window closed (Frutiger).",
        "bubbles.and.sparkles", "fx_int_bubblePop", [
            .color("color", "Color", default: cyan),
            .slider("life", "Duration", 0.2...1.2, default: 0.6, unit: "s"),
        ], tags: ["lifecycle", "close", "frutiger"])

    static let bubbleTrail = fx("bubbleTrail", "Bubble Trail", "Bubbles toward the Dock on minimize (Frutiger).",
        "bubble.left.and.bubble.right", "fx_int_bubbleTrail", [
            .color("color", "Color", default: cyan),
            .slider("life", "Duration", 0.3...1.5, default: 0.9, unit: "s"),
        ], tags: ["lifecycle", "minimize", "frutiger"])

    static let windowGlitch = fx("windowGlitch", "Window Glitch", "Glitch flash on window open (Cyberpunk).",
        "bolt.horizontal", "fx_int_windowGlitch", [
            .slider("life", "Duration", 0.2...1.0, default: 0.5, unit: "s"),
        ], tags: ["lifecycle", "open", "glitch", "cyberpunk"])

    static let shadowCollapse = fx("shadowCollapse", "Shadow Collapse", "A shadow collapses inward on close (Golden Hour).",
        "rays", "fx_int_shadowCollapse", [
            .slider("life", "Duration", 0.2...1.2, default: 0.6, unit: "s"),
        ], tags: ["lifecycle", "shadow", "golden"])

    static let captionCollapse = fx("captionCollapse", "Caption Collapse", "A caption boundary collapses on close (Noir).",
        "rectangle.compress.vertical", "fx_int_captionCollapse", [
            .slider("life", "Duration", 0.2...1.2, default: 0.6, unit: "s"),
        ], tags: ["lifecycle", "caption", "noir"])

    static let decode = fx("decode", "Decode", "Glyph scramble→resolve on window open (Matrix).",
        "text.append", "fx_int_decode", [
            .color("color", "Color", default: green),
            .slider("life", "Duration", 0.3...1.5, default: 0.8, unit: "s"),
            .slider("columns", "Columns", 8.0...60.0, default: 30, step: 1),
        ], tags: ["lifecycle", "open", "matrix"])
}
