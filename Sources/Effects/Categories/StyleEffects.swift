import Foundation
import simd

/// Artistic stylization effects: the composable passes the "world" presets chain
/// to re-render the whole desktop as a different medium (oil paint, cel animation,
/// comic page, pixel screen, pencil sketch). Each descriptor's parameter order is
/// the GPU slot order its Metal function reads (see `Style.metal`).
///
/// Cost discipline (see `docs/WORLDS.md`): the oil-cell painter runs its cells at a
/// reduced render scale and resolves to full res in the combine; the cel, ink,
/// halftone, hatch, and paper passes are single full-res taps.
enum StyleEffects {
    static let all: [EffectDescriptor] = [
        oil, lineart, flatten, quantize, cel, ink, halftone, hatch, paper, relief, pencil,
    ]

    // MARK: - Line art (flow-guided Difference-of-Gaussians)

    /// Crisp ink/contour lines, the shared front-end for the line looks (Pencil, Ghibli, Japanese
    /// Print). Full-resolution isotropic XDoG (Difference-of-Gaussians of luma, soft-thresholded)
    /// so fine detail and text stay coherent and the lines are crisp, with temporal damping so they
    /// hold still on live content instead of crawling. Composites over the effect's input or over a
    /// paper tint. Two full-res passes (separable blur H, then blur V + threshold + composite).
    private static let lineartParameters: [EffectParameter] = [
        .slider("lineScale", "Line Scale", 0.5...4, default: 0.5,
                help: "Line thickness, and the scale of structure the detector responds to (it runs a fine and a coarse Difference-of-Gaussians at this size and 2x it). Smaller is finer and crisper; larger traces the big shapes more boldly."),
        .slider("strength", "Line Strength", 0...1, default: 1.0,
                help: "Opacity of the ink."),
        .slider("threshold", "Threshold", 0...1, default: 0.0,
                help: "How strong an edge must be to ink, measured as local relative contrast so shadow detail draws like lit detail. Higher keeps only the major contours; lower fills in more."),
        .slider("sharpness", "Sharpness", 0...1, default: 0.5,
                help: "Soft graphite line at low values, hard crisp ink line at high values."),
        .slider("temporal", "Temporal Stability", 0...0.95, default: 0.6,
                help: "Holds the lines still over time so they don't crawl on live content; releases where the image moves."),
        .slider("paper", "Paper", 0...1, default: 1.0,
                help: "0 draws the lines over the input image; 1 draws them over a clean paper tint."),
        .color("ink", "Ink Color", default: SIMD4(0.22, 0.21, 0.23, 1)),
        .color("paperTint", "Paper Color", default: SIMD4(0.95, 0.93, 0.87, 1)),
    ]

    static let lineart = EffectDescriptor(
        id: "style.lineart", name: "Line Art", category: .artistic,
        subtitle: "Crisp ink lines from a full-res difference-of-Gaussians.",
        icon: "scribble.variable",
        parameters: lineartParameters,
        passes: [
            EffectPass("fx_lineart_blurH", scale: 1.0, direction: SIMD2<Float>(1, 0)),
            EffectPass("fx_lineart_dog", scale: 1.0, direction: SIMD2<Float>(0, 1)),
            EffectPass("fx_lineart_compose", scale: 1.0),
        ],
        tags: ["line art", "ink", "xdog", "contour", "pencil", "anime", "crisp lines"],
        needsHistory: true)

    // MARK: - Oil paint (colour-region cells on a smoothed structure tensor)

    /// Real oil-painting filter built from colour-region cells, not edge-preserving
    /// smoothing. A smoothed structure tensor (tensor + two half-res blurs) gives the flow
    /// field; the cell pass then assigns every pixel to a local colour-coherent superpixel
    /// ("stroke") and fills it flat. Stroke SIZE is emergent from edge detection: flat areas
    /// get big strokes, edges and text get small ones, with no separate readability gate.
    /// Boundaries snap to colour edges and cells elongate along the flow. The combine adds
    /// canvas, the Amount blend, and temporal damping. One fragment pass does the painting.
    // Hoisted out of the descriptor initializer and explicitly typed: a 13-element array
    // literal inside the EffectDescriptor(...) call pushed Swift's type-checker past its
    // expression-complexity limit. The explicit [EffectParameter] type makes inference fast.
    private static let oilParameters: [EffectParameter] = oilVisibleParams + oilHiddenParams + oilMacroParams

    private static let oilVisibleParams: [EffectParameter] = [
        // VISIBLE (slots 0..4). strokeRange is two handles: lo = smallest stroke (complex
        // areas), hi = largest stroke (flat areas).
        .range("strokeRange", "Brushstroke Size", 0...1, defaultLow: 0.0, defaultHigh: 1.0,
               help: "Stroke size range. The lower handle is the smallest stroke, used in complex/detailed areas (and text); the upper handle is the largest, used in flat/simple areas."),
        .slider("temporal", "Temporal Smoothing", 0...0.95, default: 0.3,
                help: "Settles the painterly shimmer over time. Static areas accumulate into a stable image while moving content stays crisp (the previous frame is rejected wherever the scene changed), so higher values smooth more without ghosting."),
        .slider("canvas", "Canvas Texture", 0...1, default: 0.4,
                help: "Strength of the woven canvas tooth multiplied through the paint."),
        .slider("renderScale", "Render Scale", 0.1...1.0, default: 0.25, group: "Performance",
                help: "Paints the cells at this fraction of full resolution. Lower is faster and softer; higher is sharper and slower. Complex areas/text are always sharpened at full res."),
    ]

