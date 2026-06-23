import Foundation
import simd

/// Per-window chrome effects (MAOE §12): screen-space borders, glows, shadows, and
/// vignettes masked to each window's rectangle from the live geometry feed (§5.1). Every
/// pass sets `requiresWindowRects` so the engine engages `WindowGeometryProvider` and the
/// renderer binds the `WindowGeometry` buffer at index 2. Chrome is recomputed from the
/// live window list each frame and opacity-gated by `kCGWindowAlpha`, so a closed window
/// leaves no ghost border.
enum WindowChromeEffects {
    static let all: [EffectDescriptor] = [windowBorder, spriteBorder, windowShadow, windowVignette, titleStrip, focusDim, windowPunch, windowRain, menuBar, dock]

    /// An ORNATE sprite window frame (MAOE §12): real corner artwork (an art-nouveau flourish
    /// bundled under `Resources/BorderSprites/ornate-corner@2x.png`) mirrored into each window's
    /// four corners, plus a thin ink rule along the edges. Used by Noir. The sprite's alpha is the
    /// shape; `ink` recolours it, so it reads as dark ink on the B&W frame rather than a glow.
    static let spriteBorder = EffectDescriptor(
        id: "chrome.spriteBorder", name: "Ornate Frame", category: .chrome,
        subtitle: "Art-nouveau sprite corners + an ink rule, from the live window list.",
        icon: "seal",
        parameters: [
            .slider("cornerSize", "Corner Size", 0.03...0.15, default: 0.075,
                    help: "Corner flourish size, in fractions of display height."),
            .slider("ruleWidth", "Rule Width", 0.0005...0.005, default: 0.0016),
            .color("ink", "Ink", default: SIMD4(0.04, 0.04, 0.05, 1.0)),
            .slider("intensity", "Intensity", 0.0...1.0, default: 0.9),
        ],
        passes: [EffectPass("fx_chrome_spriteBorder", requiresWindowRects: true, injectsMenuBarHeight: true)],
        tags: ["window", "border", "ornate", "sprite", "noir"])

    /// In-shader menu-bar styling (MAOE §9): painted onto the shaded top strip, appended by the
    /// engine from the active world's `systemUI.menuBar`. Animated (the Noir caption flickers).
    static let menuBar = EffectDescriptor(
        id: "chrome.menuBar", name: "Menu Bar Style", category: .chrome,
        subtitle: "Per-world menu-bar treatment, painted into the shaded strip.",
        icon: "menubar.rectangle",
        parameters: [
            .options("style", "Style", ["None", "Soft Shadow", "Caption", "Reflective", "Pastel"], default: 0),
            .slider("height", "Height", 0.0...0.1, default: 0.024),
            .slider("intensity", "Intensity", 0.0...1.0, default: 1.0),
        ],
        passes: [EffectPass("fx_chrome_menuBar")],
        tags: ["menu bar", "system", "chrome"], isAnimated: true)

    /// In-shader Dock styling (MAOE §9): painted onto the shaded Dock region (rect supplied by
    /// the engine), appended from the active world's `systemUI.dock`.
    static let dock = EffectDescriptor(
        id: "chrome.dock", name: "Dock Style", category: .chrome,
        subtitle: "Per-world Dock treatment, painted onto the shaded Dock.",
        icon: "dock.rectangle",
        parameters: [
            .options("style", "Style", ["None", "Grounded Shadow", "Stage Frame", "Neon Outline", "Matte Pastel", "Reflective"], default: 0),
            .vector4("dockRect", "Dock Rect (UV)", default: SIMD4(0, 0, 0, 0)),
            .slider("intensity", "Intensity", 0.0...1.0, default: 1.0),
            .vector3("color", "Color", default: SIMD3(0.3, 1.0, 0.45)),
        ],
        passes: [EffectPass("fx_chrome_dock", requiresWindowRects: false)],
        tags: ["dock", "system", "chrome"])

    /// Geometry-aware generative rain (MAOE §15.2): falls in the window gaps, occluded behind
    /// windows, splashing on their top edges. Cyberpunk's "neon rain in the window gaps".
    static let windowRain = EffectDescriptor(
        id: "chrome.windowRain",
        name: "Window Rain",
        category: .chrome,
        subtitle: "Rain in the window gaps, occluded behind windows (§15.2).",
        icon: "cloud.rain",
        parameters: [
            .color("color", "Color", default: SIMD4(0.3, 0.9, 1.0, 1.0)),
            .slider("density", "Density", 0.2...2.0, default: 0.8),
            .slider("speed", "Speed", 0.2...3.0, default: 1.2),
        ],
        passes: [EffectPass("fx_chrome_windowRain", requiresWindowRects: true)],
        tags: ["window", "rain", "generative", "ambient"],
        isAnimated: true
    )

