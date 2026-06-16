export const meta = {
  name: 'spectra-effect-library',
  description: 'Generate the 12 non-color effect categories (descriptors + Metal shaders) against the locked Spectra contract',
  phases: [{ title: 'Generate', detail: 'one agent per effect category' }],
}

const ROOT = '/Users/jacksonadams/Code/spectra'
const SHADER_DIR = `${ROOT}/Sources/Shaders`
const CAT_DIR = `${ROOT}/Sources/Effects/Categories`

const CONTRACT = `
You are implementing one category of GPU visual effects for "Spectra", a macOS
desktop shader engine. The architecture and contract are ALREADY BUILT and
COMPILE-VERIFIED. You must follow them EXACTLY so your files drop in cleanly.

STEP 1 — READ THESE FILES FIRST (they are the contract and the gold-standard template):
  - ${SHADER_DIR}/SpectraCommon.h        (uniform struct + all helper functions you may use)
  - ${SHADER_DIR}/Color.metal             (template: how a shader file is structured)
  - ${CAT_DIR}/ColorEffects.swift         (template: how a descriptor file is structured)
  - ${ROOT}/Sources/Core/Parameters/EffectParameter.swift   (the parameter API + convenience constructors)
  - ${ROOT}/Sources/Core/Effects/EffectDescriptor.swift     (descriptor + EffectPass API)

THE CONTRACT (do not violate any of these):
  1. Each effect = one EffectDescriptor (Swift) + one or more Metal fragment functions.
  2. Every fragment function signature is EXACTLY:
       fragment float4 NAME(RasterizerData in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            texture2d<float> orig [[texture(1)]],
                            constant SpectraUniforms &u [[buffer(0)]]) { ... }
     - texture(0) = the effect's sampling source (previous pass / previous effect output)
     - texture(1) = the effect's ORIGINAL input, used ONLY for universal compositing
     - For single-pass effects, src and orig are the same texture.
  3. Read parameters from u.params[] in DECLARATION ORDER. A scalar/bool/integer/angle
     occupies ONE slot; a point occupies TWO (x,y); a color occupies FOUR (r,g,b,a).
     So if your parameter list is [sliderA, point P, sliderB], then:
       u.params[0]=A, u.params[1]=P.x, u.params[2]=P.y, u.params[3]=B.
  4. Angle parameters arrive in DEGREES (convert to radians in the shader if needed).
  5. ALWAYS return via the universal compositor:
       float3 base = spectra_tex(orig, in.uv).rgb;
       float3 c = spectra_tex(src, in.uv).rgb;
       ... compute float3 processed ...
       return spectra_compositeRGBA(base, processed, u);
     (compute 'base' from orig at the unmodified uv; never composite against a moved uv.)
  6. Use ONLY helper functions defined in SpectraCommon.h (sampling, color, noise,
     blend, geometry). Do NOT redefine them. If you genuinely need a new helper,
     mark it 'inline' and prefix its name with the category to avoid link collisions.
  7. Time-based animation uses u.time (seconds). Per-instance variation uses u.seed (0..1).
     Resolution is u.resolution (pixels); 1/resolution is u.texelSize.
  8. For multi-pass effects (e.g. separable blur), declare passes explicitly:
       import simd
       ... EffectDescriptor(id:..., name:..., category:..., passes: [
             EffectPass("fx_x_h", direction: SIMD2<Float>(1, 0)),
             EffectPass("fx_x_v", direction: SIMD2<Float>(0, 1))], parameters: [...])
     Read u.direction in the shader for separable direction. Intermediate passes may
     return raw float4 (no composite); the FINAL pass must composite against orig.
  9. Mark animated effects with isAnimated: true in the EffectDescriptor initializer.

NAMING (critical for linking — all fragment functions share one metallib):
  - Fragment function names MUST be globally unique. Prefix every function with
    "fx_<categoryKey>_" (e.g. fx_blur_gaussian_h, fx_crt_scanlines).
  - Descriptor ids MUST be unique and prefixed with the category key (e.g. "blur.gaussian").
  - The Swift enum MUST be named EXACTLY as specified and expose:
        static let all: [EffectDescriptor] = [ ... ]

QUALITY BAR:
  - Production quality. NO TODOs, NO stubs, NO placeholder math, NO comments promising
    future work. Every effect must do something visually real and tasteful.
  - Each parameter needs a sensible range and default that looks good at defaults.
  - Keep shaders efficient (bounded loops; reasonable tap counts).

VERIFY BEFORE FINISHING:
  - Compile your Metal file in isolation (the Metal toolchain is installed):
        xcrun metal -c "<your .metal path>" -I "${SHADER_DIR}" -o /tmp/<key>.air
    Fix every error until it compiles cleanly. Warnings are acceptable but avoid them.
  - Re-read your Swift file and confirm: enum name correct, every descriptor's
    parameter order matches the slot indices its shader reads, function names match
    between Swift (EffectPass/function:) and Metal, ids unique and prefixed.

DO NOT modify any file other than the two you are asked to create. Do NOT run a full
xcodebuild. Write exactly two files (the Swift descriptor file and the Metal shader file).
`

