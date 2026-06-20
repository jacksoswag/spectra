import Foundation
import simd

/// Artistic stylization effects: the composable passes the "world" presets chain
/// to re-render the whole desktop as a different medium (oil paint, cel animation,
/// comic page, pixel screen, pencil sketch). Each descriptor's parameter order is
/// the GPU slot order its Metal function reads (see `Style.metal`).
///
/// Cost discipline (see `docs/WORLDS.md`): the painterly Kuwahara runs at half
/// resolution inside `style.painterly` and resolves back to full res; the cel,
/// ink, halftone, mosaic, hatch, and paper passes are single full-res taps.
enum StyleEffects {
    static let all: [EffectDescriptor] = [
        oil, slic, flatten, quantize, cel, comic, ink, halftone, hatch, paper, relief, painterly,
    ]

    // MARK: - Oil paint (colour-region cells on a smoothed structure tensor)

    /// Real oil-painting filter built from colour-region cells, not edge-preserving
    /// smoothing. A smoothed structure tensor (tensor + two half-res blurs) gives the flow
    /// field; the cell pass then assigns every pixel to a local colour-coherent superpixel
    /// ("stroke") and fills it flat. Stroke SIZE is emergent from edge detection: flat areas
    /// get big strokes, edges and text get small ones, with no separate readability gate.
    /// Boundaries snap to colour edges and cells elongate along the flow. The combine adds
    /// canvas, the Amount blend, and temporal damping. One fragment pass does the painting.
    static let oil = EffectDescriptor(
        id: "style.oil", name: "Oil Paint", category: .artistic,
        subtitle: "Colour-region brush cells, sized by the image's edges.",
        icon: "paintbrush.fill",
        parameters: [
            // VISIBLE (slots 0..5). strokeRange is two handles: lo = smallest stroke (complex
            // areas), hi = largest stroke (flat areas).
            .range("strokeRange", "Brushstroke Size", 0...1, defaultLow: 0.0, defaultHigh: 1.0,
                   help: "Stroke size range. The lower handle is the smallest stroke, used in complex/detailed areas (and text); the upper handle is the largest, used in flat/simple areas."),
            .slider("colorVar", "Brushstroke Color Noise", 0...1, default: 1.0,
                    help: "Per-stroke broken colour in textured areas. 0 is true colour; higher gives impressionist colour variation."),
            .slider("temporal", "Temporal Smoothing", 0...0.95, default: 0.3,
                    help: "Damps the painting against the previous frame so live content doesn't boil."),
            .slider("canvas", "Canvas Texture", 0...1, default: 0.4,
                    help: "Strength of the woven canvas tooth multiplied through the paint."),
            .slider("renderScale", "Render Scale", 0.25...1.0, default: 0.25, group: "Performance",
                    help: "Paints the cells at this fraction of full resolution. Lower is faster and softer; higher is sharper and slower. Complex areas/text are always sharpened at full res."),
            // HIDDEN (slots 6..10): baked-in tuned values, not user-facing.
            .slider("detail", "Edge Fidelity", 0...1, default: 1.0, group: "Hidden"),
            .slider("amount", "Amount", 0...1, default: 1.0, group: "Hidden"),
            .slider("flow", "Flow", 0...1, default: 1.0, group: "Hidden"),
            .slider("warp", "Edge Irregularity", 0...1, default: 1.0, group: "Hidden"),
            .slider("edgeSmooth", "Edge Smoothing", 0...1, default: 1.0, group: "Hidden"),
        ],
        passes: [
            EffectPass("fx_style_oil_tensor", scale: 0.5),
            EffectPass("fx_style_oil_blur", scale: 0.5, direction: SIMD2<Float>(1, 0)),
            EffectPass("fx_style_oil_blur", scale: 0.5, direction: SIMD2<Float>(0, 1)),
            // Cells paint at reduced res (driven by Render Scale, slot 5); the combine brings them
            // back to full res, sharpens complex areas, and taps the smoothed structure tensor
            // (pass 2) for a stable flow field instead of recomputing a raw Sobel.
            EffectPass("fx_style_oil_cells", scale: 0.6, scaleParam: 5),
            EffectPass("fx_style_oil_combine", scale: 1.0, tapPass: 2),
        ],
        tags: ["oil", "painterly", "impressionist", "van gogh", "brush", "flow"],
        needsHistory: true)