    /// Filter the focused window in/out of the effect (MAOE §16.3), appended by the engine on
    /// the filter-window hotkey. mode 0 shows the real desktop inside the focused window; mode 1
    /// restricts the effect to it.
    static let windowPunch = EffectDescriptor(
        id: "chrome.windowPunch",
        name: "Filter Window",
        category: .chrome,
        subtitle: "Punch the focused window out of the effect (or restrict the effect to it).",
        icon: "rectangle.dashed",
        parameters: [
            .options("mode", "Mode", ["Show desktop in window", "Restrict effect to window"], default: 0),
        ],
        passes: [EffectPass("fx_chrome_windowPunch", requiresWindowRects: true)],
        tags: ["window", "filter", "focus", "chrome"]
    )

    /// Focus spotlight (MAOE §15.1): dim + desaturate everything except the focused window.
    static let focusDim = EffectDescriptor(
        id: "chrome.focusDim",
        name: "Focus Spotlight",
        category: .chrome,
        subtitle: "Dim and desaturate everything but the focused window.",
        icon: "spotlight",
        parameters: [
            .slider("dim", "Dim", 0.0...1.0, default: 0.6),
        ],
        passes: [EffectPass("fx_chrome_focusDim", requiresWindowRects: true)],
        tags: ["window", "focus", "spotlight", "chrome"]
    )

    /// A coloured edge glow hugging each window's rounded rect. The active-window glow
    /// facet (Golden Hour gold, Matrix green) sets `activeOnly`.
    static let windowBorder = EffectDescriptor(
        id: "chrome.windowBorder",
        name: "Window Border",
        category: .chrome,
        subtitle: "Per-window edge glow from the live window list.",
        icon: "macwindow",
        parameters: [
            .options("style", "Style", ["Glow", "Inset Neon", "Bevel", "Glass", "Film Strip", "Damaged Circuit", "Circuit RGB"], default: 0),
            .color("color", "Color", default: SIMD4(0.45, 0.8, 1.0, 1.0)),
            .slider("width", "Width", 0.0...0.04, default: 0.005,
                    help: "Border half-width, in fractions of display height."),
            .slider("softness", "Softness", 0.0...4.0, default: 1.2),
            .toggle("activeOnly", "Active Window Only", default: false,
                    help: "Frame only the frontmost window."),
            .toggle("screenFrame", "Screen Frame", default: false,
                    help: "Also wrap the whole display edge (always on, independent of windows)."),
        ],
        passes: [EffectPass("fx_chrome_windowBorder", requiresWindowRects: true)],
        tags: ["window", "border", "chrome", "frame"]
    )

    /// A directional drop shadow cast into the gap beside each window (Golden Hour, Fuji).
    /// Doubles the native macOS shadow, so it is meant to pair with `yabai -m config
    /// window_shadow off`; the engine gates authoring it on yabai readiness (§12).
    static let windowShadow = EffectDescriptor(
        id: "chrome.windowShadow",
        name: "Window Shadow",
        category: .chrome,
        subtitle: "Directional drop shadow from one light direction (needs yabai shadow off).",
        icon: "shadow",
        parameters: [
            .angle("lightAngle", "Light Angle", default: 210),
            .slider("distance", "Distance", 0.0...0.06, default: 0.012),
            .slider("softness", "Softness", 0.005...0.08, default: 0.025),
            .slider("opacity", "Opacity", 0.0...1.0, default: 0.5),
        ],
        passes: [EffectPass("fx_chrome_windowShadow", requiresWindowRects: true)],
        tags: ["window", "shadow", "chrome", "light"]
    )

    /// A soft vignette hugging each window's inner edge (Pencil Sketch paper, Painting bleed).
    static let windowVignette = EffectDescriptor(
        id: "chrome.windowVignette",
        name: "Window Vignette",
        category: .chrome,
        subtitle: "Soft inner-edge vignette per window.",
        icon: "rectangle.inset.filled",
        parameters: [
            .color("color", "Color", default: SIMD4(0.05, 0.04, 0.03, 1.0)),
            .slider("strength", "Strength", 0.0...1.0, default: 0.4),
            .slider("size", "Size", 0.01...0.2, default: 0.06),
        ],
        passes: [EffectPass("fx_chrome_windowVignette", requiresWindowRects: true)],
        tags: ["window", "vignette", "chrome", "paper"]
    )

    /// A concave glossy strip over each window's top ~28 pt (Frutiger Aero header).
    static let titleStrip = EffectDescriptor(
        id: "chrome.titleStrip",
        name: "Title Strip Gloss",
        category: .chrome,
        subtitle: "Glossy heuristic title-bar strip (Frutiger).",
        icon: "macwindow.badge.plus",
        parameters: [
            .color("color", "Gloss Tint", default: SIMD4(0.7, 0.88, 1.0, 1.0)),
            .slider("height", "Strip Height", 0.01...0.08, default: 0.03,
                    help: "Top strip height as a fraction of display height (~28 pt)."),
        ],
        passes: [EffectPass("fx_chrome_titleStrip", requiresWindowRects: true)],
        tags: ["window", "header", "gloss", "frutiger"]
    )
}