    private static let oilHiddenParams: [EffectParameter] = [
        // HIDDEN (slots 5..12): baked-in tuned values, not user-facing.
        .slider("detail", "Edge Fidelity", 0...1, default: 1.0, group: "Hidden"),
        .slider("amount", "Amount", 0...1, default: 1.0, group: "Hidden"),
        .slider("flow", "Flow", 0...1, default: 1.0, group: "Hidden"),
        .slider("warp", "Edge Irregularity", 0...1, default: 1.0, group: "Hidden"),
        .slider("edgeSmooth", "Edge Smoothing", 0...1, default: 1.0, group: "Hidden"),
        // Painterly-family knobs (slots 10..12). Default 0 = identity, so a preset that does not
        // set them is unchanged; Painting and Ghibli drive them.
        .slider("pooling", "Pigment Pooling", 0...1, default: 0.0, group: "Hidden"),
        .slider("wetBleed", "Wet Bleed", 0...1, default: 0.0, group: "Hidden"),
        .slider("pigmentDesat", "Pigment Desaturation", 0...1, default: 0.0, group: "Hidden"),
    ]

    // VISIBLE macro knob at slot 13. Declared LAST so the tuned hidden slots 5..12 keep their
    // indices. One control drives the whole Van Gogh treatment: divisionist broken colour
    // (each stroke a saturated warm/cool variant that optically mixes back to the true colour)
    // plus stronger directional elongation and deeper stroke seams. Default 0 = identity, so
    // every existing preset that does not set it is untouched.
    private static let oilMacroParams: [EffectParameter] = [
        .slider("vanGogh", "Van Gogh", 0...1, default: 0.0,
                help: "Broken-colour divisionism. Each brush cell becomes a saturated warm/cool variant whose offset is zero-mean across neighbours, so at viewing distance the strokes optically mix back to the true colour while up close each mark is vivid. Also elongates strokes along the forms and deepens the seams between them. 0 is off, 1 is full Van Gogh."),
    ]

    static let oil = EffectDescriptor(
        id: "style.oil", name: "Oil Paint", category: .artistic,
        subtitle: "Colour-region brush cells, sized by the image's edges.",
        icon: "paintbrush.fill",
        parameters: oilParameters,
        passes: [
            EffectPass("fx_style_oil_tensor", scale: 0.5),
            EffectPass("fx_style_oil_blur", scale: 0.5, direction: SIMD2<Float>(1, 0)),
            EffectPass("fx_style_oil_blur", scale: 0.5, direction: SIMD2<Float>(0, 1)),
            // Cells paint at reduced res (driven by Render Scale, slot 5); the combine brings them
            // back to full res, sharpens complex areas, and taps the smoothed structure tensor
            // (pass 2) for a stable flow field instead of recomputing a raw Sobel.
            EffectPass("fx_style_oil_cells", scale: 0.6, scaleParam: 4),
            EffectPass("fx_style_oil_combine", scale: 1.0, tapPass: 2),
        ],
        tags: ["oil", "painterly", "impressionist", "van gogh", "brush", "flow"],
        needsHistory: true)

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
            .integer("bands", "Tones", 2...16, default: 5),
            .slider("saturation", "Saturation", -1...1, default: 0.4),
            .slider("inkStrength", "Ink", 0...1, default: 0.8),
            .slider("inkWidth", "Ink Width", 0.5...4, default: 2.0),
            .slider("smoothness", "Edge Softness", 0...1, default: 0.3),
            .slider("abstraction", "Abstraction", 0...1, default: 0.6),
        ],
        passes: [
            // Two abstraction iterations flatten textured regions into paintable fields. Run at
            // 0.7 (not 0.5) so the fields aren't chunky/blocky on upsample.
            EffectPass("fx_style_cel_abstract", scale: 0.7),
            EffectPass("fx_style_cel_abstract", scale: 0.7),
            EffectPass("fx_style_cel_combine", scale: 1.0),
        ],
        tags: ["cel", "anime", "toon", "ink", "flat", "abstraction"])

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
            .slider("drift", "Drift", 0...1, default: 0.35,
                    help: "Slowly animates the paper grain, faster where the screen is moving. 0 freezes it."),
        ],
        tags: ["paper", "canvas", "texture", "watercolor", "substrate"],
        needsHistory: true)

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

    // MARK: - Pencil sketch (paper + cross-hatch tone + contour ink)

    /// A real graphite drawing rather than a desaturated overlay: the base is paper white,
    /// tone is built only from form-following cross-hatching (denser where the image is
    /// darker), and contour lines come from a Sobel on luma. One full-res pass.
    static let pencil = EffectDescriptor(
        id: "style.pencil", name: "Pencil Sketch", category: .artistic,
        subtitle: "Graphite drawing: contour lines and cross-hatch tone on paper.",
        icon: "pencil.and.outline",
        function: "fx_style_pencil",
        parameters: [
            .slider("spacing", "Hatch Spacing", 2...10, default: 5),
            .slider("tone", "Shading", 0...1, default: 0.85),
            .slider("contour", "Contour Lines", 0...1, default: 0.9),
            .slider("grain", "Paper Grain", 0...1, default: 0.4),
            .color("paper", "Paper Tint", default: SIMD4(0.95, 0.93, 0.87, 1)),
        ],
        tags: ["pencil", "sketch", "graphite", "hatch", "drawing", "monochrome"])
}