    // MARK: - SLIC superpixel painterly

    /// Screen-space SLIC superpixel painterly: clusters pixels into stroke-like
    /// superpixels by color + position, samples real scene color (faithful hues),
    /// warps sampling for organic strokes, and dials its imposingness DOWN where
    /// local contrast is high so text and dense UI stay readable. One full-res pass.
    static let slic = EffectDescriptor(
        id: "style.slic", name: "Painterly (SLIC)", category: .artistic,
        subtitle: "Impressionist superpixel strokes; backs off on text to stay readable.",
        icon: "paintbrush.pointed.fill",
        function: "fx_style_slic",
        parameters: [
            .slider("cellSize", "Stroke Size", 8...64, default: 26),
            .slider("colorWeight", "Edge Fidelity", 1...100, default: 56),
            .slider("posterize", "Posterize", 16...256, default: 120),   // high = stable, low = shimmers
            .slider("sceneBlend", "Amount", 0...1, default: 0.85),
            .slider("warpStrength", "Warp", 0...64, default: 10),
            .slider("noiseScale", "Warp Scale", 0.1...4, default: 1.0),
            .slider("noiseSpeed", "Warp Speed", 0...4, default: 0.0),     // 0 = static (no boil); raise for drift
            .slider("hueJitter", "Hue Jitter", 0...1, default: 0.04),
            .slider("adapt", "Keep Text Readable", 0...1, default: 0.7),
        ],
        tags: ["painterly", "impressionist", "oil", "slic", "superpixel", "van gogh", "brush"],
        isAnimated: false)

    // MARK: - Edge-preserving smooth

    /// Small bilateral-style smooth that removes micro-noise and JPEG/text fringe
    /// so later quantize/ink passes do not false-trigger, while keeping real edges.
    static let flatten = EffectDescriptor(
        id: "style.flatten", name: "Flatten", category: .artistic,
        subtitle: "Edge-preserving smooth; the base for cel and ink looks.",
        icon: "drop.halffull",
        function: "fx_style_flatten",
        parameters: [
            .slider("radius", "Radius", 0.5...3, default: 1.5),
            .slider("edge", "Edge Preserve", 0...1, default: 0.6),
        ],
        tags: ["smooth", "bilateral", "cel", "flatten"])

    // MARK: - Posterize to flat cel bands

    /// Quantizes luminance into N flat bands with smoothstep ramps (so near-edge
    /// pixels do not toggle between frames) and lifts saturation for the cel look.
    static let quantize = EffectDescriptor(
        id: "style.quantize", name: "Cel Quantize", category: .artistic,
        subtitle: "Flatten tone into bold bands, the flat cel-shaded look.",
        icon: "square.stack.3d.up.fill",
        function: "fx_style_quantize",
        parameters: [
            .integer("bands", "Bands", 2...12, default: 6),
            .slider("smoothness", "Edge Softness", 0...1, default: 0.5),
            .slider("saturation", "Saturation", -1...1, default: 0.15),
            .slider("blackPoint", "Black Point", 0...0.5, default: 0.0),
        ],
        tags: ["cel", "posterize", "anime", "flat", "bands"])

    // MARK: - Cel shade (abstraction + bold tones + ink)