const CATEGORIES = [
  {
    key: 'sharpen', enumName: 'SharpenEffects', cat: '.sharpen',
    swift: `${CAT_DIR}/SharpenEffects.swift`, metal: `${SHADER_DIR}/Sharpen.metal`,
    brief: `Implement these 6 effects (neighbor sampling via u.texelSize):
      - Sharpen (amount): classic unsharp using a 3x3 high-pass.
      - Unsharp Mask (amount, radius): subtract a blurred sample set, add back scaled.
      - Clarity (amount): midtone local-contrast boost (mask by midtone luma).
      - Local Contrast (amount, radius): large-radius unsharp on luma only.
      - Detail Enhancement (amount): multi-radius high-frequency boost.
      - Edge Enhancement (amount): Sobel/Laplacian edge detect added back to the image.`,
  },
  {
    key: 'blur', enumName: 'BlurEffects', cat: '.blur',
    swift: `${CAT_DIR}/BlurEffects.swift`, metal: `${SHADER_DIR}/Blur.metal`,
    brief: `Implement these 8 effects. Use 'import simd' for multi-pass descriptors:
      - Gaussian Blur (radius): TWO-PASS separable (fx_blur_gaussian_h / _v) reading u.direction; weighted taps.
      - Lens Blur (radius): disc-shaped bokeh sampling (single pass, rotated golden-angle taps).
      - Directional Blur (angle degrees, length): sample along the angle.
      - Motion Blur (angle degrees, amount): like directional but with falloff.
      - Zoom Blur (center point, strength): sample toward/from center.
      - Bokeh Blur (radius, intensity): hexagonal/disc bokeh with highlight boost.
      - Depth Blur (focusCenter point, focusRange, strength): blur increasing with distance from focus band.
      - Tilt Shift (focusY, bandWidth, strength): horizontal in-focus band, blur above/below.
      Keep tap counts bounded (e.g. <= ~24). For single-pass blurs use golden-angle disc sampling.`,
  },
  {
    key: 'distort', enumName: 'DistortionEffects', cat: '.distortion',
    swift: `${CAT_DIR}/DistortionEffects.swift`, metal: `${SHADER_DIR}/Distortion.metal`,
    brief: `Implement these 12 UV-remap effects (sample src at a modified uv; composite base at original uv):
      - Warp (center point, amount): radial sinusoidal warp.
      - Bulge (center, radius, amount): magnify outward.
      - Pinch (center, radius, amount): squeeze inward.
      - Fish Eye (amount): strong barrel.
      - Barrel Distortion (k1, k2): lens barrel/pincushion.
      - Chromatic Distortion (amount): per-channel radial scale (RGB fringing).
      - Heat Distortion (intensity, speed): animated noise warp (isAnimated).
      - Wave (amplitude, frequency, speed): animated sine displacement (isAnimated).
      - Ripple (center, amplitude, frequency, speed): animated concentric ripples (isAnimated).
      - Swirl (center, angle, radius): rotate uv by angle falling off with radius.
      - Shockwave (center, time-driven radius via speed, width, amplitude): animated ring (isAnimated).
      - Perspective Warp (horizontal, vertical): keystone-style uv skew.`,
  },
  {
    key: 'crt', enumName: 'RetroEffects', cat: '.retro',
    swift: `${CAT_DIR}/RetroEffects.swift`, metal: `${SHADER_DIR}/Retro.metal`,
    brief: `Implement these 14 CRT/analog effects (use u.resolution for pixel-locked patterns):
      - CRT (scanline, mask, curvature, brightness): combined tube look.
      - CRT Advanced (scanline, maskStrength, curvature, bloom, vignette): richer combined.
      - Scanlines (count, strength): darken alternating lines.
      - Shadow Mask (strength, scale): RGB triad shadow mask.
      - Aperture Grille (strength, scale): vertical RGB stripes.
      - Curvature (amount): barrel + edge vignette + outside-black.
      - CRT Bloom (threshold, intensity): bright-area glow.
      - Phosphor Glow (intensity, persistence): soft phosphor smear/glow.
      - Composite Video (artifacts, bleed): luma/chroma crosstalk via YIQ.
      - RF Signal Loss (noise, dropout, speed): animated static + sync loss (isAnimated).
      - Color Bleed (amount): horizontal chroma smear.
      - NTSC (artifacts, fringing): YIQ bandlimited look.
      - PAL (artifacts, softness): PAL variant.
      - Analog Television (combined: scanlines+mask+bleed+vignette+slight noise, isAnimated).`,
  },
  {
    key: 'vhs', enumName: 'VHSEffects', cat: '.vhs',
    swift: `${CAT_DIR}/VHSEffects.swift`, metal: `${SHADER_DIR}/VHS.metal`,
    brief: `Implement these 12 VHS tape effects (most animated via u.time; isAnimated: true):
      - Tracking Errors (intensity, speed): horizontal band displacement that drifts vertically.
      - Tape Wrinkle (intensity, position, speed): a horizontal warped band.
      - Dropouts (density, speed): white/black streak dropouts.
      - Chromatic Drift (amount): chroma horizontally offset from luma.
      - Head Switching Noise (height, intensity): torn noisy strip at the bottom.
      - Horizontal Jitter (amount, speed): per-line horizontal shake.
      - Vertical Roll (speed): image rolls vertically.
      - Noise Bands (intensity, count, speed): moving noisy horizontal bands.
      - Tape Damage (intensity, speed): combined dropouts + tears + noise.
      - Generation Loss (amount): softening + chroma bleed + noise + slight desaturation (not animated).
      - Color Smear (amount): chroma horizontal lag/smear.
      - Audio-Reactive Tracking (intensity, speed): pulsing tracking error driven by a synthesized audio envelope from u.time (isAnimated).`,
  },
  {
    key: 'cam', enumName: 'CamcorderEffects', cat: '.camcorder',
    swift: `${CAT_DIR}/CamcorderEffects.swift`, metal: `${SHADER_DIR}/Camcorder.metal`,
    brief: `Implement consumer camcorder looks AND a procedural on-screen display. ~10 effects:
      Looks (color/grain/sharpness/interlacing combos): Consumer 90s, Digital 2000s, MiniDV, Hi8, VHS-C.
        Each: a tasteful preset look with 1-3 params (e.g. intensity, grain, sharpness). Use interlacing
        (darken/oddly-offset alternate fields based on u.resolution and u.time) where appropriate (isAnimated for interlacing/grain).
      - Interlacing (strength): standalone field interlacing (isAnimated).
      - Compression Artifacts (blockiness, strength): 8x8 block quantization / DCT-ish banding.
      - Auto Exposure Pulse (amount, speed): brightness breathing (isAnimated).
      - Autofocus Hunt (amount, speed): periodic slight defocus (blur) hunting (isAnimated).
      - REC OSD (showRec toggle, showTimecode toggle, showBattery toggle): draw a blinking red REC dot
        (top-left), a battery icon (top-right), and a ticking HH:MM:SS timecode derived from u.time using a
        procedural 7-segment renderer (top area). Implement the 7-seg digit drawing as inline helpers prefixed
        fx_cam_. (isAnimated). This gives an authentic running-camcorder overlay without CPU text.`,
  },
  {
    key: 'film', enumName: 'FilmEffects', cat: '.film',
    swift: `${CAT_DIR}/FilmEffects.swift`, metal: `${SHADER_DIR}/Film.metal`,
    brief: `Implement these 14 film effects (grain/leaks/flicker animated => isAnimated):
      - 16mm (grain, gateWeave, contrast): heavier grain + weave look.
      - 35mm (grain, halation): classic cinema look.
      - 70mm (grain low, richness): large-format clean look.
      - Kodak (warm color science): warm highlights, teal shadows tasteful.
      - Fuji (color science): greener/cooler tasteful.
      - Film Grain (intensity, size): animated luminance grain.
      - Dust (density, speed): animated dust specks.
      - Scratches (density, speed): animated vertical scratches.
      - Gate Weave (amount, speed): animated uv jitter (vertical/horizontal weave).
      - Light Leaks (intensity, position, speed): animated colored leak from an edge.
      - Halation (threshold, intensity): red/orange glow around highlights.
      - Bloom (threshold, intensity): bright bloom.
      - Flicker (intensity, speed): animated brightness flicker.
      - Film Burn (intensity, speed): animated burn/blowout from a moving hotspot.`,
  },
  {
    key: 'noise', enumName: 'NoiseEffects', cat: '.noise',
    swift: `${CAT_DIR}/NoiseEffects.swift`, metal: `${SHADER_DIR}/Noise.metal`,
    brief: `Implement a procedural noise framework: 14 noise effects. Common params per effect:
      intensity (0..1), scale (0.1..64), speed (0..5), colorize (0..1 toggle-like slider), and use u.seed.
      Animate with u.time*speed (isAnimated: true). Add the noise to the image (or modulate) and composite.
      Types (use the header noise helpers where available):
      - White, Gaussian (spectra_gaussianNoise), Blue (approx: high-freq hashed minus low-freq), Pink (1/f
        via summed octaves with decreasing amplitude), Brown (heavier low-freq fbm), Perlin (spectra_gradientNoise),
        Simplex (spectra_simplex), Cellular (spectra_cellular F1), Film Grain (luma-only animated),
        Sensor Noise (per-channel read noise + slight hot pixels), Compression Noise (8x8 blocky noise),
        Dust Noise (sparse bright specks), Speckle (multiplicative), Digital Noise (quantized bit-ish noise).
      colorize blends between monochrome noise and per-channel colored noise.`,
  },
  {
    key: 'pixel', enumName: 'PixelEffects', cat: '.pixel',
    swift: `${CAT_DIR}/PixelEffects.swift`, metal: `${SHADER_DIR}/Pixel.metal`,
    brief: `Implement ~12 pixel effects (use u.resolution for pixel grids; spectra_texPoint for nearest):
      - Pixelation (blockSize): snap uv to a grid.
      - Pixel Sort (threshold, length, vertical toggle): approximate by smearing pixels above/below a luma
        threshold along a direction (bounded loop).
      - Dithering (levels, strength): hashed dither before quantization.
      - Ordered Dither (levels, scale): generic ordered dither.
      - Bayer Dither (levels): 4x4 Bayer matrix dither (define the matrix inline, prefixed).
      - Floyd-Steinberg (levels): approximate error-diffusion with a small neighborhood kernel.
      - Color Quantization (levels): reduce palette via rounding.
      - Retro Resolution (targetWidth): downsample to a low res then nearest-upscale.
      - Game Boy (off-strength): 4-shade green DMG palette + low-res.
      - PS1 (jitter, dither, depth): vertex-snap-style jitter + dithering + 16-bit color.
      - Nintendo 64 (blur, dither): characteristic soft + dithered look.
      - Arcade (scanline, palette): CRT-arcade low-res palette look.`,
  },
  {
    key: 'glitch', enumName: 'GlitchEffects', cat: '.glitch',
    swift: `${CAT_DIR}/GlitchEffects.swift`, metal: `${SHADER_DIR}/Glitch.metal`,
    brief: `Implement ~12 glitch effects (most animated via u.time => isAnimated):
      - Datamosh (intensity, speed): blocky directional smear driven by noise.
      - RGB Split (amount, angle): offset channels (not necessarily animated).
      - Scan Corruption (intensity, speed): random horizontal line shifts.
      - Frame Tearing (intensity, speed): a moving horizontal tear seam offset.
      - Signal Corruption (intensity, speed): blocks of garbled/inverted color.
      - Digital Failure (intensity, speed): combined dropouts + color blocks + noise.
      - Compression Glitch (blockiness, intensity, speed): macroblock displacement.
      - Buffer Corruption (intensity, speed): rows offset by a hashed amount.
      - Bit Crush (bits): reduce bit depth per channel (not animated).
      - Macroblocking (blockSize, intensity): average 8x8/16x16 blocks with errors.
      - Frame Repeat (rate): freeze to a time-quantized look (approximate by snapping u.time -> static hash seed).
      - Frame Skip (rate, intensity): periodic jump/displacement (animated).`,
  },
  {
    key: 'env', enumName: 'EnvironmentEffects', cat: '.environment',
    swift: `${CAT_DIR}/EnvironmentEffects.swift`, metal: `${SHADER_DIR}/Environment.metal`,
    brief: `Implement these 10 atmospheric overlays (animated ones isAnimated):
      - Rain (intensity, speed, angle): animated streaks + subtle refraction.
      - Fog (density, height, speed): animated soft fog (height-based, drifting noise).
      - Snow (intensity, speed, size): animated falling flakes.
      - Dust (intensity, speed): animated floating motes.
      - Underwater (intensity, speed): animated caustic warble + blue tint.
      - Heat Haze (intensity, speed): animated rising shimmer (uv warp).
      - God Rays (sun point, intensity, decay): radial light scattering from sun toward pixel.
      - Sun Glare (sun point, intensity): bright bloom/flare at the sun position.
      - Lens Flare (sun point, intensity): ghosts + halo along the sun-center axis.
      - Cloud Overlay (coverage, speed): animated fbm cloud shadows/overlay.`,
  },
  {
    key: 'a11y', enumName: 'AccessibilityEffects', cat: '.accessibility',
    swift: `${CAT_DIR}/AccessibilityEffects.swift`, metal: `${SHADER_DIR}/Accessibility.metal`,
    brief: `Implement these 7 accessibility effects:
      - High Contrast (amount): increase contrast + clamp around midtone.
      - Color Blind Modes (mode options: Protanopia/Deuteranopia/Tritanopia, daltonize amount): simulate AND
        optionally daltonize (correct) based on a second slider; use an options parameter for mode.
      - Focus Spotlight (center point, radius, dimAmount): keep a circle bright, dim the rest.
      - Background Dim (amount): uniform dim.
      - Reading Mode (warmth, contrast): sepia-ish low-blue comfortable reading tint.
      - Night Mode (amount): dim + warm + reduce harsh whites.
      - Blue Light Reduction (amount): reduce blue channel warmly.`,
  },
]

