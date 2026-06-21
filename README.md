# Spectra

Spectra is a desktop-wide GPU visual effects engine for macOS. It captures your displays in real time with ScreenCaptureKit, runs them through a Metal shader pipeline, and presents the processed result through a fullscreen, click-through overlay. Think ReShade and RetroArch shader presets, applied to the whole Mac desktop, with a native studio for building and stacking effects.

## What it does

- Captures every connected display at native resolution and refresh rate (60Hz and 120Hz ProMotion).
- Processes frames entirely on the GPU. There is no CPU image processing and the capture-to-texture path is zero-copy through a `CVMetalTextureCache`.
- Renders the result back through a per-display overlay window that clicks through to the real desktop beneath it. The overlay presents through an EDR-capable 16-bit layer, so it is HDR-aware on capable displays, follows the user across Spaces, and shades native-fullscreen Spaces by elevating to the shielding window level for the duration of the fullscreen Space.
- When a display's stack is made up entirely of per-channel color operations (brightness, contrast, exposure, gamma, black/white point, invert, posterize, solarize, levels), Spectra bakes it into a scanout transfer LUT and applies it through `CGSetDisplayTransferByTable` instead of the overlay. The grade then holds across every Space, swipe, and full-screen app without any window involved, and the original profile is restored on stop.
- Ships 168 built-in effects across 14 categories, almost all real Metal fragment shaders (plus three desktop-level system effects).
- Stacks effects in any order, with per-effect strength, opacity, blend amount, and one of 16 blend modes applied to every effect for free.
- Stores presets, and includes a curated library (Noir, Cyberpunk, Matrix, CRT, VHS, Frutiger Aero, Studio Ghibli, Comic Book, Impressionism, and more).
- Lets you build new effects visually by composing existing building blocks, with a live preview, auto-generated controls, exposed parameters, and a generated thumbnail. No graphics programming required.
- Imports and exports `.metal`, `.shader`, `.json`, and `.spectra` files, compiling and validating imported shaders before they ever touch the renderer. Drop a shader file into the library folder and Spectra imports and hot-reloads it automatically.

## The studio

One unified workspace, no modes. Everything lives in a single coherent window:

- **Effect Library** on the left: the primary interface. Search, filter by category, tag, or favorites, and add effects to the stack. Custom effects can be edited, duplicated, exported, or deleted in place; multi-select adds several at once.
- **Live Preview** in the center: the processed result of the selected display, rendered continuously.
- **Effect Stack and Parameters** on the right: add, remove, reorder (drag and drop), duplicate, rename, group, enable, and disable layered effects, with universal and effect-specific controls beneath.
- **Performance** along the bottom on demand: frame rate, GPU and CPU time, latency, dropped frames, pipeline analysis, and on-demand per-effect cost profiling.

A menu bar item is always available for quick pause/unpause, preset switching (grouped by category), an intensity slider, and a quality slider with an Auto toggle that hands control to the adaptive governor. Live fps and latency read at a glance, with shortcuts into the Studio and Settings windows.

## Authoring effects

There is one editor: a visual composer. You assemble a new effect from a palette of building blocks (color operations, blurs, distortions, noise, blends), tune each with the standard inspector, watch it live, choose which parameters to expose, set its name, category, tags, and description, and save it into the library as a reusable effect. Authored effects can be exported and shared.

Shader authors who prefer to write Metal directly do so in their own editor and drop the `.metal` or `.shader` file into the library folder. Spectra compiles it against its shader prelude, infers controls from the parameters it references, validates it, and registers it without a relaunch. A misbehaving shader can never crash the renderer: compile failures report diagnostics, and a GPU fault disables the offending effect automatically.

## Effect library

168 effects, grouped into 14 categories:

- **Color** (26): brightness, contrast, saturation, vibrance, exposure, gamma, highlights, shadows, whites, blacks, black/white point, temperature, tint, sepia, invert, posterize, solarize, color balance, levels, hue shift, channel mixer, tone curve, freehand curves, color LUT, gradient map.
- **Sharpen** (6): sharpen, unsharp mask, clarity, local contrast, detail enhancement, edge enhancement.
- **Blur** (8): gaussian (separable), lens, directional, motion, zoom, bokeh, depth, tilt shift.
- **Distortion** (12): warp, bulge, pinch, fish eye, barrel, chromatic, heat, wave, ripple, swirl, shockwave, perspective.
- **Retro / CRT** (14): CRT, CRT advanced, scanlines, shadow mask, aperture grille, curvature, bloom, phosphor glow with temporal persistence, composite video, RF signal loss, color bleed, NTSC, PAL, analog television.
- **VHS** (12): tracking, wrinkle, dropouts, chroma drift, head switch, jitter, vertical roll, noise bands, damage, generation loss, color smear, audio-reactive tracking.
- **Camcorder** (10): consumer 90s, digital 2000s, MiniDV, Hi8, VHS-C, interlacing, compression, auto-exposure pulse, autofocus hunt, REC on-screen display with ticking timecode, date stamp, and zoom readout.
- **Film** (16): 16mm, 35mm, 70mm, Kodak, Fuji, grain, dust, scratches, gate weave, debris, light leaks, halation, bloom, glow, flicker, burn.
- **Noise** (14): white, gaussian, blue, pink, brown, perlin, simplex, cellular, sensor grain, sensor, compression, dust, speckle, digital.
- **Pixel** (12): pixelation, pixel sort, dithering, ordered dither, bayer, floyd-steinberg, color quantization, retro resolution, Game Boy, PS1, N64, arcade.
- **Glitch** (13): datamosh, RGB split, scan corruption, frame tearing, signal corruption, digital failure, compression glitch, buffer corruption, bit crush, macroblocking, frame repeat, frame skip, digital rain. Datamosh and the frame repeat/skip effects use a true previous-frame feedback texture.
- **Environment** (11): rain, fog, snow, dust motes, bubbles, underwater, heat haze, god rays, sun glare, lens flare, cloud overlay.
- **Artistic** (11): oil paint (colour-region cells), painterly (SLIC superpixels), flatten, quantize, cel, comic, ink, halftone, hatch, paper, relief.
- **System / Desktop** (3): window transparency, automatic window layout, and an adaptive desktop tint (driven by yabai and a desktop-level overlay rather than a fragment shader).

Every effect automatically carries strength, opacity, blend amount, blend mode, and an enable toggle, composited by a single shared helper so the behavior is consistent across the whole library. Curves, gradients, and LUTs are edited with dedicated controls and baked into auxiliary GPU textures.

## Multi-monitor

Each display has its own effect stack and its own preset, capturing and rendering independently at its native resolution and refresh rate. Displays can be enabled or disabled individually, and hot-plugging is handled live. Per-display stacks and presets persist across launches.

## Performance

Spectra reports per-display and combined frame rate, CPU encode time, GPU time, frame interval, capture-to-present latency, dropped frames, GPU pass count, and VRAM in use. A pipeline analysis panel summarizes the resolved chain, and an on-demand profiler measures each effect's real GPU cost in isolation. When adaptive quality is on and GPU time runs past the display's frame budget, it lowers capture resolution in steps and restores it when headroom returns.

The target is under 16ms latency with minimal CPU use. Rendering is driven by a per-window `CAMetalDisplayLink` whose callback fires off the main run loop on a dedicated render thread, gated by triple buffering. Intermediate textures are recycled through a pool to avoid per-frame allocation.

## Requirements

- macOS 15 or later (built and tested against the macOS 26 SDK).
- Apple Silicon.
- Screen Recording permission, which Spectra requests on first use.

## Build and run

See [BUILD.md](BUILD.md). The short version:

```sh
xcodegen generate
open Spectra.xcodeproj   # then run, or:
xcodebuild -project Spectra.xcodeproj -scheme Spectra -configuration Debug \
  -destination 'platform=macOS' build
```

On first launch, grant Screen Recording access in System Settings when prompted, then click the green Start button in the toolbar to begin rendering. The same button turns red ("Stop") while effects are running, and the menu bar item offers Pause/Unpause.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the module breakdown, the effect contract, and the render pipeline. The codebase is organized into focused modules (Core, Capture, Render, Effects, Shaders, Presets, Storage, Performance, Editor, Engine, UI, App) wired together through a single injected `SpectraEngine` coordinator.

## License

Provided as-is for evaluation.