    /// The anime/toon look: a strong edge-preserving abstraction flattens the image
    /// into regions (dissolving small text), then luminance is banded into bold flat
    /// tones and outlines are drawn from the abstracted edges, so ink traces real
    /// shapes instead of text. Two passes; the abstraction runs at half resolution.
    static let cel = EffectDescriptor(
        id: "style.cel", name: "Cel Shade", category: .artistic,
        subtitle: "Flat anime cels with bold ink, abstracted so text stays clean.",
        icon: "person.crop.rectangle.stack",
        parameters: [
            .integer("bands", "Tones", 2...8, default: 5),
            .slider("saturation", "Saturation", -1...1, default: 0.4),
            .slider("inkStrength", "Ink", 0...1, default: 0.8),
            .slider("inkWidth", "Ink Width", 0.5...4, default: 2.0),
            .slider("smoothness", "Edge Softness", 0...1, default: 0.3),
            .slider("abstraction", "Abstraction", 0...1, default: 0.6),
        ],
        passes: [
            // Two abstraction iterations strongly flatten textured regions (sea, foliage,
            // gradients) into paintable fields so ink traces only major shapes.
            EffectPass("fx_style_cel_abstract", scale: 0.5),
            EffectPass("fx_style_cel_abstract", scale: 0.5),
            EffectPass("fx_style_cel_combine", scale: 1.0),
        ],
        tags: ["cel", "anime", "toon", "ink", "flat", "abstraction"])

    // MARK: - Comic / newsprint (texture-imposing)

    /// Prints the whole frame as a halftone comic page: abstraction, hard posterize,
    /// a resolution-relative Ben-Day dot screen on paper, and bold ink outlines. This
    /// imposes a material rather than interpreting a scene, so even a flat desktop
    /// reads as a comic. Parameter order matches `fx_style_comic_combine`; the two
    /// abstraction passes reuse `fx_style_cel_abstract` (abstraction at slot 5).
    static let comic = EffectDescriptor(
        id: "style.comic", name: "Comic Print", category: .artistic,
        subtitle: "Halftone comic page with bold ink, on paper. Works on any content.",
        icon: "circle.grid.3x3.fill",
        parameters: [
            .integer("bands", "Tones", 2...6, default: 3),
            .slider("saturation", "Saturation", -1...1, default: 0.5),
            .slider("inkStrength", "Ink", 0...1, default: 0.9),
            .slider("inkWidth", "Ink Width", 0.5...4, default: 1.6),
            .slider("dotDensity", "Dot Density", 0...1, default: 0.5),
            .slider("abstraction", "Abstraction", 0...1, default: 0.7),
            .slider("paper", "Paper", 0...1, default: 0.85),
        ],
        passes: [
            EffectPass("fx_style_cel_abstract", scale: 0.5),
            EffectPass("fx_style_cel_abstract", scale: 0.5),
            EffectPass("fx_style_comic_combine", scale: 1.0),
        ],
        tags: ["comic", "halftone", "newsprint", "pop art", "ben-day", "print"])

    // MARK: - Ink / contour lines

    /// Sobel/DoG contour lines drawn over the image: the linework of comic, anime,
    /// and pencil looks. `color` is the ink color (RGBA, 4 slots).
    static let ink = EffectDescriptor(
        id: "style.ink", name: "Ink Lines", category: .artistic,
        subtitle: "Contour outlines from edges: comic ink to pencil contour.",
        icon: "scribble.variable",
        function: "fx_style_ink",
        parameters: [
            .slider("thickness", "Thickness", 0.5...3, default: 1.0),
            .slider("threshold", "Threshold", 0...1, default: 0.5),
            .slider("opacity", "Opacity", 0...1, default: 0.85),
            .slider("softness", "Softness", 0...1, default: 0.35),
            .color("color", "Ink Color", default: SIMD4(0.04, 0.04, 0.05, 1)),
        ],
        tags: ["ink", "outline", "edge", "comic", "xdog", "line"])

    // MARK: - Ben-Day halftone