phase('Generate')

const REPORT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    category: { type: 'string' },
    enumName: { type: 'string' },
    swiftPath: { type: 'string' },
    metalPath: { type: 'string' },
    effectCount: { type: 'integer' },
    effectIDs: { type: 'array', items: { type: 'string' } },
    fragmentFunctions: { type: 'array', items: { type: 'string' } },
    metalCompiles: { type: 'boolean' },
    metalError: { type: 'string' },
    notes: { type: 'string' },
  },
  required: ['category', 'enumName', 'effectCount', 'fragmentFunctions', 'metalCompiles'],
}

const results = await parallel(CATEGORIES.map((cat) => () =>
  agent(
    `${CONTRACT}

============================================================
YOUR CATEGORY: ${cat.enumName}  (EffectCategory: ${cat.cat})
Swift file to CREATE: ${cat.swift}
Metal file to CREATE: ${cat.metal}
Function/id prefix: fx_${cat.key}_  /  "${cat.key === 'crt' ? 'retro' : cat.key === 'distort' ? 'distortion' : cat.key === 'cam' ? 'camcorder' : cat.key === 'env' ? 'environment' : cat.key === 'a11y' ? 'accessibility' : cat.key}."
(Use a clean, human descriptor id prefix matching the category name, e.g. "blur.gaussian", "crt"->"retro.crt", "distort"->"distortion.warp", "cam"->"camcorder.miniDV", "env"->"environment.rain", "a11y"->"accessibility.nightMode".)

EFFECTS TO IMPLEMENT:
${cat.brief}

Now: read the contract files, write the two files, compile the Metal in isolation,
fix until clean, then report. Remember: only create those two files.`,
    { label: `gen:${cat.key}`, phase: 'Generate', schema: REPORT_SCHEMA }
  ).then((r) => r || { category: cat.key, enumName: cat.enumName, effectCount: 0, fragmentFunctions: [], metalCompiles: false, metalError: 'agent returned null' })
))

return {
  categories: results.map((r) => ({
    category: r.category,
    enumName: r.enumName,
    effects: r.effectCount,
    functions: (r.fragmentFunctions || []).length,
    metalCompiles: r.metalCompiles,
    error: r.metalError || '',
  })),
  totalEffects: results.reduce((sum, r) => sum + (r.effectCount || 0), 0),
  totalFunctions: results.reduce((sum, r) => sum + ((r.fragmentFunctions || []).length), 0),
  failures: results.filter((r) => !r.metalCompiles).map((r) => r.category),
}
