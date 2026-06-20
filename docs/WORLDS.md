# Spectra Worlds

A design and implementation spec for turning presets into full "worlds": looks that re-render the whole desktop as a different visual medium (an oil painting, a cel-animation frame, a comic page, a pixel screen).

## What a world is

A world re-renders every pixel of the desktop through a stack of stylization passes plus a color grade, so the screen reads as a coherent place instead of the normal Mac with a tint on top. The transform touches the entire frame, which is why it reads as a world. The Matrix preset's falling code already does a small version of this: it makes the desktop feel like a terminal.

The shader sees a flat captured image and stylizes what is there. Two things stay out of scope, and the spec says so up front:

- **Per-element redesign** (themed traffic lights, restyled app icons, custom window chrome). This needs UI structure the shader does not have. A limited, honest version through the macOS Accessibility API is described in its own section as optional polish.
- **Generative scene replacement** (turning the desktop into a meadow or a flying castle). No model runs in the pass.

The world feeling comes from medium, palette, and atmosphere applied across the whole frame.

## Design principles

1. **Worlds are standalone.** A world is a complete look and does not stack on a heavy color preset. The chain is the world.
2. **Legibility is a dial.** Every world exposes an abstraction/strength knob and ships at a default that keeps body text readable. Heavy abstraction is opt-in.
3. **Stability beats fidelity on motion.** Moving text and video are the hard case. Ink and stroke orientation get temporal damping so the frame does not boil or flicker.
4. **Cost is bounded by the heaviest pass.** The painterly worlds run their expensive filter at half resolution. The cel, ink, and pixel worlds avoid it entirely.
5. **Reuse the pipeline.** Worlds are data-driven `EffectDescriptor`s with multiple passes, exactly like today's effects. No new renderer.

## The stylization engine

Worlds live in a new category, `Artistic`, backed by `Sources/Effects/Categories/StyleEffects.swift` and `Sources/Shaders/Style.metal`. Each world is a preset that chains a subset of composable passes, then a per-world grade. Costs below are estimates for the owner's supersampled "More Space" display (roughly 5 to 6 megapixels of GPU work per frame), from the feasibility study.

| Pass | Role | Est. cost | Reuses |
|---|---|---|---|
| `style.flatten` | Edge-preserving bilateral smooth (full-res, single pass); removes micro-noise so later passes do not false-trigger | ~1 ms | new |
| `style.painterly` | The legacy oil/painterly stroke: pre-smooth + anisotropic Kuwahara at half res, then a full-res bicubic resolve. The structure tensor is computed inline in the gather. Used by Studio Ghibli and Watercolor | 3 to 8 ms | Sobel kernel, `spectra_bicubic` |
| `style.oil` | Colour-region cell painter (SLIC-style superpixels): a structure tensor plus two blurs build a flow field, a reduced-res cell pass assigns each pixel to a local colour-coherent cell and fills it flat with the cell size emergent from edge magnitude, then a full-res combine re-paints complex areas/text sharply (reusing the tapped tensor) and adds a canvas tooth. Used by Impressionism | 4 to 8 ms | Sobel kernel, tensor blur |
| `style.quantize` | Posterize value to N bands, smoothstep ramps, per-band saturation; the flat cel look | <0.5 ms | new |
| `style.ink` | Sobel contour lines: thickness, threshold, opacity, softness, color | 1 to 1.5 ms | Sobel kernel |
| `style.halftone` | Ben-Day dot screen in shadows/mids; comic shading | <0.5 ms | new |
| `style.mosaic` | Block downsample + palette snap; pixel art | <0.5 ms | `Blur.metal` downsample |
| `style.hatch` | Directional cross-hatch by luma; sketch shading | ~0.5 ms | new |
| `style.paper` | Procedural canvas/paper grain, multiply; watercolor and sketch substrate | <0.5 ms | noise library in `SpectraCommon.h` |
| `style.relief` | Height-from-luma + directional light; thick-paint impasto | ~1 ms | new |
| Grade | Per-world palette via a baked 3D LUT | ~0.4 ms | `AuxTextureFactory` LUT path |

Contract notes:

- Multi-pass via `EffectPass` entries; the ping-pong pool handles intermediates (`EffectChainRenderer`).
- The renderer binds `texture(0)` (previous pass output) and `texture(1)` (the effect's original input), with aux LUTs at index 2+, a tapped earlier-pass output at index 9, and history at index 10. A pass can reuse an earlier pass's output via `EffectPass.tapPass` (the renderer keeps it alive instead of recycling it); `style.oil`'s combine uses this to read the smoothed structure tensor the two blur passes built, so the full-res stroke layer shares one stable flow field with the cell pass. The legacy `style.painterly` Kuwahara still computes its tensor inline.
- `style.painterly` runs three passes: pre-smooth at scale 0.5, the Kuwahara gather at scale 0.5, then a full-res resolve that bicubic-upsamples the half-res paint and folds a little original luma detail back for legibility. `EffectPass.scale` is relative to the full chain resolution, so half-res passes share one grid. `style.flatten` is a single full-res pass.
- Worlds with motion (grain, atmosphere) set `isAnimated: true`. Purely spatial worlds set `isAnimated: false` so the Auto governor can throttle them.
- Stability on motion comes from spatial design, not temporal feedback: quantize uses smoothstep band edges and ink uses a high soft threshold so the frame does not boil. The renderer's history texture is chain-level (the previous final frame), so clean per-effect ink/orientation damping would need a per-effect history slot; that is a later refinement, and no world depends on it today.
- Each world's palette is a baked 3D LUT parameter, so color identity costs one lookup.

## Cost and stability budget

| World | Heavy passes | Est. GPU time | Tier |
|---|---|---|---|
| Pixel Art | mosaic | <1 ms | cheap |
| Pencil Sketch | ink + hatch | ~2 ms | cheap |
| Comic Book | ink + halftone | 3 to 4 ms | cheap |
| 90's Anime | quantize + bold ink | 3 to 4 ms | cheap |
| Watercolor | isotropic Kuwahara | 4 to 5 ms | medium |
| Studio Ghibli | anisotropic Kuwahara + ink | 6 to 8 ms | heavy |
| Impressionism | colour-region cell painter (`style.oil`) | 4 to 8 ms | medium-heavy |

Rules:

- Half resolution is mandatory for Kuwahara and flatten. Full-resolution anisotropic Kuwahara costs 10 to 20 ms in the current fragment pipeline and is not the first implementation.
- The compute-shader tile-cached Kuwahara (1.5 to 3 ms) is a later optimization. It needs a compute pipeline the renderer does not have today. Ship the half-res fragment version first, measure, then decide.
- XDoG ink shimmers on text below about 14 px. Default thresholds keep ink off small body text, and temporal damping (history blend 0.3 to 0.4) handles the rest. Worlds that must stay calm on text lean on quantize plus Sobel-darkening rather than full XDoG.
- Quantize uses a smoothstep ramp at each band edge so near-threshold pixels do not toggle between frames.
- Validate every world on scrolling text and video, not just still screenshots.

## The worlds

### Impressionism

- **Appeal:** the most recognizable painting style on earth. "My desktop is a painting" is an instant share. Demo hero.
- **Recipe:** `style.oil` (the colour-region cell painter) then a light vibrance lift. The cell pass assigns every pixel to a local colour-coherent cell and fills it flat; cell size is emergent from the structure-tensor edge magnitude, so flat areas get big strokes and edges and text get small ones, with no separate readability gate. Cells elongate along the flow and snap to colour boundaries. The combine re-paints complex areas at full resolution from the tapped smoothed tensor, adds a canvas tooth, and damps over time.
- **Parameters:** Brushstroke Size is a two-handle range (lower = smallest stroke for complex areas and text, upper = largest for flat areas), plus brushstroke colour noise, temporal smoothing, canvas texture, and render scale. The rest of the look (edge fidelity, flow, edge irregularity, edge smoothing, amount) is baked.
- **Signature:** flowing colour-region brush marks that follow the image, broken colour, a faint canvas tooth, legible text.
- **Limits:** complex areas are reconstructed from tiny strokes, so at large minimum stroke sizes small text softens. Render scale trades sharpness for speed; complex areas are always sharpened at full res regardless.

### Studio Ghibli

- **Appeal:** huge, beloved, cozy. The warm hand-painted look maps onto the study and cozy-setup audience.
- **Recipe (the feasibility-verified one):** domain-transform flatten, then anisotropic Kuwahara (radius 7, soft, half-res), then soft quantize (6 bands, smoothstep), then a warm Ghibli LUT (amber shadows, sage mids, sky-blue and straw highlights), then light XDoG ink (sigma 1.2, strong edges only, 65% opacity, history-blended).
- **Cost:** 6 to 8 ms half-res.
- **Signature:** soft painterly fields, warm nostalgic palette, gentle ink.
- **Limits:** no foreground/background separation, so everything is equally painterly. Keep ink light so it does not read as comic.

### 90's Anime

Darker and harder-edged than Ghibli.

- **Appeal:** Akira, Ghost in the Shell, and OVA nostalgia. Moodier and grittier, with streamer and anime-fan pull.
- **Recipe:** light flatten, then hard quantize (4 to 5 bands, crisp ramps), then bold dark ink (thicker XDoG, near-black, higher opacity, history-blended), then a moody grade LUT (desaturated mids, deep saturated shadows, slight teal or amber cast), then faint grain with an optional thin scanline for the cel-on-tape feel, then optional subtle chromatic aberration at the frame edge.
- **Cost:** 3 to 4 ms, no Kuwahara.
- **Signature:** flat hard cels, heavy dark linework, deep moody palette, faint analog texture.
- **Limits:** harder ink shimmers more on small text than Ghibli's, so keep the ink threshold high. Cheaper and more stable than the painterly worlds.

### Comic Book

- **Appeal:** pop-art loudness. The halftone dots are unmistakable in a thumbnail. Demo hero.
- **Recipe:** flatten, then bold posterize (3 to 4 bands), then heavy black ink outlines (thick XDoG, high opacity), then a Ben-Day halftone dot screen in shadows and mids, then a punchy primary LUT, then an optional white-page paper.
- **Cost:** 3 to 4 ms.
- **Signature:** thick black outlines, Ben-Day halftone, bold saturated primaries.
- **Limits:** halftone over dense text looks busy. Gate it to lower-frequency regions and keep the dot size moderate.

### Pixel Art

Recommended addition.

- **Appeal:** universal gaming nostalgia, extremely shareable, the cheapest world. Palette variants (Game Boy green, an NES-style 16-color set, a generic modern palette) add replay value and a clean preset-pack story.
- **Recipe:** mosaic downsample to chunky blocks (4 to 8 px), then palette snap to a limited LUT, then optional ordered dither at block edges.
- **Cost:** under 1 ms.
- **Signature:** chunky pixels, limited palette.
- **Limits:** text smaller than the block size becomes unreadable by design. Expose block size, default to a readable size, and offer a chunky variant.

### Watercolor

Recommended addition.

- **Appeal:** soft, cozy, journal and study aesthetic. Wet and light where Van Gogh is thick oil, so the two do not overlap.
- **Recipe:** wet flatten, then low-radius isotropic Kuwahara (soft, non-directional), then edge pigment-pooling (darken at edges in place of hard ink), then light quantize, then a cold-press paper texture (multiply), then a pale pastel LUT.
- **Cost:** 4 to 5 ms.
- **Signature:** soft pigment bleed, visible paper grain, pastel palette.
- **Limits:** low contrast on already-pale UI. Let the paper texture carry the identity.

### Pencil Sketch

Recommended addition.

- **Appeal:** "did you draw my desktop?" Strong wow, cheap, and a monochrome change of pace from the color worlds.
- **Recipe:** desaturate, then graphite contour lines (XDoG), then directional cross-hatch shading by luma in mids and shadows, then a warm-gray near-monochrome LUT, then a paper texture.
- **Cost:** ~2 ms.
- **Signature:** graphite contours, cross-hatch, paper.
- **Limits:** hatch density needs tuning so dark UI does not fill solid. Keep hatch spacing resolution-aware.

### Future candidates

Backlog worlds worth building once the engine is proven:

- **Ukiyo-e** (Japanese woodblock): flat color, bold outline, paper. Distinct and elegant, smaller audience.
- **Pop Art / Warhol:** quad-panel posterize in bold complementary palettes.
- **Vaporwave:** purple, pink, and teal grade with grain and a slight bloom. The cheapest to add since it is mostly color.
- **Blueprint:** cyan line extraction on navy. A technical-drawing novelty.

## Semantic UI accents (optional, later)

The per-element idea from the original vision (themed traffic lights, restyled icons, a Blade-Runner chrome) is real but limited, and it is polish on top of a world rather than the world itself. The shader cannot do it. The macOS Accessibility API can do part of it.

What it can do:

- Read native window frames, the close/minimize/zoom button rects, Dock icon rects, and menu bar bounds (event-driven, cached).
- Composite themed art over those rects before the chain, using the `CursorCompositor` and `CursorSampler` pattern already in the codebase.
- Per-world accents: a frosted aqua title-bar strip for Frutiger Aero, an Art-Deco frame for Noir, a neon underglow on the Dock for Cyberpunk.

What it cannot do:

- Reskin Electron and Chromium apps (VS Code, Figma, Arc, Discord, Slack): they hide the Accessibility button subroles.
- Touch native full-screen windows: they do not enumerate.
- Replace arbitrary app icons: the API returns rects, not artwork. Themed icons are an art pipeline, not a shader.
- Track fast window drags without lag: the geometry is 1 to 2 frames stale, so themed chrome trails the window on quick drags.

Scope decision: ship accents only for stable, low-motion targets (Dock, menu bar, settled native windows), gate them behind the Accessibility permission (the app is already direct-distributed because of ScreenCaptureKit, so there is no App Store conflict), and keep them as accents. The dramatic transformation stays in the full-frame stylization.

## Build phasing

1. **Engine scaffold.** Add the `.artistic` category, `StyleEffects.swift`, and `Style.metal` with quantize, ink, mosaic, paper, the LUT wiring, and temporal damping. Ship one cheap world (90's Anime or Comic Book) and measure GPU time on the real display. Files: `Sources/Effects/Categories/StyleEffects.swift`, `Sources/Shaders/Style.metal`, `Sources/Effects/BuiltInEffects.swift`, `Sources/Effects/EffectRegistry.swift`, `Sources/Presets/Preset.swift` (new category case + icon), `Sources/Presets/BuiltInPresets.swift`.
2. **Cheap worlds.** Comic Book, 90's Anime, Pixel Art, Pencil Sketch. All avoid Kuwahara. Validate stability on text and video.
3. **Painterly worlds.** Add `style.flatten`, `style.structureTensor`, `style.kuwahara` (half-res fragment). Ship Studio Ghibli, Van Gogh (add `style.relief`), and Watercolor. Re-measure, and move to a compute-shader Kuwahara only if the half-res fragment version misses budget.
4. **Atmosphere extras.** Reusable procedural particle passes in the Environment category. `environment.bubbles` is the Frutiger Aero rising water-bubble bokeh (aqua body, Fresnel rim, specular glint, screen-blended). `environment.rain` and `environment.dust` already exist and are reused: rain for Cyberpunk's wet night, dust for Studio Ghibli's motes in the light.
5. **Optional UI accents.** Dock, menu bar, and native window frames through the Accessibility API.

## Marketing fit

From the preset market research:

- **Demo heroes** (record well, the before/after pops in a thumbnail): Van Gogh, Comic Book, Pixel Art. Lead the App Store screenshots and short-form video with these.
- **Cozy and retention** (slow-burn, study and setup audience): Studio Ghibli, Watercolor, Pencil Sketch.
- The "I didn't know my Mac could do this" reaction is strongest on Van Gogh and Pixel Art.
- The Artistic category as a whole, and Pixel Art's palette variants, are a natural paid preset-pack story if in-app packs happen later.

## Risks and open questions

- Kuwahara cost on the supersampled display is the gating unknown. The Phase 1 measurement decides whether the painterly worlds need the compute path.
- XDoG text shimmer: confirm ink defaults on real moving text before shipping any inked world.
- Temporal damping adds mild motion ghosting. Confirm it reads as acceptable on video.
- UI accents add a permission step and a real reliability surface. Keep them optional and bounded.
- Palette LUTs need authoring. Budget time to tune each world's grade together, since visual verification is owner-side (the overlay is not screen-capturable).