    /// Ben-Day dot screen gated to shadows and midtones: the comic shading texture.
    static let halftone = EffectDescriptor(
        id: "style.halftone", name: "Halftone", category: .artistic,
        subtitle: "Ben-Day dot screen in the shadows and mids.",
        icon: "circle.grid.3x3.fill",
        function: "fx_style_halftone",
        parameters: [
            .slider("scale", "Dot Density", 2...16, default: 6),
            .angle("angle", "Screen Angle", default: 45),
            .slider("strength", "Strength", 0...1, default: 0.7),
            .slider("coverage", "Coverage", 0...1, default: 0.6),
        ],
        tags: ["halftone", "comic", "dots", "ben-day", "pop art"])

    // MARK: - Cross-hatch shading

    /// Directional cross-hatch by luminance: the pencil/etching shading texture.
    static let hatch = EffectDescriptor(
        id: "style.hatch", name: "Cross-Hatch", category: .artistic,
        subtitle: "Directional pencil hatching keyed to brightness.",
        icon: "line.diagonal",
        function: "fx_style_hatch",
        parameters: [
            .slider("spacing", "Spacing", 2...12, default: 5),
            .slider("strength", "Strength", 0...1, default: 0.7),
            .angle("angle", "Angle", default: 35),
        ],
        tags: ["hatch", "pencil", "sketch", "etching", "shading"])

    // MARK: - Paper / canvas substrate

    /// Procedural paper or canvas grain multiplied over the image, the watercolor
    /// and sketch substrate. `tint` is the paper color (RGBA, 4 slots).
    static let paper = EffectDescriptor(
        id: "style.paper", name: "Paper", category: .artistic,
        subtitle: "Procedural paper or canvas grain, multiplied through.",
        icon: "doc.plaintext",
        function: "fx_style_paper",
        parameters: [
            .slider("intensity", "Intensity", 0...1, default: 0.3),
            .slider("scale", "Grain Scale", 0.5...8, default: 2.5),
            .color("tint", "Paper Tint", default: SIMD4(0.96, 0.94, 0.88, 1)),
        ],
        tags: ["paper", "canvas", "texture", "watercolor", "substrate"])

    // MARK: - Impasto relief

    /// Height-from-luminance directional lighting: the raised thick-paint impasto
    /// for the oil worlds, applied on top of the painterly fields.
    static let relief = EffectDescriptor(
        id: "style.relief", name: "Impasto Relief", category: .artistic,
        subtitle: "Thick-paint relief lit from a single light.",
        icon: "mountain.2.fill",
        function: "fx_style_relief",
        parameters: [
            .slider("amount", "Amount", 0...1, default: 0.5),
            .slider("height", "Height", 0...1, default: 0.5),
            .angle("angle", "Light Angle", default: 135),
        ],
        tags: ["impasto", "relief", "oil", "paint", "emboss"])

    // MARK: - Painterly Kuwahara

    /// Generalized (optionally anisotropic) Kuwahara: the swirling-brushstroke oil
    /// stroke. Runs at half resolution (the `pre` smooth and the gather) then a
    /// full-res `resolve` upsamples and folds a little original detail back for
    /// legibility. All three passes read the same parameter slots.
    static let painterly = EffectDescriptor(
        id: "style.painterly", name: "Painterly", category: .artistic,
        subtitle: "Oil-paint brushstrokes via a half-res Kuwahara filter.",
        icon: "paintbrush.fill",
        parameters: [
            .slider("radius", "Stroke Size", 1...8, default: 4),
            .slider("anisotropy", "Anisotropy", 0...1, default: 0.5),
            .slider("sharpness", "Sharpness", 0...1, default: 0.5),
            .slider("detail", "Detail", 0...1, default: 0.25),
        ],
        passes: [
            EffectPass("fx_style_painterly_pre", scale: 0.5),
            EffectPass("fx_style_painterly_kuwahara", scale: 0.5),
            EffectPass("fx_style_painterly_resolve", scale: 1.0),
        ],
        tags: ["painterly", "kuwahara", "oil", "van gogh", "brush", "impressionist"])
}
